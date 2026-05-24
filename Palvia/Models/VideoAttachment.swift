import Foundation
import UIKit
import AVFoundation

struct VideoAttachment: Codable, Identifiable {
    let id: UUID
    /// Thumbnail image data (JPEG). Full video lives on disk via `fileReference`.
    let thumbnailData: Data
    let mimeType: String
    let width: Int
    let height: Int
    let duration: TimeInterval
    let fileSize: Int64

    /// When non-nil, the full video lives on disk at this reference
    /// (format: `agentfile://<agentId>/<filename>`).
    var fileReference: String?

    // MARK: - Size & Duration Limits

    /// Maximum file size for inline base64 API transmission (20 MB).
    static let maxInlineFileSize: Int64 = 20 * 1024 * 1024

    /// Maximum video duration for API submission (2 minutes).
    static let maxDurationSeconds: TimeInterval = 120

    /// Maximum resolution (longest edge) to send to API.
    static let maxResolution: Int = 720

    /// Validation result for video eligibility.
    enum ValidationResult {
        case valid
        case tooLarge(fileSize: Int64, limit: Int64)
        case tooLong(duration: TimeInterval, limit: TimeInterval)
        case tooLargeAndLong(fileSize: Int64, sizeLimit: Int64, duration: TimeInterval, durationLimit: TimeInterval)
    }

    /// Check whether the video meets size and duration limits for inline API transmission.
    var validationResult: ValidationResult {
        let oversized = fileSize > Self.maxInlineFileSize
        let overlong = duration > Self.maxDurationSeconds
        if oversized && overlong {
            return .tooLargeAndLong(
                fileSize: fileSize, sizeLimit: Self.maxInlineFileSize,
                duration: duration, durationLimit: Self.maxDurationSeconds
            )
        } else if oversized {
            return .tooLarge(fileSize: fileSize, limit: Self.maxInlineFileSize)
        } else if overlong {
            return .tooLong(duration: duration, limit: Self.maxDurationSeconds)
        }
        return .valid
    }

    /// Whether this video exceeds inline transmission limits and requires preprocessing.
    var needsPreprocessing: Bool {
        if case .valid = validationResult { return false }
        return true
    }

    /// Base64 data URI of the full video (for API transmission).
    /// Returns nil if the file is missing or exceeds the inline size limit.
    var base64DataURI: String? {
        guard fileSize <= Self.maxInlineFileSize else { return nil }
        guard let data = resolvedVideoData else { return nil }
        return "data:\(mimeType);base64,\(data.base64EncodedString())"
    }

    /// Load the full video data from disk.
    var resolvedVideoData: Data? {
        guard let fileReference else { return nil }
        guard let (agentId, filename) = AgentFileManager.parseFileReference(fileReference) else { return nil }
        let url = AgentFileManager.shared.fileURL(agentId: agentId, name: filename)
        return try? Data(contentsOf: url)
    }

    /// Whether the original file has been deleted by the user.
    var isFileDeleted: Bool {
        guard let fileReference else { return false }
        guard let (agentId, filename) = AgentFileManager.parseFileReference(fileReference) else { return true }
        return !AgentFileManager.shared.fileExists(agentId: agentId, name: filename)
    }

    /// Thumbnail as UIImage.
    var thumbnailImage: UIImage? {
        thumbnailData.isEmpty ? nil : UIImage(data: thumbnailData)
    }

    /// Human-readable duration string.
    var durationString: String {
        let mins = Int(duration) / 60
        let secs = Int(duration) % 60
        return String(format: "%d:%02d", mins, secs)
    }

    /// Human-readable file size string.
    var fileSizeString: String {
        ByteCountFormatter.string(fromByteCount: fileSize, countStyle: .file)
    }

    // MARK: - Factory Methods

    /// Create from an agentfile:// reference by extracting metadata from the video on disk.
    static func from(fileReference ref: String) async -> VideoAttachment? {
        guard let (agentId, filename) = AgentFileManager.parseFileReference(ref) else { return nil }
        let url = AgentFileManager.shared.fileURL(agentId: agentId, name: filename)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }

        let asset = AVURLAsset(url: url)
        guard let cmDuration = try? await asset.load(.duration) else { return nil }
        let duration = CMTimeGetSeconds(cmDuration)
        guard duration.isFinite, duration > 0 else { return nil }

        var width = 0, height = 0
        if let tracks = try? await asset.loadTracks(withMediaType: .video),
           let track = tracks.first {
            if let naturalSize = try? await track.load(.naturalSize),
               let transform = try? await track.load(.preferredTransform) {
                let size = naturalSize.applying(transform)
                width = Int(abs(size.width))
                height = Int(abs(size.height))
            }
        }

        let fileSize: Int64
        if let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
           let size = attrs[.size] as? Int64 {
            fileSize = size
        } else {
            fileSize = 0
        }

        let thumbnail = await generateThumbnail(from: url)
        let ext = (filename as NSString).pathExtension.lowercased()

        return VideoAttachment(
            id: UUID(),
            thumbnailData: thumbnail,
            mimeType: mimeTypeForExtension(ext),
            width: width,
            height: height,
            duration: duration,
            fileSize: fileSize,
            fileReference: ref
        )
    }

    /// Create from raw video data, saving to the agent's file folder.
    static func from(data: Data, filename: String, agentId: UUID) async -> VideoAttachment? {
        let ext = (filename as NSString).pathExtension.lowercased()
        guard supportedExtensions.contains(ext) else { return nil }

        do {
            try AgentFileManager.shared.writeFile(agentId: agentId, name: filename, data: data)
        } catch {
            return nil
        }

        let ref = AgentFileManager.makeFileReference(agentId: agentId, filename: filename)
        return await from(fileReference: ref)
    }

    // MARK: - Supported Formats

    static let supportedExtensions: Set<String> = [
        "mp4", "mov", "m4v", "webm"
    ]

    // MARK: - Thumbnail

    static func generateThumbnail(from url: URL, maxDimension: CGFloat = 128) async -> Data {
        let asset = AVURLAsset(url: url)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: maxDimension, height: maxDimension)

        let durationSeconds: Double
        if let cmDuration = try? await asset.load(.duration) {
            durationSeconds = CMTimeGetSeconds(cmDuration)
        } else {
            durationSeconds = 2.0
        }
        let time = CMTime(seconds: min(1.0, durationSeconds / 2), preferredTimescale: 600)
        guard let cgImage = try? generator.copyCGImage(at: time, actualTime: nil) else {
            return Data()
        }
        let image = UIImage(cgImage: cgImage)
        return image.jpegData(compressionQuality: 0.5) ?? Data()
    }

    // MARK: - MIME Types

    static func mimeTypeForExtension(_ ext: String) -> String {
        switch ext {
        case "mp4": return "video/mp4"
        case "mov": return "video/quicktime"
        case "m4v": return "video/x-m4v"
        case "webm": return "video/webm"
        case "avi": return "video/x-msvideo"
        case "mkv": return "video/x-matroska"
        default: return "video/mp4"
        }
    }
}
