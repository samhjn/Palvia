import XCTest
import SwiftData
@testable import iClaw

/// Tests for the universal `agentfile://` file reference mechanism across
/// MarkdownContentView, Message extraction, ContextManager injection,
/// PromptBuilder format info, and modality stripping.
final class AgentFileReferenceTests: XCTestCase {

    private var testAgentId: UUID!

    override func setUp() {
        super.setUp()
        testAgentId = UUID()
    }

    override func tearDown() {
        AgentFileManager.shared.cleanupAgentFiles(agentId: testAgentId)
        testAgentId = nil
        super.tearDown()
    }

    // MARK: - ImageAttachment.from(fileReference:)

    func testFromFileReferenceLoadsImage() {
        let imageData = createMinimalPNGData()
        guard let ref = AgentFileManager.shared.saveImage(imageData, mimeType: "image/png", agentId: testAgentId) else {
            XCTFail("saveImage failed"); return
        }

        let attachment = ImageAttachment.from(fileReference: ref)
        XCTAssertNotNil(attachment)
        XCTAssertEqual(attachment?.fileReference, ref)
        XCTAssertEqual(attachment?.mimeType, "image/png")
        XCTAssertFalse(attachment?.imageData.isEmpty ?? true, "Should have thumbnail data")
    }

    func testFromFileReferenceReturnsNilForMissingFile() {
        let fakeRef = AgentFileManager.makeFileReference(agentId: testAgentId, filename: "nonexistent.png")
        let attachment = ImageAttachment.from(fileReference: fakeRef)
        XCTAssertNil(attachment)
    }

    func testFromFileReferenceDetectsMimeType() {
        let data = Data(repeating: 0xFF, count: 50)
        let jpgRef = AgentFileManager.makeFileReference(agentId: testAgentId, filename: "photo.jpg")
        let pngRef = AgentFileManager.makeFileReference(agentId: testAgentId, filename: "chart.png")
        let gifRef = AgentFileManager.makeFileReference(agentId: testAgentId, filename: "anim.gif")

        _ = try? AgentFileManager.shared.writeFile(agentId: testAgentId, name: "photo.jpg", data: data)
        _ = try? AgentFileManager.shared.writeFile(agentId: testAgentId, name: "chart.png", data: data)
        _ = try? AgentFileManager.shared.writeFile(agentId: testAgentId, name: "anim.gif", data: data)

        XCTAssertEqual(ImageAttachment.from(fileReference: jpgRef)?.mimeType, "image/jpeg")
        XCTAssertEqual(ImageAttachment.from(fileReference: pngRef)?.mimeType, "image/png")
        XCTAssertEqual(ImageAttachment.from(fileReference: gifRef)?.mimeType, "image/gif")
    }

    // MARK: - Message.extractInlineImages with agentfile:// refs

    func testExtractInlineImagesUsesAgentFileRef() {
        let imageBytes = createMinimalPNGData()
        let b64 = imageBytes.base64EncodedString()
        let content = "Here is an image: ![chart](data:image/png;base64,\(b64))"

        let (cleaned, images) = Message.extractInlineImages(from: content, agentId: testAgentId)

        XCTAssertEqual(images.count, 1)
        XCTAssertNotNil(images.first?.fileReference)
        XCTAssertTrue(images.first?.fileReference?.hasPrefix("agentfile://") ?? false)
        XCTAssertTrue(cleaned.contains("agentfile://"), "Should use agentfile:// ref")
        XCTAssertTrue(cleaned.contains("![chart](agentfile://"), "Should preserve alt text 'chart'")
        XCTAssertFalse(cleaned.contains("base64,"), "Should not contain base64 data")
    }

    func testExtractInlineImagesPreservesAltText() {
        let imageBytes = Data(repeating: 0xAB, count: 50)
        let b64 = imageBytes.base64EncodedString()
        let content = "![sales data Q4](data:image/jpeg;base64,\(b64))"

        let (cleaned, images) = Message.extractInlineImages(from: content, agentId: testAgentId)

        XCTAssertEqual(images.count, 1)
        XCTAssertTrue(cleaned.contains("![sales data Q4](agentfile://"))
    }

