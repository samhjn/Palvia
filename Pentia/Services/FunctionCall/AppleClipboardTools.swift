import Foundation
import UIKit

struct AppleClipboardTools {

    @MainActor
    func readClipboard(arguments: [String: Any]) -> String {
        let pasteboard = UIPasteboard.general

        if let text = pasteboard.string, !text.isEmpty {
            return """
            Clipboard content (text):
            \(text)
            """
        }

        if let url = pasteboard.url {
            return "Clipboard content (URL): \(url.absoluteString)"
        }

        if pasteboard.hasImages {
            return "Clipboard contains an image (not displayable as text)."
        }

        if pasteboard.hasStrings {
            return "Clipboard contains strings but they appear empty."
        }

        return "(Clipboard is empty)"
    }

    @MainActor
    func writeClipboard(arguments: [String: Any]) -> String {
        guard let text = arguments["text"] as? String else {
            return "[Error] Missing required parameter: text"
        }

        UIPasteboard.general.string = text
        let preview = text.count > 100 ? String(text.prefix(100)) + "..." : text
        return "Text copied to clipboard (\(text.count) characters): \(preview)"
    }
}
