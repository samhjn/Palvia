import Foundation
import WebKit
import Observation

@MainActor
@Observable
final class BrowserService: NSObject {
    static let shared = BrowserService()

    private(set) var webView: WKWebView
    private(set) var currentURL: URL?
    private(set) var pageTitle: String?
    private(set) var isLoading: Bool = false
    private(set) var canGoBack: Bool = false
    private(set) var canGoForward: Bool = false
    private(set) var estimatedProgress: Double = 0

    /// When non-nil the browser is showing a local Agent HTML file and only
    /// `file://` URLs under this directory are allowed by the navigation policy.
    private(set) var currentAgentScope: URL?

    /// Notification posted when a local Agent file is loaded and the UI should
    /// switch to the Browser tab.
    static let switchToBrowserTabNotification = Notification.Name("BrowserService.switchToBrowserTab")

    // MARK: - Mutex Lock

    private(set) var lockedBySessionId: UUID?
    private(set) var lockedByAgentName: String?
    private(set) var lockTimestamp: Date?

    private static let lockTimeout: TimeInterval = 120

    var isAgentControlled: Bool {
        guard lockedBySessionId != nil, let ts = lockTimestamp else { return false }
        if Date().timeIntervalSince(ts) > Self.lockTimeout {
            forceReleaseLock()
            return false
        }
        return true
    }

    /// Try to acquire the browser lock for an agent session.
    /// Returns nil on success, or an error message if locked by another session.
    func acquireLock(sessionId: UUID, agentName: String) -> String? {
        expireStaleLock()
        if let existing = lockedBySessionId, existing != sessionId {
            return "[Error] Browser is locked by agent \"\(lockedByAgentName ?? "unknown")\" (session \(existing.uuidString.prefix(8))…). Wait for it to finish or ask the user to take over from the Browser tab."
        }
        lockedBySessionId = sessionId
        lockedByAgentName = agentName
        lockTimestamp = Date()
        return nil
    }

    /// Refresh the lock timestamp (called on each successful tool operation).
    func refreshLock(sessionId: UUID) {
        if lockedBySessionId == sessionId {
            lockTimestamp = Date()
        }
    }

    /// Release the lock for a specific session.
    func releaseLock(sessionId: UUID) {
        if lockedBySessionId == sessionId {
            forceReleaseLock()
        }
    }

    /// Force-release regardless of owner (user "Take Over").
    func forceReleaseLock() {
        lockedBySessionId = nil
        lockedByAgentName = nil
        lockTimestamp = nil
    }

    private func expireStaleLock() {
        guard let ts = lockTimestamp else { return }
        if Date().timeIntervalSince(ts) > Self.lockTimeout {
            forceReleaseLock()
        }
    }

    private var navigationContinuation: CheckedContinuation<Bool, Never>?
    private var kvoTokens: [NSKeyValueObservation] = []

    private override init() {
        let config = WKWebViewConfiguration()
        config.allowsInlineMediaPlayback = true
        config.mediaTypesRequiringUserActionForPlayback = []
        self.webView = WKWebView(frame: .zero, configuration: config)
        super.init()
        webView.navigationDelegate = self
        setupKVO()
    }

    private func setupKVO() {
        kvoTokens.append(webView.observe(\.isLoading) { [weak self] wv, _ in
            Task { @MainActor in self?.isLoading = wv.isLoading }
        })
        kvoTokens.append(webView.observe(\.canGoBack) { [weak self] wv, _ in
            Task { @MainActor in self?.canGoBack = wv.canGoBack }
        })
        kvoTokens.append(webView.observe(\.canGoForward) { [weak self] wv, _ in
            Task { @MainActor in self?.canGoForward = wv.canGoForward }
        })
        kvoTokens.append(webView.observe(\.estimatedProgress) { [weak self] wv, _ in
            Task { @MainActor in self?.estimatedProgress = wv.estimatedProgress }
        })
        kvoTokens.append(webView.observe(\.url) { [weak self] wv, _ in
            Task { @MainActor in self?.currentURL = wv.url }
        })
        kvoTokens.append(webView.observe(\.title) { [weak self] wv, _ in
            Task { @MainActor in self?.pageTitle = wv.title }
        })
    }

