import Foundation
import SwiftData

struct ConfigTools {
    let agentService: AgentService
    let agent: Agent

    func readConfig(arguments: [String: Any]) -> String {
        guard let key = arguments["key"] as? String else {
            return toolError("Missing required parameter: key")
        }

        if let content = agentService.readConfig(agent: agent, key: key) {
            return content.isEmpty
                ? "(Config '\(key)' exists but is empty)"
                : content
        } else {
            let available = agentService.listConfigs(agent: agent).joined(separator: ", ")
            return toolError("Config '\(key)' not found. Available configs: \(available)")
        }
    }

    func writeConfig(arguments: [String: Any]) -> String {
        guard let key = arguments["key"] as? String else {
            return toolError("Missing required parameter: key")
        }
        guard let content = arguments["content"] as? String else {
            return toolError("Missing required parameter: content")
        }

        agentService.writeConfig(agent: agent, key: key, content: content)
        return "Successfully updated '\(key)' (\(content.count) characters)"
    }

    private func toolError(_ message: String) -> String {
        "[Error] \(message)"
    }
}
