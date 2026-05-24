import Foundation
import UIKit

/// Implements file management tool calls for an agent's file folder.
struct FileTools {
    let agent: Agent
    private let fm = AgentFileManager.shared

    private var agentId: UUID { fm.resolveAgentId(for: agent) }

    /// Default byte limit when the LLM does not specify a `size`.
    static let defaultReadSize = 1024

    /// Accept `path` as the canonical parameter name; fall back to `name` for backward compat.
    private static func argPath(_ arguments: [String: Any]) -> String? {
        if let p = arguments["path"] as? String, !p.isEmpty { return p }
        if let n = arguments["name"] as? String, !n.isEmpty { return n }
        return nil
    }

    func listFiles(arguments: [String: Any]) -> String {
        let path = (arguments["path"] as? String) ?? ""
        let files = fm.listFiles(agentId: agentId, path: path)
        let header = path.isEmpty ? "Files" : "Files in '\(path)'"
        if files.isEmpty {
            return "\(header): (empty)"
        }
        var lines = ["\(header) (\(files.count)):"]
        for f in files {
            let badge: String
            if f.isDirectory { badge = " [dir]" }
            else if f.isImage { badge = " [image]" }
            else if f.isVideo { badge = " [video]" }
            else { badge = "" }
            lines.append("  \(f.name) — \(f.formattedSize)\(badge)  (modified: \(Self.dateFormatter.string(from: f.modifiedAt)))")
        }
        return lines.joined(separator: "\n")
    }

    func readFile(arguments: [String: Any]) -> String {
        guard let path = Self.argPath(arguments) else {
            return "[Error] Missing required parameter: path"
        }
        let mode = (arguments["mode"] as? String) ?? "text"
        let requestedSize = Self.intArg(arguments["size"])
        let offset = max(0, Self.intArg(arguments["offset"]) ?? 0)
        let size = requestedSize ?? Self.defaultReadSize

        do {
            let data = try fm.readFile(agentId: agentId, name: path)
            let total = data.count
            let start = min(offset, total)
            let end = min(start + max(size, 0), total)
            let slice = data.subdata(in: start..<end)
            let truncated = end < total
            let suffix: String = {
                guard truncated else { return "" }
                return "\n[truncated: read \(end - start) of \(total) bytes, next offset=\(end)]"
            }()

            switch mode {
            case "base64":
                return slice.base64EncodedString() + suffix
            case "hex":
                return HexDump.format(slice, startOffset: start) + suffix
            default: // "text"
                if let text = String(data: slice, encoding: .utf8) {
                    return text + suffix
                }
                return "[Error] File is binary; use mode='hex' or mode='base64' to read."
            }
        } catch {
            return "[Error] \(error.localizedDescription)"
        }
    }

    func writeFile(arguments: [String: Any]) -> String {
        guard let path = Self.argPath(arguments) else {
            return "[Error] Missing required parameter: path"
        }
        let content = arguments["content"] as? String ?? ""
        let encoding = (arguments["encoding"] as? String) ?? "text"

        let data: Data
        if encoding == "base64" {
            guard let decoded = Data(base64Encoded: content, options: .ignoreUnknownCharacters) else {
                return "[Error] Invalid base64 content."
            }
            data = decoded
        } else {
            data = Data(content.utf8)
        }

        do {
            try fm.writeFile(agentId: agentId, name: path, data: data)
            return "File '\(path)' written successfully (\(ByteCountFormatter.string(fromByteCount: Int64(data.count), countStyle: .file)))."
        } catch {
            return "[Error] \(error.localizedDescription)"
        }
    }

    func deleteFile(arguments: [String: Any]) -> String {
        guard let path = Self.argPath(arguments) else {
            return "[Error] Missing required parameter: path"
        }
        do {
            try fm.deleteFile(agentId: agentId, name: path)
            return "Deleted '\(path)'."
        } catch {
            return "[Error] \(error.localizedDescription)"
        }
    }

    func fileInfo(arguments: [String: Any]) -> String {
        guard let path = Self.argPath(arguments) else {
            return "[Error] Missing required parameter: path"
        }
        guard let info = fm.fileInfo(agentId: agentId, name: path) else {
            return "[Error] File not found: \(path)"
        }
        return """
        path: \(path)
        name: \(info.name)
        size: \(info.formattedSize)
        is_directory: \(info.isDirectory)
        is_image: \(info.isImage)
        created: \(Self.dateFormatter.string(from: info.createdAt))
        modified: \(Self.dateFormatter.string(from: info.modifiedAt))
        """
    }

