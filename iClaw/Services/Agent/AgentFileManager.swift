import Foundation
import UIKit
import os.log

private let fileLog = OSLog(subsystem: "com.iclaw.files", category: "agent-file-manager")

/// Manages per-agent file storage on disk.
///
/// Directory layout: `<Documents>/AgentFiles/<agentId>/`
/// Sub-agents share the top-level parent agent's folder via `resolveAgentId(for:)`.
///
/// File paths accepted by CRUD methods may be either a bare filename (e.g. `notes.txt`)
/// or a relative path with forward-slash separators (e.g. `docs/2026/notes.md`).
/// Absolute paths and path traversal (`..`) are rejected.
final class AgentFileManager {

    static let shared = AgentFileManager()

    private let fm = FileManager.default

    var rootDirectory: URL {
        fm.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("AgentFiles", isDirectory: true)
    }

    /// Root for user-authored skill packages, exposed via the `/skills/` mount
    /// in the `fs.*` bridge. Sibling of `AgentFiles/`. Visible in the iOS
    /// Files app via `UIFileSharingEnabled` + `LSSupportsOpeningDocumentsInPlace`.
    var skillsRoot: URL {
        fm.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Skills", isDirectory: true)
    }

    // MARK: - Skills mount

    /// Result of resolving a path under the reserved `skills/` mount. The
    /// resolver chooses between the read-only built-in bundle and the
    /// writable user skills directory based on the slug.
    struct SkillMountResolution: Equatable {
        let url: URL
        /// First path component after `skills/` — the skill slug. `nil` when
        /// resolving the mount root itself (`skills` with no children).
        let slug: String?
        /// True when the resolved URL is inside the read-only app bundle.
        /// Writes to such URLs are rejected by the resolver in Phase 4b.
        let isBuiltIn: Bool
    }

    /// Path prefix that triggers the skills-mount resolver. Note: no leading
    /// slash — JS-side leading slashes are stripped by the bridge before
    /// reaching here. `isSafeRelativePath` continues to reject leading slashes
    /// in agent-scoped paths.
    static let skillsMountComponent = "skills"

    /// True when `path` targets the `skills/` mount (either the mount root or
    /// any sub-path under it).
    static func isSkillsMountPath(_ path: String) -> Bool {
        path == skillsMountComponent || path.hasPrefix(skillsMountComponent + "/")
    }

    /// Resolve a path under the `skills/` mount. The path is given **without**
    /// the leading `skills/` component (e.g. `"deep-research/SKILL.md"`,
    /// `"my-custom"`, or `""` for the mount root).
    ///
    /// When `forWriting` is true, paths under built-in slugs throw
    /// `FileToolError.readOnlySkill(slug)` — built-ins live in the read-only
    /// app bundle and writes to them must be rejected with a clean error
    /// (rather than letting the OS surface a generic permission denial).
    ///
    /// - Throws: `FileToolError.unsafeFilename` for any traversal attempt;
    ///           `FileToolError.readOnlySkill` for writes to built-in slugs.
    func resolveSkillsPath(_ relative: String, forWriting: Bool = false) throws -> SkillMountResolution {
        // Empty → mount root listing.
        if relative.isEmpty {
            return SkillMountResolution(url: skillsRoot, slug: nil, isBuiltIn: false)
        }
        guard Self.isSafeRelativePath(relative) else {
            throw FileToolError.unsafeFilename(relative)
        }
        // First path component is the slug; everything after is the in-package path.
        let parts = relative.split(separator: "/", maxSplits: 1, omittingEmptySubsequences: false)
        let slug = String(parts[0])
        let remainder = parts.count > 1 ? String(parts[1]) : ""

        if BuiltInSkills.shippedSlugs.contains(slug) {
            if forWriting {
                throw FileToolError.readOnlySkill(slug)
            }
            // Built-in: route to the bundle. Read-only by construction.
            guard let pkg = BuiltInSkillsDirectoryLoader.packageURL(forSlug: slug) else {
                throw FileToolError.fileNotFound(relative)
            }
            let url = remainder.isEmpty
                ? pkg.standardizedFileURL
                : pkg.appendingPathComponent(remainder).standardizedFileURL
            // Containment check against the built-in package root — the
            // sanitized relative path can't escape, but standardize-and-check
            // is cheap belt-and-suspenders.
            let basePath = pkg.standardizedFileURL.path.hasSuffix("/")
                ? pkg.standardizedFileURL.path
                : pkg.standardizedFileURL.path + "/"
            guard url.path == pkg.standardizedFileURL.path || url.path.hasPrefix(basePath) else {
                throw FileToolError.unsafeFilename(relative)
            }
            return SkillMountResolution(url: url, slug: slug, isBuiltIn: true)
        }

        // User skill: route to <Documents>/Skills/<slug>/...
        let base = skillsRoot.standardizedFileURL
        let target = base.appendingPathComponent(relative).standardizedFileURL
        let basePath = base.path.hasSuffix("/") ? base.path : base.path + "/"
        guard target.path == base.path || target.path.hasPrefix(basePath) else {
            throw FileToolError.unsafeFilename(relative)
        }
        return SkillMountResolution(url: target, slug: slug, isBuiltIn: false)
    }

