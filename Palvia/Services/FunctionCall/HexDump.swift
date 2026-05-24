import Foundation

/// hexdump-style formatting: each line is 16 bytes shown as
/// `00000000: de ad be ef ...  ................`
enum HexDump {
    static func format(_ data: Data, startOffset: Int = 0) -> String {
        guard !data.isEmpty else { return "" }
        var lines: [String] = []
        let bytesPerLine = 16
        let bytes = Array(data)
        var lineStart = 0
        while lineStart < bytes.count {
            let lineEnd = min(lineStart + bytesPerLine, bytes.count)
            let chunk = bytes[lineStart..<lineEnd]
            let address = String(format: "%08x", startOffset + lineStart)

            var hexCols = ""
            for i in 0..<bytesPerLine {
                if i == 8 { hexCols += " " }
                if i < chunk.count {
                    let byte = chunk[chunk.startIndex + i]
                    hexCols += String(format: "%02x", byte)
                } else {
                    hexCols += "  "
                }
                if i < bytesPerLine - 1 { hexCols += " " }
            }

            var ascii = ""
            for i in 0..<chunk.count {
                let byte = chunk[chunk.startIndex + i]
                if byte >= 0x20 && byte < 0x7f {
                    ascii.append(Character(UnicodeScalar(byte)))
                } else {
                    ascii.append(".")
                }
            }

            lines.append("\(address): \(hexCols)  \(ascii)")
            lineStart = lineEnd
        }
        return lines.joined(separator: "\n")
    }
}
