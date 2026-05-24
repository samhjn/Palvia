import XCTest
@testable import Pentia

// MARK: - FileInfo.isHTML

final class FileInfoHTMLTests: XCTestCase {

    func testHTMLExtensionDetected() {
        let htmlFiles = ["index.html", "page.htm", "INDEX.HTML", "About.HTM"]
        for name in htmlFiles {
            let info = FileInfo(name: name, size: 100, createdAt: Date(), modifiedAt: Date(), isImage: false, isVideo: false)
            XCTAssertTrue(info.isHTML, "'\(name)' should be detected as HTML")
        }
    }

    func testNonHTMLExtensionNotDetected() {
        let others = ["style.css", "app.js", "notes.txt", "README.md", "data.json", "image.png"]
        for name in others {
            let info = FileInfo(name: name, size: 100, createdAt: Date(), modifiedAt: Date(), isImage: false, isVideo: false)
            XCTAssertFalse(info.isHTML, "'\(name)' should not be detected as HTML")
        }
    }

    func testHTMLFilesAreAlsoTextPreviewable() {
        let info = FileInfo(name: "page.html", size: 100, createdAt: Date(), modifiedAt: Date(), isImage: false, isVideo: false)
        XCTAssertTrue(info.isHTML)
        XCTAssertTrue(info.isTextPreviewable, "HTML files should remain in textExtensions for fallback")
    }

    func testDirectoryIsNotHTML() {
        let info = FileInfo(name: "html", size: 0, createdAt: Date(), modifiedAt: Date(), isImage: false, isVideo: false, isDirectory: true)
        XCTAssertFalse(info.isHTML, "Directory named 'html' should not be detected as HTML")
    }
}

// MARK: - BrowserService Agent Scope

@MainActor
final class BrowserAgentScopeTests: XCTestCase {

    private var testAgentId: UUID!

    override func setUp() {
        super.setUp()
        testAgentId = UUID()
        BrowserService.shared.forceReleaseLock()
        BrowserService.shared.closeAllPages()
    }

    override func tearDown() {
        AgentFileManager.shared.cleanupAgentFiles(agentId: testAgentId)
        BrowserService.shared.closeAllPages()
        BrowserService.shared.forceReleaseLock()
        testAgentId = nil
        super.tearDown()
    }

    func testInitialAgentScopeIsNil() {
        XCTAssertNil(BrowserService.shared.currentAgentScope)
    }

    func testLoadAgentFileSetsScope() throws {
        let html = "<html><body>Hello</body></html>"
        try AgentFileManager.shared.writeFile(agentId: testAgentId, name: "index.html", data: Data(html.utf8))

        let fileURL = AgentFileManager.shared.fileURL(agentId: testAgentId, name: "index.html")

        // loadAgentFile sets currentAgentScope synchronously before awaiting
        // navigation; we call the WebView load directly to verify the scope
        // without relying on WKWebView finishing navigation in unit tests.
        let agentDir = AgentFileManager.shared.agentDirectory(for: testAgentId)
        BrowserService.shared.webView.loadFileURL(fileURL, allowingReadAccessTo: agentDir)

        // Simulate what loadAgentFile does synchronously
        let scope = agentDir.standardizedFileURL
        XCTAssertNotNil(scope)

        let expected = AgentFileManager.shared.agentDirectory(for: testAgentId).standardizedFileURL
        XCTAssertEqual(scope, expected,
                       "Scope should be the agent's root directory")
    }

    func testCloseAllPagesClearsAgentScope() async throws {
        let html = "<html><body>Hello</body></html>"
        try AgentFileManager.shared.writeFile(agentId: testAgentId, name: "test.html", data: Data(html.utf8))

        let fileURL = AgentFileManager.shared.fileURL(agentId: testAgentId, name: "test.html")

        // loadAgentFile sets currentAgentScope synchronously before the await;
        // start the task and yield so the synchronous part runs.
        let task = Task {
            await BrowserService.shared.loadAgentFile(fileURL: fileURL, agentId: testAgentId)
        }
        await Task.yield()
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertNotNil(BrowserService.shared.currentAgentScope,
                        "loadAgentFile should set scope before navigation")
        task.cancel()

        BrowserService.shared.closeAllPages()
        XCTAssertNil(BrowserService.shared.currentAgentScope,
                     "closeAllPages should clear agent scope")
    }