    // MARK: - Agent ID Resolution

    /// Walk the parentAgent chain to find the top-level (root) agent ID.
    /// Sub-agents share the root agent's file folder.
    ///
    /// - Important: This traverses SwiftData `@Relationship` properties (`parentAgent`).
    ///   All callers must be on `@MainActor` to avoid concurrent relationship faulting.
    func resolveAgentId(for agent: Agent) -> UUID {
        var current = agent
        while let parent = current.parentAgent {
            current = parent
        }
        return current.id
    }

    // MARK: - Directory

    func agentDirectory(for agentId: UUID) -> URL {
        rootDirectory.appendingPathComponent(agentId.uuidString, isDirectory: true)
    }

    @discardableResult
    private func ensureDirectory(for agentId: UUID) throws -> URL {
        let dir = agentDirectory(for: agentId)
        if !fm.fileExists(atPath: dir.path) {
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        return dir
    }

    /// Resolve a relative path under the agent's directory. Validates against path
    /// traversal and ensures the final URL stays within the agent's directory
    /// (second line of defense against symlink escapes).
    ///
    /// Special case: paths under the reserved `skills/` mount are routed to a
    /// shared location instead of the per-agent directory — the read-only app
    /// bundle for built-ins, the writable `<Documents>/Skills/<slug>/` for
    /// user skills. When `forWriting` is true, writes to built-in slugs throw
    /// `FileToolError.readOnlySkill`. Other absolute-style paths (`/foo`)
    /// continue to be rejected as today; only the `/skills/` form is
    /// normalized so JS callers can write `fs.writeFile('/skills/foo/...')`.
    func resolvedURL(agentId: UUID, path: String, forWriting: Bool = false) throws -> URL {
        // JS-side leading slash on the skills mount only: `/skills/foo` →
        // `skills/foo`. All other absolute-style paths stay unsafe.
        let normalized: String
        if path == "/" + Self.skillsMountComponent || path.hasPrefix("/" + Self.skillsMountComponent + "/") {
            normalized = String(path.dropFirst())
        } else {
            normalized = path
        }

        if Self.isSkillsMountPath(normalized) {
            let remainder = normalized == Self.skillsMountComponent
                ? ""
                : String(normalized.dropFirst(Self.skillsMountComponent.count + 1))
            return try resolveSkillsPath(remainder, forWriting: forWriting).url
        }
        guard Self.isSafeRelativePath(normalized) else {
            throw FileToolError.unsafeFilename(normalized)
        }
        let base = agentDirectory(for: agentId).standardizedFileURL
        let target = base.appendingPathComponent(normalized).standardizedFileURL
        let basePath = base.path.hasSuffix("/") ? base.path : base.path + "/"
        guard target.path == base.path || target.path.hasPrefix(basePath) else {
            throw FileToolError.unsafeFilename(normalized)
        }
        return target
    }

    // MARK: - File CRUD

    /// List direct children of the given subdirectory (relative `path`, default root).
    func listFiles(agentId: UUID, path: String = "") -> [FileInfo] {
        let dir: URL
        if path.isEmpty {
            dir = agentDirectory(for: agentId)
        } else {
            guard let resolved = try? resolvedURL(agentId: agentId, path: path) else { return [] }
            dir = resolved
        }
        guard let contents = try? fm.contentsOfDirectory(
            at: dir,
            includingPropertiesForKeys: [.fileSizeKey, .creationDateKey, .contentModificationDateKey, .isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }

        return contents.compactMap { url in
            guard let attrs = try? url.resourceValues(forKeys: [.fileSizeKey, .creationDateKey, .contentModificationDateKey, .isDirectoryKey]) else {
                return nil
            }
            let name = url.lastPathComponent
            let ext = url.pathExtension.lowercased()
            let isDir = attrs.isDirectory ?? false
            return FileInfo(
                name: name,
                size: Int64(attrs.fileSize ?? 0),
                createdAt: attrs.creationDate ?? Date(),
                modifiedAt: attrs.contentModificationDate ?? Date(),
                isImage: !isDir && Self.imageExtensions.contains(ext),
                isVideo: !isDir && Self.videoExtensions.contains(ext),
                isDirectory: isDir
            )
        }.sorted { lhs, rhs in
            if lhs.isDirectory != rhs.isDirectory { return lhs.isDirectory && !rhs.isDirectory }
            return lhs.modifiedAt > rhs.modifiedAt
        }
    }

    @discardableResult
    func writeFile(agentId: UUID, name: String, data: Data) throws -> URL {
        try ensureDirectory(for: agentId)
        let url = try resolvedURL(agentId: agentId, path: name, forWriting: true)
        let parent = url.deletingLastPathComponent()
        if !fm.fileExists(atPath: parent.path) {
            try fm.createDirectory(at: parent, withIntermediateDirectories: true)
        }
        try data.write(to: url, options: .atomic)
        return url
    }

    func readFile(agentId: UUID, name: String) throws -> Data {
        let url = try resolvedURL(agentId: agentId, path: name)
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: url.path, isDirectory: &isDir), !isDir.boolValue else {
            throw FileToolError.fileNotFound(name)
        }
        return try Data(contentsOf: url)
    }

    /// Delete a file or directory (recursive for directories) at the given relative path.
    func deleteFile(agentId: UUID, name: String) throws {
        let url = try resolvedURL(agentId: agentId, path: name, forWriting: true)
        guard fm.fileExists(atPath: url.path) else {
            throw FileToolError.fileNotFound(name)
        }
        try fm.removeItem(at: url)
    }

    func fileExists(agentId: UUID, name: String) -> Bool {
        guard let url = try? resolvedURL(agentId: agentId, path: name) else { return false }
        return fm.fileExists(atPath: url.path)
    }

    func fileURL(agentId: UUID, name: String) -> URL {
        (try? resolvedURL(agentId: agentId, path: name))
            ?? agentDirectory(for: agentId).appendingPathComponent(name)
    }

    func fileInfo(agentId: UUID, name: String) -> FileInfo? {
        guard let url = try? resolvedURL(agentId: agentId, path: name) else { return nil }
        guard let attrs = try? url.resourceValues(forKeys: [.fileSizeKey, .creationDateKey, .contentModificationDateKey, .isDirectoryKey]),
              fm.fileExists(atPath: url.path) else { return nil }
        let ext = url.pathExtension.lowercased()
        let isDir = attrs.isDirectory ?? false
        return FileInfo(
            name: (name as NSString).lastPathComponent,
            size: Int64(attrs.fileSize ?? 0),
            createdAt: attrs.creationDate ?? Date(),
            modifiedAt: attrs.contentModificationDate ?? Date(),
            isImage: !isDir && Self.imageExtensions.contains(ext),
            isVideo: !isDir && Self.videoExtensions.contains(ext),
            isDirectory: isDir
        )
    }

    /// Create a directory (including intermediate components) under the agent's folder.
    /// Idempotent — returns without error if the directory already exists.
    @discardableResult
    func makeDirectory(agentId: UUID, path: String) throws -> URL {
        try ensureDirectory(for: agentId)
        let url = try resolvedURL(agentId: agentId, path: path, forWriting: true)
        var isDir: ObjCBool = false
        if fm.fileExists(atPath: url.path, isDirectory: &isDir) {
            if isDir.boolValue { return url }
            throw FileToolError.fileAlreadyExists(path)
        }
        try fm.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// Copy a file or directory from `src` to `dest` (both relative to the agent's folder).
    /// Creates missing destination parents. When the source is a directory, copies recursively
    /// iff `recursive` is true; otherwise throws.
    @discardableResult
    func copyFile(agentId: UUID, src: String, dest: String, recursive: Bool = true) throws -> URL {
        try ensureDirectory(for: agentId)
        // src is read; dest is written. Reading from a built-in skill (the
        // fork-then-edit pattern) must be allowed — only `dest` carries the
        // write-mode constraint.
        let srcURL = try resolvedURL(agentId: agentId, path: src)
        let destURL = try resolvedURL(agentId: agentId, path: dest, forWriting: true)
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: srcURL.path, isDirectory: &isDir) else {
            throw FileToolError.fileNotFound(src)
        }
        if isDir.boolValue && !recursive {
            throw FileToolError.isDirectory(src)
        }
        let parent = destURL.deletingLastPathComponent()
        if !fm.fileExists(atPath: parent.path) {
            try fm.createDirectory(at: parent, withIntermediateDirectories: true)
        }
        if fm.fileExists(atPath: destURL.path) {
            throw FileToolError.fileAlreadyExists(dest)
        }
        try fm.copyItem(at: srcURL, to: destURL)
        return destURL
    }

    /// Move or rename a file/directory from `src` to `dest` (both relative to the agent's folder).
    /// Creates missing destination parents. Fails if destination already exists.
    @discardableResult
    func moveFile(agentId: UUID, src: String, dest: String) throws -> URL {
        try ensureDirectory(for: agentId)
        // Both src and dest must be writable: a move removes the source.
        let srcURL = try resolvedURL(agentId: agentId, path: src, forWriting: true)
        let destURL = try resolvedURL(agentId: agentId, path: dest, forWriting: true)
        guard fm.fileExists(atPath: srcURL.path) else {
            throw FileToolError.fileNotFound(src)
        }
        let parent = destURL.deletingLastPathComponent()
        if !fm.fileExists(atPath: parent.path) {
            try fm.createDirectory(at: parent, withIntermediateDirectories: true)
        }
        if fm.fileExists(atPath: destURL.path) {
            throw FileToolError.fileAlreadyExists(dest)
        }
        try fm.moveItem(at: srcURL, to: destURL)
        return destURL
    }

    /// Truncate a regular file to exactly `length` bytes. Extends with zero bytes if the
    /// file is shorter than `length`; shrinks if longer. Creates the file if it doesn't exist.
    func truncateFile(agentId: UUID, path: String, length: UInt64) throws {
        try ensureDirectory(for: agentId)
        let url = try resolvedURL(agentId: agentId, path: path, forWriting: true)
        let parent = url.deletingLastPathComponent()
        if !fm.fileExists(atPath: parent.path) {
            try fm.createDirectory(at: parent, withIntermediateDirectories: true)
        }
        var isDir: ObjCBool = false
        if !fm.fileExists(atPath: url.path, isDirectory: &isDir) {
            fm.createFile(atPath: url.path, contents: nil)
        } else if isDir.boolValue {
            throw FileToolError.isDirectory(path)
        }
        let handle = try FileHandle(forUpdating: url)
        defer { try? handle.close() }
        let current = try handle.seekToEnd()
        if length < current {
            try handle.truncate(atOffset: length)
        } else if length > current {
            try handle.seek(toOffset: current)
            let pad = Data(count: Int(length - current))
            try handle.write(contentsOf: pad)
        }
    }

    /// Append raw bytes to a file (creating the file + missing parent dirs as needed).
    @discardableResult
    func appendFile(agentId: UUID, name: String, data: Data) throws -> URL {
        try ensureDirectory(for: agentId)
        let url = try resolvedURL(agentId: agentId, path: name, forWriting: true)
        let parent = url.deletingLastPathComponent()
        if !fm.fileExists(atPath: parent.path) {
            try fm.createDirectory(at: parent, withIntermediateDirectories: true)
        }
        if !fm.fileExists(atPath: url.path) {
            try data.write(to: url, options: .atomic)
            return url
        }
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        _ = try handle.seekToEnd()
        try handle.write(contentsOf: data)
        return url
    }

    // MARK: - Image Support

    /// Save an image to the agent's folder, returning a `fileReference` string.
    /// The full-resolution image is written to disk; the caller should store a thumbnail in `imageData`.
    func saveImage(_ imageData: Data, mimeType: String, agentId: UUID) -> String? {
        let ext = Self.extensionForMime(mimeType)
        let name = "img_\(UUID().uuidString.prefix(8)).\(ext)"
        do {
            try writeFile(agentId: agentId, name: name, data: imageData)
            os_log(.info, log: fileLog, "Saved image %{public}@ for agent %{public}@", name, agentId.uuidString)
            return Self.makeFileReference(agentId: agentId, filename: name)
        } catch {
            os_log(.error, log: fileLog, "Failed to save image: %{public}@", error.localizedDescription)
            return nil
        }
    }

    /// Save video data to the agent's file directory and return the `agentfile://` reference.
    func saveVideo(_ videoData: Data, extension ext: String = "mp4", agentId: UUID) -> String? {
        let name = "vid_\(UUID().uuidString.prefix(8)).\(ext)"
        do {
            try writeFile(agentId: agentId, name: name, data: videoData)
            os_log(.info, log: fileLog, "Saved video %{public}@ for agent %{public}@", name, agentId.uuidString)
            return Self.makeFileReference(agentId: agentId, filename: name)
        } catch {
            os_log(.error, log: fileLog, "Failed to save video: %{public}@", error.localizedDescription)
            return nil
        }
    }

    /// Load image data from a `agentfile://` reference.
    func loadImageData(from fileReference: String) -> Data? {
        guard let (agentId, filename) = Self.parseFileReference(fileReference) else { return nil }
        return try? readFile(agentId: agentId, name: filename)
    }

    // MARK: - File Reference

    static let fileReferenceScheme = "agentfile"

    static func makeFileReference(agentId: UUID, filename: String) -> String {
        "\(fileReferenceScheme)://\(agentId.uuidString)/\(filename)"
    }

    /// Parse `agentfile://<agentId>/<path>` → (agentId, path). Path may include subdirectories.
    static func parseFileReference(_ ref: String) -> (UUID, String)? {
        guard ref.hasPrefix("\(fileReferenceScheme)://") else { return nil }
        let path = String(ref.dropFirst("\(fileReferenceScheme)://".count))
        guard let slashIdx = path.firstIndex(of: "/") else { return nil }
        let idStr = String(path[..<slashIdx])
        let filename = String(path[path.index(after: slashIdx)...])
        guard let uuid = UUID(uuidString: idStr), !filename.isEmpty, isSafeRelativePath(filename) else { return nil }
        return (uuid, filename)
    }

    // MARK: - Cleanup

    func cleanupAgentFiles(agentId: UUID) {
        let dir = agentDirectory(for: agentId)
        try? fm.removeItem(at: dir)
        os_log(.info, log: fileLog, "Cleaned up files for agent %{public}@", agentId.uuidString)
    }

    /// Remove directories that don't correspond to any known agent ID.
    func cleanupOrphanDirectories(knownAgentIds: Set<UUID>) {
        guard let contents = try? fm.contentsOfDirectory(
            at: rootDirectory, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]
        ) else { return }
        for url in contents {
            if let uuid = UUID(uuidString: url.lastPathComponent), !knownAgentIds.contains(uuid) {
                try? fm.removeItem(at: url)
                os_log(.info, log: fileLog, "Removed orphan dir %{public}@", url.lastPathComponent)
            }
        }
    }

