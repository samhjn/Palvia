import Foundation
import UniformTypeIdentifiers

/// Generic file attachment for non-image, non-video files (PDFs, docs, text,
/// archives, etc.). Parallels `ImageAttachment` / `VideoAttachment`.
///
/// The actual bytes live in the agent's on-disk file folder, referenced via
/// `fileReference` (format `agentfile://<agentId>/<filename>`). This struct
/// only carries metadata so it can be JSON-encoded into drafts and messages
/// cheaply.
struct FileAttachment: Codable, Identifiable, Hashable {
    let id: UUID
    let name: String
    let fileReference: String
    let size: Int64
    let mimeType: String

    // MARK: - Computed

    /// `true` if the backing file has been deleted by the user since the
    /// attachment was created.
    var isFileDeleted: Bool {
        guard let (agentId, filename) = AgentFileManager.parseFileReference(fileReference) else {
            return true
        }
        return !AgentFileManager.shared.fileExists(agentId: agentId, name: filename)
    }

    /// Human-readable file size, e.g. `"1.2 MB"`.
    var fileSizeString: String {
        ByteCountFormatter.string(fromByteCount: size, countStyle: .file)
    }

    /// SF Symbol name best matching the file's extension.
    var systemIconName: String {
        let ext = (name as NSString).pathExtension.lowercased()
        switch ext {
        case "pdf": return "doc.richtext"
        case "txt", "md", "markdown", "log": return "doc.plaintext"
        case "json", "xml", "yaml", "yml", "toml", "csv", "tsv": return "doc.badge.gearshape"
        case "zip", "gz", "tar", "rar", "7z": return "doc.zipper"
        case "html", "htm": return "globe"
        case "swift", "js", "ts", "py", "rb", "go", "rs", "c", "cpp", "h", "m", "mm", "java", "kt", "sh":
            return "chevron.left.forwardslash.chevron.right"
        case "mp3", "wav", "m4a", "aac", "flac": return "waveform"
        default: return "doc"
        }
    }

    // MARK: - Factories

    /// Create from a source URL by copying the file's bytes into the agent's
    /// file folder. The source URL is typically a temporary file provided by
    /// a document picker or the Share Extension's staging directory.
    static func from(url: URL, agentId: UUID, preferredName: String? = nil) -> FileAttachment? {
        let requested = preferredName ?? url.lastPathComponent
        let finalName = uniqueFilename(preferred: requested, agentId: agentId)
        guard let data = try? Data(contentsOf: url) else { return nil }
        do {
            try AgentFileManager.shared.writeFile(agentId: agentId, name: finalName, data: data)
        } catch {
            return nil
        }
        let ref = AgentFileManager.makeFileReference(agentId: agentId, filename: finalName)
        return FileAttachment(
            id: UUID(),
            name: finalName,
            fileReference: ref,
            size: Int64(data.count),
            mimeType: mimeType(forFilename: finalName)
        )
    }

    /// Create from raw data by writing it to the agent's folder.
    static func from(data: Data, filename: String, agentId: UUID) -> FileAttachment? {
        let finalName = uniqueFilename(preferred: filename, agentId: agentId)
        do {
            try AgentFileManager.shared.writeFile(agentId: agentId, name: finalName, data: data)
        } catch {
            return nil
        }
        let ref = AgentFileManager.makeFileReference(agentId: agentId, filename: finalName)
        return FileAttachment(
            id: UUID(),
            name: finalName,
            fileReference: ref,
            size: Int64(data.count),
            mimeType: mimeType(forFilename: finalName)
        )
    }

    /// Create from an existing `agentfile://` reference. Returns `nil` if the
    /// file is missing.
    static func from(fileReference ref: String) -> FileAttachment? {
        guard let (agentId, filename) = AgentFileManager.parseFileReference(ref) else { return nil }
        guard let info = AgentFileManager.shared.fileInfo(agentId: agentId, name: filename) else { return nil }
        return FileAttachment(
            id: UUID(),
            name: filename,
            fileReference: ref,
            size: info.size,
            mimeType: mimeType(forFilename: filename)
        )
    }

    // MARK: - Helpers

    /// Disambiguate filename collisions by appending a short UUID.
    private static func uniqueFilename(preferred: String, agentId: UUID) -> String {
        let safe = AgentFileManager.isSafeFilename(preferred) ? preferred : "file_\(UUID().uuidString.prefix(8))"
        guard AgentFileManager.shared.fileExists(agentId: agentId, name: safe) else { return safe }
        let ns = safe as NSString
        let base = ns.deletingPathExtension
        let ext = ns.pathExtension
        let suffix = UUID().uuidString.prefix(6)
        if ext.isEmpty {
            return "\(base)_\(suffix)"
        }
        return "\(base)_\(suffix).\(ext)"
    }

    static func mimeType(forFilename name: String) -> String {
        let ext = (name as NSString).pathExtension.lowercased()
        guard !ext.isEmpty,
              let type = UTType(filenameExtension: ext),
              let mime = type.preferredMIMEType else {
            return "application/octet-stream"
        }
        return mime
    }
}