    func testExtractInlineImagesWithoutAgentIdUsesAttachmentRef() {
        let imageBytes = Data(repeating: 0xAB, count: 50)
        let b64 = imageBytes.base64EncodedString()
        let content = "![test](data:image/png;base64,\(b64))"

        let (cleaned, images) = Message.extractInlineImages(from: content, agentId: nil)

        XCTAssertEqual(images.count, 1)
        XCTAssertNil(images.first?.fileReference)
        XCTAssertTrue(cleaned.contains("attachment:0"), "Should fall back to attachment:N")
    }

    func testExtractMultipleInlineImages() {
        let b64 = Data(repeating: 0xCC, count: 30).base64EncodedString()
        let content = """
        First: ![img1](data:image/png;base64,\(b64))
        Second: ![img2](data:image/jpeg;base64,\(b64))
        """

        let (cleaned, images) = Message.extractInlineImages(from: content, agentId: testAgentId)

        XCTAssertEqual(images.count, 2)
        XCTAssertTrue(cleaned.contains("![img1](agentfile://"))
        XCTAssertTrue(cleaned.contains("![img2](agentfile://"))

        let refs = images.compactMap(\.fileReference)
        XCTAssertEqual(refs.count, 2)
        XCTAssertNotEqual(refs[0], refs[1], "Each image should have a unique file reference")
    }

    func testExtractInlineImagesNoImagesReturnsOriginal() {
        let content = "No images here, just plain text."
        let (cleaned, images) = Message.extractInlineImages(from: content, agentId: testAgentId)
        XCTAssertEqual(cleaned, content)
        XCTAssertTrue(images.isEmpty)
    }

    // MARK: - ContextManager.resolveAgentFileImages

    func testResolveAgentFileImagesFindsRefs() {
        let imageData = createMinimalPNGData()
        guard let ref = AgentFileManager.shared.saveImage(imageData, mimeType: "image/png", agentId: testAgentId) else {
            XCTFail("saveImage failed"); return
        }

        let content = "Look at this: ![chart](\(ref))"
        let images = ContextManager.resolveAgentFileImages(from: content)

        XCTAssertEqual(images.count, 1)
        XCTAssertEqual(images.first?.fileReference, ref)
    }

    func testResolveAgentFileImagesMultiple() {
        let data = createMinimalPNGData()
        guard let ref1 = AgentFileManager.shared.saveImage(data, mimeType: "image/png", agentId: testAgentId),
              let ref2 = AgentFileManager.shared.saveImage(data, mimeType: "image/jpeg", agentId: testAgentId) else {
            XCTFail("saveImage failed"); return
        }

        let content = "![a](\(ref1)) and ![b](\(ref2))"
        let images = ContextManager.resolveAgentFileImages(from: content)

        XCTAssertEqual(images.count, 2)
    }

    func testResolveAgentFileImagesSkipsMissingFiles() {
        let fakeRef = AgentFileManager.makeFileReference(agentId: testAgentId, filename: "gone.png")
        let content = "![deleted](\(fakeRef))"
        let images = ContextManager.resolveAgentFileImages(from: content)

        XCTAssertTrue(images.isEmpty)
    }

    func testResolveAgentFileImagesIgnoresNonImageRefs() {
        let content = "Check [this file](agentfile://\(testAgentId.uuidString)/report.txt)"
        let images = ContextManager.resolveAgentFileImages(from: content)
        XCTAssertTrue(images.isEmpty, "Non-image markdown links should not be resolved as images")
    }

    func testResolveAgentFileImagesEmptyContent() {
        let images = ContextManager.resolveAgentFileImages(from: "No refs here")
        XCTAssertTrue(images.isEmpty)
    }

    // MARK: - ContextManager.stripAgentFileImageRefs

    func testStripAgentFileImageRefsReplacesWithDescription() {
        let ref = AgentFileManager.makeFileReference(agentId: testAgentId, filename: "chart.png")
        let content = "Here: ![sales chart](\(ref))"

        let stripped = ContextManager.stripAgentFileImageRefs(content)

        XCTAssertTrue(stripped.contains("[Image: sales chart]"))
        XCTAssertFalse(stripped.contains("agentfile://"))
    }