    // MARK: - Safety

    /// Single-component filename check: rejects any name containing `/` or `\`.
    static func isSafeFilename(_ name: String) -> Bool {
        guard !name.isEmpty, name.count <= 255 else { return false }
        if name.contains("/") || name.contains("\\") || name.contains("\0") { return false }
        if name == "." || name == ".." || name.hasPrefix("..") { return false }
        return true
    }

    /// Relative-path check: allows `/` as component separator but rejects absolute paths,
    /// empty components, `.`/`..` components, null bytes, and backslashes.
    static func isSafeRelativePath(_ path: String) -> Bool {
        guard !path.isEmpty, path.count <= 4096 else { return false }
        if path.hasPrefix("/") || path.contains("\\") || path.contains("\0") { return false }
        let components = path.split(separator: "/", omittingEmptySubsequences: false)
        for comp in components {
            let c = String(comp)
            if c.isEmpty { return false }
            if c == "." || c == ".." { return false }
            if c.count > 255 { return false }
        }
        return true
    }

    // MARK: - Helpers

    private static let imageExtensions: Set<String> = [
        "jpg", "jpeg", "png", "gif", "webp", "heic", "heif", "bmp", "tiff", "tif", "svg"
    ]

    static let videoExtensions: Set<String> = [
        "mp4", "mov", "m4v", "webm", "avi", "mkv"
    ]

