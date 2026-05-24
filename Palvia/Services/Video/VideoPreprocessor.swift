import Foundation
import AVFoundation

/// Preprocesses video files to meet API size, duration, and format requirements.
/// Uses AVAssetExportSession for transcoding to H.264+AAC with configurable resolution and duration limits.
final class VideoPreprocessor {

    enum PreprocessError: LocalizedError {
        case exportFailed(String)
        case cancelled
        case noVideoTrack

        var errorDescription: String? {
            switch self {
            case .exportFailed(let reason): return "Video export failed: \(reason)"
            case .cancelled: return "Video preprocessing was cancelled."
            case .noVideoTrack: return "No video track found in file."
            }
        }
    }

    struct Options {
        /// Maximum file size in bytes (default: 20 MB).
        var maxFileSize: Int64 = VideoAttachment.maxInlineFileSize
        /// Maximum duration in seconds (default: 120s).
        var maxDuration: TimeInterval = VideoAttachment.maxDurationSeconds
        /// Maximum resolution for longest edge (default: 720px).
        var maxResolution: Int = VideoAttachment.maxResolution
        /// Export preset (default: medium quality for balance of size and clarity).
        var preset: String = AVAssetExportPresetMediumQuality
    }

    /// Preprocess a video file, transcoding/trimming as needed.
    /// Returns the URL of the processed file (may be the original if no processing needed).
    static func preprocess(
        url: URL,
        options: Options = Options()
    ) async throws -> URL {
        let asset = AVURLAsset(url: url)
        let cmDuration = try await asset.load(.duration)
        let duration = CMTimeGetSeconds(cmDuration)

        // Check if processing is actually needed
        let fileSize = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int64) ?? 0
        let needsTrim = duration > options.maxDuration
        let needsResize = try await needsResolution(asset: asset, maxResolution: options.maxResolution)
        let needsSizeReduction = fileSize > options.maxFileSize

        if !needsTrim && !needsResize && !needsSizeReduction {
            return url // No processing needed
        }

        guard let exportSession = AVAssetExportSession(asset: asset, presetName: options.preset) else {
            throw PreprocessError.exportFailed("Failed to create export session with preset \(options.preset)")
        }

        let outputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("mp4")

        exportSession.outputURL = outputURL
        exportSession.outputFileType = .mp4
        exportSession.shouldOptimizeForNetworkUse = true

        // Apply duration trim
        if needsTrim {
            let startTime = CMTime.zero
            let endTime = CMTime(seconds: options.maxDuration, preferredTimescale: 600)
            exportSession.timeRange = CMTimeRange(start: startTime, end: endTime)
        }

        // Export
        await exportSession.export()

        switch exportSession.status {
        case .completed:
            return outputURL
        case .cancelled:
            throw PreprocessError.cancelled
        case .failed:
            let reason = exportSession.error?.localizedDescription ?? "Unknown"
            throw PreprocessError.exportFailed(reason)
        default:
            throw PreprocessError.exportFailed("Unexpected export status: \(exportSession.status.rawValue)")
        }
    }

    /// Check if the video resolution exceeds the maximum.
    private static func needsResolution(asset: AVAsset, maxResolution: Int) async throws -> Bool {
        guard let tracks = try? await asset.loadTracks(withMediaType: .video),
              let track = tracks.first else { return false }
        let naturalSize = try await track.load(.naturalSize)
        let transform = try await track.load(.preferredTransform)
        let size = naturalSize.applying(transform)
        let w = Int(abs(size.width))
        let h = Int(abs(size.height))
        return max(w, h) > maxResolution
    }
}