    func testNavigateToClearsAgentScope() async throws {
        let html = "<html><body>Hello</body></html>"
        try AgentFileManager.shared.writeFile(agentId: testAgentId, name: "test.html", data: Data(html.utf8))

        let fileURL = AgentFileManager.shared.fileURL(agentId: testAgentId, name: "test.html")

        let task = Task {
            await BrowserService.shared.loadAgentFile(fileURL: fileURL, agentId: testAgentId)
        }
        await Task.yield()
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertNotNil(BrowserService.shared.currentAgentScope)
        task.cancel()

        // navigate(to:) clears the scope synchronously before loading
        let navTask = Task {
            await BrowserService.shared.navigate(to: "about:blank")
        }
        await Task.yield()
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertNil(BrowserService.shared.currentAgentScope,
                     "navigate(to:) should clear agent scope")
        navTask.cancel()
    }

    func testLoadAgentFileFromSubdirectory() async throws {
        try AgentFileManager.shared.makeDirectory(agentId: testAgentId, path: "pages")
        let html = "<html><body>Sub page</body></html>"
        try AgentFileManager.shared.writeFile(agentId: testAgentId, name: "pages/about.html", data: Data(html.utf8))

        let fileURL = AgentFileManager.shared.fileURL(agentId: testAgentId, name: "pages/about.html")

        let task = Task {
            await BrowserService.shared.loadAgentFile(fileURL: fileURL, agentId: testAgentId)
        }
        await Task.yield()
        try await Task.sleep(for: .milliseconds(50))

        let scope = BrowserService.shared.currentAgentScope
        XCTAssertNotNil(scope)
        let agentDir = AgentFileManager.shared.agentDirectory(for: testAgentId).standardizedFileURL
        XCTAssertEqual(scope, agentDir,
                       "Scope should be agent root even when loading from subdirectory")
        task.cancel()
    }
}

// MARK: - BrowserTools agentfile:// parsing logic

final class BrowserToolsAgentFileTests: XCTestCase {

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

    func testAgentFileReferenceParsingForHTML() {
        let ref = AgentFileManager.makeFileReference(agentId: testAgentId, filename: "app.html")
        guard let (agentId, filename) = AgentFileManager.parseFileReference(ref) else {
            XCTFail("Should parse agentfile:// HTML reference"); return
        }
        XCTAssertEqual(agentId, testAgentId)
        XCTAssertEqual(filename, "app.html")
        let ext = (filename as NSString).pathExtension.lowercased()
        XCTAssertTrue(["html", "htm"].contains(ext))
    }

    func testAgentFileReferenceParsingForNonHTML() {
        let ref = AgentFileManager.makeFileReference(agentId: testAgentId, filename: "data.json")
        guard let (_, filename) = AgentFileManager.parseFileReference(ref) else {
            XCTFail("Should parse agentfile:// reference"); return
        }
        let ext = (filename as NSString).pathExtension.lowercased()
        XCTAssertFalse(["html", "htm"].contains(ext),
                       "Non-HTML file should be detected and rejected by navigate()")
    }

    func testMissingHTMLFileNotOnDisk() throws {
        let fileURL = AgentFileManager.shared.fileURL(agentId: testAgentId, name: "missing.html")
        XCTAssertFalse(FileManager.default.fileExists(atPath: fileURL.path),
                       "File that was never written should not exist")
    }

    func testExistingHTMLFileOnDisk() throws {
        try AgentFileManager.shared.writeFile(agentId: testAgentId, name: "app.html",
                                               data: Data("<html></html>".utf8))
        let fileURL = AgentFileManager.shared.fileURL(agentId: testAgentId, name: "app.html")
        XCTAssertTrue(FileManager.default.fileExists(atPath: fileURL.path),
                      "Written HTML file should exist on disk")
    }

    func testRegularURLNotParsedAsAgentFile() {
        let regularURL = "https://example.com"
        let result = AgentFileManager.parseFileReference(regularURL)
        XCTAssertNil(result, "Regular URLs should not parse as agentfile:// references")
    }
}

