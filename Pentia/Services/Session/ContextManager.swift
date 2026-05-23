import Foundation

final class ContextManager {
    static let defaultMaxTokens = 32000
    static let compressionThreshold = 24000

    let maxContextTokens: Int

    init(maxContextTokens: Int = ContextManager.defaultMaxTokens) {
        self.maxContextTokens = maxContextTokens
    }

    func buildContextWindow(
        session: Session,
        systemPrompt: String
    ) -> [LLMChatMessage] {
        var messages: [LLMChatMessage] = []

        let hasCompressed = session.compressedUpToIndex > 0
        let compressed = session.compressedContext ?? ""

        var fullSystemPrompt = systemPrompt
        if hasCompressed, !compressed.isEmpty {
            fullSystemPrompt += "\n\n---\n\n"
            fullSystemPrompt += "## Compressed Conversation History\n\n"
            fullSystemPrompt += "**The following is a structured summary of earlier messages. "
            fullSystemPrompt += "The \"Active Directives\" section contains user instructions that are STILL IN EFFECT — "
            fullSystemPrompt += "you MUST continue to follow them as if the user just said them.**\n\n"
            fullSystemPrompt += compressed
        }
        messages.append(.system(fullSystemPrompt))

        let systemTokens = TokenEstimator.estimate(fullSystemPrompt)
        var availableTokens = maxContextTokens - systemTokens

        let sorted = session.sortedMessages.filter { $0.role != .system }

        var anchoredIds = Set<UUID>()

        // When compression has occurred, pin the first user message (original
        // task instruction) so the LLM never loses the user's initial intent.
        if hasCompressed {
            if let firstUserMsg = sorted.first(where: { $0.role == .user }) {
                let anchor = convertToLLMMessage(firstUserMsg)
                let anchorTokens = TokenEstimator.estimateMessage(firstUserMsg)
                messages.append(anchor)
                availableTokens -= anchorTokens
                anchoredIds.insert(firstUserMsg.id)
            }
        }

        let recentMessages = selectRecentMessages(
            from: sorted,
            startingAfterIndex: session.compressedUpToIndex,
            maxTokens: availableTokens
        )

        // Pin the most recent user message with images if it was compressed
        // away or dropped from the selection window. This ensures the LLM can
        // always "see" the latest user-provided image.
        if hasCompressed {
            let recentIds = Set(recentMessages.map(\.id))
            if let latestImageMsg = sorted.last(where: {
                $0.role == .user && $0.imageAttachmentsData != nil
            }), !recentIds.contains(latestImageMsg.id),
               !anchoredIds.contains(latestImageMsg.id) {
                let imgTokens = latestImageMsg.tokenEstimate > 0
                    ? latestImageMsg.tokenEstimate
                    : TokenEstimator.estimateMessage(latestImageMsg)
                if imgTokens < availableTokens / 4 {
                    messages.append(convertToLLMMessage(latestImageMsg))
                    availableTokens -= imgTokens
                    anchoredIds.insert(latestImageMsg.id)
                }
            }
        }

        let eligibleRecent = recentMessages.filter { !anchoredIds.contains($0.id) }
        messages.append(contentsOf: convertWithImageForwarding(eligibleRecent))

        return messages
    }

