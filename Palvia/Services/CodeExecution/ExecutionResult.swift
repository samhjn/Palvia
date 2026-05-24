import Foundation

// CodeExecutor registry for managing multiple executor types
final class CodeExecutorRegistry: @unchecked Sendable {
    static let shared = CodeExecutorRegistry()

    private var executors: [String: CodeExecutor] = [:]

    private init() {
        register(JavaScriptExecutor())
    }

    func register(_ executor: CodeExecutor) {
        executors[executor.language] = executor
    }

    func executor(for language: String) -> CodeExecutor? {
        executors[language]
    }

    func availableLanguages() -> [String] {
        executors.filter { $0.value.isAvailable }.map { $0.key }
    }

    func defaultExecutor() -> CodeExecutor {
        executors["javascript"] ?? JavaScriptExecutor()
    }
}