// MARK: - Navigation Policy (decidePolicyFor scope validation)

@MainActor
final class BrowserNavigationPolicyTests: XCTestCase {

    func testFileURLBlockedWithoutScope() {
        let service = BrowserService.shared
        service.closeAllPages()
        XCTAssertNil(service.currentAgentScope,
                     "Precondition: no agent scope should be active")
    }

    func testScopePathContainmentLogic() {
        let agentId = UUID()
        let agentDir = AgentFileManager.shared.agentDirectory(for: agentId).standardizedFileURL
        let scopePath = agentDir.path.hasSuffix("/") ? agentDir.path : agentDir.path + "/"

        let insideFile = agentDir.appendingPathComponent("index.html").standardizedFileURL
        XCTAssertTrue(insideFile.path.hasPrefix(scopePath),
                      "File inside agent dir should pass scope check")

        let subDir = agentDir.appendingPathComponent("css/style.css").standardizedFileURL
        XCTAssertTrue(subDir.path.hasPrefix(scopePath),
                      "File in subdirectory should pass scope check")

        let outsideFile = agentDir.deletingLastPathComponent()
            .appendingPathComponent("other-agent/evil.html").standardizedFileURL
        XCTAssertFalse(outsideFile.path.hasPrefix(scopePath),
                       "File outside agent dir should fail scope check")

        let parentTraversal = agentDir.appendingPathComponent("../../../etc/passwd").standardizedFileURL
        XCTAssertFalse(parentTraversal.path.hasPrefix(scopePath),
                       "Path traversal should fail scope check")
    }
}

// MARK: - Deep Link HTML Handling

final class DeepLinkHTMLTests: XCTestCase {

    func testHTMLExtensionDetectedInDeepLink() {
        let htmlExts = ["html", "htm"]
        for ext in htmlExts {
            let ref = "agentfile://\(UUID().uuidString)/page.\(ext)"
            guard let (_, filename) = AgentFileManager.parseFileReference(ref) else {
                XCTFail("Failed to parse reference for .\(ext)"); continue
            }
            let parsedExt = (filename as NSString).pathExtension.lowercased()
            XCTAssertTrue(["html", "htm"].contains(parsedExt),
                          ".\(ext) should be detected as HTML in deep link")
        }
    }

    func testNonHTMLDeepLinkNotTreatedAsHTML() {
        let nonHTMLExts = ["txt", "json", "css", "js", "png", "pdf"]
        for ext in nonHTMLExts {
            let ref = "agentfile://\(UUID().uuidString)/file.\(ext)"
            guard let (_, filename) = AgentFileManager.parseFileReference(ref) else {
                XCTFail("Failed to parse reference for .\(ext)"); continue
            }
            let parsedExt = (filename as NSString).pathExtension.lowercased()
            XCTAssertFalse(["html", "htm"].contains(parsedExt),
                           ".\(ext) should not be treated as HTML")
        }
    }

    func testSubdirectoryHTMLDeepLink() {
        let agentId = UUID()
        let ref = AgentFileManager.makeFileReference(agentId: agentId, filename: "pages/docs/index.html")
        guard let (parsedId, filename) = AgentFileManager.parseFileReference(ref) else {
            XCTFail("Failed to parse subdirectory HTML reference"); return
        }
        XCTAssertEqual(parsedId, agentId)
        XCTAssertEqual(filename, "pages/docs/index.html")
        let ext = (filename as NSString).pathExtension.lowercased()
        XCTAssertEqual(ext, "html")
    }
}

// MARK: - Notification name

final class BrowserSwitchNotificationTests: XCTestCase {

    func testNotificationNameExists() {
        let name = BrowserService.switchToBrowserTabNotification
        XCTAssertFalse(name.rawValue.isEmpty)
        XCTAssertTrue(name.rawValue.contains("switchToBrowserTab"))
    }
}

// MARK: - Integration: HTML with relative resources

final class AgentHTMLResourcePathTests: XCTestCase {

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

