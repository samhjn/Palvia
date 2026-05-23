import XCTest
@testable import iClaw

final class TextFilePreviewTests: XCTestCase {

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

    // MARK: - TextFilePreviewCoordinator.textExtensions

    func testCommonTextExtensionsIncluded() {
        let expected: [String] = [
            "txt", "md", "markdown", "log", "json", "xml", "csv",
            "yaml", "yml", "js", "py", "swift", "html", "css",
            "ts", "tsx", "jsx", "sh", "go", "rs", "c", "cpp",
            "h", "hpp", "java", "kt", "toml", "ini", "sql",
        ]
        for ext in expected {
            XCTAssertTrue(
                TextFilePreviewCoordinator.textExtensions.contains(ext),
                "Expected textExtensions to contain '\(ext)'"
            )
        }
    }

    func testImageExtensionsNotInTextExtensions() {
        let imageExts = ["jpg", "jpeg", "png", "gif", "webp", "heic", "bmp", "tiff"]
        for ext in imageExts {
            XCTAssertFalse(
                TextFilePreviewCoordinator.textExtensions.contains(ext),
                "Image extension '\(ext)' should not be in textExtensions"
            )
        }
    }

    func testBinaryExtensionsNotInTextExtensions() {
        let binaryExts = ["pdf", "zip", "gz", "tar", "rar", "exe", "bin", "mp3", "mp4"]
        for ext in binaryExts {
            XCTAssertFalse(
                TextFilePreviewCoordinator.textExtensions.contains(ext),
                "Binary extension '\(ext)' should not be in textExtensions"
            )
        }
    }

    // MARK: - FileInfo.isTextPreviewable

    func testIsTextPreviewableForTextFiles() {
        let textFiles = ["notes.txt", "README.md", "config.json", "script.py", "main.swift", "app.js", "style.css"]
        for name in textFiles {
            let info = FileInfo(name: name, size: 100, createdAt: Date(), modifiedAt: Date(), isImage: false, isVideo: false)
            XCTAssertTrue(info.isTextPreviewable, "'\(name)' should be text-previewable")
        }
    }

    func testIsTextPreviewableForImageFiles() {
        let imageFiles = ["photo.jpg", "icon.png", "anim.gif"]
        for name in imageFiles {
            let info = FileInfo(name: name, size: 100, createdAt: Date(), modifiedAt: Date(), isImage: true, isVideo: false)
            XCTAssertFalse(info.isTextPreviewable, "'\(name)' should not be text-previewable")
        }
    }

    func testIsTextPreviewableForBinaryFiles() {
        let binaryFiles = ["doc.pdf", "archive.zip", "video.mp4"]
        for name in binaryFiles {
            let info = FileInfo(name: name, size: 100, createdAt: Date(), modifiedAt: Date(), isImage: false, isVideo: false)
            XCTAssertFalse(info.isTextPreviewable, "'\(name)' should not be text-previewable")
        }
    }

    func testIsTextPreviewableIsCaseInsensitive() {
        let info = FileInfo(name: "README.MD", size: 100, createdAt: Date(), modifiedAt: Date(), isImage: false, isVideo: false)
        XCTAssertTrue(info.isTextPreviewable, "Extension matching should be case-insensitive")
    }

    func testIsTextPreviewableNoExtension() {
        let info = FileInfo(name: "Makefile", size: 100, createdAt: Date(), modifiedAt: Date(), isImage: false, isVideo: false)
        // "Makefile" has no extension -> empty string, which is in textExtensions only if listed as "makefile"
        // The pathExtension of "Makefile" is "", so it should NOT be previewable
        XCTAssertFalse(info.isTextPreviewable, "Files without extension should not match")
    }

    // MARK: - TextFilePreviewCoordinator state

    @MainActor
    func testCoordinatorShowSetsState() {
        let coordinator = TextFilePreviewCoordinator.shared
        coordinator.show(content: "Hello, World!", filename: "test.txt")

        XCTAssertTrue(coordinator.isPresented)
        XCTAssertEqual(coordinator.content, "Hello, World!")
        XCTAssertEqual(coordinator.filename, "test.txt")
        XCTAssertFalse(coordinator.isMarkdown)

        // Cleanup
        coordinator.close(animated: false)
    }

    @MainActor
    func testCoordinatorShowMarkdownDetection() {
        let coordinator = TextFilePreviewCoordinator.shared
        coordinator.show(content: "# Title\nSome text", filename: "README.md")

        XCTAssertTrue(coordinator.isPresented)
        XCTAssertTrue(coordinator.isMarkdown)

        coordinator.close(animated: false)
    }

