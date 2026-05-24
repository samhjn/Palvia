import Foundation
import os.log

private let jsLog = OSLog(subsystem: "com.iclaw.javascript", category: "executor")

/// JavaScript executor backed by a WKWebView sandbox.
/// Console output is captured; a synchronous `fetch` polyfill (via XHR) and
/// common polyfills are injected automatically.
final class JavaScriptExecutor: CodeExecutor, @unchecked Sendable {
    let language = "javascript"
    let isAvailable = true

    func execute(code: String, mode: ExecutionMode, timeout: TimeInterval) async throws -> ExecutionResult {
        try await execute(code: code, mode: mode, timeout: timeout, blockedBridgeActions: [], execId: nil, args: [:])
    }

    /// Execute JS with per-agent Apple bridge permission enforcement.
    ///
    /// - Parameters:
    ///   - blockedBridgeActions: Bridge actions blocked for this agent (from `ToolCategory.blockedBridgeActions(for:)`).
    ///   - execId: Unique ID for this execution context, used for native-layer permission verification.
    ///   - args: Key-value arguments injected into the JS environment as the `args` object.
    func execute(
        code: String,
        mode: ExecutionMode,
        timeout: TimeInterval,
        blockedBridgeActions: Set<String>,
        execId: String?,
        args: [String: Any] = [:]
    ) async throws -> ExecutionResult {
        os_log(.info, log: jsLog, "[JS] execute called, mode=%{public}@, timeout=%{public}f", mode.rawValue, timeout)

        let callerManagedContext = execId != nil
        let effectiveExecId = execId ?? UUID().uuidString
        let script = Self.buildScript(code: code, mode: mode, blockedBridgeActions: blockedBridgeActions, execId: effectiveExecId)

        // Only register permissions if the caller hasn't already set up a context
        // (callers like CodeExecutionTools pre-register with agentId for file ops).
        let needsPermissionRegistration = !callerManagedContext && !blockedBridgeActions.isEmpty
        if needsPermissionRegistration {
            await AppleEcosystemBridge.shared.registerPermissions(execId: effectiveExecId) { action in
                !blockedBridgeActions.contains(action)
            }
        }

        defer {
            if needsPermissionRegistration {
                Task { @MainActor in
                    AppleEcosystemBridge.shared.unregisterPermissions(execId: effectiveExecId)
                }
            }
        }

        // Inject user args via WKWebView's native argument bridging.
        // The `args` variable becomes available in the JS script scope automatically.
        let jsArguments: [String: Any] = args.isEmpty ? [:] : ["args": args]

        // If the WebContent process crashes (OOM, etc.), the runtime auto-recreates.
        // Retry once so transient crashes are transparent to the caller.
        let dict: [String: Any]
        do {
            dict = try await WKWebViewJSRuntime.shared.evaluate(script: script, arguments: jsArguments, timeout: timeout)
        } catch CodeExecutorError.runtimeCrashed {
            os_log(.info, log: jsLog, "[JS] Runtime crashed, retrying once after auto-recovery")
            dict = try await WKWebViewJSRuntime.shared.evaluate(script: script, arguments: jsArguments, timeout: timeout)
        }

        let stdout = dict["stdout"] as? String ?? ""
        let stderr = dict["stderr"] as? String ?? ""
        let error  = dict["error"] as? String

        if let error, !error.isEmpty {
            let combinedErr = stderr.isEmpty ? error : stderr + "\n" + error
            return .failure(stderr: combinedErr)
        }

        switch mode {
        case .repl:
            let repl = dict["result"] as? String
            return .success(stdout: stdout, stderr: stderr, repl: repl)
        case .script:
            return .success(stdout: stdout, stderr: stderr)
        }
    }

    /// Execute JS as a callable — user code is wrapped in an `async function()` IIFE
    /// so a top-level `return` statement yields the call's return value. Used by the
    /// `snippets.invoke` bridge action. The caller is responsible for having
    /// pre-registered an `ExecutionContext` for `execId` on `AppleEcosystemBridge`.
    ///
    /// - Parameters:
    ///   - code: Snippet body. May include a top-level `return value;`.
    ///   - args: Injected as the `args` object inside the callee.
    ///   - stdin: Injected as the `stdin` string global; empty when not piping.
    func executeCallable(
        code: String,
        timeout: TimeInterval,
        blockedBridgeActions: Set<String>,
        execId: String,
        args: [String: Any] = [:],
        stdin: String = ""
    ) async throws -> CallableResult {
        let script = Self.buildCallableScript(
            code: code,
            blockedBridgeActions: blockedBridgeActions,
            execId: execId
        )

        let jsArguments: [String: Any] = [
            "args": args,
            "stdin": stdin
        ]

        // No retry on runtime crash: the parent's callAsyncJavaScript is also
        // wiped by the webview reload, so retrying the nested call inside a dead
        // parent context would produce a useless result. Let the error bubble up
        // and the outer executor's crash-retry handle a fresh execution.
        let dict = try await WKWebViewJSRuntime.shared.evaluate(script: script, arguments: jsArguments, timeout: timeout)

        let errorRaw = dict["error"]
        let errorString: String?
        if let s = errorRaw as? String, !s.isEmpty {
            errorString = s
        } else {
            errorString = nil
        }

        let rawValue = dict["result"]
        // NSNull is WKWebView's bridge for JS null / undefined; collapse to Swift nil.
        let value: Any? = (rawValue is NSNull) ? nil : rawValue

        return CallableResult(
            stdout: dict["stdout"] as? String ?? "",
            stderr: dict["stderr"] as? String ?? "",
            value: value,
            error: errorString
        )
    }