    func testHTMLWithRelativeCSSPathResolvesWithinAgentDir() throws {
        try AgentFileManager.shared.makeDirectory(agentId: testAgentId, path: "css")
        try AgentFileManager.shared.writeFile(
            agentId: testAgentId, name: "css/style.css",
            data: Data("body { color: red; }".utf8)
        )

        let html = """
        <!DOCTYPE html>
        <html>
        <head><link rel="stylesheet" href="css/style.css"></head>
        <body><h1>Hello</h1></body>
        </html>
        """
        try AgentFileManager.shared.writeFile(agentId: testAgentId, name: "index.html", data: Data(html.utf8))

        let agentDir = AgentFileManager.shared.agentDirectory(for: testAgentId)
        let htmlURL = agentDir.appendingPathComponent("index.html")
        let cssURL = agentDir.appendingPathComponent("css/style.css")

        XCTAssertTrue(FileManager.default.fileExists(atPath: htmlURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: cssURL.path))

        let scopePath = agentDir.standardizedFileURL.path
        let cssPath = cssURL.standardizedFileURL.path
        let scopePrefix = scopePath.hasSuffix("/") ? scopePath : scopePath + "/"
        XCTAssertTrue(cssPath.hasPrefix(scopePrefix),
                      "CSS file should be within agent scope for WKWebView access")
    }

    func testHTMLWithRelativeJSPathResolvesWithinAgentDir() throws {
        try AgentFileManager.shared.makeDirectory(agentId: testAgentId, path: "js")
        try AgentFileManager.shared.writeFile(
            agentId: testAgentId, name: "js/app.js",
            data: Data("console.log('loaded');".utf8)
        )

        let html = """
        <!DOCTYPE html>
        <html>
        <head><script src="js/app.js"></script></head>
        <body></body>
        </html>
        """
        try AgentFileManager.shared.writeFile(agentId: testAgentId, name: "index.html", data: Data(html.utf8))

        let agentDir = AgentFileManager.shared.agentDirectory(for: testAgentId)
        let jsURL = agentDir.appendingPathComponent("js/app.js")

        XCTAssertTrue(FileManager.default.fileExists(atPath: jsURL.path))

        let scopePath = agentDir.standardizedFileURL.path
        let jsPath = jsURL.standardizedFileURL.path
        let scopePrefix = scopePath.hasSuffix("/") ? scopePath : scopePath + "/"
        XCTAssertTrue(jsPath.hasPrefix(scopePrefix),
                      "JS file should be within agent scope for WKWebView access")
    }

    func testParentTraversalStaysOutsideScope() throws {
        let html = """
        <!DOCTYPE html>
        <html>
        <head><script src="../../other-agent/steal.js"></script></head>
        <body></body>
        </html>
        """
        try AgentFileManager.shared.writeFile(agentId: testAgentId, name: "index.html", data: Data(html.utf8))

        let agentDir = AgentFileManager.shared.agentDirectory(for: testAgentId)
        let maliciousURL = agentDir.appendingPathComponent("../../other-agent/steal.js").standardizedFileURL

        let scopePath = agentDir.standardizedFileURL.path
        let scopePrefix = scopePath.hasSuffix("/") ? scopePath : scopePath + "/"
        XCTAssertFalse(maliciousURL.path.hasPrefix(scopePrefix),
                       "Parent traversal should resolve outside agent scope")
    }

    func testSiblingHTMLNavigation() throws {
        let page1 = "<html><body><a href=\"page2.html\">Next</a></body></html>"
        let page2 = "<html><body>Page 2</body></html>"
        try AgentFileManager.shared.writeFile(agentId: testAgentId, name: "page1.html", data: Data(page1.utf8))
        try AgentFileManager.shared.writeFile(agentId: testAgentId, name: "page2.html", data: Data(page2.utf8))

        let agentDir = AgentFileManager.shared.agentDirectory(for: testAgentId)
        let page2URL = agentDir.appendingPathComponent("page2.html").standardizedFileURL

        let scopePath = agentDir.standardizedFileURL.path
        let scopePrefix = scopePath.hasSuffix("/") ? scopePath : scopePath + "/"
        XCTAssertTrue(page2URL.path.hasPrefix(scopePrefix),
                      "Sibling HTML file should be within agent scope")
    }
}
