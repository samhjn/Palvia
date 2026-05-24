import Foundation
import UIKit

struct ImageAttachment: Codable, Identifiable {
    let id: UUID
    let imageData: Data
    let mimeType: String
    let width: Int
    let height: Int

    /// When non-nil, the full-resolution image lives on disk at this reference
    /// (format: `agentfile://<agentId>/<filename>`).
    /// `imageData` then holds only a small thumbnail for fallback display.
    var fileReference: String?

    var base64DataURI: String {
        let data = resolvedImageData ?? imageData
        return "data:\(mimeType);base64,\(data.base64EncodedString())"
    }

    /// Resolve the best available image data: file-backed full resolution first, then inline data.
    var resolvedImageData: Data? {
        if let fileReference {
            if let data = AgentFileManager.shared.loadImageData(from: fileReference) {
                return data
            }
            return imageData.isEmpty ? nil : imageData
        }
        return imageData.isEmpty ? nil : imageData
    }

    /// Whether the original file has been deleted by the user.
    var isFileDeleted: Bool {
        guard let fileReference else { return false }
        return AgentFileManager.shared.loadImageData(from: fileReference) == nil
    }

    var uiImage: UIImage? {
        guard let data = resolvedImageData else { return nil }
        return UIImage(data: data)
    }

    /// The inline thumbnail image (always from `imageData`, ignoring file reference).
    var thumbnailImage: UIImage? {
        imageData.isEmpty ? nil : UIImage(data: imageData)
    }

    // MARK: - Factory Methods

    /// Create from a UIImage with full-resolution saved to the agent's file folder.
    /// `imageData` stores a small thumbnail; the full file is referenced via `fileReference`.
    static func from(image: UIImage, agentId: UUID, maxDimension: CGFloat = 1024, quality: CGFloat = 0.75) -> ImageAttachment? {
        let resized = resize(image: image, maxDimension: maxDimension)
        guard let fullData = resized.jpegData(compressionQuality: quality) else { return nil }
        let w = Int(resized.size.width * resized.scale)
        let h = Int(resized.size.height * resized.scale)

        let thumbnail = generateThumbnail(from: resized)
        let ref = AgentFileManager.shared.saveImage(fullData, mimeType: "image/jpeg", agentId: agentId)

        return ImageAttachment(
            id: UUID(),
            imageData: thumbnail,
            mimeType: "image/jpeg",
            width: w,
            height: h,
            fileReference: ref
        )
    }

    /// Legacy factory: inline-only (no file reference). Used for backward compatibility.
    static func from(image: UIImage, maxDimension: CGFloat = 1024, quality: CGFloat = 0.75) -> ImageAttachment? {
        let resized = resize(image: image, maxDimension: maxDimension)
        guard let data = resized.jpegData(compressionQuality: quality) else { return nil }
        return ImageAttachment(
            id: UUID(),
            imageData: data,
            mimeType: "image/jpeg",
            width: Int(resized.size.width * resized.scale),
            height: Int(resized.size.height * resized.scale)
        )
    }

    /// Create from a base64 data URI, optionally saving to the agent's file folder.
    static func from(base64DataURI uri: String, agentId: UUID? = nil) -> ImageAttachment? {
        guard uri.hasPrefix("data:") else { return nil }
        let withoutPrefix = String(uri.dropFirst(5))
        guard let semicolonIdx = withoutPrefix.firstIndex(of: ";") else { return nil }
        let mimeType = String(withoutPrefix[..<semicolonIdx])
        let afterSemicolon = String(withoutPrefix[withoutPrefix.index(after: semicolonIdx)...])
        guard afterSemicolon.hasPrefix("base64,") else { return nil }
        let base64String = String(afterSemicolon.dropFirst(7))
        guard let data = Data(base64Encoded: base64String, options: .ignoreUnknownCharacters) else { return nil }

        var width = 512, height = 512
        if let image = UIImage(data: data) {
            width = Int(image.size.width * image.scale)
            height = Int(image.size.height * image.scale)
        }

        if let agentId {
            let thumbnail: Data
            if let image = UIImage(data: data) {
                thumbnail = generateThumbnail(from: image)
            } else {
                thumbnail = Data()
            }
            let ref = AgentFileManager.shared.saveImage(data, mimeType: mimeType, agentId: agentId)
            return ImageAttachment(id: UUID(), imageData: thumbnail, mimeType: mimeType,
                                   width: width, height: height, fileReference: ref)
        }

        return ImageAttachment(id: UUID(), imageData: data, mimeType: mimeType,
                               width: width, height: height)
    }

    /// Create from an `agentfile://` reference by loading data from disk.
    /// Returns nil if the referenced file doesn't exist or isn't a valid image.
    static func from(fileReference ref: String) -> ImageAttachment? {
        guard let data = AgentFileManager.shared.loadImageData(from: ref) else { return nil }
        let mimeType = mimeTypeForReference(ref)
        let width: Int
        let height: Int
        let thumbnail: Data
        if let image = UIImage(data: data) {
            width = Int(image.size.width * image.scale)
            height = Int(image.size.height * image.scale)
            thumbnail = generateThumbnail(from: image)
        } else {
            width = 512; height = 512
            thumbnail = Data()
        }
        return ImageAttachment(
            id: UUID(),
            imageData: thumbnail,
            mimeType: mimeType,
            width: width,
            height: height,
            fileReference: ref
        )
    }

    private static func mimeTypeForReference(_ ref: String) -> String {
        guard let (_, filename) = AgentFileManager.parseFileReference(ref) else { return "image/jpeg" }
        let ext = (filename as NSString).pathExtension.lowercased()
        switch ext {
        case "png": return "image/png"
        case "gif": return "image/gif"
        case "webp": return "image/webp"
        case "heic": return "image/heic"
        case "bmp": return "image/bmp"
        case "tiff", "tif": return "image/tiff"
        case "svg": return "image/svg+xml"
        default: return "image/jpeg"
        }
    }

    // MARK: - Thumbnail

    static func generateThumbnail(from image: UIImage, maxDimension: CGFloat = 64, quality: CGFloat = 0.3) -> Data {
        let resized = resize(image: image, maxDimension: maxDimension)
        return resized.jpegData(compressionQuality: quality) ?? Data()
    }

    // MARK: - Resize

    private static func resize(image: UIImage, maxDimension: CGFloat) -> UIImage {
        let size = image.size
        guard max(size.width, size.height) > maxDimension else { return image }

        let ratio = maxDimension / max(size.width, size.height)
        let newSize = CGSize(width: size.width * ratio, height: size.height * ratio)
        let renderer = UIGraphicsImageRenderer(size: newSize)
        return renderer.image { _ in
            image.draw(in: CGRect(origin: .zero, size: newSize))
        }
    }
}