    // MARK: - Multimodal

    private static let supportedImageExtensions: Set<String> = [
        "jpg", "jpeg", "png", "gif", "webp", "heic", "heif", "bmp", "tiff", "tif"
    ]

    func attachMedia(arguments: [String: Any]) async -> ToolCallResult {
        guard let name = Self.argPath(arguments) else {
            return ToolCallResult("[Error] Missing required parameter: path")
        }

        let ext = (name as NSString).pathExtension.lowercased()
        let modality = arguments["modality"] as? String ?? detectModality(ext: ext)

        switch modality {
        case "image":
            guard Self.supportedImageExtensions.contains(ext) else {
                return ToolCallResult("[Error] Unsupported image format '.\(ext)'. Supported: jpg, png, gif, webp, heic, bmp, tiff.")
            }
            do {
                let data = try fm.readFile(agentId: agentId, name: name)
                let mimeType = mimeTypeForExtension(ext)
                let width: Int
                let height: Int
                let thumbnail: Data
                if let image = UIImage(data: data) {
                    width = Int(image.size.width * image.scale)
                    height = Int(image.size.height * image.scale)
                    thumbnail = ImageAttachment.generateThumbnail(from: image)
                } else {
                    width = 512; height = 512
                    thumbnail = Data()
                }
                let ref = AgentFileManager.makeFileReference(agentId: agentId, filename: name)
                let attachment = ImageAttachment(
                    id: UUID(),
                    imageData: thumbnail,
                    mimeType: mimeType,
                    width: width,
                    height: height,
                    fileReference: ref
                )
                return ToolCallResult(
                    "Image '\(name)' (\(width)x\(height), \(ByteCountFormatter.string(fromByteCount: Int64(data.count), countStyle: .file))) attached to conversation.",
                    imageAttachments: [attachment]
                )
            } catch {
                return ToolCallResult("[Error] \(error.localizedDescription)")
            }

        case "audio":
            return ToolCallResult("[Error] Audio modality is not yet supported. Currently only image files can be attached.")

        case "video":
            guard Self.supportedVideoExtensions.contains(ext) else {
                return ToolCallResult("[Error] Unsupported video format '.\(ext)'. Supported: mp4, mov, m4v, webm.")
            }
            do {
                _ = try fm.readFile(agentId: agentId, name: name)
                let ref = AgentFileManager.makeFileReference(agentId: agentId, filename: name)
                guard let attachment = await VideoAttachment.from(fileReference: ref) else {
                    return ToolCallResult("[Error] Failed to read video metadata from '\(name)'.")
                }
                return ToolCallResult(
                    "Video '\(name)' (\(attachment.width)x\(attachment.height), \(attachment.durationString), \(attachment.fileSizeString)) attached to conversation.",
                    videoAttachments: [attachment]
                )
            } catch {
                return ToolCallResult("[Error] \(error.localizedDescription)")
            }

        default:
            return ToolCallResult("[Error] Unknown modality '\(modality)'. Supported: image, video. Planned: audio.")
        }
    }

    private static let supportedVideoExtensions: Set<String> = [
        "mp4", "mov", "m4v", "webm"
    ]

    private func detectModality(ext: String) -> String {
        if Self.supportedImageExtensions.contains(ext) { return "image" }
        let audioExts: Set<String> = ["mp3", "wav", "m4a", "aac", "ogg", "flac", "aiff"]
        if audioExts.contains(ext) { return "audio" }
        let videoExts: Set<String> = ["mp4", "mov", "avi", "mkv", "webm", "m4v"]
        if videoExts.contains(ext) { return "video" }
        return "unknown"
    }

    private func mimeTypeForExtension(_ ext: String) -> String {
        switch ext {
        case "png": return "image/png"
        case "gif": return "image/gif"
        case "webp": return "image/webp"
        case "heic", "heif": return "image/heic"
        case "bmp": return "image/bmp"
        case "tiff", "tif": return "image/tiff"
        default: return "image/jpeg"
        }
    }

    private static func intArg(_ value: Any?) -> Int? {
        if let i = value as? Int { return i }
        if let i = value as? Int64 { return Int(i) }
        if let d = value as? Double { return Int(d) }
        if let s = value as? String, let i = Int(s) { return i }
        return nil
    }

    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .short
        return f
    }()
}
