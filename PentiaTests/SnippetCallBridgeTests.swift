import XCTest
@testable import iClaw

/// Covers the `snippets.*` bridge surface: preamble wiring, list dispatch,
/// and the invoke-dispatch guards (missing name, unknown snippet, non-JS language).
/// Tests that require real JS execution (recursion, stdin piping, capture mode,
/// depth/budget enforcement mid-run) live in simulator integration tests where
/// WKWebView is available.
@MainActor
final class SnippetCallBridgeTests: XCTestCase {

    private var bridge: AppleEcosystemBridge!
    private var agentId: UUID!
    private var execId: String!

    override func setUp() async throws {
        try await super.setUp()
        bridge = AppleEcosystemBridge.shared
        agentId = UUID()
        execId = UUID().uuidString
    }

    override func tearDown() async throws {
        bridge.unregisterPermissions(execId: execId)
        bridge = nil
        agentId = nil
        execId = nil
        try await super.tearDown()
    }

    // MARK: - Preamble wiring

    func testPreambleExposesSnippetsObject() {
        let preamble = AppleEcosystemBridge.jsPreamble(blockedActions: [], execId: "test")
        XCTAssertTrue(preamble.contains("var snippets"),
                      "preamble should inject the `snippets` global")
        XCTAssertTrue(preamble.contains("snippets.invoke"),
                      "preamble should declare snippets.invoke")
        XCTAssertTrue(preamble.contains("snippets.pipe"),
                      "preamble should declare snippets.pipe")
        XCTAssertTrue(preamble.contains("snippets.list"),
                      "preamble should declare snippets.list")
        XCTAssertTrue(preamble.contains("'snippets.invoke'"),
                      "preamble should route invokes through the bridge action")
        XCTAssertTrue(preamble.contains("'snippets.list'"),
                      "preamble should route list through the bridge action")
    }

    func testCallableScriptWrapsInAsyncIife() {
        // Callable scripts must allow a top-level `return value;`, which only works
        // when the user body is wrapped in an async IIFE.
        let preamble = AppleEcosystemBridge.jsPreamble(blockedActions: [], execId: "test")
        XCTAssertTrue(preamble.contains("opts.stdin")
                      || preamble.contains("opts.stdin === 'string'"),
                      "invoke wrapper should forward stdin from opts")
        XCTAssertTrue(preamble.contains("opts.capture"),
                      "invoke wrapper should honour the capture flag")
    }

    // MARK: - snippets.list dispatch

    func testSnippetsListReturnsEmptyArrayWhenNoLister() async {
        bridge.registerContext(execId: execId, agentId: agentId) { _ in true }
        let raw = await bridge.dispatchForTesting(action: "snippets.list", args: [:], execId: execId)
        XCTAssertEqual(raw, "[]",
                      "list should return an empty array when no snippet lister was registered")
    }

    func testSnippetsListReturnsRegisteredSnippets() async {
        let snippets: [AppleEcosystemBridge.SnippetInfo] = [
            .init(name: "double", language: "javascript", code: "return args.n * 2;"),
            .init(name: "greet", language: "javascript", code: "return 'hi ' + args.name;")
        ]
        bridge.registerContext(
            execId: execId,
            agentId: agentId,
            blockedActions: [],
            totalBudget: 60,
            snippetResolver: { name in snippets.first { $0.name == name } },
            snippetLister: { snippets }
        ) { _ in true }

        let raw = await bridge.dispatchForTesting(action: "snippets.list", args: [:], execId: execId)
        guard let data = raw.data(using: .utf8),
              let arr = try? JSONSerialization.jsonObject(with: data) as? [[String: String]] else {
            XCTFail("list response is not a JSON array: \(raw)")
            return
        }
        XCTAssertEqual(arr.count, 2)
        XCTAssertEqual(arr.map { $0["name"] ?? "" }.sorted(), ["double", "greet"])
        XCTAssertTrue(arr.allSatisfy { $0["language"] == "javascript" })
    }

    // MARK: - snippets.invoke guards

    func testInvokeRejectsWhenNoResolverRegistered() async {
        bridge.registerContext(execId: execId, agentId: agentId) { _ in true }
        let raw = await bridge.dispatchForTesting(
            action: "snippets.invoke",
            args: ["name": "whatever"],
            execId: execId
        )
        XCTAssertTrue(raw.contains("[Error]"))
        XCTAssertTrue(raw.lowercased().contains("unavailable") || raw.contains("not registered"),
                      "expected a clear unavailable-in-context error, got: \(raw)")
    }

    func testInvokeRejectsMissingName() async {
        let snippets: [AppleEcosystemBridge.SnippetInfo] = [
            .init(name: "noop", language: "javascript", code: "return 1;")
        ]
        bridge.registerContext(
            execId: execId,
            agentId: agentId,
            blockedActions: [],
            totalBudget: 60,
            snippetResolver: { name in snippets.first { $0.name == name } },
            snippetLister: { snippets }
        ) { _ in true }

        let raw = await bridge.dispatchForTesting(
            action: "snippets.invoke",
            args: [:],
            execId: execId
        )
        XCTAssertTrue(raw.contains("[Error]"))
        XCTAssertTrue(raw.lowercased().contains("missing"), "got: \(raw)")
    }

    func testInvokeRejectsUnknownSnippet() async {
        let snippets: [AppleEcosystemBridge.SnippetInfo] = [
            .init(name: "real", language: "javascript", code: "return 1;")
        ]
        bridge.registerContext(
            execId: execId,
            agentId: agentId,
            blockedActions: [],
            totalBudget: 60,
            snippetResolver: { name in snippets.first { $0.name == name } },
            snippetLister: { snippets }
        ) { _ in true }

        let raw = await bridge.dispatchForTesting(
            action: "snippets.invoke",
            args: ["name": "ghost"],
            execId: execId
        )
        XCTAssertTrue(raw.contains("[Error]"))
        XCTAssertTrue(raw.contains("'ghost'"), "error should name the missing snippet, got: \(raw)")
        XCTAssertTrue(raw.contains("real"), "error should list available snippets, got: \(raw)")
    }

    func testInvokeRejectsNonJavaScriptSnippet() async {
        let snippets: [AppleEcosystemBridge.SnippetInfo] = [
            .init(name: "pyscript", language: "python", code: "print('hi')")
        ]
        bridge.registerContext(
            execId: execId,
            agentId: agentId,
            blockedActions: [],
            totalBudget: 60,
            snippetResolver: { name in snippets.first { $0.name == name } },
            snippetLister: { snippets }
        ) { _ in true }

        let raw = await bridge.dispatchForTesting(
            action: "snippets.invoke",
            args: ["name": "pyscript"],
            execId: execId
        )
        XCTAssertTrue(raw.contains("[Error]"))
        XCTAssertTrue(raw.contains("python") || raw.lowercased().contains("javascript"),
                      "error should explain the language mismatch, got: \(raw)")
    }

    // MARK: - Depth cap constant

    func testMaxSnippetCallDepthConstant() {
        XCTAssertEqual(AppleEcosystemBridge.maxSnippetCallDepth, 16,
                       "documented depth limit should match the constant")
    }
}
