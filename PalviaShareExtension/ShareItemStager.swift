import Foundation
import UniformTypeIdentifiers
import UIKit
import os.log

private let stagerLog = OSLog(subsystem: "com.iclaw.share", category: "stager")

/// Extracts attachments from `NSExtensionItem`s, writes each one to the App
/// Group's staging directory, and emits a `HandoffManifest`.
///
/// Runs inside the Share Extension process. Must not import SwiftData or the
/// main app's `AgentFileManager` (those live in the main app target).
enum ShareItemStager {

    /// Stage every attachment across the extension's input items. Returns the
    /// `handoffId` on success, or `nil` if nothing was staged.
    static func stage(
        items: [NSExtensionItem],
        agentId: UUID
    ) async -> UUID? {
        guard let stagingRoot = SharedContainer.ensureStagingDirectory() else {
            os_log(.error, log: stagerLog,
                   "App Group container unavailable — check that group.com.iclaw.app is enabled on both targets' entitlements")
            return nil
        }

        let handoffId = UUID()
        let dir = stagingRoot.appendingPathComponent(handoffId.uuidString, isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        } catch {
            os_log(.error, log: stagerLog, "Failed to create staging dir: %{public}@", String(describing: error))
            return nil
        }

        var files: [HandoffFile] = []
        var collectedText: String = ""

        for item in items {
            for provider in item.attachments ?? [] {
                if let file = await stageProvider(provider, into: dir) {
                    files.append(file)
                } else if let text = await extractText(from: provider) {
                    if !collectedText.isEmpty { collectedText += "\n\n" }
                    collectedText += text
                } else {
                    os_log(.default, log: stagerLog,
                           "Provider yielded no file or text; registeredTypeIdentifiers=%{public}@",
                           provider.registeredTypeIdentifiers.joined(separator: ","))
                }
            }
        }

        // Bundle any collected text/URL attachments into a single text file.
        if !collectedText.isEmpty {
            let name = "shared_\(UUID().uuidString.prefix(6)).txt"
            let url = dir.appendingPathComponent(name)
            if let data = collectedText.data(using: .utf8),
               (try? data.write(to: url, options: .atomic)) != nil {
                files.append(HandoffFile(name: name, kind: .text, displayName: nil))
            }
        }

        guard !files.isEmpty else {
            os_log(.error, log: stagerLog, "No files staged for handoff %{public}@ — aborting",
                   handoffId.uuidString)
            try? FileManager.default.removeItem(at: dir)
            return nil
        }

        let manifest = HandoffManifest(
            version: HandoffManifest.currentVersion,
            agentId: agentId,
            files: files
        )
        do {
            try manifest.write(to: dir)
        } catch {
            os_log(.error, log: stagerLog, "Failed to write manifest: %{public}@",
                   String(describing: error))
            try? FileManager.default.removeItem(at: dir)
            return nil
        }

        os_log(.default, log: stagerLog, "Staged %d files in %{public}@", files.count, handoffId.uuidString)
        return handoffId
    }

    // MARK: - Per-provider staging

    private static func stageProvider(
        _ provider: NSItemProvider,
        into dir: URL
    ) async -> HandoffFile? {
        // Probe type identifiers in priority order.
        if provider.hasItemConformingToTypeIdentifier(UTType.movie.identifier) {
            if let file = await copyAsFile(
                provider: provider,
                typeId: UTType.movie.identifier,
                into: dir,
                namePrefix: "vid",
                defaultExt: "mov",
                kind: .video
            ) {
                return file
            }
        }

        if provider.hasItemConformingToTypeIdentifier(UTType.image.identifier) {
            if let file = await stageImage(provider: provider, into: dir) {
                return file
            }
        }

        if provider.hasItemConformingToTypeIdentifier(UTType.pdf.identifier) {
            if let file = await copyAsFile(
                provider: provider,
                typeId: UTType.pdf.identifier,
                into: dir,
                namePrefix: "doc",
                defaultExt: "pdf",
                kind: .file
            ) {
                return file
            }
        }

        if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
            if let file = await stageFileURL(provider: provider, into: dir) {
                return file
            }
        }

        if provider.hasItemConformingToTypeIdentifier(UTType.data.identifier) {
            if let file = await copyAsFile(
                provider: provider,
                typeId: UTType.data.identifier,
                into: dir,
                namePrefix: "file",
                defaultExt: "bin",
                kind: .file
            ) {
                return file
            }
        }