    func testStripAgentFileImageRefsEmptyAlt() {
        let ref = AgentFileManager.makeFileReference(agentId: testAgentId, filename: "img.png")
        let content = "![](\(ref))"

        let stripped = ContextManager.stripAgentFileImageRefs(content)

        XCTAssertTrue(stripped.contains("[Image: ]"))
        XCTAssertFalse(stripped.contains("agentfile://"))
    }

    func testStripAgentFileImageRefsMultiple() {
        let ref1 = AgentFileManager.makeFileReference(agentId: testAgentId, filename: "a.png")
        let ref2 = AgentFileManager.makeFileReference(agentId: testAgentId, filename: "b.jpg")
        let content = "![first](\(ref1)) text ![second](\(ref2))"

        let stripped = ContextManager.stripAgentFileImageRefs(content)

        XCTAssertTrue(stripped.contains("[Image: first]"))
        XCTAssertTrue(stripped.contains("[Image: second]"))
        XCTAssertFalse(stripped.contains("agentfile://"))
    }

    func testStripAgentFileImageRefsLeavesLinksAlone() {
        let ref = AgentFileManager.makeFileReference(agentId: testAgentId, filename: "report.pdf")
        let content = "Download [report](\(ref))"

        let stripped = ContextManager.stripAgentFileImageRefs(content)

        XCTAssertTrue(stripped.contains("agentfile://"), "Non-image links (no !) should not be stripped")
        XCTAssertEqual(stripped, content)
    }

    func testStripAgentFileImageRefsNoChange() {
        let content = "No image refs here, just text."
        let stripped = ContextManager.stripAgentFileImageRefs(content)
        XCTAssertEqual(stripped, content)
    }

    // MARK: - stripUnsupportedModalities with agentfile:// refs

    func testStripUnsupportedModalitiesStripsAgentFileRefs() {
        let ref = AgentFileManager.makeFileReference(agentId: testAgentId, filename: "chart.png")
        let imageAttachment = ImageAttachment(
            id: UUID(), imageData: Data([0xFF]), mimeType: "image/png",
            width: 100, height: 100, fileReference: ref
        )

        var messages: [LLMChatMessage] = [
            .userWithImages("Look at ![my chart](\(ref))", images: [imageAttachment])
        ]

        let noVision = ModelCapabilities(supportsVision: false)
        let stripped = ChatViewModel.stripUnsupportedModalities(from: &messages, capabilities: noVision)

        XCTAssertEqual(stripped.total, 1)
        XCTAssertEqual(messages.count, 1)
        XCTAssertTrue(messages[0].content?.contains("[Image: my chart]") ?? false,
                      "agentfile:// refs should be replaced with [Image: alt]")
        XCTAssertFalse(messages[0].content?.contains("agentfile://") ?? true)
        XCTAssertNil(messages[0].contentParts, "Image content parts should be stripped")
    }

    func testStripUnsupportedModalitiesKeepsAgentFileRefsWhenVisionSupported() {
        let ref = AgentFileManager.makeFileReference(agentId: testAgentId, filename: "photo.jpg")

        var messages: [LLMChatMessage] = [
            .user("See ![photo](\(ref))")
        ]

        let withVision = ModelCapabilities(supportsVision: true)
        let stripped = ChatViewModel.stripUnsupportedModalities(from: &messages, capabilities: withVision)

        XCTAssertEqual(stripped.total, 0)
        XCTAssertTrue(messages[0].content?.contains("agentfile://") ?? false,
                      "agentfile:// refs should remain when vision is supported")
    }

    // MARK: - PromptBuilder file reference section