    /// Converts a sequence of Messages to LLMChatMessages, forwarding any images
    /// from assistant messages into the next user message. Most LLM APIs only
    /// accept image content parts in user messages, so this ensures that
    /// assistant-generated images remain visible to subsequent models.
    func convertWithImageForwarding(_ msgs: [Message]) -> [LLMChatMessage] {
        var result: [LLMChatMessage] = []
        var pendingImages: [ImageAttachment] = []
        var pendingVideos: [VideoAttachment] = []

        for msg in msgs {
            switch msg.role {
            case .user:
                let text = Self.stripImageRefsForContext(msg.content ?? "")
                var allImages: [ImageAttachment] = []
                var allVideos: [VideoAttachment] = []
                var deletedCount = 0

                if let imgData = msg.imageAttachmentsData,
                   let decoded = try? JSONDecoder().decode([ImageAttachment].self, from: imgData),
                   !decoded.isEmpty {
                    let (live, deleted) = Self.partitionLiveImages(decoded)
                    allImages.append(contentsOf: live)
                    deletedCount += deleted
                }

                if let vidData = msg.videoAttachmentsData,
                   let decoded = try? JSONDecoder().decode([VideoAttachment].self, from: vidData),
                   !decoded.isEmpty {
                    let live = decoded.filter { !$0.isFileDeleted }
                    allVideos.append(contentsOf: live)
                }

                // Auto-resolve agentfile:// image refs in text content
                let existingRefs = Set(allImages.compactMap(\.fileReference))
                for img in Self.resolveAgentFileImages(from: text) {
                    if let ref = img.fileReference, !existingRefs.contains(ref) {
                        allImages.append(img)
                    }
                }

                let forwardedImageCount = pendingImages.count
                let forwardedVideoCount = pendingVideos.count
                allImages.append(contentsOf: pendingImages)
                allVideos.append(contentsOf: pendingVideos)
                pendingImages = []
                pendingVideos = []

                let forwardedCount = forwardedImageCount + forwardedVideoCount
                if !allImages.isEmpty || !allVideos.isEmpty || deletedCount > 0 {
                    var finalText = text
                    if deletedCount > 0 {
                        finalText += "\n[Note: \(deletedCount) image(s) were deleted by the user and are no longer available.]"
                    }
                    if forwardedCount > 0 {
                        let hint = "[Note: \(forwardedCount) of the attached media were generated by the assistant in a previous response, not sent by the user.]"
                        finalText = hint + "\n\n" + finalText
                    }
                    if allImages.isEmpty && allVideos.isEmpty {
                        result.append(.user(finalText))
                    } else if !allImages.isEmpty || !allVideos.isEmpty {
                        result.append(.userWithMedia(finalText, images: allImages, videos: allVideos))
                    }
                } else {
                    result.append(.user(text))
                }

            case .assistant:
                var toolCalls: [LLMToolCall]? = nil
                if let data = msg.toolCallsData {
                    toolCalls = try? JSONDecoder().decode([LLMToolCall].self, from: data)
                }
                let text = msg.content.map { Self.stripImageRefsForContext($0) }

                if let imgData = msg.imageAttachmentsData,
                   let images = try? JSONDecoder().decode([ImageAttachment].self, from: imgData),
                   !images.isEmpty {
                    let (live, deleted) = Self.partitionLiveImages(images)
                    for img in live where !pendingImages.contains(where: { $0.id == img.id }) {
                        pendingImages.append(img)
                    }
                    var suffix = "\n\n[The \(images.count) image(s) generated above are forwarded as attachments in the next user message due to API constraints.]"
                    if deleted > 0 {
                        suffix += "\n[\(deleted) image(s) were deleted by the user.]"
                    }
                    let hinted = (text ?? "") + suffix
                    result.append(.assistant(hinted, toolCalls: toolCalls,
                                             reasoningContent: msg.thinkingContent,
                                             thinkingSignature: msg.thinkingSignature))
                } else {
                    result.append(.assistant(text, toolCalls: toolCalls,
                                             reasoningContent: msg.thinkingContent,
                                             thinkingSignature: msg.thinkingSignature))
                }

                if let vidData = msg.videoAttachmentsData,
                   let videos = try? JSONDecoder().decode([VideoAttachment].self, from: vidData),
                   !videos.isEmpty {
                    let live = videos.filter { !$0.isFileDeleted }
                    for vid in live where !pendingVideos.contains(where: { $0.id == vid.id }) {
                        pendingVideos.append(vid)
                    }
                }

            case .tool:
                if let imgData = msg.imageAttachmentsData,
                   let images = try? JSONDecoder().decode([ImageAttachment].self, from: imgData),
                   !images.isEmpty {
                    let (live, _) = Self.partitionLiveImages(images)
                    for img in live where !pendingImages.contains(where: { $0.id == img.id }) {
                        pendingImages.append(img)
                    }
                }
                if let vidData = msg.videoAttachmentsData,
                   let videos = try? JSONDecoder().decode([VideoAttachment].self, from: vidData),
                   !videos.isEmpty {
                    let live = videos.filter { !$0.isFileDeleted }
                    for vid in live where !pendingVideos.contains(where: { $0.id == vid.id }) {
                        pendingVideos.append(vid)
                    }
                }
                result.append(.tool(
                    content: msg.content ?? "",
                    toolCallId: msg.toolCallId ?? "",
                    name: msg.name
                ))

            default:
                break
            }
        }

        if !pendingImages.isEmpty || !pendingVideos.isEmpty {
            let totalCount = pendingImages.count + pendingVideos.count
            let hint = "[The following \(totalCount) media attachment(s) were generated by the assistant in a previous response.]"
            result.append(.userWithMedia(hint, images: pendingImages, videos: pendingVideos))
        }

        return result
    }