    // MARK: - Script Builder

    private static func buildCallableScript(
        code: String,
        blockedBridgeActions: Set<String>,
        execId: String
    ) -> String {
        let preamble = AppleEcosystemBridge.jsPreamble(blockedActions: blockedBridgeActions, execId: execId)
        return """
        \(runtimeScript)
        \(preamble)
        if (typeof stdin === 'undefined') var stdin = '';
        try {
            var __val = await (async function() {
                \(code)
            })();
            if (__val && typeof __val.then === 'function') __val = await __val;
            return {stdout: __stdout, stderr: __stderr, result: __val, error: null};
        } catch(__e) {
            __appendErr(String(__e) + '\\n');
            return {stdout: __stdout, stderr: __stderr, result: null, error: String(__e)};
        }
        """
    }

    private static func buildScript(
        code: String,
        mode: ExecutionMode,
        blockedBridgeActions: Set<String>,
        execId: String
    ) -> String {
        let userCode: String
        switch mode {
        case .repl:
            userCode = """
            var __val = eval(\(escapeForJS(code)));
            if (__val && typeof __val.then === 'function') __val = await __val;
            var __repl = __formatJSValue(__val);
            return {stdout: __stdout, stderr: __stderr, result: __repl, error: null};
            """
        case .script:
            userCode = """
            \(code)
            return {stdout: __stdout, stderr: __stderr, result: null, error: null};
            """
        }

        let preamble = AppleEcosystemBridge.jsPreamble(blockedActions: blockedBridgeActions, execId: execId)

        return """
        \(runtimeScript)
        \(preamble)
        try {
            \(userCode)
        } catch(__e) {
            __appendErr(String(__e) + '\\n');
            return {stdout: __stdout, stderr: __stderr, result: null, error: String(__e)};
        }
        """
    }

    // MARK: - Helpers

    private static func escapeForJS(_ code: String) -> String {
        let escaped = code
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: "\\n")
            .replacingOccurrences(of: "\r", with: "\\r")
            .replacingOccurrences(of: "\t", with: "\\t")
        return "\"\(escaped)\""
    }

    // MARK: - JavaScript Runtime

    static let runtimeScript: String = """
    var __stdout = '';
    var __stderr = '';
    if (typeof args === 'undefined') var args = {};

    function __appendOut(s) { __stdout += s; }
    function __appendErr(s) { __stderr += s; }

    // --- Console ---
    var console = {
        log: function() {
            var args = Array.prototype.slice.call(arguments);
            __appendOut(args.map(function(a) {
                if (a === null) return 'null';
                if (a === undefined) return 'undefined';
                if (typeof a === 'object') { try { return JSON.stringify(a); } catch(e) { return String(a); } }
                return String(a);
            }).join(' ') + '\\n');
        },
        warn: function() {
            var args = Array.prototype.slice.call(arguments);
            __appendErr('[warn] ' + args.map(String).join(' ') + '\\n');
        },
        error: function() {
            var args = Array.prototype.slice.call(arguments);
            __appendErr('[error] ' + args.map(String).join(' ') + '\\n');
        },
        info: function() { console.log.apply(null, arguments); },
        debug: function() { console.log.apply(null, arguments); },
        table: function(data) { console.log(JSON.stringify(data, null, 2)); },
        time: function() {},
        timeEnd: function() {},
        assert: function(cond, msg) { if (!cond) __appendErr('[assert] ' + (msg || 'Assertion failed') + '\\n'); },
        dir: function(obj) { console.log(JSON.stringify(obj, null, 2)); },
        clear: function() { __stdout = ''; __stderr = ''; }
    };

    function print() { console.log.apply(null, arguments); }

    // --- Timer polyfills (synchronous: run immediately) ---
    var __timerId = 0;
    function setTimeout(fn, delay) { try { fn(); } catch(e) {} return ++__timerId; }
    function setInterval(fn, delay) { return ++__timerId; }
    function clearTimeout(id) {}
    function clearInterval(id) {}

    // --- Network: synchronous fetch via same-origin proxy ---
    // XHR goes to iclaw-js://sandbox/fetch?url=<encoded> (same origin as page),
    // where JSFetchSchemeHandler proxies the request through URLSession (no CORS).
    function fetch(url, options) {
        options = options || {};
        var method = (options.method || 'GET').toUpperCase();
        var body = options.body || null;
        var headers = options.headers || {};

        var targetUrl = typeof url === 'string' ? url : url.toString();
        var proxyUrl = '/fetch?url=' + encodeURIComponent(targetUrl);

        var xhr = new XMLHttpRequest();
        xhr.open(method, proxyUrl, false);
        for (var key in headers) {
            if (headers.hasOwnProperty(key)) xhr.setRequestHeader(key, headers[key]);
        }
        try { xhr.send(body); } catch(e) {
            return {ok: false, status: 0, text: '', json: function(){ return {}; },
                    headers: {}, statusText: 'Network error: ' + e.message};
        }
        var responseText = xhr.responseText;
        var status = xhr.status;
        return {
            ok: status >= 200 && status < 300,
            status: status,
            text: responseText,
            json: function() { return JSON.parse(responseText); },
            headers: {},
            statusText: xhr.statusText || (status >= 200 && status < 300 ? 'OK' : 'Error')
        };
    }

    // --- Format JS value for repl ---
    function __formatJSValue(v) {
        if (v === undefined) return 'undefined';
        if (v === null) return 'null';
        if (typeof v === 'function') return v.toString();
        try { return JSON.stringify(v, null, 2); } catch(e) { return String(v); }
    }
    """
}
