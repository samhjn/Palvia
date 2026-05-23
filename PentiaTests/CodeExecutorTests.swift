import XCTest
@testable import iClaw

final class CodeExecutorTests: XCTestCase {

    // MARK: - ExecutionMode

    func testExecutionModeRawValues() {
        XCTAssertEqual(ExecutionMode.repl.rawValue, "repl")
        XCTAssertEqual(ExecutionMode.script.rawValue, "script")
    }

    func testExecutionModeFromRawValue() {
        XCTAssertEqual(ExecutionMode(rawValue: "repl"), .repl)
        XCTAssertEqual(ExecutionMode(rawValue: "script"), .script)
        XCTAssertNil(ExecutionMode(rawValue: "invalid"))
    }

    // MARK: - ExecutionResult

    func testExecutionResultSuccess() {
        let result = ExecutionResult.success(stdout: "Hello\n", stderr: "", repl: nil)
        XCTAssertEqual(result.stdout, "Hello\n")
        XCTAssertTrue(result.stderr.isEmpty)
        XCTAssertNil(result.repl)
        XCTAssertEqual(result.exitCode, 0)
    }

    func testExecutionResultSuccessDefaults() {
        let result = ExecutionResult.success()
        XCTAssertTrue(result.stdout.isEmpty)
        XCTAssertTrue(result.stderr.isEmpty)
        XCTAssertNil(result.repl)
        XCTAssertEqual(result.exitCode, 0)
    }

    func testExecutionResultSuccessWithRepl() {
        let result = ExecutionResult.success(stdout: "", repl: "42")
        XCTAssertEqual(result.repl, "42")
        XCTAssertEqual(result.exitCode, 0)
    }

    func testExecutionResultFailure() {
        let result = ExecutionResult.failure(stderr: "SyntaxError: Unexpected token")
        XCTAssertTrue(result.stdout.isEmpty)
        XCTAssertEqual(result.stderr, "SyntaxError: Unexpected token")
        XCTAssertNil(result.repl)
        XCTAssertEqual(result.exitCode, 1)
    }

    func testExecutionResultFailureCustomExitCode() {
        let result = ExecutionResult.failure(stderr: "Timeout", exitCode: 124)
        XCTAssertEqual(result.exitCode, 124)
    }

    // MARK: - CodeExecutorError

    func testCodeExecutorErrorNotAvailable() {
        let error = CodeExecutorError.executorNotAvailable("python")
        XCTAssertNotNil(error.errorDescription)
        XCTAssertTrue(error.errorDescription!.contains("python"))
    }

    func testCodeExecutorErrorExecutionFailed() {
        let error = CodeExecutorError.executionFailed("Bad syntax")
        XCTAssertNotNil(error.errorDescription)
        XCTAssertTrue(error.errorDescription!.contains("Bad syntax"))
    }

    func testCodeExecutorErrorTimeout() {
        let error = CodeExecutorError.timeout
        XCTAssertNotNil(error.errorDescription)
        XCTAssertTrue(error.errorDescription!.lowercased().contains("timeout") ||
                      error.errorDescription!.lowercased().contains("timed out"))
    }

    func testCodeExecutorErrorRuntimeCrashed() {
        let error = CodeExecutorError.runtimeCrashed
        XCTAssertNotNil(error.errorDescription)
        XCTAssertTrue(error.errorDescription!.lowercased().contains("crash"))
    }

    // MARK: - CodeExecutor Protocol Defaults

    func testDefaultTimeout() {
        XCTAssertEqual(JavaScriptExecutor.defaultTimeout, 60)
    }

    // MARK: - CodeExecutorRegistry

    func testRegistryDefaultExecutor() {
        let registry = CodeExecutorRegistry.shared
        let executor = registry.defaultExecutor()
        XCTAssertEqual(executor.language, "javascript")
    }

    func testRegistryJavaScriptAvailable() {
        let registry = CodeExecutorRegistry.shared
        let executor = registry.executor(for: "javascript")
        XCTAssertNotNil(executor)
        XCTAssertEqual(executor?.language, "javascript")
        XCTAssertTrue(executor?.isAvailable ?? false)
    }

    func testRegistryUnknownLanguage() {
        let registry = CodeExecutorRegistry.shared
        let executor = registry.executor(for: "python")
        XCTAssertNil(executor)
    }

    func testRegistryAvailableLanguages() {
        let registry = CodeExecutorRegistry.shared
        let languages = registry.availableLanguages()
        XCTAssertTrue(languages.contains("javascript"))
    }

    // MARK: - JavaScriptExecutor Properties

    func testJavaScriptExecutorProperties() {
        let executor = JavaScriptExecutor()
        XCTAssertEqual(executor.language, "javascript")
        XCTAssertTrue(executor.isAvailable)
    }

    // MARK: - Runtime Script Validity

    func testRuntimeScriptIsNonEmpty() {
        XCTAssertFalse(JavaScriptExecutor.runtimeScript.isEmpty)
    }

    func testRuntimeScriptContainsConsole() {
        let script = JavaScriptExecutor.runtimeScript
        XCTAssertTrue(script.contains("var console"))
        XCTAssertTrue(script.contains("log: function"))
        XCTAssertTrue(script.contains("error: function"))
        XCTAssertTrue(script.contains("warn: function"))
    }

    func testRuntimeScriptContainsFetch() {
        let script = JavaScriptExecutor.runtimeScript
        XCTAssertTrue(script.contains("function fetch"))
        XCTAssertTrue(script.contains("XMLHttpRequest"))
    }

    func testRuntimeScriptContainsTimerPolyfills() {
        let script = JavaScriptExecutor.runtimeScript
        XCTAssertTrue(script.contains("setTimeout"))
        XCTAssertTrue(script.contains("setInterval"))
        XCTAssertTrue(script.contains("clearTimeout"))
        XCTAssertTrue(script.contains("clearInterval"))
    }

    func testRuntimeScriptContainsFormatFunction() {
        let script = JavaScriptExecutor.runtimeScript
        XCTAssertTrue(script.contains("__formatJSValue"))
    }

    func testRuntimeScriptContainsOutputCapture() {
        let script = JavaScriptExecutor.runtimeScript
        XCTAssertTrue(script.contains("__stdout"))
        XCTAssertTrue(script.contains("__stderr"))
        XCTAssertTrue(script.contains("__appendOut"))
        XCTAssertTrue(script.contains("__appendErr"))
    }

    // MARK: - Fetch Proxy Integration

    func testRuntimeScriptFetchRoutesViaProxy() {
        let script = JavaScriptExecutor.runtimeScript
        XCTAssertTrue(script.contains("/fetch?url="),
                       "fetch polyfill should route through same-origin proxy path")
        XCTAssertTrue(script.contains("encodeURIComponent"),
                       "fetch polyfill should percent-encode the target URL")
    }

    func testRuntimeScriptFetchIsSynchronous() {
        let script = JavaScriptExecutor.runtimeScript
        XCTAssertTrue(script.contains("proxyUrl, false"),
                       "fetch XHR must use async=false for synchronous operation")
    }
}
