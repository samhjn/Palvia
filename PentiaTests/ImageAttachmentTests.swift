import XCTest
@testable import iClaw

final class ImageAttachmentTests: XCTestCase {

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

    // MARK: - Codable Backward Compatibility

    func testDecodeWithoutFileReference() throws {
        let json = """
        {
            "id": "\(UUID().uuidString)",
            "imageData": "\(Data([0xFF, 0xD8]).base64EncodedString())",
            "mimeType": "image/jpeg",
            "width": 100,
            "height": 100
        }
        """
        let data = Data(json.utf8)
        let attachment = try JSONDecoder().decode(ImageAttachment.self, from: data)
        XCTAssertNil(attachment.fileReference)
        XCTAssertFalse(attachment.imageData.isEmpty)
    }

    func testRoundTripWithFileReference() throws {
        let original = ImageAttachment(
            id: UUID(),
            imageData: Data([0x01, 0x02]),
            mimeType: "image/png",
            width: 64,
            height: 64,
            fileReference: "agentfile://\(UUID().uuidString)/test.png"
        )
        let encoded = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(ImageAttachment.self, from: encoded)
        XCTAssertEqual(decoded.id, original.id)
        XCTAssertEqual(decoded.fileReference, original.fileReference)
        XCTAssertEqual(decoded.imageData, original.imageData)
        XCTAssertEqual(decoded.mimeType, original.mimeType)
        XCTAssertEqual(decoded.width, original.width)
        XCTAssertEqual(decoded.height, original.height)
    }

    // MARK: - resolvedImageData

    func testResolvedImageDataFallbackToInline() {
        let inlineData = Data([0xAA, 0xBB])
        let attachment = ImageAttachment(
            id: UUID(), imageData: inlineData, mimeType: "image/jpeg",
            width: 10, height: 10
        )
        XCTAssertEqual(attachment.resolvedImageData, inlineData)
        XCTAssertFalse(attachment.isFileDeleted)
    }

    func testResolvedImageDataFromFile() {
        let fullData = Data(repeating: 0xCC, count: 200)
        guard let ref = AgentFileManager.shared.saveImage(fullData, mimeType: "image/png", agentId: testAgentId) else {
            XCTFail("saveImage failed"); return
        }

        let attachment = ImageAttachment(
            id: UUID(), imageData: Data([0x01]), mimeType: "image/png",
            width: 10, height: 10, fileReference: ref
        )
        XCTAssertEqual(attachment.resolvedImageData, fullData)
        XCTAssertFalse(attachment.isFileDeleted)
    }

    func testResolvedImageDataFallbackWhenFileDeleted() {
        let thumbnailData = Data([0x01, 0x02])
        let fakeRef = AgentFileManager.makeFileReference(agentId: testAgentId, filename: "gone.png")

        let attachment = ImageAttachment(
            id: UUID(), imageData: thumbnailData, mimeType: "image/png",
            width: 10, height: 10, fileReference: fakeRef
        )

        XCTAssertTrue(attachment.isFileDeleted)
        XCTAssertEqual(attachment.resolvedImageData, thumbnailData)
    }

    func testIsFileDeletedFalseWithoutReference() {
        let attachment = ImageAttachment(
            id: UUID(), imageData: Data([0xFF]), mimeType: "image/jpeg",
            width: 10, height: 10
        )
        XCTAssertFalse(attachment.isFileDeleted)
    }

    // MARK: - Factory: file-backed via agentId

    func testFromBase64DataURIWithAgentId() {
        let imageBytes = Data(repeating: 0xAB, count: 50)
        let b64 = imageBytes.base64EncodedString()
        let uri = "data:image/png;base64,\(b64)"

        let attachment = ImageAttachment.from(base64DataURI: uri, agentId: testAgentId)
        XCTAssertNotNil(attachment)
        XCTAssertNotNil(attachment?.fileReference)
        XCTAssertTrue(attachment?.fileReference?.hasPrefix("agentfile://") ?? false)
    }

    func testFromBase64DataURIWithoutAgentId() {
        let imageBytes = Data(repeating: 0xAB, count: 50)
        let b64 = imageBytes.base64EncodedString()
        let uri = "data:image/png;base64,\(b64)"

        let attachment = ImageAttachment.from(base64DataURI: uri)
        XCTAssertNotNil(attachment)
        XCTAssertNil(attachment?.fileReference)
        XCTAssertEqual(attachment?.imageData, imageBytes)
    }

    // MARK: - Thumbnail

    func testThumbnailGeneration() {
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: 200, height: 200))
        let image = renderer.image { ctx in
            UIColor.red.setFill()
            ctx.fill(CGRect(x: 0, y: 0, width: 200, height: 200))
        }
        let thumbData = ImageAttachment.generateThumbnail(from: image, maxDimension: 32)
        XCTAssertFalse(thumbData.isEmpty)

        guard let fullData = image.jpegData(compressionQuality: 0.75) else {
            XCTFail("Could not generate JPEG"); return
        }
        XCTAssertTrue(thumbData.count < fullData.count)
    }
}