    // MARK: - Close / Reset

    func closeAllPages() {
        webView.load(URLRequest(url: URL(string: "about:blank")!))
        currentURL = nil
        pageTitle = nil
        currentAgentScope = nil
    }

    // MARK: - Navigation

    @discardableResult
    func navigate(to urlString: String) async -> Result<String, BrowserError> {
        guard let url = URL(string: urlString) ?? URL(string: "https://\(urlString)") else {
            return .failure(.invalidURL(urlString))
        }
        currentAgentScope = nil
        let request = URLRequest(url: url)
        webView.load(request)
        let success = await waitForNavigation(timeout: 30)
        if success {
            return .success("Navigated to \(webView.url?.absoluteString ?? urlString) — \(webView.title ?? "")")
        } else {
            return .failure(.navigationTimeout)
        }
    }

    // MARK: - Local Agent File

    /// Load an HTML file from the Agent's file directory in the browser.
    /// The entire Agent root directory is set as the readable scope so that
    /// relative references to JS, CSS, images, etc. within the Agent work.
    @discardableResult
    func loadAgentFile(fileURL: URL, agentId: UUID) async -> Result<String, BrowserError> {
        let agentDir = AgentFileManager.shared.agentDirectory(for: agentId)
        currentAgentScope = agentDir.standardizedFileURL
        webView.loadFileURL(fileURL, allowingReadAccessTo: agentDir)
        let success = await waitForNavigation(timeout: 15)
        if success {
            NotificationCenter.default.post(name: Self.switchToBrowserTabNotification, object: nil)
            return .success("Loaded \(fileURL.lastPathComponent)")
        } else {
            return .failure(.navigationTimeout)
        }
    }

    func goBack() async -> Result<String, BrowserError> {
        guard webView.canGoBack else { return .failure(.cannotGoBack) }
        webView.goBack()
        let _ = await waitForNavigation(timeout: 15)
        return .success("Went back to \(webView.url?.absoluteString ?? "unknown")")
    }

    func goForward() async -> Result<String, BrowserError> {
        guard webView.canGoForward else { return .failure(.cannotGoForward) }
        webView.goForward()
        let _ = await waitForNavigation(timeout: 15)
        return .success("Went forward to \(webView.url?.absoluteString ?? "unknown")")
    }

    func reload() async -> Result<String, BrowserError> {
        webView.reload()
        let _ = await waitForNavigation(timeout: 15)
        return .success("Reloaded \(webView.url?.absoluteString ?? "unknown")")
    }

    // MARK: - JavaScript Execution

    private static let jsErrorPrefix = "__ICLAW_JS_ERR__:"

    func executeJavaScript(_ script: String) async -> Result<String, BrowserError> {
        // Wrap in try-catch to prevent errors from propagating to the
        // host page's error boundaries (e.g. React ErrorBoundary).
        let safeScript = "try { \(script) } catch(__iclaw_e) { '\(Self.jsErrorPrefix)' + String(__iclaw_e) }"
        do {
            let result = try await webView.evaluateJavaScript(safeScript)
            if let result = result {
                let str = String(describing: result)
                if str.hasPrefix(Self.jsErrorPrefix) {
                    return .failure(.javaScriptError(String(str.dropFirst(Self.jsErrorPrefix.count))))
                }
                return .success(str)
            }
            return .success("(undefined)")
        } catch {
            return .failure(.javaScriptError(error.localizedDescription))
        }
    }

