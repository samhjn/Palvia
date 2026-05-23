import Foundation

struct SessionExporter {

    /// Export a session to Markdown with YAML front matter.
    /// Machine-readable metadata in front matter, human-readable conversation body.
    static func exportToMarkdown(_ session: Session) -> String {
        var lines: [String] = []

        let isoFormatter = ISO8601DateFormatter()
        isoFormatter.formatOptions = [.withInternetDateTime]

        let readableFormatter = DateFormatter()
        readableFormatter.dateFormat = "yyyy-MM-dd HH:mm:ss"

        let agentName = session.agent?.name ?? "Unknown"

        // YAML front matter
        lines.append("---")
        lines.append("title: \"\(escapeYAML(session.title))\"")
        lines.append("agent: \"\(escapeYAML(agentName))\"")
        lines.append("session_id: \(session.id.uuidString)")
        lines.append("created_at: \(isoFormatter.string(from: session.createdAt))")
        lines.append("updated_at: \(isoFormatter.string(from: session.updatedAt))")
        lines.append("message_count: \(session.messages.count)")
        if session.compressedUpToIndex > 0 {
            lines.append("compressed_messages: \(session.compressedUpToIndex)")
        }
        if let compressed = session.compressedContext, !compressed.isEmpty {
            lines.append("has_compressed_context: true")
        }
        lines.append("exported_at: \(isoFormatter.string(from: Date()))")
        lines.append("---")
        lines.append("")

        // Header
        lines.append("# \(session.title)")
        lines.append("")
        lines.append("> **Agent:** \(agentName)  ")
        lines.append("> **Created:** \(readableFormatter.string(from: session.createdAt))  ")
        lines.append("> **Messages:** \(session.messages.count)")
        lines.append("")

        // Compressed context summary
        if let compressed = session.compressedContext, !compressed.isEmpty {
            lines.append("## Compressed Context")
            lines.append("")
            lines.append("<details>")
            lines.append("<summary>Prior conversation summary (\(session.compressedUpToIndex) messages compressed)</summary>")
            lines.append("")
            lines.append(compressed)
            lines.append("")
            lines.append("</details>")
            lines.append("")
        }

        lines.append("---")
        lines.append("")

        // Messages
        let sorted = session.sortedMessages
        for message in sorted {
            let timestamp = readableFormatter.string(from: message.timestamp)

            switch message.role {
            case .system:
                lines.append("### System")
                lines.append("")
                if let content = message.content {
                    lines.append(content)
                }

            case .user:
                lines.append("### \(L10n.Export.roleUser) `\(timestamp)`")
                lines.append("")
                if let content = message.content {
                    lines.append(content)
                }

            case .assistant:
                lines.append("### \(L10n.Export.roleAssistant) `\(timestamp)`")
                lines.append("")

                // Thinking content
                if let thinking = message.thinkingContent, !thinking.isEmpty {
                    lines.append("<details>")
                    lines.append("<summary>\(L10n.Chat.thinkingProcess)</summary>")
                    lines.append("")
                    lines.append(thinking)
                    lines.append("")
                    lines.append("</details>")
                    lines.append("")
                }

                if let content = message.content, !content.isEmpty {
                    lines.append(content)
                }

                // Tool calls
                if let toolData = message.toolCallsData,
                   let calls = try? JSONDecoder().decode([LLMToolCall].self, from: toolData) {
                    lines.append("")
                    for call in calls {
                        lines.append("**\(L10n.Export.toolCall):** `\(call.function.name)`")
                        if !call.function.arguments.isEmpty {
                            // Try pretty-print JSON arguments
                            let args = prettyJSON(call.function.arguments)
                            lines.append("```json")
                            lines.append(args)
                            lines.append("```")
                        }
                    }
                }

            case .tool:
                let toolName = message.name ?? "tool"
                lines.append("### \(L10n.Export.roleTool): \(toolName) `\(timestamp)`")
                lines.append("")
                if let content = message.content, !content.isEmpty {
                    lines.append("```")
                    lines.append(content)
                    lines.append("```")
                }
            }

            // Token info
            if let prompt = message.apiPromptTokens, let completion = message.apiCompletionTokens {
                lines.append("")
                lines.append("<!-- tokens: prompt=\(prompt) completion=\(completion) -->")
            }

            lines.append("")
            lines.append("---")
            lines.append("")
        }

        return lines.joined(separator: "\n")
    }

    /// Generate a sanitized filename for the export.
    static func exportFileName(for session: Session) -> String {
        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "yyyyMMdd_HHmm"
        let dateStr = dateFormatter.string(from: session.createdAt)

        let title = session.title
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
            .prefix(5)
            .joined(separator: "_")

        let safeName = title.isEmpty ? "session" : title
        return "iClaw_\(safeName)_\(dateStr).md"
    }

    /// Write the exported markdown to a temporary file and return its URL.
    static func exportToFile(_ session: Session) -> URL? {
        let markdown = exportToMarkdown(session)
        let fileName = exportFileName(for: session)
        let tempDir = FileManager.default.temporaryDirectory
        let fileURL = tempDir.appendingPathComponent(fileName)

        do {
            try markdown.write(to: fileURL, atomically: true, encoding: .utf8)
            return fileURL
        } catch {
            return nil
        }
    }

    // MARK: - Helpers

    private static func escapeYAML(_ value: String) -> String {
        value.replacingOccurrences(of: "\"", with: "\\\"")
    }

    private static func prettyJSON(_ jsonString: String) -> String {
        guard let data = jsonString.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data),
              let pretty = try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys]),
              let result = String(data: pretty, encoding: .utf8) else {
            return jsonString
        }
        return result
    }
}
