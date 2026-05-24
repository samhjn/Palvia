import Foundation
import SwiftData

enum MessageRole: String, Codable {
    case system
    case user
    case assistant
    case tool
}

@Model
final class Message {
    var id: UUID
    var session: Session?
    var roleRaw: String
    var content: String?
    var toolCallsData: Data?
    var toolCallId: String?
    var name: String?
    var thinkingContent: String?
    /// Anthropic-style thinking signature paired with `thinkingContent`. Must
    /// be replayed in the assistant's `thinking` content block on subsequent
    /// requests for thinking-mode tool-use turns (Anthropic native and
    /// DeepSeek's Anthropic-compat mode both require it).
    var thinkingSignature: String?
    var imageAttachmentsData: Data?
    var videoAttachmentsData: Data?
    var fileAttachmentsData: Data?
    var timestamp: Date
    var tokenEstimate: Int

    /// API-reported prompt token count (nil if not available from vendor).
    var apiPromptTokens: Int?
    /// API-reported completion token count (nil if not available from vendor).
    var apiCompletionTokens: Int?

    var role: MessageRole {
        get { MessageRole(rawValue: roleRaw) ?? .user }
        set { roleRaw = newValue.rawValue }
    }

    init(
        role: MessageRole,
        content: String? = nil,
        toolCallsData: Data? = nil,
        toolCallId: String? = nil,
        name: String? = nil,
        tokenEstimate: Int = 0
    ) {
        self.id = UUID()
        self.roleRaw = role.rawValue
        self.content = content
        self.toolCallsData = toolCallsData
        self.toolCallId = toolCallId
        self.name = name
        self.timestamp = Date()
        if tokenEstimate > 0 {
            self.tokenEstimate = tokenEstimate
        } else {
            self.tokenEstimate = Self.computeTokenEstimate(
                content: content,
                toolCallsData: toolCallsData,
                name: name,
                imageAttachmentsData: nil,
                videoAttachmentsData: nil
            )
        }
    }

    /// Recompute and persist the token estimate (e.g. after adding image attachments).
    func recalculateTokenEstimate() {
        tokenEstimate = Self.computeTokenEstimate(
            content: content,
            toolCallsData: toolCallsData,
            name: name,
            imageAttachmentsData: imageAttachmentsData,
            videoAttachmentsData: videoAttachmentsData
        )
    }

    // MARK: - Inline Image Extraction

    /// Extract inline base64 data-URI images from `content` into `imageAttachmentsData`.
    /// Content is updated with localized image placeholders. Returns true if any images were extracted.
    @discardableResult
    func extractAndStoreInlineImages(agentId: UUID? = nil) -> Bool {
        guard let content, content.contains(";base64,") else { return false }
        let existingCount = (imageAttachmentsData.flatMap {
            try? JSONDecoder().decode([ImageAttachment].self, from: $0)
        })?.count ?? 0
        let (cleaned, images) = Self.extractInlineImages(from: content, startIndex: existingCount, agentId: agentId)
        guard !images.isEmpty else { return false }

        self.content = cleaned
        let existing = (imageAttachmentsData.flatMap {
            try? JSONDecoder().decode([ImageAttachment].self, from: $0)
        }) ?? []
        let all = existing + images
        imageAttachmentsData = try? JSONEncoder().encode(all)
        recalculateTokenEstimate()
        return true
    }

    /// Parse markdown image syntax with base64 data URIs, returning cleaned text and extracted images.
    /// When `agentId` is provided, images are saved to disk and replaced with `![alt](agentfile://...)`
    /// references. Otherwise falls back to `![](attachment:N)` placeholders.
    static func extractInlineImages(from content: String, startIndex: Int = 0, agentId: UUID? = nil) -> (cleanedContent: String, images: [ImageAttachment]) {
        let pattern = "!\\[([^\\]]*)\\]\\((data:image/[^)]+)\\)"
        guard let regex = try? NSRegularExpression(pattern: pattern) else {
            return (content, [])
        }

        let nsContent = content as NSString
        let fullRange = NSRange(location: 0, length: nsContent.length)
        let matches = regex.matches(in: content, range: fullRange)
        guard !matches.isEmpty else { return (content, []) }

        var images: [ImageAttachment] = []
        var replacementRanges: [(NSRange, String)] = []
        var imageIndex = startIndex

        for match in matches {
            let alt = nsContent.substring(with: match.range(at: 1))
            let uri = nsContent.substring(with: match.range(at: 2))
            if let attachment = ImageAttachment.from(base64DataURI: uri, agentId: agentId) {
                images.append(attachment)
                if let ref = attachment.fileReference {
                    replacementRanges.append((match.range, "![\(alt)](\(ref))"))
                } else {
                    replacementRanges.append((match.range, "![\(alt)](attachment:\(imageIndex))"))
                }
                imageIndex += 1
            }
        }

        guard !images.isEmpty else { return (content, []) }

        let result = NSMutableString(string: nsContent)
        for (range, replacement) in replacementRanges.reversed() {
            result.replaceCharacters(in: range, with: replacement)
        }

        return (result as String, images)
    }

    private static func computeTokenEstimate(
        content: String?,
        toolCallsData: Data?,
        name: String?,
        imageAttachmentsData: Data?,
        videoAttachmentsData: Data?
    ) -> Int {
        let overhead = 4
        var total = overhead

        if let content {
            if content.contains(";base64,") {
                let (stripped, imageCount) = TokenEstimator.stripBase64ForEstimation(content)
                total += TokenEstimator.estimate(stripped)
                total += imageCount * TokenEstimator.estimateImageTokens(width: 512, height: 512)
            } else {
                total += TokenEstimator.estimate(content)
            }
        }

        if let toolData = toolCallsData {
            if let calls = try? JSONDecoder().decode([LLMToolCall].self, from: toolData) {
                for call in calls {
                    total += TokenEstimator.estimate(call.function.name)
                    total += TokenEstimator.estimate(call.function.arguments)
                    total += 8
                }
            }
        }

        if let name {
            total += TokenEstimator.estimate(name) + 1
        }

        if let imgData = imageAttachmentsData,
           let images = try? JSONDecoder().decode([ImageAttachment].self, from: imgData) {
            for img in images {
                total += TokenEstimator.estimateImageTokens(width: img.width, height: img.height)
            }
        }

        if let vidData = videoAttachmentsData,
           let videos = try? JSONDecoder().decode([VideoAttachment].self, from: vidData) {
            for vid in videos {
                // Gemini charges ~258 tokens per second of video at 1 FPS sampling.
                // Use this as a reasonable cross-provider estimate.
                total += TokenEstimator.estimateVideoTokens(duration: vid.duration, width: vid.width, height: vid.height)
            }
        }

        return total
    }
}