    @MainActor
    func testPromptContainsFileReferenceSection() {
        let container = try! ModelContainer(
            for: Schema([Agent.self, LLMProvider.self, Session.self, AgentConfig.self,
                         CodeSnippet.self, CronJob.self, InstalledSkill.self, Skill.self,
                         Message.self, SessionEmbedding.self]),
            configurations: [ModelConfiguration(isStoredInMemoryOnly: true)]
        )
        let context = ModelContext(container)
        let agent = Agent(name: "Test")
        context.insert(agent)
        try! context.save()

        let builder = PromptBuilder()
        let prompt = builder.buildSystemPrompt(for: agent, rootAgentId: testAgentId)

        XCTAssertTrue(prompt.contains("agentfile://"), "Should contain agentfile:// scheme info")
        XCTAssertTrue(prompt.contains("File References"), "Should have File References section")
        XCTAssertTrue(prompt.contains(testAgentId.uuidString), "Should contain the root agent ID")
        XCTAssertTrue(prompt.contains("![description]"), "Should show image embed syntax")
        XCTAssertTrue(prompt.contains("[display text]"), "Should show link syntax")
    }

    @MainActor
    func testPromptOmitsFileReferenceSectionWhenFilesDisabled() {
        let container = try! ModelContainer(
            for: Schema([Agent.self, LLMProvider.self, Session.self, AgentConfig.self,
                         CodeSnippet.self, CronJob.self, InstalledSkill.self, Skill.self,
                         Message.self, SessionEmbedding.self]),
            configurations: [ModelConfiguration(isStoredInMemoryOnly: true)]
        )
        let context = ModelContext(container)
        let agent = Agent(name: "Test")
        context.insert(agent)
        agent.setPermissionLevel(.disabled, for: .files)
        try! context.save()

        let builder = PromptBuilder()
        let prompt = builder.buildSystemPrompt(for: agent, rootAgentId: testAgentId)

        XCTAssertFalse(prompt.contains("File References"),
                       "File References section should not appear when files are disabled")
    }

    // MARK: - MarkdownContentView block-level image parsing with agentfile://

    func testMarkdownParseBlockImageAgentFileRef() {
        let ref = AgentFileManager.makeFileReference(agentId: testAgentId, filename: "photo.jpg")
        let content = "![my photo](\(ref))"
        let view = MarkdownContentView(content)
        let blocks = view.parseBlocks()

        XCTAssertEqual(blocks.count, 1)
        if case .image(let alt, let url) = blocks[0] {
            XCTAssertEqual(alt, "my photo")
            XCTAssertEqual(url, ref)
        } else {
            XCTFail("Expected .image block, got \(blocks[0])")
        }
    }

    func testMarkdownParseBlockImageAgentFileRefWithSurroundingText() {
        let ref = AgentFileManager.makeFileReference(agentId: testAgentId, filename: "chart.png")
        let content = """
        Here is the chart:

        ![Q4 sales](\(ref))

        As you can see, sales grew.
        """
        let view = MarkdownContentView(content)
        let blocks = view.parseBlocks()

        let imageBlocks = blocks.filter {
            if case .image = $0 { return true }
            return false
        }
        XCTAssertEqual(imageBlocks.count, 1)
    }

    // MARK: - MarkdownContentView inline image parsing with agentfile://

    func testMarkdownInlineImageAgentFileRef() {
        let ref = AgentFileManager.makeFileReference(agentId: testAgentId, filename: "icon.png")
        let content = "Check this ![icon](\(ref)) image"
        let result = MarkdownContentView.parseInlineMarkdown(content, isUserMessage: false)

        let fullText = String(result.characters)
        XCTAssertTrue(fullText.contains("icon"), "Should contain alt text")
    }

    // MARK: - MarkdownContentView link parsing with agentfile://

    func testMarkdownLinkAgentFileRef() {
        let ref = AgentFileManager.makeFileReference(agentId: testAgentId, filename: "report.pdf")
        let content = "Download [the report](\(ref))"
        let result = MarkdownContentView.parseInlineMarkdown(content, isUserMessage: false)

        let fullText = String(result.characters)
        XCTAssertTrue(fullText.contains("the report"), "Link text should appear")
    }

    // MARK: - End-to-end: extract → resolve cycle