    /// Partition images into live (file exists or no fileReference) and count of deleted.
    private static func partitionLiveImages(_ images: [ImageAttachment]) -> (live: [ImageAttachment], deletedCount: Int) {
        var live: [ImageAttachment] = []
        var deleted = 0
        for img in images {
            if img.isFileDeleted {
                deleted += 1
            } else {
                live.append(img)
            }
        }
        return (live, deleted)
    }

    /// Tokens for ALL messages (including already-compressed ones). Useful for stats.
    func totalSessionTokens(session: Session) -> Int {
        session.messages.reduce(0) { total, msg in
            let est = msg.tokenEstimate
            return total + (est > 0 ? est : TokenEstimator.estimateMessage(msg))
        }
    }

    /// Tokens that would actually be sent to the LLM:
    /// compressed summary + messages after `compressedUpToIndex`.
    func activeContextTokens(session: Session) -> Int {
        var total = 0

        if let compressed = session.compressedContext, !compressed.isEmpty {
            total += TokenEstimator.estimate(compressed)
        }

        let sorted = session.sortedMessages.filter { $0.role != .system }
        let active = sorted.dropFirst(session.compressedUpToIndex)
        for msg in active {
            let est = msg.tokenEstimate
            total += est > 0 ? est : TokenEstimator.estimateMessage(msg)
        }

        return total
    }

    private func selectRecentMessages(
        from messages: [Message],
        startingAfterIndex: Int,
        maxTokens: Int
    ) -> [Message] {
        let eligible = Array(messages.dropFirst(startingAfterIndex))

        var selected: [Message] = []
        var tokenCount = 0

        for message in eligible.reversed() {
            let tokens = message.tokenEstimate > 0
                ? message.tokenEstimate
                : TokenEstimator.estimateMessage(message)
            if tokenCount + tokens > maxTokens && !selected.isEmpty {
                break
            }
            selected.insert(message, at: 0)
            tokenCount += tokens
        }

        selected = repairToolCallPairs(selected)

        return selected
    }

    /// Ensures tool call message pairs are intact.
    private func repairToolCallPairs(_ messages: [Message]) -> [Message] {
        var result = messages

        while let first = result.first, first.role == .tool {
            result.removeFirst()
        }

        if let last = result.last, last.role == .assistant, last.toolCallsData != nil {
            if let toolCalls = try? JSONDecoder().decode([LLMToolCall].self, from: last.toolCallsData!) {
                let expectedIds = Set(toolCalls.map(\.id))
                let followingToolIds = Set(
                    result.dropLast()
                        .suffix(toolCalls.count)
                        .filter { $0.role == .tool }
                        .compactMap(\.toolCallId)
                )
                if !expectedIds.isSubset(of: followingToolIds) {
                    result.removeLast()
                }
            }
        }

        return result
    }

    private func convertToLLMMessage(_ message: Message) -> LLMChatMessage {
        switch message.role {
        case .user:
            let text = Self.stripImageRefsForContext(message.content ?? "")
            var allImages: [ImageAttachment] = []
            if let imgData = message.imageAttachmentsData,
               let images = try? JSONDecoder().decode([ImageAttachment].self, from: imgData),
               !images.isEmpty {
                allImages.append(contentsOf: images)
            }
            let existingRefs = Set(allImages.compactMap(\.fileReference))
            for img in Self.resolveAgentFileImages(from: text) {
                if let ref = img.fileReference, !existingRefs.contains(ref) {
                    allImages.append(img)
                }
            }
            if !allImages.isEmpty {
                return .userWithImages(text, images: allImages)
            }
            return .user(text)
        case .assistant:
            var toolCalls: [LLMToolCall]? = nil
            if let data = message.toolCallsData {
                toolCalls = try? JSONDecoder().decode([LLMToolCall].self, from: data)
            }
            let text = message.content.map { Self.stripImageRefsForContext($0) }
            return .assistant(text, toolCalls: toolCalls,
                              reasoningContent: message.thinkingContent,
                              thinkingSignature: message.thinkingSignature)
        case .tool:
            return .tool(
                content: message.content ?? "",
                toolCallId: message.toolCallId ?? "",
                name: message.name
            )
        case .system:
            return .system(message.content ?? "")
        }
    }