    private static func extensionForMime(_ mime: String) -> String {
        switch mime.lowercased() {
        case "image/png": return "png"
        case "image/gif": return "gif"
        case "image/webp": return "webp"
        case "image/heic": return "heic"
        case "image/bmp": return "bmp"
        case "image/tiff": return "tiff"
        case "image/svg+xml": return "svg"
        default: return "jpg"
        }
    }
}

// MARK: - FileInfo

struct FileInfo: Identifiable {
    let name: String
    let size: Int64
    let createdAt: Date
    let modifiedAt: Date
    let isImage: Bool
    let isVideo: Bool
    let isDirectory: Bool

    init(
        name: String,
        size: Int64,
        createdAt: Date,
        modifiedAt: Date,
        isImage: Bool,
        isVideo: Bool,
        isDirectory: Bool = false
    ) {
        self.name = name
        self.size = size
        self.createdAt = createdAt
        self.modifiedAt = modifiedAt
        self.isImage = isImage
        self.isVideo = isVideo
        self.isDirectory = isDirectory
    }

    var id: String { name }

    private static let htmlExtensions: Set<String> = ["html", "htm"]

    var isHTML: Bool {
        let ext = (name as NSString).pathExtension.lowercased()
        return Self.htmlExtensions.contains(ext)
    }