    /// Execute user-provided JavaScript with `return` and `await` support.
    /// Uses `callAsyncJavaScript` which wraps code in an async function body,
    /// and includes try-catch for error isolation from the host page.
    func executeUserJavaScript(_ code: String) async -> Result<String, BrowserError> {
        let wrappedCode = """
        try {
            \(code)
        } catch(__iclaw_e) {
            return '\(Self.jsErrorPrefix)' + String(__iclaw_e);
        }
        """
        do {
            let result = try await webView.callAsyncJavaScript(
                wrappedCode, arguments: [:], in: nil, contentWorld: .page
            )
            if let result = result {
                let str = String(describing: result)
                if str.hasPrefix(Self.jsErrorPrefix) {
                    return .failure(.javaScriptError(String(str.dropFirst(Self.jsErrorPrefix.count))))
                }
                return .success(str)
            }
            return .success("(undefined)")
        } catch {
            return .failure(.javaScriptError(error.localizedDescription))
        }
    }

    // MARK: - Page Content

    func getPageInfo(includeHTML: Bool = false, simplified: Bool = true) async -> Result<String, BrowserError> {
        let url = webView.url?.absoluteString ?? "(no page loaded)"
        let title = webView.title ?? "(untitled)"

        var info = "URL: \(url)\nTitle: \(title)"

        if includeHTML {
            let script = simplified ? Self.simplifiedDOMScript : "document.documentElement.outerHTML"
            let htmlResult = await executeJavaScript(script)
            switch htmlResult {
            case .success(let html):
                let truncated = html.count > 15000 ? String(html.prefix(15000)) + "\n...(truncated)" : html
                info += "\n\nContent:\n\(truncated)"
            case .failure(let err):
                info += "\n\n[Failed to get content: \(err.localizedDescription)]"
            }
        }

        return .success(info)
    }

    // MARK: - Keyboard Suppression

    /// Dismiss the keyboard by resigning first responder from the web view.
    func dismissKeyboard() {
        webView.resignFirstResponder()
        webView.endEditing(true)
        // Also blur any focused element inside the web content
        webView.evaluateJavaScript("document.activeElement && document.activeElement.blur()") { _, _ in }
    }