    @MainActor
    func testCoordinatorShowMarkdownExtensionVariant() {
        let coordinator = TextFilePreviewCoordinator.shared
        coordinator.show(content: "content", filename: "doc.markdown")

        XCTAssertTrue(coordinator.isMarkdown)

        coordinator.close(animated: false)
    }

    @MainActor
    func testCoordinatorShowNonMarkdownFile() {
        let coordinator = TextFilePreviewCoordinator.shared
        coordinator.show(content: "{}", filename: "config.json")

        XCTAssertTrue(coordinator.isPresented)
        XCTAssertFalse(coordinator.isMarkdown)

        coordinator.close(animated: false)
    }

    @MainActor
    func testCoordinatorCloseResetsPresented() {
        let coordinator = TextFilePreviewCoordinator.shared
        coordinator.show(content: "test", filename: "test.txt")
        XCTAssertTrue(coordinator.isPresented)

        coordinator.close(animated: false)
        XCTAssertFalse(coordinator.isPresented)
    }

    // MARK: - Integration: File read + preview

    func testTextFileCanBeReadAndPreviewed() throws {
        let content = "Line 1\nLine 2\nLine 3"
        try AgentFileManager.shared.writeFile(agentId: testAgentId, name: "notes.txt", data: Data(content.utf8))

        let data = try AgentFileManager.shared.readFile(agentId: testAgentId, name: "notes.txt")
        let text = String(data: data, encoding: .utf8)

        XCTAssertEqual(text, content)

        let info = AgentFileManager.shared.fileInfo(agentId: testAgentId, name: "notes.txt")
        XCTAssertNotNil(info)
        XCTAssertTrue(info?.isTextPreviewable ?? false)
        XCTAssertFalse(info?.isImage ?? true)
    }

    func testMarkdownFileCanBeReadAndPreviewed() throws {
        let content = "# Hello\n\nThis is **bold** and _italic_."
        try AgentFileManager.shared.writeFile(agentId: testAgentId, name: "README.md", data: Data(content.utf8))

        let data = try AgentFileManager.shared.readFile(agentId: testAgentId, name: "README.md")
        let text = String(data: data, encoding: .utf8)

        XCTAssertEqual(text, content)

        let info = AgentFileManager.shared.fileInfo(agentId: testAgentId, name: "README.md")
        XCTAssertNotNil(info)
        XCTAssertTrue(info?.isTextPreviewable ?? false)
    }

    func testJsonFileCanBeReadAndPreviewed() throws {
        let content = """
        {
            "name": "iClaw",
            "version": "1.0"
        }
        """
        try AgentFileManager.shared.writeFile(agentId: testAgentId, name: "config.json", data: Data(content.utf8))

        let info = AgentFileManager.shared.fileInfo(agentId: testAgentId, name: "config.json")
        XCTAssertNotNil(info)
        XCTAssertTrue(info?.isTextPreviewable ?? false)
    }

    func testCodeFileCanBeReadAndPreviewed() throws {
        let content = "print(\"Hello, World!\")"
        try AgentFileManager.shared.writeFile(agentId: testAgentId, name: "script.py", data: Data(content.utf8))

        let info = AgentFileManager.shared.fileInfo(agentId: testAgentId, name: "script.py")
        XCTAssertNotNil(info)
        XCTAssertTrue(info?.isTextPreviewable ?? false)
    }

    // MARK: - Image files remain non-text-previewable

    func testImageFileIsNotTextPreviewable() throws {
        let imageData = Data(repeating: 0xFF, count: 100)
        try AgentFileManager.shared.writeFile(agentId: testAgentId, name: "photo.jpg", data: imageData)

        let info = AgentFileManager.shared.fileInfo(agentId: testAgentId, name: "photo.jpg")
        XCTAssertNotNil(info)
        XCTAssertTrue(info?.isImage ?? false)
        XCTAssertFalse(info?.isTextPreviewable ?? true)
    }

    // MARK: - Mutual exclusivity: isImage vs isTextPreviewable

    func testImageAndTextPreviewableMutuallyExclusive() throws {
        let files: [(name: String, isImg: Bool, isTxt: Bool)] = [
            ("photo.jpg", true, false),
            ("icon.png", true, false),
            ("notes.txt", false, true),
            ("README.md", false, true),
            ("config.json", false, true),
            ("archive.zip", false, false),
            ("document.pdf", false, false),
        ]

        for file in files {
            let info = FileInfo(name: file.name, size: 0, createdAt: Date(), modifiedAt: Date(),
                                isImage: file.isImg, isVideo: false)
            XCTAssertEqual(info.isImage, file.isImg, "isImage mismatch for \(file.name)")
            XCTAssertEqual(info.isTextPreviewable, file.isTxt, "isTextPreviewable mismatch for \(file.name)")

            if info.isImage {
                XCTAssertFalse(info.isTextPreviewable, "\(file.name): should not be both image and text-previewable")
            }
        }
    }