    var isTextPreviewable: Bool {
        let ext = (name as NSString).pathExtension.lowercased()
        return TextFilePreviewCoordinator.textExtensions.contains(ext)
    }

    var formattedSize: String {
        if isDirectory { return "—" }
        return ByteCountFormatter.string(fromByteCount: size, countStyle: .file)
    }
}

// MARK: - Errors

enum FileToolError: LocalizedError {
    case unsafeFilename(String)
    case fileNotFound(String)
    case fileAlreadyExists(String)
    case isDirectory(String)
    case invalidFlag(String)
    case invalidFd(Int)
    case tooManyFds
    case readOnlySkill(String)

    var errorDescription: String? {
        switch self {
        case .unsafeFilename(let name): return "Unsafe path: \(name)"
        case .fileNotFound(let name): return "File not found: \(name)"
        case .fileAlreadyExists(let name): return "File already exists: \(name)"
        case .isDirectory(let name): return "Is a directory: \(name)"
        case .invalidFlag(let flag): return "Invalid open flag: \(flag)"
        case .invalidFd(let fd): return "Invalid file descriptor: \(fd)"
        case .tooManyFds: return "Too many open descriptors"
        case .readOnlySkill(let slug):
            return "Cannot modify built-in skill '\(slug)' (read-only). Fork it first: fs.cp('skills/\(slug)', 'skills/<new-slug>', {recursive: true})."
        }
    }
}