    func testEndToEndExtractThenResolve() {
        let imageBytes = createMinimalPNGData()
        let b64 = imageBytes.base64EncodedString()
        let original = "Analysis: ![trend chart](data:image/png;base64,\(b64))"

        // Step 1: Extract inline images (simulates LLM response processing)
        let (cleaned, images) = Message.extractInlineImages(from: original, agentId: testAgentId)
        XCTAssertEqual(images.count, 1)
        XCTAssertTrue(cleaned.contains("agentfile://"))
        XCTAssertTrue(cleaned.contains("![trend chart]"))

        // Step 2: Resolve agentfile:// refs (simulates ContextManager building context)
        let resolved = ContextManager.resolveAgentFileImages(from: cleaned)
        XCTAssertEqual(resolved.count, 1)
        XCTAssertEqual(resolved.first?.fileReference, images.first?.fileReference)
    }

    func testEndToEndExtractStripForNonVision() {
        let imageBytes = createMinimalPNGData()
        let b64 = imageBytes.base64EncodedString()
        let original = "Result: ![data plot](data:image/png;base64,\(b64))"

        // Step 1: Extract
        let (cleaned, _) = Message.extractInlineImages(from: original, agentId: testAgentId)

        // Step 2: Strip for non-vision model
        let stripped = ContextManager.stripAgentFileImageRefs(cleaned)
        XCTAssertTrue(stripped.contains("[Image: data plot]"))
        XCTAssertFalse(stripped.contains("agentfile://"))
        XCTAssertFalse(stripped.contains("base64"))
    }

    // MARK: - Sub-agent image forwarding via agentfile:// refs

    func testSubAgentImageForwardingViaTextRefs() {
        let data = createMinimalPNGData()
        guard let ref = AgentFileManager.shared.saveImage(data, mimeType: "image/png", agentId: testAgentId) else {
            XCTFail("saveImage failed"); return
        }

        let message = "Analyze this image"
        let imageRefs = [ref]
        let refLines = imageRefs.enumerated().map { i, r in
            "![forwarded image \(i + 1)](\(r))"
        }.joined(separator: "\n")
        let enrichedMessage = message + "\n\n" + refLines

        XCTAssertTrue(enrichedMessage.contains("Analyze this image"))
        XCTAssertTrue(enrichedMessage.contains("![forwarded image 1](\(ref))"))

        // Verify the refs can be resolved
        let resolved = ContextManager.resolveAgentFileImages(from: enrichedMessage)
        XCTAssertEqual(resolved.count, 1)
        XCTAssertEqual(resolved.first?.fileReference, ref)
    }

    // MARK: - Backward compatibility: attachment:N still works

    func testAttachmentRefStillParsedByMarkdown() {
        let content = "![](attachment:0)"
        let view = MarkdownContentView(content)
        let blocks = view.parseBlocks()

        XCTAssertEqual(blocks.count, 1)
        if case .image(_, let url) = blocks[0] {
            XCTAssertEqual(url, "attachment:0")
        } else {
            XCTFail("Expected .image block")
        }
    }

    // MARK: - convertWithImageForwarding: assistant image forwarding

    /// Helper: create an ImageAttachment with a real file on disk.
    private func makeSavedAttachment(mimeType: String = "image/png") -> ImageAttachment {
        let data = createMinimalPNGData()
        let ref = AgentFileManager.shared.saveImage(data, mimeType: mimeType, agentId: testAgentId)!
        let thumbnail = Data([0x01, 0x02])
        return ImageAttachment(
            id: UUID(), imageData: thumbnail, mimeType: mimeType,
            width: 2, height: 2, fileReference: ref
        )
    }

    /// Helper: attach encoded [ImageAttachment] to a Message.
    private func attachImages(_ images: [ImageAttachment], to message: Message) {
        message.imageAttachmentsData = try? JSONEncoder().encode(images)
    }

