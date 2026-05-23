import Foundation
import WebKit
import os.log

private let runtimeLog = OSLog(subsystem: "com.iclaw.jsruntime", category: "wkwebview")

/// Shared WKWebView-based JavaScript runtime.
///
/// All JS code execution goes through a hidden WKWebView whose WebContent
/// process runs in a separate address space.  If the WebContent process
/// crashes (OOM, JIT bug, etc.) the runtime automatically recreates the
/// web view and resumes accepting work.
@MainActor
final class WKWebViewJSRuntime: NSObject {
    static let shared = WKWebViewJSRuntime()

    private var webView: WKWebView!
    private var isPageLoaded = false
    private var pageLoadWaiters: [CheckedContinuation<Void, Never>] = []
    private(set) var isCrashed = false
    private(set) var crashCount = 0

    private var pendingContinuations: [String: CheckedContinuation<[String: Any], Error>] = [:]

    /// Scheme handler that proxies JS `fetch()` requests via URLSession,
    /// bypassing WKWebView's CORS restrictions on synchronous XHR.
    private let fetchSchemeHandler = JSFetchSchemeHandler()

    private static let blankHTML = """
    <!DOCTYPE html>
    <html><head><meta charset="utf-8"></head><body></body></html>
    """

    // MARK: - Lifecycle

    private override init() {
        super.init()
        buildWebView()
    }

    private func buildWebView() {
        let config = WKWebViewConfiguration()
        config.allowsInlineMediaPlayback = true
        config.setURLSchemeHandler(fetchSchemeHandler, forURLScheme: JSFetchSchemeHandler.scheme)
        AppleEcosystemBridge.shared.install(on: config)
        webView = WKWebView(frame: CGRect(x: 0, y: 0, width: 1, height: 1), configuration: config)
        webView.navigationDelegate = self
        isPageLoaded = false
        isCrashed = false
        webView.loadHTMLString(Self.blankHTML, baseURL: JSFetchSchemeHandler.sandboxBaseURL)
    }

    /// Tear down the old web view and create a fresh one.
    private func recreate() {
        os_log(.info, log: runtimeLog, "Recreating WKWebView (crash #%d)", crashCount)
        webView.navigationDelegate = nil
        webView = nil
        buildWebView()
    }

    private func ensureReady() async {
        if isCrashed { recreate() }
        if !isPageLoaded {
            await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
                pageLoadWaiters.append(c)
            }
        }
    }

    // MARK: - Public API

    /// Execute a self-contained JavaScript snippet that **returns a dictionary**
    /// with at least `stdout`, `stderr`, `result`, and `error` keys.
    ///
    /// The caller is responsible for wrapping user code + runtime preamble in an
    /// IIFE that produces the dictionary.  This method adds timeout and crash
    /// handling on top.
    ///
    /// - Parameters:
    ///   - arguments: Key-value pairs injected as local variables in the script scope
    ///     (bridged automatically by WKWebView: String, Number, Bool, Array, Dictionary, null).
    func evaluate(script: String, arguments: [String: Any] = [:], timeout: TimeInterval) async throws -> [String: Any] {
        await ensureReady()

        let execId = UUID().uuidString

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                pendingContinuations[execId] = continuation

                webView.callAsyncJavaScript(script, arguments: arguments, in: nil, in: .page) { [weak self] result in
                    Task { @MainActor in
                        guard let self, let cont = self.pendingContinuations.removeValue(forKey: execId) else { return }
                        switch result {
                        case .success(let value):
                            if let dict = value as? [String: Any] {
                                cont.resume(returning: dict)
                            } else {
                                cont.resume(returning: [
                                    "stdout": "",
                                    "stderr": "",
                                    "result": value as Any,
                                    "error": NSNull()
                                ])
                            }
                        case .failure(let error):
                            cont.resume(throwing: self.classify(error))
                        }
                    }
                }

                // Timeout watchdog
                Task { @MainActor [weak self] in
                    try? await Task.sleep(for: .seconds(timeout))
                    guard let self, let cont = self.pendingContinuations.removeValue(forKey: execId) else { return }
                    cont.resume(throwing: CodeExecutorError.timeout)
                    self.reloadPage()
                }
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                guard let self, let cont = self.pendingContinuations.removeValue(forKey: execId) else { return }
                cont.resume(throwing: CancellationError())
                self.reloadPage()
            }
        }
    }

    // MARK: - Helpers

    private func reloadPage() {
        isPageLoaded = false
        webView.loadHTMLString(Self.blankHTML, baseURL: JSFetchSchemeHandler.sandboxBaseURL)
    }

    private func classify(_ error: Error) -> Error {
        let ns = error as NSError
        if ns.domain == "WKErrorDomain" && ns.code == 5 {
            return CodeExecutorError.runtimeCrashed
        }
        return CodeExecutorError.executionFailed(error.localizedDescription)
    }
}

// MARK: - WKNavigationDelegate

extension WKWebViewJSRuntime: WKNavigationDelegate {
    nonisolated func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        Task { @MainActor in
            isPageLoaded = true
            let waiters = pageLoadWaiters
            pageLoadWaiters.removeAll()
            for w in waiters { w.resume() }
        }
    }

    nonisolated func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        Task { @MainActor in
            os_log(.error, log: runtimeLog, "Navigation failed: %{public}@", error.localizedDescription)
            let waiters = pageLoadWaiters
            pageLoadWaiters.removeAll()
            for w in waiters { w.resume() }
        }
    }

    nonisolated func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        Task { @MainActor in
            os_log(.error, log: runtimeLog, "WebContent process terminated (crash #%d)", crashCount + 1)
            isCrashed = true
            crashCount += 1

            let pending = pendingContinuations
            pendingContinuations.removeAll()
            for (_, cont) in pending {
                cont.resume(throwing: CodeExecutorError.runtimeCrashed)
            }
        }
    }
}