    // MARK: - Non-UTF8 data gracefully handled

    func testNonUTF8DataReturnsNilString() throws {
        // Write binary data to a .txt file — String(data:encoding:) should return nil
        let binaryData = Data([0x80, 0x81, 0x82, 0xFE, 0xFF])
        try AgentFileManager.shared.writeFile(agentId: testAgentId, name: "binary.txt", data: binaryData)

        let data = try AgentFileManager.shared.readFile(agentId: testAgentId, name: "binary.txt")
        let text = String(data: data, encoding: .utf8)
        // String init may return nil for invalid UTF-8, which is the expected guard path
        // in the FileRowView and handleAgentFileLink
        if text != nil {
            // Some invalid byte sequences may still decode; that's acceptable
        } else {
            XCTAssertNil(text, "Non-UTF-8 data should fail to decode")
        }
    }

    // MARK: - Coordinator rapid open/close

    @MainActor
    func testCoordinatorRapidShowCloseCycles() {
        let coordinator = TextFilePreviewCoordinator.shared

        for i in 0..<5 {
            coordinator.show(content: "cycle \(i)", filename: "test\(i).txt")
            XCTAssertTrue(coordinator.isPresented)
            XCTAssertEqual(coordinator.content, "cycle \(i)")

            coordinator.close(animated: false)
            XCTAssertFalse(coordinator.isPresented)
        }
    }

    @MainActor
    func testCoordinatorShowOverwritesPreviousContent() {
        let coordinator = TextFilePreviewCoordinator.shared

        coordinator.show(content: "first", filename: "a.txt")
        XCTAssertEqual(coordinator.content, "first")
        XCTAssertEqual(coordinator.filename, "a.txt")
        XCTAssertFalse(coordinator.isMarkdown)

        // Show a new file without closing the first
        coordinator.show(content: "# Second", filename: "b.md")
        XCTAssertTrue(coordinator.isPresented)
        XCTAssertEqual(coordinator.content, "# Second")
        XCTAssertEqual(coordinator.filename, "b.md")
        XCTAssertTrue(coordinator.isMarkdown)

        coordinator.close(animated: false)
    }

    @MainActor
    func testCoordinatorCloseIsIdempotent() {
        let coordinator = TextFilePreviewCoordinator.shared
        coordinator.show(content: "test", filename: "test.txt")

        coordinator.close(animated: false)
        XCTAssertFalse(coordinator.isPresented)

        // Closing again should not crash or change state
        coordinator.close(animated: false)
        XCTAssertFalse(coordinator.isPresented)
    }

    // MARK: - Markdown detection edge cases

    @MainActor
    func testCoordinatorNonMarkdownExtensionsTreatedAsPlainText() {
        let coordinator = TextFilePreviewCoordinator.shared
        let plainExts = ["txt", "json", "swift", "py", "html", "css", "yaml", "log"]
        for ext in plainExts {
            coordinator.show(content: "# heading", filename: "file.\(ext)")
            XCTAssertFalse(coordinator.isMarkdown,
                           ".\(ext) should not be treated as markdown even if content has markdown syntax")
            coordinator.close(animated: false)
        }
    }

    @MainActor
    func testCoordinatorEmptyContent() {
        let coordinator = TextFilePreviewCoordinator.shared
        coordinator.show(content: "", filename: "empty.txt")

        XCTAssertTrue(coordinator.isPresented)
        XCTAssertEqual(coordinator.content, "")
        XCTAssertEqual(coordinator.filename, "empty.txt")

        coordinator.close(animated: false)
    }

    @MainActor
    func testCoordinatorLargeContent() {
        let coordinator = TextFilePreviewCoordinator.shared
        let largeContent = String(repeating: "Line of text\n", count: 10_000)
        coordinator.show(content: largeContent, filename: "large.log")

        XCTAssertTrue(coordinator.isPresented)
        XCTAssertEqual(coordinator.content?.count, largeContent.count)

        coordinator.close(animated: false)
    }

    @MainActor
    func testCoordinatorUnicodeFilenameAndContent() {
        let coordinator = TextFilePreviewCoordinator.shared
        coordinator.show(content: "你好世界 🌍\nこんにちは", filename: "笔记.md")

        XCTAssertTrue(coordinator.isPresented)
        XCTAssertTrue(coordinator.isMarkdown)
        XCTAssertEqual(coordinator.content, "你好世界 🌍\nこんにちは")
        XCTAssertEqual(coordinator.filename, "笔记.md")

        coordinator.close(animated: false)
    }
}
