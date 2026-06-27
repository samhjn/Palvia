import XCTest
@testable import Palvia

/// Tests for the Models.dev catalog decoding and the mapping onto Palvia's
/// provider/model configuration vocabulary.
final class ModelsDevCatalogTests: XCTestCase {

    /// A trimmed slice of the real `https://models.dev/api.json` payload —
    /// enough providers and field shapes to exercise decoding + mapping.
    private let sampleJSON = """
    {
      "anthropic": {
        "id": "anthropic",
        "name": "Anthropic",
        "npm": "@ai-sdk/anthropic",
        "env": ["ANTHROPIC_API_KEY"],
        "models": {
          "claude-opus-4-5": {
            "id": "claude-opus-4-5",
            "name": "Claude Opus 4.5",
            "reasoning": true,
            "tool_call": true,
            "temperature": true,
            "release_date": "2025-11-24",
            "modalities": { "input": ["text", "image", "pdf"], "output": ["text"] },
            "limit": { "context": 200000, "output": 64000 }
          }
        }
      },
      "deepseek": {
        "id": "deepseek",
        "name": "DeepSeek",
        "npm": "@ai-sdk/openai-compatible",
        "api": "https://api.deepseek.com",
        "env": ["DEEPSEEK_API_KEY"],
        "models": {
          "deepseek-chat": {
            "id": "deepseek-chat",
            "name": "DeepSeek Chat",
            "tool_call": true,
            "modalities": { "input": ["text"], "output": ["text"] }
          }
        }
      },
      "acme-gateway": {
        "id": "acme-gateway",
        "name": "Acme Gateway",
        "npm": "@ai-sdk/openai-compatible",
        "api": "https://api.acme.example/v1/",
        "models": {
          "acme-vision": {
            "id": "acme-vision",
            "name": "Acme Vision",
            "tool_call": false,
            "modalities": { "input": ["text", "image", "video"], "output": ["text", "image"] }
          }
        }
      },
      "empty-provider": {
        "id": "empty-provider",
        "name": "Empty",
        "models": {}
      }
    }
    """

    private func decodeSample() throws -> ModelsDevCatalog {
        let data = sampleJSON.data(using: .utf8)!
        return try JSONDecoder().decode(ModelsDevCatalog.self, from: data)
    }

    // MARK: - Decoding

    func testDecodesAllProviders() throws {
        let catalog = try decodeSample()
        XCTAssertEqual(catalog.byID.count, 4)
        XCTAssertNotNil(catalog.byID["anthropic"])
        XCTAssertEqual(catalog.byID["anthropic"]?.models.first?.displayName, "Claude Opus 4.5")
    }

    func testProvidersListExcludesEmptyAndSortsByName() throws {
        let catalog = try decodeSample()
        let providers = catalog.providers
        // "empty-provider" has no models and must be filtered out.
        XCTAssertEqual(providers.map(\.id), ["acme-gateway", "anthropic", "deepseek"])
        XCTAssertFalse(providers.contains { $0.id == "empty-provider" })
    }

    func testModelFieldsDecode() throws {
        let catalog = try decodeSample()
        let model = catalog.byID["anthropic"]!.models.first!
        XCTAssertEqual(model.id, "claude-opus-4-5")
        XCTAssertEqual(model.reasoning, true)
        XCTAssertEqual(model.toolCall, true)
        XCTAssertEqual(model.limit?.context, 200000)
        XCTAssertTrue(model.supportsImageInput)
        XCTAssertFalse(model.supportsVideoInput)
        XCTAssertFalse(model.generatesImages)
    }

    // MARK: - Endpoint / API style mapping

    func testKnownProviderMapping() throws {
        let catalog = try decodeSample()
        let anthropic = catalog.byID["anthropic"]!
        XCTAssertEqual(ModelsDevMapping.apiStyle(for: anthropic), .anthropic)
        XCTAssertEqual(ModelsDevMapping.endpoint(for: anthropic), "https://api.anthropic.com/v1")

        let deepseek = catalog.byID["deepseek"]!
        // Curated table wins over the catalog's bare `api` (which lacks /v1).
        XCTAssertEqual(ModelsDevMapping.apiStyle(for: deepseek), .openAI)
        XCTAssertEqual(ModelsDevMapping.endpoint(for: deepseek), "https://api.deepseek.com/v1")
    }

    func testUnknownProviderFallsBackToCatalogAPI() throws {
        let catalog = try decodeSample()
        let acme = catalog.byID["acme-gateway"]!
        XCTAssertEqual(ModelsDevMapping.apiStyle(for: acme), .openAI)
        // Trailing slash is trimmed.
        XCTAssertEqual(ModelsDevMapping.endpoint(for: acme), "https://api.acme.example/v1")
        XCTAssertTrue(ModelsDevMapping.hasEndpoint(for: acme))
    }

    func testUnknownAnthropicNpmMapsToAnthropic() {
        let provider = ModelsDevProvider(
            id: "some-anthropic-proxy",
            name: "Proxy",
            npm: "@ai-sdk/anthropic",
            api: "https://proxy.example"
        )
        XCTAssertEqual(ModelsDevMapping.apiStyle(for: provider), .anthropic)
    }

    func testProviderWithoutEndpointReportsMissing() {
        let provider = ModelsDevProvider(id: "mystery", name: "Mystery", npm: "@ai-sdk/openai")
        XCTAssertEqual(ModelsDevMapping.endpoint(for: provider), "")
        XCTAssertFalse(ModelsDevMapping.hasEndpoint(for: provider))
    }

    // MARK: - Capability mapping

    func testReasoningModelGetsThinkingLevel() throws {
        let catalog = try decodeSample()
        let caps = catalog.byID["anthropic"]!.models.first!.capabilities()
        XCTAssertTrue(caps.supportsVision)
        XCTAssertTrue(caps.supportsToolUse)
        XCTAssertTrue(caps.thinkingLevel.isEnabled)
        XCTAssertEqual(caps.imageGenerationMode, .none)
    }

    func testToolCallFalseDisablesToolUse() throws {
        let catalog = try decodeSample()
        let caps = catalog.byID["acme-gateway"]!.models.first!.capabilities()
        XCTAssertFalse(caps.supportsToolUse)
    }

    func testImageOutputBecomesChatInline() throws {
        let catalog = try decodeSample()
        let caps = catalog.byID["acme-gateway"]!.models.first!.capabilities()
        XCTAssertEqual(caps.imageGenerationMode, .chatInline)
    }

    func testVideoInputCapability() throws {
        let catalog = try decodeSample()
        let caps = catalog.byID["acme-gateway"]!.models.first!.capabilities()
        XCTAssertTrue(caps.supportsVideoInput)
        // Video input implies vision.
        XCTAssertTrue(caps.supportsVision)
    }

    // MARK: - Import payload

    func testCapabilitiesPreservedAcrossModels() throws {
        let catalog = try decodeSample()
        let provider = catalog.byID["deepseek"]!
        let model = provider.models.first!
        let caps = model.capabilities()
        // deepseek-chat classifies as DeepSeek v4 → high thinking by inference.
        XCTAssertTrue(caps.thinkingLevel.isEnabled)
        XCTAssertTrue(caps.supportsToolUse)
        XCTAssertFalse(caps.supportsVision)
    }
}