    /// If the browser is agent-controlled, dismiss the keyboard after a short delay
    /// to allow the JS operation to complete first.
    private func dismissKeyboardIfAgentControlled() {
        guard isAgentControlled else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
            self?.dismissKeyboard()
        }
    }

    // MARK: - Element Interaction

    func click(elementId: String? = nil, xpath: String? = nil, selector: String? = nil) async -> Result<String, BrowserError> {
        guard let resolved = resolveTarget(elementId: elementId, xpath: xpath, selector: selector) else {
            return .failure(.elementNotFound("No element_id, xpath, or selector provided"))
        }
        let desc = (elementId ?? xpath ?? selector ?? "").replacingOccurrences(of: "'", with: "\\'")
        let script = """
        (function() {
            const el = \(resolved);
            if (!el) return JSON.stringify({error: 'Element not found: \(desc)'});
            el.click();
            var r = JSON.stringify({ok: true, tag: el.tagName, text: (el.textContent || '').trim().substring(0, 100)});
            if (document.activeElement) document.activeElement.blur();
            return r;
        })()
        """
        let result = await executeJavaScript(script)
        dismissKeyboardIfAgentControlled()
        return parseJSResult(result, action: "click")
    }

    func input(elementId: String? = nil, xpath: String? = nil, selector: String? = nil, text: String, clearFirst: Bool = true) async -> Result<String, BrowserError> {
        guard let resolved = resolveTarget(elementId: elementId, xpath: xpath, selector: selector) else {
            return .failure(.elementNotFound("No element_id, xpath, or selector provided"))
        }
        let desc = (elementId ?? xpath ?? selector ?? "").replacingOccurrences(of: "'", with: "\\'")
        let clearScript = clearFirst ? "el.value = '';" : ""
        let script = """
        (function() {
            const el = \(resolved);
            if (!el) return JSON.stringify({error: 'Element not found: \(desc)'});
            el.focus();
            \(clearScript)
            const nativeInputValueSetter = Object.getOwnPropertyDescriptor(window.HTMLInputElement.prototype, 'value')?.set
                || Object.getOwnPropertyDescriptor(window.HTMLTextAreaElement.prototype, 'value')?.set;
            if (nativeInputValueSetter) {
                nativeInputValueSetter.call(el, \(jsEscape(text)));
            } else {
                el.value = \(jsEscape(text));
            }
            el.dispatchEvent(new Event('input', {bubbles: true}));
            el.dispatchEvent(new Event('change', {bubbles: true}));
            el.blur();
            return JSON.stringify({ok: true, tag: el.tagName, value: el.value.substring(0, 100)});
        })()
        """
        let result = await executeJavaScript(script)
        dismissKeyboardIfAgentControlled()
        return parseJSResult(result, action: "input")
    }

    func select(elementId: String? = nil, xpath: String? = nil, selector: String? = nil, value: String) async -> Result<String, BrowserError> {
        guard let resolved = resolveTarget(elementId: elementId, xpath: xpath, selector: selector) else {
            return .failure(.elementNotFound("No element_id, xpath, or selector provided"))
        }
        let desc = (elementId ?? xpath ?? selector ?? "").replacingOccurrences(of: "'", with: "\\'")
        let script = """
        (function() {
            const el = \(resolved);
            if (!el || el.tagName !== 'SELECT') return JSON.stringify({error: 'SELECT element not found: \(desc)'});
            el.value = \(jsEscape(value));
            el.dispatchEvent(new Event('change', {bubbles: true}));
            el.blur();
            return JSON.stringify({ok: true, selectedValue: el.value, selectedText: el.options[el.selectedIndex]?.text || ''});
        })()
        """
        let result = await executeJavaScript(script)
        dismissKeyboardIfAgentControlled()
        return parseJSResult(result, action: "select")
    }

    func extract(elementId: String? = nil, xpath: String? = nil, selector: String? = nil, attribute: String? = nil) async -> Result<String, BrowserError> {
        guard let resolved = resolveTarget(elementId: elementId, xpath: xpath, selector: selector, all: true) else {
            return .failure(.elementNotFound("No element_id, xpath, or selector provided"))
        }
        let desc = (elementId ?? xpath ?? selector ?? "").replacingOccurrences(of: "'", with: "\\'")
        let attrCode: String
        if let attribute = attribute {
            attrCode = "el.getAttribute(\(jsEscape(attribute))) || ''"
        } else {
            attrCode = "(el.innerText || el.textContent || '').trim()"
        }
        let script = """
        (function() {
            const els = \(resolved);
            if (els.length === 0) return JSON.stringify({error: 'No elements found: \(desc)'});
            const results = [];
            els.forEach(function(el, i) {
                if (i < 50) results.push(\(attrCode));
            });
            return JSON.stringify({ok: true, count: els.length, results: results});
        })()
        """
        let result = await executeJavaScript(script)
        switch result {
        case .success(let json):
            if let data = json.data(using: .utf8),
               let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                if let error = dict["error"] as? String {
                    return .failure(.elementNotFound(error))
                }
                let count = dict["count"] as? Int ?? 0
                let results = dict["results"] as? [String] ?? []
                let output = results.enumerated().map { "[\($0.offset)] \($0.element)" }.joined(separator: "\n")
                return .success("\(count) element(s) found:\n\(output)")
            }
            return .success(json)
        case .failure(let err):
            return .failure(err)
        }
    }

    func waitForElement(elementId: String? = nil, xpath: String? = nil, selector: String? = nil, timeout: TimeInterval = 10) async -> Result<String, BrowserError> {
        guard let resolved = resolveTarget(elementId: elementId, xpath: xpath, selector: selector) else {
            return .failure(.elementNotFound("No element_id, xpath, or selector provided"))
        }
        let desc = elementId ?? xpath ?? selector ?? ""
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline, !Task.isCancelled {
            let script = "(\(resolved)) !== null"
            let result = await executeJavaScript(script)
            if case .success(let value) = result, value == "1" || value == "true" {
                return .success("Element found: \(desc)")
            }
            try? await Task.sleep(for: .milliseconds(300))
            if Task.isCancelled { break }
        }
        return .failure(.waitTimeout(desc, timeout))
    }

    func scroll(direction: String = "down", pixels: Int = 500) async -> Result<String, BrowserError> {
        let y = direction == "up" ? -pixels : pixels
        let script = "window.scrollBy(0, \(y)); JSON.stringify({scrollY: window.scrollY, scrollHeight: document.body.scrollHeight})"
        let result = await executeJavaScript(script)
        switch result {
        case .success(let json):
            return .success("Scrolled \(direction) \(abs(pixels))px — \(json)")
        case .failure(let err):
            return .failure(err)
        }
    }

    // MARK: - Private Helpers

    private func waitForNavigation(timeout: TimeInterval) async -> Bool {
        if !webView.isLoading { return true }
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                self.navigationContinuation = continuation
                Task {
                    try? await Task.sleep(for: .seconds(timeout))
                    if let c = self.navigationContinuation {
                        self.navigationContinuation = nil
                        c.resume(returning: false)
                    }
                }
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                if let c = self?.navigationContinuation {
                    self?.navigationContinuation = nil
                    c.resume(returning: false)
                }
            }
        }
    }

    private func completeNavigation(success: Bool) {
        if let c = navigationContinuation {
            navigationContinuation = nil
            c.resume(returning: success)
        }
    }

    // MARK: - Selector Resolution

    /// Matches `:contains("text")` or `:contains('text')` pseudo-selectors.
    static let containsRegex = try! NSRegularExpression(
        pattern: #":contains\(([\"'])(.*?)\1\)"#
    )

    /// Convert a selector to a JS expression that evaluates to the matched element(s).
    /// Handles `:contains("text")` by converting to querySelectorAll + textContent filter,
    /// since `:contains()` is not a valid native CSS pseudo-selector.
    func resolveSelector(_ selector: String, all: Bool = false) -> String {
        let range = NSRange(selector.startIndex..., in: selector)
        guard let match = Self.containsRegex.firstMatch(in: selector, range: range) else {
            return all
                ? "document.querySelectorAll(\(jsEscape(selector)))"
                : "document.querySelector(\(jsEscape(selector)))"
        }
        let matchRange = Range(match.range, in: selector)!
        let baseSelector = String(selector[..<matchRange.lowerBound])
        let textRange = Range(match.range(at: 2), in: selector)!
        let searchText = String(selector[textRange])

        if all {
            return "Array.from(document.querySelectorAll(\(jsEscape(baseSelector)))).filter(function(el){return (el.textContent||'').indexOf(\(jsEscape(searchText)))!==-1})"
        } else {
            return "Array.from(document.querySelectorAll(\(jsEscape(baseSelector)))).find(function(el){return (el.textContent||'').indexOf(\(jsEscape(searchText)))!==-1})||null"
        }
    }

    func jsEscape(_ str: String) -> String {
        let escaped = str
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "'", with: "\\'")
            .replacingOccurrences(of: "\n", with: "\\n")
            .replacingOccurrences(of: "\r", with: "\\r")
        return "'\(escaped)'"
    }

    // MARK: - Element ID & XPath Resolution

    /// Resolve element(s) by data-palvia-id attribute.
    func resolveElementId(_ elementId: String, all: Bool = false) -> String {
        if all {
            return "document.querySelectorAll('[data-palvia-id=' + \(jsEscape(elementId)) + ']')"
        } else {
            return "document.querySelector('[data-palvia-id=' + \(jsEscape(elementId)) + ']')"
        }
    }

    /// Resolve element(s) by XPath expression.
    func resolveXPath(_ xpath: String, all: Bool = false) -> String {
        if all {
            return "(function(){var r=[];var x=document.evaluate(\(jsEscape(xpath)),document,null,XPathResult.ORDERED_NODE_SNAPSHOT_TYPE,null);for(var i=0;i<x.snapshotLength;i++)r.push(x.snapshotItem(i));return r})()"
        } else {
            return "(function(){var x=document.evaluate(\(jsEscape(xpath)),document,null,XPathResult.FIRST_ORDERED_NODE_TYPE,null);return x.singleNodeValue})()"
        }
    }

    /// Unified resolution: element_id > xpath > selector. Returns nil if none provided.
    func resolveTarget(elementId: String?, xpath: String?, selector: String?, all: Bool = false) -> String? {
        if let eid = elementId { return resolveElementId(eid, all: all) }
        if let xp = xpath { return resolveXPath(xp, all: all) }
        if let sel = selector { return resolveSelector(sel, all: all) }
        return nil
    }

    private func parseJSResult(_ result: Result<String, BrowserError>, action: String) -> Result<String, BrowserError> {
        switch result {
        case .success(let json):
            if let data = json.data(using: .utf8),
               let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                if let error = dict["error"] as? String {
                    return .failure(.elementNotFound(error))
                }
                return .success("\(action) succeeded: \(json)")
            }
            return .success(json)
        case .failure(let err):
            return .failure(err)
        }
    }

    /// Extracts a simplified readable DOM: text, links, inputs, buttons, etc.
    /// Interactive elements are tagged with 5-char random IDs (data-palvia-id) for easy reference.
    private static let simplifiedDOMScript = """
    (function() {
        var _ids = new Set();
        var _chars = 'abcdefghijkmnpqrstuvwxyz23456789';
        function genId() {
            var id;
            do { id = ''; for (var i = 0; i < 5; i++) id += _chars[Math.floor(Math.random()*_chars.length)]; } while (_ids.has(id));
            _ids.add(id);
            return id;
        }
        function tagEl(node) {
            var id = genId();
            node.setAttribute('data-palvia-id', id);
            return id;
        }
        function isInteractive(node) {
            var tag = (node.tagName || '').toLowerCase();
            if (['a','button','input','textarea','select'].includes(tag)) return true;
            var role = (node.getAttribute && node.getAttribute('role') || '').toLowerCase();
            if (['button','link','checkbox','tab','menuitem','switch','option'].includes(role)) return true;
            if (node.getAttribute && node.getAttribute('contenteditable') === 'true') return true;
            return false;
        }
        document.querySelectorAll('[data-palvia-id]').forEach(function(el) { el.removeAttribute('data-palvia-id'); });
        function walk(node, depth) {
            if (depth > 15) return '';
            var skip = new Set(['SCRIPT','STYLE','NOSCRIPT','SVG','PATH','META','LINK']);
            if (skip.has(node.tagName)) return '';
            var out = '';
            var tag = (node.tagName || '').toLowerCase();
            if (tag === 'a') {
                var id = tagEl(node);
                var href = node.getAttribute('href') || '';
                var text = (node.innerText || '').trim().substring(0, 80);
                if (text) out += '[#' + id + ' link: ' + text + ' -> ' + href + '] ';
            } else if (tag === 'input') {
                var id = tagEl(node);
                var t = node.type || 'text';
                var n = node.name || node.id || '';
                if (t === 'checkbox' || t === 'radio') {
                    var v = node.value || '';
                    out += '[#' + id + ' input(' + t + ') name=' + n + ' value="' + v.substring(0,50) + '" checked=' + node.checked + '] ';
                } else if (t === 'submit' || t === 'button') {
                    out += '[#' + id + ' button: ' + (node.value || '').trim().substring(0,50) + '] ';
                } else {
                    var v = node.value || '';
                    var p = node.placeholder || '';
                    out += '[#' + id + ' input(' + t + ') name=' + n + ' value="' + v.substring(0,50) + '" placeholder="' + p.substring(0,50) + '"] ';
                }
            } else if (tag === 'textarea') {
                var id = tagEl(node);
                var n = node.name || node.id || '';
                out += '[#' + id + ' textarea name=' + n + ' value="' + (node.value || '').substring(0,100) + '"] ';
            } else if (tag === 'button') {
                var id = tagEl(node);
                out += '[#' + id + ' button: ' + (node.innerText || node.value || '').trim().substring(0,50) + '] ';
            } else if (tag === 'select') {
                var id = tagEl(node);
                var n = node.name || node.id || '';
                var opts = Array.from(node.options).map(function(o) { return o.value + '=' + o.text; }).join(', ');
                out += '[#' + id + ' select name=' + n + ' options: ' + opts.substring(0,200) + '] ';
            } else if (tag === 'img') {
                out += '[img: ' + (node.alt || node.src || '').substring(0,80) + '] ';
            } else if (node.nodeType === 3) {
                var t = node.textContent.trim();
                if (t.length > 0) out += t + ' ';
            } else if (isInteractive(node)) {
                var id = tagEl(node);
                var role = (node.getAttribute('role') || '').toLowerCase();
                var text = (node.innerText || '').trim().substring(0, 80);
                out += '[#' + id + ' ' + tag + (role ? '(role=' + role + ')' : '') + ': ' + text + '] ';
            }
            if (node.childNodes) {
                for (var c of node.childNodes) { out += walk(c, depth + 1); }
            }
            if (['P','DIV','LI','TR','H1','H2','H3','H4','H5','H6','BR','HR','SECTION','ARTICLE','HEADER','FOOTER','MAIN','NAV'].includes(node.tagName)) {
                out += '\\n';
            }
            return out;
        }
        return walk(document.body || document.documentElement, 0).replace(/\\n{3,}/g, '\\n\\n').trim();
    })()
    """
}

