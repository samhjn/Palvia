import Foundation

enum ExecutionMode: String, Sendable {
    case repl
    case script
}

struct ExecutionResult: Sendable {
    let stdout: String
    let stderr: String
    let repl: String?
    let exitCode: Int

    static func success(stdout: String = "", stderr: String = "", repl: String? = nil) -> ExecutionResult {
        ExecutionResult(stdout: stdout, stderr: stderr, repl: repl, exitCode: 0)
    }

    static func failure(stderr: String, exitCode: Int = 1) -> ExecutionResult {
        ExecutionResult(stdout: "", stderr: stderr, repl: nil, exitCode: exitCode)
    }
}

/// Structured result from a callable JS execution (used by `snippets.invoke`).
/// Unlike `ExecutionResult`, `value` is the raw JS return value bridged through
/// WKWebView (String / Number / Bool / Array / Dict / NSNull), not a formatted string.
struct CallableResult: @unchecked Sendable {
    let stdout: String
    let stderr: String
    let value: Any?
    let error: String?
}

/// Conforming types must implement at least one of the two `execute` methods
/// to break the mutual default-implementation cycle.
protocol CodeExecutor: Sendable {
    var language: String { get }
    var isAvailable: Bool { get }
    func execute(code: String, mode: ExecutionMode) async throws -> ExecutionResult
    func execute(code: String, mode: ExecutionMode, timeout: TimeInterval) async throws -> ExecutionResult
}

extension CodeExecutor {
    static var defaultTimeout: TimeInterval { 60 }

    func execute(code: String, mode: ExecutionMode) async throws -> ExecutionResult {
        try await execute(code: code, mode: mode, timeout: Self.defaultTimeout)
    }

    func execute(code: String, mode: ExecutionMode, timeout: TimeInterval) async throws -> ExecutionResult {
        try await execute(code: code, mode: mode)
    }
}

enum CodeExecutorError: LocalizedError {
    case executorNotAvailable(String)
    case executionFailed(String)
    case timeout
    case runtimeCrashed

    var errorDescription: String? {
        switch self {
        case .executorNotAvailable(let lang): return "\(lang) executor is not available"
        case .executionFailed(let msg): return "Execution failed: \(msg)"
        case .timeout: return "Execution timed out"
        case .runtimeCrashed: return "JavaScript runtime crashed — will auto-recover on next execution"
        }
    }
}