    /// Strip inline image references (base64 data URIs and attachment:N refs) from content.
    /// `agentfile://` refs are kept since they are small, informative URLs (not raw base64).
    static func stripImageRefsForContext(_ content: String) -> String {
        var result = content

        if result.contains(";base64,") {
            let base64Pattern = "!\\[[^\\]]*\\]\\(data:image/[^)]+\\)"
            if let regex = try? NSRegularExpression(pattern: base64Pattern) {
                let range = NSRange(result.startIndex..., in: result)
                result = regex.stringByReplacingMatches(in: result, range: range, withTemplate: L10n.Chat.imagePlaceholder)
            }
        }

        if result.contains("attachment:") {
            let attachPattern = "!\\[[^\\]]*\\]\\(attachment:\\d+\\)"
            if let regex = try? NSRegularExpression(pattern: attachPattern) {
                let range = NSRange(result.startIndex..., in: result)
                result = regex.stringByReplacingMatches(in: result, range: range, withTemplate: L10n.Chat.imagePlaceholder)
            }
        }

        return result
    }

    // MARK: - agentfile:// Image Resolution

    /// Resolve `![alt](agentfile://...)` image references in content to `ImageAttachment` objects.
    /// Used to auto-inject images into LLM context when messages contain `agentfile://` image refs.
    static func resolveAgentFileImages(from content: String) -> [ImageAttachment] {
        guard content.contains("agentfile://") else { return [] }

        let pattern = "!\\[[^\\]]*\\]\\((agentfile://[^)]+)\\)"
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let nsContent = content as NSString
        let range = NSRange(location: 0, length: nsContent.length)
        let matches = regex.matches(in: content, range: range)
        guard !matches.isEmpty else { return [] }

        var images: [ImageAttachment] = []
        for match in matches {
            let ref = nsContent.substring(with: match.range(at: 1))
            if let attachment = ImageAttachment.from(fileReference: ref) {
                images.append(attachment)
            }
        }
        return images
    }

    /// Replace `![alt](agentfile://...)` with `[Image: alt]` for models that don't support vision.
    static func stripAgentFileImageRefs(_ content: String) -> String {
        guard content.contains("agentfile://") else { return content }
        let pattern = "!\\[([^\\]]*)\\]\\(agentfile://[^)]+\\)"
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return content }
        let range = NSRange(content.startIndex..., in: content)
        return regex.stringByReplacingMatches(in: content, range: range, withTemplate: "[Image: $1]")
    }
}

// MARK: - Token Estimator

/// BPE-aware token estimator for mixed CJK/Latin text.
///
/// Calibrated against GPT-4 / Claude tokenizer behavior:
/// - ASCII text: ~1 token per 4 characters
/// - CJK ideographs: ~2 tokens per character
/// - Hangul syllables: ~2 tokens per character
/// - Emoji / symbols: ~3 tokens each
/// - Whitespace/punctuation grouped with surrounding text
/// - Per-message overhead: ~4 tokens (role tag, delimiters)
enum TokenEstimator {

    static func estimate(_ text: String) -> Int {
        guard !text.isEmpty else { return 0 }

        var asciiCount = 0
        var cjkCount = 0
        var emojiCount = 0

        for scalar in text.unicodeScalars {
            let v = scalar.value
            if v <= 0x7F {
                asciiCount += 1
            } else if isCJK(v) {
                cjkCount += 1
            } else if isEmoji(v) || v > 0xFFFF {
                emojiCount += 1
            } else {
                cjkCount += 1
            }
        }

        let asciiTokens = max(asciiCount / 4, asciiCount > 0 ? 1 : 0)
        let cjkTokens = cjkCount * 2
        let emojiTokens = emojiCount * 3

        return asciiTokens + cjkTokens + emojiTokens
    }