// MARK: - WKNavigationDelegate

extension BrowserService: WKNavigationDelegate {
    nonisolated func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationAction: WKNavigationAction,
        decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
    ) {
        // WebKit always calls delegate methods on the main thread.
        MainActor.assumeIsolated {
            guard let url = navigationAction.request.url else {
                decisionHandler(.allow)
                return
            }

            guard url.isFileURL else {
                decisionHandler(.allow)
                return
            }

            // Allow file:// navigation only when an Agent scope is active and
            // the target stays within that scope directory.
            if let scope = self.currentAgentScope {
                let scopePath = scope.path.hasSuffix("/") ? scope.path : scope.path + "/"
                let targetPath = url.standardizedFileURL.path
                if targetPath.hasPrefix(scopePath) || targetPath == scope.path {
                    decisionHandler(.allow)
                } else {
                    decisionHandler(.cancel)
                }
            } else {
                decisionHandler(.cancel)
            }
        }
    }

    nonisolated func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        Task { @MainActor in completeNavigation(success: true) }
    }

    nonisolated func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        Task { @MainActor in completeNavigation(success: false) }
    }

    nonisolated func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        Task { @MainActor in completeNavigation(success: false) }
    }
}

// MARK: - Errors

enum BrowserError: LocalizedError {
    case invalidURL(String)
    case navigationTimeout
    case cannotGoBack
    case cannotGoForward
    case javaScriptError(String)
    case elementNotFound(String)
    case waitTimeout(String, TimeInterval)

    var errorDescription: String? {
        switch self {
        case .invalidURL(let url): return "Invalid URL: \(url)"
        case .navigationTimeout: return "Navigation timed out"
        case .cannotGoBack: return "Cannot go back — no history"
        case .cannotGoForward: return "Cannot go forward — no forward history"
        case .javaScriptError(let msg): return "JavaScript error: \(msg)"
        case .elementNotFound(let msg): return msg
        case .waitTimeout(let sel, let t): return "Timed out waiting for '\(sel)' after \(Int(t))s"
        }
    }
}