    func testForwardAssistantImagesToNextUserMessage() {
        let cm = ContextManager()
        let assistantImg = makeSavedAttachment()

        let userMsg = Message(role: .user, content: "Generate a chart")
        let assistantMsg = Message(role: .assistant, content: "Here is the chart")
        attachImages([assistantImg], to: assistantMsg)
        let nextUserMsg = Message(role: .user, content: "Looks good, thanks")

        let result = cm.convertWithImageForwarding([userMsg, assistantMsg, nextUserMsg])

        XCTAssertEqual(result.count, 3)

        // The next user message should contain the forwarded image
        let lastMsg = result[2]
        XCTAssertEqual(lastMsg.role, .user)
        XCTAssertNotNil(lastMsg.contentParts, "Should have content parts with forwarded image")
        let imagePartCount = lastMsg.contentParts?.filter {
            if case .imageURL = $0 { return true }; return false
        }.count ?? 0
        XCTAssertEqual(imagePartCount, 1, "Should have exactly 1 forwarded image")
        XCTAssertTrue(lastMsg.content?.contains("generated by the assistant") ?? false,
                      "Should contain forwarding hint")
    }

    func testAssistantMessageAnnotatedWhenImagesForwarded() {
        let cm = ContextManager()
        let img = makeSavedAttachment()

        let assistantMsg = Message(role: .assistant, content: "Generated image")
        attachImages([img], to: assistantMsg)
        let nextUserMsg = Message(role: .user, content: "Thanks")

        let result = cm.convertWithImageForwarding([assistantMsg, nextUserMsg])

        XCTAssertEqual(result.count, 2)
        XCTAssertTrue(result[0].content?.contains("forwarded as attachments in the next user message") ?? false,
                      "Assistant message should have forwarding annotation")
    }

    func testPendingImagesAtEndCreateSyntheticUserMessage() {
        let cm = ContextManager()
        let img = makeSavedAttachment()

        let assistantMsg = Message(role: .assistant, content: "Here is the result")
        attachImages([img], to: assistantMsg)

        // No user message follows the assistant
        let result = cm.convertWithImageForwarding([assistantMsg])

        XCTAssertEqual(result.count, 2, "Should have assistant + synthetic user message")
        XCTAssertEqual(result[1].role, .user)
        XCTAssertNotNil(result[1].contentParts, "Synthetic user message should carry the image")
        XCTAssertTrue(result[1].content?.contains("generated by the assistant") ?? false)
    }

    func testToolResultImagesForwardedToNextUserMessage() {
        let cm = ContextManager()
        let toolImg = makeSavedAttachment()

        let toolMsg = Message(role: .tool, content: "Tool output", toolCallId: "tc1", name: "screenshot")
        attachImages([toolImg], to: toolMsg)
        let nextUserMsg = Message(role: .user, content: "I see")

        let result = cm.convertWithImageForwarding([toolMsg, nextUserMsg])

        XCTAssertEqual(result.count, 2)
        let imagePartCount = result[1].contentParts?.filter {
            if case .imageURL = $0 { return true }; return false
        }.count ?? 0
        XCTAssertEqual(imagePartCount, 1, "Tool image should be forwarded to next user message")
    }

    // MARK: - Multi-image generation: tool + assistant dedup

    /// When `generate_image` returns N images, ChatViewModel stores the same
    /// attachments on BOTH the tool message and the following assistant message
    /// (via attachPendingToolMedia). Without id-based dedup in the assistant
    /// branch, the next user message would receive 2*N images. Verify that the
    /// forwarded set collapses back to N.
    func testMultiImageToolThenAssistantDedupedToSingleSet() {
        let cm = ContextManager()
        let imgA = makeSavedAttachment()
        let imgB = makeSavedAttachment()

        // Tool produces [A, B]
        let toolMsg = Message(role: .tool, content: "Generated 2 images.", toolCallId: "tc1", name: "generate_image")
        attachImages([imgA, imgB], to: toolMsg)

        // Next assistant reply also carries [A, B] (same UUIDs) because
        // attachPendingToolMedia duplicates them onto the assistant bubble.
        let assistantMsg = Message(role: .assistant, content: "Here are two images.")
        attachImages([imgA, imgB], to: assistantMsg)

        let nextUserMsg = Message(role: .user, content: "Thanks")

        let result = cm.convertWithImageForwarding([toolMsg, assistantMsg, nextUserMsg])

        XCTAssertEqual(result.count, 3)
        let lastMsg = result[2]
        XCTAssertEqual(lastMsg.role, .user)
        let imagePartCount = lastMsg.contentParts?.filter {
            if case .imageURL = $0 { return true }; return false
        }.count ?? 0
        XCTAssertEqual(imagePartCount, 2,
                       "Duplicated tool+assistant images should dedupe by id to exactly 2")
    }