        return nil
    }

    private static func stageImage(provider: NSItemProvider, into dir: URL) async -> HandoffFile? {
        // Images can arrive as URL, UIImage, or Data.
        if let item = try? await provider.loadItem(forTypeIdentifier: UTType.image.identifier, options: nil) {
            if let url = item as? URL {
                return copyFile(from: url, into: dir, namePrefix: "img", defaultExt: "jpg", kind: .image)
            }
            if let data = item as? Data {
                let ext = extensionForImageData(data) ?? "jpg"
                return writeData(data, into: dir, namePrefix: "img", ext: ext, kind: .image)
            }
            if let image = item as? UIImage, let data = image.jpegData(compressionQuality: 0.9) {
                return writeData(data, into: dir, namePrefix: "img", ext: "jpg", kind: .image)
            }
        }
        return nil
    }

    private static func stageFileURL(provider: NSItemProvider, into dir: URL) async -> HandoffFile? {
        guard let item = try? await provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil),
              let url = item as? URL else {
            return nil
        }
        let kind = kindForExtension(url.pathExtension.lowercased())
        return copyFile(
            from: url,
            into: dir,
            namePrefix: "file",
            defaultExt: "bin",
            kind: kind,
            preserveOriginalName: true
        )
    }

    private static func copyAsFile(
        provider: NSItemProvider,
        typeId: String,
        into dir: URL,
        namePrefix: String,
        defaultExt: String,
        kind: HandoffFileKind
    ) async -> HandoffFile? {
        guard let item = try? await provider.loadItem(forTypeIdentifier: typeId, options: nil) else {
            return nil
        }
        if let url = item as? URL {
            return copyFile(from: url, into: dir, namePrefix: namePrefix, defaultExt: defaultExt, kind: kind)
        }
        if let data = item as? Data {
            return writeData(data, into: dir, namePrefix: namePrefix, ext: defaultExt, kind: kind)
        }
        return nil
    }

    // MARK: - Text extraction

    private static func extractText(from provider: NSItemProvider) async -> String? {
        if provider.hasItemConformingToTypeIdentifier(UTType.url.identifier) {
            if let item = try? await provider.loadItem(forTypeIdentifier: UTType.url.identifier, options: nil) {
                if let url = item as? URL {
                    return url.absoluteString
                }
                if let s = item as? String {
                    return s
                }
            }
        }
        if provider.hasItemConformingToTypeIdentifier(UTType.plainText.identifier) {
            if let item = try? await provider.loadItem(forTypeIdentifier: UTType.plainText.identifier, options: nil),
               let text = item as? String {
                return text
            }
        }
        return nil
    }

    // MARK: - Low-level write helpers

    private static func copyFile(
        from src: URL,
        into dir: URL,
        namePrefix: String,
        defaultExt: String,
        kind: HandoffFileKind,
        preserveOriginalName: Bool = false
    ) -> HandoffFile? {
        let ext = src.pathExtension.isEmpty ? defaultExt : src.pathExtension
        let name: String
        if preserveOriginalName, isSafeFilename(src.lastPathComponent) {
            name = uniqueFilename(preferred: src.lastPathComponent, in: dir)
        } else {
            name = "\(namePrefix)_\(UUID().uuidString.prefix(8)).\(ext)"
        }
        let dst = dir.appendingPathComponent(name)
        let accessed = src.startAccessingSecurityScopedResource()
        defer { if accessed { src.stopAccessingSecurityScopedResource() } }
        do {
            try FileManager.default.copyItem(at: src, to: dst)
            return HandoffFile(name: name, kind: kind, displayName: src.lastPathComponent)
        } catch {
            // Fall back to reading into memory then writing.
            if let data = try? Data(contentsOf: src),
               (try? data.write(to: dst, options: .atomic)) != nil {
                return HandoffFile(name: name, kind: kind, displayName: src.lastPathComponent)
            }
            return nil
        }
    }

    private static func writeData(
        _ data: Data,
        into dir: URL,
        namePrefix: String,
        ext: String,
        kind: HandoffFileKind
    ) -> HandoffFile? {
        let name = "\(namePrefix)_\(UUID().uuidString.prefix(8)).\(ext)"
        let url = dir.appendingPathComponent(name)
        do {
            try data.write(to: url, options: .atomic)
            return HandoffFile(name: name, kind: kind, displayName: nil)
        } catch {
            return nil
        }
    }

    private static func uniqueFilename(preferred: String, in dir: URL) -> String {
        let dst = dir.appendingPathComponent(preferred)
        guard FileManager.default.fileExists(atPath: dst.path) else { return preferred }
        let ns = preferred as NSString
        let base = ns.deletingPathExtension
        let ext = ns.pathExtension
        let suffix = UUID().uuidString.prefix(6)
        return ext.isEmpty ? "\(base)_\(suffix)" : "\(base)_\(suffix).\(ext)"
    }

    // MARK: - Classification

    private static func kindForExtension(_ ext: String) -> HandoffFileKind {
        let imageExts: Set<String> = ["jpg", "jpeg", "png", "gif", "webp", "heic", "heif", "bmp", "tiff", "tif", "svg"]
        let videoExts: Set<String> = ["mp4", "mov", "m4v", "webm", "avi", "mkv"]
        if imageExts.contains(ext) { return .image }
        if videoExts.contains(ext) { return .video }
        return .file
    }

    private static func extensionForImageData(_ data: Data) -> String? {
        guard let first = data.first else { return nil }
        switch first {
        case 0xFF: return "jpg"
        case 0x89: return "png"
        case 0x47: return "gif"
        case 0x42: return "bmp"
        case 0x49, 0x4D: return "tiff"
        default: return nil
        }
    }

    private static func isSafeFilename(_ name: String) -> Bool {
        guard !name.isEmpty, name.count <= 255 else { return false }
        if name.contains("/") || name.contains("\\") || name.contains("\0") { return false }
        if name == "." || name == ".." || name.hasPrefix("..") { return false }
        return true
    }
}
