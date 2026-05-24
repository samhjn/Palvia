import Foundation
import SwiftData

struct CodeExecutionTools {
    let agent: Agent
    let modelContext: ModelContext

    func executeJavaScript(arguments: [String: Any]) async throws -> String {
        guard let code = arguments["code"] as? String else {
            return "[Error] Missing required parameter: code"
        }

        let modeStr = arguments["mode"] as? String ?? "script"
        let mode: ExecutionMode = modeStr == "repl" ? .repl : .script
        let timeout = resolveJSTimeout(arguments: arguments)
        let userArgs = arguments["args"] as? [String: Any] ?? [:]

        guard let jsExecutor = CodeExecutorRegistry.shared.executor(for: "javascript") as? JavaScriptExecutor else {
            return "[Error] JavaScript executor is not available"
        }

        let blockedActions = ToolCategory.blockedBridgeActions(for: agent)
        let execId = UUID().uuidString
        let agentId = AgentFileManager.shared.resolveAgentId(for: agent)

        // Snapshot the agent's snippets once at registration time; the snapshot is
        // captured by the resolver/lister closures so bridge dispatch can run them
        // on any actor without re-entering SwiftData. Re-invocations of this tool
        // always re-register with a fresh snapshot, so edits made between runs are
        // picked up on the next call.
        let snippetSnapshot: [AppleEcosystemBridge.SnippetInfo] = agent.codeSnippets.map {
            .init(name: $0.name, language: $0.language, code: $0.code)
        }
        let resolver: @Sendable (String) -> AppleEcosystemBridge.SnippetInfo? = { name in
            snippetSnapshot.first { $0.name == name }
        }
        let lister: @Sendable () -> [AppleEcosystemBridge.SnippetInfo] = { snippetSnapshot }

        await AppleEcosystemBridge.shared.registerContext(
            execId: execId,
            agentId: agentId,
            blockedActions: blockedActions,
            totalBudget: timeout,
            snippetResolver: resolver,
            snippetLister: lister
        ) { action in !blockedActions.contains(action) }

        defer {
            Task { @MainActor in
                AppleEcosystemBridge.shared.unregisterPermissions(execId: execId)
            }
        }

        do {
            let result = try await jsExecutor.execute(
                code: code,
                mode: mode,
                timeout: timeout,
                blockedBridgeActions: blockedActions,
                execId: execId,
                args: userArgs
            )
            var output = ""
            if !result.stdout.isEmpty {
                output += result.stdout
            }
            if !result.stderr.isEmpty {
                if !output.isEmpty { output += "\n" }
                output += "[stderr] \(result.stderr)"
            }
            if let repl = result.repl {
                if !output.isEmpty { output += "\n" }
                output += repl
            }
            return output.isEmpty ? "(No output)" : output
        } catch is CancellationError {
            throw CancellationError()
        } catch CodeExecutorError.timeout {
            return "[Error] Execution timed out after \(Int(timeout))s"
        } catch CodeExecutorError.runtimeCrashed {
            return "[Error] JavaScript runtime crashed due to excessive memory usage. The runtime has been automatically recovered. Please simplify your code to use less memory (e.g. process data in smaller batches, avoid large arrays/strings) and try again."
        } catch {
            return "[Error] \(error.localizedDescription)"
        }
    }

    private func resolveJSTimeout(arguments: [String: Any]) -> TimeInterval {
        if let t = arguments["timeout"] as? Double, t > 0 {
            return min(max(t, 1), 300)
        }
        if let t = arguments["timeout"] as? Int, t > 0 {
            return min(max(TimeInterval(t), 1), 300)
        }
        if let config = agent.customConfigs.first(where: { $0.key == "javascript_timeout" }),
           let t = Double(config.content), t > 0 {
            return min(max(t, 1), 300)
        }
        return 60
    }

    func saveCode(arguments: [String: Any]) -> String {
        guard let name = arguments["name"] as? String else {
            return "[Error] Missing required parameter: name"
        }
        guard let code = arguments["code"] as? String else {
            return "[Error] Missing required parameter: code"
        }
        let language = arguments["language"] as? String ?? "javascript"

        if let existing = agent.codeSnippets.first(where: { $0.name == name }) {
            existing.code = code
            existing.language = language
            existing.updatedAt = Date()
        } else {
            let snippet = CodeSnippet(name: name, language: language, code: code)
            modelContext.insert(snippet)
            agent.codeSnippets.append(snippet)
        }
        try? modelContext.save()
        return "Saved code snippet '\(name)' (\(language), \(code.count) chars)"
    }

    func loadCode(arguments: [String: Any]) -> String {
        guard let name = arguments["name"] as? String else {
            return "[Error] Missing required parameter: name"
        }

        if let snippet = agent.codeSnippets.first(where: { $0.name == name }) {
            return "[\(snippet.language)] \(snippet.name):\n\(snippet.code)"
        } else {
            let available = agent.codeSnippets.map { $0.name }.joined(separator: ", ")
            return "[Error] Code snippet '\(name)' not found. Available: \(available.isEmpty ? "(none)" : available)"
        }
    }

    func listCode() -> String {
        let snippets = agent.codeSnippets
        if snippets.isEmpty {
            return "(No saved code snippets)"
        }
        return snippets.map { "- \($0.name) [\($0.language)] (\($0.code.count) chars)" }.joined(separator: "\n")
    }

    func runSnippet(arguments: [String: Any]) async throws -> String {
        guard let name = arguments["name"] as? String else {
            return "[Error] Missing required parameter: name"
        }

        guard let snippet = agent.codeSnippets.first(where: { $0.name == name }) else {
            let available = agent.codeSnippets.map { $0.name }.joined(separator: ", ")
            return "[Error] Code snippet '\(name)' not found. Available: \(available.isEmpty ? "(none)" : available)"
        }

        guard snippet.language == "javascript" else {
            return "[Error] Only JavaScript snippets can be executed. '\(name)' is \(snippet.language)."
        }

        var jsArgs: [String: Any] = ["code": snippet.code]
        if let mode = arguments["mode"] as? String {
            jsArgs["mode"] = mode
        }
        if let timeout = arguments["timeout"] {
            jsArgs["timeout"] = timeout
        }
        if let args = arguments["args"] {
            jsArgs["args"] = args
        }

        return try await executeJavaScript(arguments: jsArgs)
    }

    func deleteCode(arguments: [String: Any]) -> String {
        guard let name = arguments["name"] as? String else {
            return "[Error] Missing required parameter: name"
        }

        guard let snippet = agent.codeSnippets.first(where: { $0.name == name }) else {
            let available = agent.codeSnippets.map { $0.name }.joined(separator: ", ")
            return "[Error] Code snippet '\(name)' not found. Available: \(available.isEmpty ? "(none)" : available)"
        }

        modelContext.delete(snippet)
        try? modelContext.save()
        return "Deleted code snippet '\(name)'"
    }
}