    /// An assistant message carrying genuinely unique images (no prior tool
    /// duplication) must still have ALL of them forwarded intact.
    func testMultiImageAssistantOnlyAllForwarded() {
        let cm = ContextManager()
        let imgA = makeSavedAttachment()
        let imgB = makeSavedAttachment()
        let imgC = makeSavedAttachment()

        let assistantMsg = Message(role: .assistant, content: "Three unique images.")
        attachImages([imgA, imgB, imgC], to: assistantMsg)
        let nextUserMsg = Message(role: .user, content: "Got it")

        let result = cm.convertWithImageForwarding([assistantMsg, nextUserMsg])

        XCTAssertEqual(result.count, 2)
        let imagePartCount = result[1].contentParts?.filter {
            if case .imageURL = $0 { return true }; return false
        }.count ?? 0
        XCTAssertEqual(imagePartCount, 3, "All 3 unique images should be forwarded")
    }

    /// When assistant carries images that partially overlap with a preceding
    /// tool message, only the non-duplicates should add to the forwarded set.
    func testMultiImagePartialOverlapDedup() {
        let cm = ContextManager()
        let shared = makeSavedAttachment()
        let onlyAssistant = makeSavedAttachment()

        let toolMsg = Message(role: .tool, content: "tool out", toolCallId: "tc1", name: "generate_image")
        attachImages([shared], to: toolMsg)

        let assistantMsg = Message(role: .assistant, content: "two in total")
        attachImages([shared, onlyAssistant], to: assistantMsg)

        let nextUserMsg = Message(role: .user, content: "ok")

        let result = cm.convertWithImageForwarding([toolMsg, assistantMsg, nextUserMsg])

        let imagePartCount = result.last?.contentParts?.filter {
            if case .imageURL = $0 { return true }; return false
        }.count ?? 0
        XCTAssertEqual(imagePartCount, 2,
                       "Overlap should dedupe shared image; unique assistant image still forwarded")
    }

    // MARK: - convertWithImageForwarding: user-sent images with agentfile refs

    func testUserMessageWithAgentFileRefsResolvesImages() {
        let cm = ContextManager()
        let img = makeSavedAttachment()
        let ref = img.fileReference!

        // Simulate new behavior: user message with agentfile ref in content + imageAttachmentsData
        let userMsg = Message(role: .user, content: "Analyze this\n![image](\(ref))")
        attachImages([img], to: userMsg)

        let result = cm.convertWithImageForwarding([userMsg])

        XCTAssertEqual(result.count, 1)
        XCTAssertNotNil(result[0].contentParts, "Should have image content parts")

        let imagePartCount = result[0].contentParts?.filter {
            if case .imageURL = $0 { return true }; return false
        }.count ?? 0
        XCTAssertEqual(imagePartCount, 1, "Should have exactly 1 image (deduplicated)")
    }

    func testUserImageDeduplicationBetweenAttachmentsAndContentRefs() {
        let cm = ContextManager()
        let img = makeSavedAttachment()
        let ref = img.fileReference!

        // Same image present in both imageAttachmentsData and content as agentfile ref
        let userMsg = Message(role: .user, content: "Check ![photo](\(ref))")
        attachImages([img], to: userMsg)

        let result = cm.convertWithImageForwarding([userMsg])

        let imagePartCount = result[0].contentParts?.filter {
            if case .imageURL = $0 { return true }; return false
        }.count ?? 0
        XCTAssertEqual(imagePartCount, 1, "Dedup: same image in attachments and content should yield 1 image")
    }