    /// Estimate tokens for a Message, including content, tool calls, images, and overhead.
    static func estimateMessage(_ message: Message) -> Int {
        let overhead = 4
        var total = overhead

        if let content = message.content {
            if content.contains(";base64,") {
                let (stripped, imageCount) = stripBase64ForEstimation(content)
                total += estimate(stripped)
                total += imageCount * estimateImageTokens(width: 512, height: 512)
            } else {
                total += estimate(content)
            }
        }

        if let toolData = message.toolCallsData {
            if let calls = try? JSONDecoder().decode([LLMToolCall].self, from: toolData) {
                for call in calls {
                    total += estimate(call.function.name)
                    total += estimate(call.function.arguments)
                    total += 8
                }
            }
        }

        if let name = message.name {
            total += estimate(name) + 1
        }

        if let imgData = message.imageAttachmentsData,
           let images = try? JSONDecoder().decode([ImageAttachment].self, from: imgData) {
            for img in images {
                total += estimateImageTokens(width: img.width, height: img.height)
            }
        }

        if let vidData = message.videoAttachmentsData,
           let videos = try? JSONDecoder().decode([VideoAttachment].self, from: vidData) {
            for vid in videos {
                total += estimateVideoTokens(duration: vid.duration, width: vid.width, height: vid.height)
            }
        }

        return total
    }

    /// Strip base64 data-URI images from content for estimation purposes.
    /// Returns the cleaned text and the number of images found.
    static func stripBase64ForEstimation(_ content: String) -> (text: String, imageCount: Int) {
        let pattern = "!\\[[^\\]]*\\]\\(data:image/[^)]+\\)"
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return (content, 0) }
        let range = NSRange(content.startIndex..., in: content)
        let matches = regex.matches(in: content, range: range)
        guard !matches.isEmpty else { return (content, 0) }
        let cleaned = regex.stringByReplacingMatches(in: content, range: range, withTemplate: L10n.Chat.imagePlaceholder)
        return (cleaned, matches.count)
    }

    /// Estimate vision token cost for a single image based on tile-based pricing.
    ///
    /// Uses OpenAI's high-detail formula as a reasonable cross-provider estimate:
    /// 85 base tokens + 170 per 512x512 tile.
    static func estimateImageTokens(width: Int, height: Int) -> Int {
        guard width > 0, height > 0 else { return 85 }
        let tilesX = max(1, (width + 511) / 512)
        let tilesY = max(1, (height + 511) / 512)
        return 85 + tilesX * tilesY * 170
    }

    /// Estimate token cost for a video based on duration and resolution.
    ///
    /// Gemini samples video at 1 FPS and charges ~258 tokens per frame.
    /// This provides a reasonable cross-provider estimate.
    static func estimateVideoTokens(duration: TimeInterval, width: Int, height: Int) -> Int {
        guard duration > 0 else { return 258 }
        let frameCount = max(1, Int(duration)) // ~1 FPS
        let tokensPerFrame = 258 // Gemini's approximate per-frame cost
        return frameCount * tokensPerFrame
    }

    private static func isCJK(_ v: UInt32) -> Bool {
        (v >= 0x4E00 && v <= 0x9FFF) ||
        (v >= 0x3400 && v <= 0x4DBF) ||
        (v >= 0x20000 && v <= 0x2FA1F) ||
        (v >= 0xF900 && v <= 0xFAFF) ||
        (v >= 0x3040 && v <= 0x309F) ||
        (v >= 0x30A0 && v <= 0x30FF) ||
        (v >= 0xAC00 && v <= 0xD7AF) ||
        (v >= 0x3000 && v <= 0x303F) ||
        (v >= 0xFF00 && v <= 0xFFEF) ||
        (v >= 0x3100 && v <= 0x312F)
    }

    private static func isEmoji(_ v: UInt32) -> Bool {
        (v >= 0x1F600 && v <= 0x1F64F) ||
        (v >= 0x1F300 && v <= 0x1F5FF) ||
        (v >= 0x1F680 && v <= 0x1F6FF) ||
        (v >= 0x1F900 && v <= 0x1F9FF) ||
        (v >= 0x2600 && v <= 0x26FF) ||
        (v >= 0x2700 && v <= 0x27BF) ||
        (v >= 0xFE00 && v <= 0xFE0F) ||
        (v >= 0x1FA00 && v <= 0x1FA6F) ||
        (v >= 0x1FA70 && v <= 0x1FAFF)
    }
}
