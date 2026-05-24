import Foundation

enum SSEEvent {
    case message(data: String)
    case done
}

struct SSEParser {
    private var buffer = ""
    private var dataLines: [String] = []

    /// Parse a raw line from `bytes.lines` (without trailing newline).
    mutating func parseLine(_ line: String) -> [SSEEvent] {
        // Empty line = end of event
        if line.isEmpty {
            return flushEvent()
        }

        if line.hasPrefix("data: ") {
            let value = String(line.dropFirst(6))
            if value == "[DONE]" {
                let events = flushEvent()
                return events + [.done]
            }
            dataLines.append(value)
        } else if line == "data:" {
            dataLines.append("")
        }
        // Ignore other SSE fields (event:, id:, retry:, comments)

        return []
    }

    /// Legacy method for chunk-based parsing. Kept for compatibility.
    mutating func parse(chunk: String) -> [SSEEvent] {
        buffer += chunk
        var events: [SSEEvent] = []

        while let range = buffer.range(of: "\n\n") {
            let eventBlock = String(buffer[buffer.startIndex..<range.lowerBound])
            buffer = String(buffer[range.upperBound...])

            var data = ""
            for line in eventBlock.components(separatedBy: "\n") {
                if line.hasPrefix("data: ") {
                    let value = String(line.dropFirst(6))
                    if value == "[DONE]" {
                        events.append(.done)
                        return events
                    }
                    if !data.isEmpty { data += "\n" }
                    data += value
                } else if line == "data:" {
                    if !data.isEmpty { data += "\n" }
                }
            }

            if !data.isEmpty {
                events.append(.message(data: data))
            }
        }

        return events
    }

    private mutating func flushEvent() -> [SSEEvent] {
        guard !dataLines.isEmpty else { return [] }
        let data = dataLines.joined(separator: "\n")
        dataLines.removeAll()
        if data.isEmpty { return [] }
        return [.message(data: data)]
    }

    mutating func reset() {
        buffer = ""
        dataLines = []
    }
}