    func testUserAgentFileRefWithoutAttachmentsStillResolvesImage() {
        let cm = ContextManager()
        let data = createMinimalPNGData()
        guard let ref = AgentFileManager.shared.saveImage(data, mimeType: "image/png", agentId: testAgentId) else {
            XCTFail("saveImage failed"); return
        }

        // agentfile ref in content but no imageAttachmentsData (e.g., pasted from sub-agent)
        let userMsg = Message(role: .user, content: "Look at ![chart](\(ref))")

        let result = cm.convertWithImageForwarding([userMsg])

        XCTAssertEqual(result.count, 1)
        XCTAssertNotNil(result[0].contentParts, "Should resolve image from agentfile ref in content")
        let imagePartCount = result[0].contentParts?.filter {
            if case .imageURL = $0 { return true }; return false
        }.count ?? 0
        XCTAssertEqual(imagePartCount, 1)
    }

    // MARK: - convertWithImageForwarding: combined forwarding + user images

    func testForwardedImagesAppendedToUserOwnImages() {
        let cm = ContextManager()
        let assistantImg = makeSavedAttachment()
        let userImg = makeSavedAttachment()
        let userRef = userImg.fileReference!

        let assistantMsg = Message(role: .assistant, content: "Generated chart")
        attachImages([assistantImg], to: assistantMsg)

        // User sends their own image while assistant's image is pending
        let userMsg = Message(role: .user, content: "Compare with this\n![my photo](\(userRef))")
        attachImages([userImg], to: userMsg)

        let result = cm.convertWithImageForwarding([assistantMsg, userMsg])

        XCTAssertEqual(result.count, 2)
        let imagePartCount = result[1].contentParts?.filter {
            if case .imageURL = $0 { return true }; return false
        }.count ?? 0
        XCTAssertEqual(imagePartCount, 2, "Should have user's own image + forwarded assistant image")
        XCTAssertTrue(result[1].content?.contains("generated by the assistant") ?? false,
                      "Should note the forwarded image")
    }

    func testDeletedImageCountedInForwarding() {
        let cm = ContextManager()
        let fakeRef = AgentFileManager.makeFileReference(agentId: testAgentId, filename: "deleted.png")
        let deletedImg = ImageAttachment(
            id: UUID(), imageData: Data(), mimeType: "image/png",
            width: 10, height: 10, fileReference: fakeRef
        )

        let userMsg = Message(role: .user, content: "Here\n![img](\(fakeRef))")
        attachImages([deletedImg], to: userMsg)

        let result = cm.convertWithImageForwarding([userMsg])

        XCTAssertEqual(result.count, 1)
        XCTAssertTrue(result[0].content?.contains("deleted by the user") ?? false,
                      "Should note that image was deleted")
    }

    // MARK: - stripImageRefsForContext preserves agentfile refs

    func testStripImageRefsForContextKeepsAgentFileRefs() {
        let ref = AgentFileManager.makeFileReference(agentId: testAgentId, filename: "photo.jpg")
        let content = "Check this ![photo](\(ref))"

        let stripped = ContextManager.stripImageRefsForContext(content)

        XCTAssertTrue(stripped.contains("agentfile://"),
                      "agentfile:// refs should be preserved by stripImageRefsForContext")
        XCTAssertEqual(stripped, content)
    }

    func testStripImageRefsForContextRemovesBase64ButKeepsAgentFile() {
        let ref = AgentFileManager.makeFileReference(agentId: testAgentId, filename: "photo.jpg")
        let content = "![b64](data:image/png;base64,AAAA) and ![file](\(ref))"

        let stripped = ContextManager.stripImageRefsForContext(content)

        XCTAssertFalse(stripped.contains("base64,"), "base64 data URI should be stripped")
        XCTAssertTrue(stripped.contains("agentfile://"), "agentfile ref should be preserved")
    }

    // MARK: - Helpers

    private func createMinimalPNGData() -> Data {
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: 2, height: 2))
        let image = renderer.image { ctx in
            UIColor.red.setFill()
            ctx.fill(CGRect(x: 0, y: 0, width: 2, height: 2))
        }
        return image.pngData() ?? Data(repeating: 0x89, count: 50)
    }
}
