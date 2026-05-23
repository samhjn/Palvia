import Foundation

/// Accumulates streaming tool call deltas and emits complete `LLMToolCall` objects.
///
/// Used by both OpenAI and Anthropic stream handlers to deduplicate
/// the tool call accumulation and emission logic.
struct ToolCallAccumulator {
    private var entries: [Int: (id: String, name: String, arguments: String)] = [:]

    /// Whether there are any pending tool calls.
    var hasPending: Bool { !entries.isEmpty }

    /// Accumulate a delta for the given index.
    mutating func accumulate(index: Int, id: String?, name: String?, arguments: String?) {
        if entries[index] == nil {
            entries[index] = (id: id ?? "", name: name ?? "", arguments: "")
        }
        if let id, !id.isEmpty {
            entries[index]?.id = id
        }
        if let name, !name.isEmpty {
            entries[index]?.name = name
        }
        if let arguments {
            entries[index]?.arguments += arguments
        }
    }

    /// Flush all accumulated tool calls, sorted by index, and reset.
    mutating func flush() -> [LLMToolCall] {
        let calls = entries.sorted(by: { $0.key < $1.key }).map { (_, acc) in
            let callId = acc.id.isEmpty ? "call_\(UUID().uuidString.prefix(8))" : acc.id
            return LLMToolCall(id: callId, name: acc.name, arguments: acc.arguments)
        }
        entries.removeAll()
        return calls
    }

    /// Flush all accumulated tool calls as `StreamChunk.toolCall` into the continuation.
    mutating func emit(to continuation: AsyncStream<StreamChunk>.Continuation) {
        for toolCall in flush() {
            continuation.yield(.toolCall(toolCall))
        }
    }
}
