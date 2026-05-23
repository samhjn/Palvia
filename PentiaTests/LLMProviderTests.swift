import XCTest
import SwiftData
@testable import iClaw

final class LLMProviderTests: XCTestCase {

    private var container: ModelContainer!
    private var context: ModelContext!

    @MainActor
    override func setUp() {
        super.setUp()
        let schema = Schema([Agent.self, LLMProvider.self, Session.self, AgentConfig.self,
                             CodeSnippet.self, CronJob.self, InstalledSkill.self, Skill.self,
                             Message.self])
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        container = try! ModelContainer(for: schema, configurations: [config])
        context = ModelContext(container)
    }

    override func tearDown() {
        container = nil
        context = nil
        super.tearDown()
    }

    // MARK: - Init Defaults

    @MainActor
    func testDefaultInit() {
        let provider = LLMProvider(name: "Test Provider")
        XCTAssertEqual(provider.name, "Test Provider")
        XCTAssertEqual(provider.endpoint, "https://api.openai.com/v1")
        XCTAssertEqual(provider.modelName, "gpt-5.4")
        XCTAssertFalse(provider.isDefault)
        XCTAssertEqual(provider.maxTokens, 4096)
        XCTAssertEqual(provider.temperature, 0.7)
        XCTAssertEqual(provider.apiStyle, .openAI)
        XCTAssertTrue(provider.apiKey.isEmpty)
    }

    @MainActor
    func testCustomInit() {
        let provider = LLMProvider(
            name: "Anthropic",
            endpoint: "https://api.anthropic.com/v1",
            apiKey: "sk-ant-xxx",
            modelName: "claude-3-opus",
            isDefault: true,
            maxTokens: 8192,
            temperature: 0.5
        )
        XCTAssertEqual(provider.name, "Anthropic")
        XCTAssertEqual(provider.endpoint, "https://api.anthropic.com/v1")
        XCTAssertEqual(provider.apiKey, "sk-ant-xxx")
        XCTAssertEqual(provider.modelName, "claude-3-opus")
        XCTAssertTrue(provider.isDefault)
        XCTAssertEqual(provider.maxTokens, 8192)
        XCTAssertEqual(provider.temperature, 0.5)
    }

    // MARK: - API Style

    @MainActor
    func testAPIStyleOpenAI() {
        let provider = LLMProvider(name: "OpenAI")
        XCTAssertEqual(provider.apiStyle, .openAI)
        XCTAssertEqual(provider.apiStyleRaw, "openai")
    }

    @MainActor
    func testAPIStyleAnthropic() {
        let provider = LLMProvider(name: "Anthropic")
        provider.apiStyle = .anthropic
        XCTAssertEqual(provider.apiStyle, .anthropic)
        XCTAssertEqual(provider.apiStyleRaw, "anthropic")
    }

    @MainActor
    func testAPIStyleDisplayNames() {
        // Display names come from L10n; just verify they're non-empty and distinct
        XCTAssertFalse(APIStyle.openAI.displayName.isEmpty)
        XCTAssertFalse(APIStyle.openAIResponses.displayName.isEmpty)
        XCTAssertFalse(APIStyle.anthropic.displayName.isEmpty)
        XCTAssertNotEqual(APIStyle.openAI.displayName, APIStyle.anthropic.displayName)
        XCTAssertNotEqual(APIStyle.openAI.displayName, APIStyle.openAIResponses.displayName)
    }

    @MainActor
    func testAPIStyleCodable() throws {
        for style in APIStyle.allCases {
            let data = try JSONEncoder().encode(style)
            let decoded = try JSONDecoder().decode(APIStyle.self, from: data)
            XCTAssertEqual(decoded, style)
        }
    }

    // MARK: - Model Capabilities

    @MainActor
    func testDefaultCapabilities() {
        let caps = ModelCapabilities.default
        XCTAssertFalse(caps.supportsVision)
        XCTAssertTrue(caps.supportsToolUse)
        XCTAssertFalse(caps.supportsImageGeneration)
        XCTAssertFalse(caps.supportsReasoning)
    }

    @MainActor
    func testCapabilitiesFallbackToInferred() {
        let provider = LLMProvider(name: "Test")

        // Unknown model with no per-model entry falls back to inferred defaults
        let caps = provider.capabilities(for: "some-model")
        XCTAssertFalse(caps.supportsVision, "Unknown model should not infer vision")
        XCTAssertTrue(caps.supportsToolUse, "Default should support tool use")
        XCTAssertFalse(caps.supportsImageGeneration)

        // Known model name should get inferred capabilities
        let gptCaps = provider.capabilities(for: "gpt-4o")
        XCTAssertTrue(gptCaps.supportsVision, "GPT-4o should infer vision")
    }

    @MainActor
    func testSetAndGetModelCapabilities() {
        let provider = LLMProvider(name: "Test")
        let caps = ModelCapabilities(
            supportsVision: true,
            supportsToolUse: true,
            supportsImageGeneration: false,
            supportsReasoning: true
        )
        provider.setCapabilities(caps, for: "claude-3-opus")

        let retrieved = provider.capabilities(for: "claude-3-opus")
        XCTAssertEqual(retrieved, caps)
    }

    @MainActor
    func testModelCapabilitiesMultipleModels() {
        let provider = LLMProvider(name: "Multi")
        let caps1 = ModelCapabilities(supportsVision: true, supportsToolUse: true)
        let caps2 = ModelCapabilities(supportsVision: false, supportsToolUse: false)

        provider.setCapabilities(caps1, for: "model-a")
        provider.setCapabilities(caps2, for: "model-b")

        XCTAssertEqual(provider.capabilities(for: "model-a"), caps1)
        XCTAssertEqual(provider.capabilities(for: "model-b"), caps2)
    }

    @MainActor
    func testModelCapabilitiesOverwrite() {
        let provider = LLMProvider(name: "Test")
        let caps1 = ModelCapabilities(supportsVision: false)
        let caps2 = ModelCapabilities(supportsVision: true)

        provider.setCapabilities(caps1, for: "model-x")
        provider.setCapabilities(caps2, for: "model-x")

        XCTAssertEqual(provider.capabilities(for: "model-x").supportsVision, true)
    }

    @MainActor
    func testModelCapabilitiesCodableRoundTrip() throws {
        let caps = ModelCapabilities(
            supportsVision: true,
            supportsToolUse: false,
            supportsImageGeneration: true,
            supportsReasoning: true
        )
        let data = try JSONEncoder().encode(caps)
        let decoded = try JSONDecoder().decode(ModelCapabilities.self, from: data)
        XCTAssertEqual(decoded, caps)
    }

    // MARK: - Thinking Level

    func testThinkingLevelDefaults() {
        let caps = ModelCapabilities.default
        XCTAssertEqual(caps.thinkingLevel, .off)
        XCTAssertFalse(caps.thinkingLevel.isEnabled)
    }

    func testThinkingLevelExplicitValue() {
        let caps = ModelCapabilities(supportsReasoning: true, thinkingLevel: .high)
        XCTAssertEqual(caps.thinkingLevel, .high)
        XCTAssertTrue(caps.thinkingLevel.isEnabled)
    }

    func testThinkingLevelCodableRoundTrip() throws {
        for level in ThinkingLevel.allCases {
            let caps = ModelCapabilities(thinkingLevel: level)
            let data = try JSONEncoder().encode(caps)
            let decoded = try JSONDecoder().decode(ModelCapabilities.self, from: data)
            XCTAssertEqual(decoded.thinkingLevel, level,
                           "ThinkingLevel.\(level.rawValue) should survive encode/decode")
        }
    }

    func testThinkingLevelMigrationFromLegacyData() throws {
        // Simulate old persisted JSON that has supportsReasoning but no thinkingLevel key
        let legacyJSON = """
        {"supportsVision":false,"supportsToolUse":true,"supportsImageGeneration":false,"supportsReasoning":true}
        """
        let data = legacyJSON.data(using: .utf8)!
        let decoded = try JSONDecoder().decode(ModelCapabilities.self, from: data)
        XCTAssertEqual(decoded.thinkingLevel, .medium,
                       "Legacy supportsReasoning=true should migrate to .medium")
        XCTAssertTrue(decoded.supportsReasoning)
    }

    func testThinkingLevelMigrationNoReasoning() throws {
        let legacyJSON = """
        {"supportsVision":true,"supportsToolUse":true,"supportsImageGeneration":false,"supportsReasoning":false}
        """
        let data = legacyJSON.data(using: .utf8)!
        let decoded = try JSONDecoder().decode(ModelCapabilities.self, from: data)
        XCTAssertEqual(decoded.thinkingLevel, .off,
                       "Legacy supportsReasoning=false should stay .off")
    }

    func testThinkingLevelComparable() {
        XCTAssertTrue(ThinkingLevel.off < ThinkingLevel.low)
        XCTAssertTrue(ThinkingLevel.low < ThinkingLevel.medium)
        XCTAssertTrue(ThinkingLevel.medium < ThinkingLevel.high)
        XCTAssertFalse(ThinkingLevel.high < ThinkingLevel.off)
    }

    func testThinkingLevelAnthropicBudget() {
        XCTAssertEqual(ThinkingLevel.off.anthropicBudgetTokens, 0)
        XCTAssertEqual(ThinkingLevel.low.anthropicBudgetTokens, 2048)
        XCTAssertEqual(ThinkingLevel.medium.anthropicBudgetTokens, 10240)
        XCTAssertEqual(ThinkingLevel.high.anthropicBudgetTokens, 32768)
    }

    func testThinkingLevelOpenAIReasoningEffort() {
        XCTAssertNil(ThinkingLevel.off.openAIReasoningEffort)
        XCTAssertEqual(ThinkingLevel.low.openAIReasoningEffort, "low")
        XCTAssertEqual(ThinkingLevel.medium.openAIReasoningEffort, "medium")
        XCTAssertEqual(ThinkingLevel.high.openAIReasoningEffort, "high")
    }

    @MainActor
    func testThinkingLevelPerModelPersistence() {
        let provider = LLMProvider(name: "Test")
        let caps = ModelCapabilities(
            supportsVision: true,
            supportsReasoning: true,
            thinkingLevel: .high
        )
        provider.setCapabilities(caps, for: "claude-opus-4-6")

        let retrieved = provider.capabilities(for: "claude-opus-4-6")
        XCTAssertEqual(retrieved.thinkingLevel, .high)
        XCTAssertTrue(retrieved.supportsReasoning)
    }

    // MARK: - Per-model Parameters

    func testPerModelParametersDefaultNil() {
        let caps = ModelCapabilities.default
        XCTAssertNil(caps.maxTokens)
        XCTAssertNil(caps.temperature)
    }

    func testPerModelParametersExplicit() {
        let caps = ModelCapabilities(maxTokens: 8192, temperature: 0.3)
        XCTAssertEqual(caps.maxTokens, 8192)
        XCTAssertEqual(caps.temperature, 0.3)
    }

    func testPerModelParametersCodableRoundTrip() throws {
        let caps = ModelCapabilities(
            supportsVision: true,
            thinkingLevel: .medium,
            maxTokens: 16384,
            temperature: 0.5
        )
        let data = try JSONEncoder().encode(caps)
        let decoded = try JSONDecoder().decode(ModelCapabilities.self, from: data)
        XCTAssertEqual(decoded.maxTokens, 16384)
        XCTAssertEqual(decoded.temperature, 0.5)
        XCTAssertEqual(decoded, caps)
    }

    func testPerModelParametersMigrationFromLegacyData() throws {
        // Old data without maxTokens/temperature fields
        let legacyJSON = """
        {"supportsVision":true,"supportsToolUse":true,"supportsImageGeneration":false,"supportsReasoning":false}
        """
        let decoded = try JSONDecoder().decode(ModelCapabilities.self, from: legacyJSON.data(using: .utf8)!)
        XCTAssertNil(decoded.maxTokens, "Legacy data without maxTokens should decode as nil")
        XCTAssertNil(decoded.temperature, "Legacy data without temperature should decode as nil")
    }

    @MainActor
    func testPerModelParametersPersistence() {
        let provider = LLMProvider(name: "Test")
        let caps = ModelCapabilities(maxTokens: 32000, temperature: 0.9)
        provider.setCapabilities(caps, for: "gpt-5.4")

        let retrieved = provider.capabilities(for: "gpt-5.4")
        XCTAssertEqual(retrieved.maxTokens, 32000)
        XCTAssertEqual(retrieved.temperature, 0.9)
    }

    @MainActor
    func testPerModelParametersNilFallsBackToProvider() {
        let provider = LLMProvider(name: "Test", maxTokens: 4096, temperature: 0.7)
        // Model with no parameter overrides
        let caps = ModelCapabilities(supportsVision: true)
        provider.setCapabilities(caps, for: "model-a")

        let retrieved = provider.capabilities(for: "model-a")
        XCTAssertNil(retrieved.maxTokens, "Per-model maxTokens should be nil (use provider default)")
        XCTAssertNil(retrieved.temperature, "Per-model temperature should be nil (use provider default)")
        // The actual fallback logic is in LLMService, verified via effectiveMaxTokens/effectiveTemperature
    }

    // MARK: - Inferred Capabilities

    func testInferredCapabilities_GPTFamily() {
        let cases: [(String, Bool)] = [
            ("gpt-5.4", true),
            ("openai/gpt-5.4", true),
            ("openai/gpt-5.4-nano", true),
            ("openai/gpt-5.3-codex", true),
            ("gpt-4o", true),
            ("gpt-4.1-mini", true),
            ("gpt-3.5-turbo", false),
        ]
        for (model, expectedVision) in cases {
            let caps = ModelCapabilities.inferred(from: model)
            XCTAssertEqual(caps.supportsVision, expectedVision,
                           "\(model): expected vision=\(expectedVision)")
            XCTAssertTrue(caps.supportsToolUse,
                          "\(model): GPT models should support tool use")
            XCTAssertFalse(caps.supportsImageGeneration,
                           "\(model): GPT models should not generate images")
        }
    }

    func testInferredCapabilities_ClaudeFamily() {
        let visionModels = [
            "claude-sonnet-4-6",
            "claude-opus-4-6",
            "anthropic/claude-sonnet-4.6",
            "anthropic/claude-opus-4.6",
            "claude-3.5-sonnet",
            "claude-3-5-sonnet-20241022",
        ]
        for model in visionModels {
            let caps = ModelCapabilities.inferred(from: model)
            XCTAssertTrue(caps.supportsVision,
                          "\(model): expected vision=true")
            XCTAssertTrue(caps.supportsToolUse,
                          "\(model): expected toolUse=true")
            XCTAssertFalse(caps.supportsImageGeneration,
                           "\(model): expected imageGen=false")
        }

        let noVisionModels = [
            "claude-3-opus",
            "claude-3-haiku",
        ]
        for model in noVisionModels {
            let caps = ModelCapabilities.inferred(from: model)
            XCTAssertFalse(caps.supportsVision,
                           "\(model): expected vision=false (below 3.5)")
        }
    }

    func testInferredCapabilities_GeminiVision() {
        let visionModels = [
            "gemini-3.1-pro-preview",
            "google/gemini-3.1-flash-lite-preview",
            "gemini-2.0-flash",
            "gemini-2.5-pro",
            "gemini-1.5-pro",
        ]
        for model in visionModels {
            let caps = ModelCapabilities.inferred(from: model)
            XCTAssertTrue(caps.supportsVision,
                          "\(model): expected vision=true")
            XCTAssertTrue(caps.supportsToolUse,
                          "\(model): expected toolUse=true")
            XCTAssertFalse(caps.supportsImageGeneration,
                           "\(model): expected imageGen=false")
        }

        let noVision = ModelCapabilities.inferred(from: "gemini-1.0-pro")
        XCTAssertFalse(noVision.supportsVision, "gemini-1.0 should not have vision")
    }

    func testInferredCapabilities_GeminiImageModels() {
        let imageModels = [
            "gemini-3.1-flash-image-preview",
            "gemini-3-pro-image-preview",
            "google/gemini-3.1-flash-image-preview",
        ]
        for model in imageModels {
            let caps = ModelCapabilities.inferred(from: model)
            XCTAssertTrue(caps.supportsVision,
                          "\(model): image models should support vision")
            XCTAssertTrue(caps.supportsImageGeneration,
                          "\(model): expected imageGen=true")
            XCTAssertFalse(caps.supportsToolUse,
                           "\(model): image models should NOT support tool use")
        }
    }

    func testInferredCapabilities_QwenFamily() {
        let visionModels = [
            "qwen3.6-plus",
            "qwen/qwen3.6-plus:free",
            "qwen2.5-vl-72b",
            "qwen-vl-max",
            "qwen-omni-turbo",
        ]
        for model in visionModels {
            let caps = ModelCapabilities.inferred(from: model)
            XCTAssertTrue(caps.supportsVision,
                          "\(model): expected vision=true")
            XCTAssertTrue(caps.supportsToolUse,
                          "\(model): expected toolUse=true")
        }

        let noVision = [
            "qwen2.5-72b",
            "qwen3-8b",
        ]
        for model in noVision {
            let caps = ModelCapabilities.inferred(from: model)
            XCTAssertFalse(caps.supportsVision,
                           "\(model): expected vision=false (below 3.5, no vl/omni)")
        }
    }

    func testInferredCapabilities_UnknownModels() {
        // `deepseek-chat` is no longer "unknown" — it aliases DeepSeek v4
        // and gets handled in `testInferredCapabilities_DeepSeekFamily`.
        let unknowns = ["llama3", "mistral-large"]
        for model in unknowns {
            let caps = ModelCapabilities.inferred(from: model)
            XCTAssertEqual(caps, .default,
                           "\(model): unknown model should return default capabilities")
        }
    }

    func testInferredCapabilities_DeepSeekFamily() {
        // DeepSeek v4 (any spelling) defaults to .high thinking — DeepSeek
        // ships with thinking enabled in its own server defaults.
        let v4Models = ["deepseek-chat", "deepseek-reasoner", "deepseek-v4-pro", "deepseek-v4-flash"]
        for model in v4Models {
            let caps = ModelCapabilities.inferred(from: model)
            XCTAssertEqual(caps.thinkingLevel, .high, "\(model): expected thinking=high")
            XCTAssertTrue(caps.supportsReasoning, "\(model): expected supportsReasoning=true")
        }

        // v3 stays at default (no thinking).
        let v3 = ModelCapabilities.inferred(from: "deepseek-v3-chat")
        XCTAssertEqual(v3.thinkingLevel, .off, "v3 should not infer thinking")
    }

    func testInferredCapabilities_DedicatedVideoGenModels() {
        // Video gen models should infer supportsVideoGeneration = true
        // The API protocol is now determined by provider's apiStyle, not per-model
        let videoModels: [(String, String)] = [
            ("sora-2", "Sora"),
            ("veo-3", "Veo"),
            ("veo_2", "Veo underscore"),
            ("wan2.6-t2v", "Wan T2V"),
            ("wan2.7-i2v-flash", "Wan I2V"),
            ("wan2.6-vace", "Wan VACE"),
            ("runway-gen4", "Runway"),
            ("gen-3-alpha", "Gen-3"),
            ("gen-4-turbo", "Gen-4"),
            ("luma-photon", "Luma"),
            ("dream-machine-v1", "Dream Machine"),
            ("kling-v2", "Kling"),
            ("minimax-video-01", "MiniMax Video"),
            ("hailuo-01", "Hailuo"),
            ("doubao-seedance-2-0", "Seedance 2.0"),
            ("doubao-seedance-1-5-pro-251215", "Seedance 1.5 pro"),
            ("doubao-seedance-1-0-lite-t2v", "Seedance 1.0 lite t2v"),
        ]
        for (model, label) in videoModels {
            let caps = ModelCapabilities.inferred(from: model)
            XCTAssertTrue(caps.supportsVideoGeneration,
                          "\(label) (\(model)): expected videoGen=true")
            XCTAssertFalse(caps.supportsToolUse,
                           "\(label) (\(model)): video-only models should NOT support tool use")
        }
    }

    func testInferredCapabilities_DedicatedImageGenModels() {
        let imageModels: [(String, String)] = [
            ("dall-e-3", "DALL-E 3"),
            ("gpt-image-1", "GPT Image"),
            ("flux-pro-1.1", "Flux"),
            ("sd3-medium", "SD3"),
            ("sdxl-turbo", "SDXL"),
            ("stable-diffusion-xl", "Stable Diffusion"),
        ]
        for (model, label) in imageModels {
            let caps = ModelCapabilities.inferred(from: model)
            XCTAssertEqual(caps.imageGenerationMode, .dedicatedAPI,
                           "\(label) (\(model)): expected imageGenMode=.dedicatedAPI")
            XCTAssertFalse(caps.supportsToolUse,
                           "\(label) (\(model)): image-only models should NOT support tool use")
            XCTAssertFalse(caps.supportsVideoGeneration,
                           "\(label) (\(model)): should not infer video generation")
        }
    }

    func testInferredCapabilities_DashScopeImageGenModels() {
        let imageModels: [(String, String)] = [
            ("wan2.7-image-pro", "Wan 2.7 Image Pro"),
            ("wan2.7-image", "Wan 2.7 Image"),
        ]
        for (model, label) in imageModels {
            let caps = ModelCapabilities.inferred(from: model)
            XCTAssertEqual(caps.imageGenerationMode, .dashScope,
                           "\(label) (\(model)): expected imageGenMode=.dashScope")
            XCTAssertFalse(caps.supportsToolUse,
                           "\(label) (\(model)): image-only models should NOT support tool use")
            XCTAssertFalse(caps.supportsVideoGeneration,
                           "\(label) (\(model)): should not infer video generation")
        }
    }

    func testInferredCapabilities_VideoInputModels() {
        let videoInputModels = [
            "gemini-2.0-flash",
            "gemini-1.5-pro",
            "qwen2.5-vl-72b",
            "qwen-omni-turbo",
            "internvl-chat-v2",
            "pixtral-12b",
        ]
        for model in videoInputModels {
            let caps = ModelCapabilities.inferred(from: model)
            XCTAssertTrue(caps.supportsVideoInput,
                          "\(model): expected supportsVideoInput=true")
            XCTAssertTrue(caps.supportsVision,
                          "\(model): video input models should also support vision")
            XCTAssertFalse(caps.supportsVideoGeneration,
                           "\(model): video INPUT models should not infer video GENERATION")
        }
    }

    func testInferredCapabilities_DoesNotOverrideExisting() {
        let custom = ModelCapabilities(
            supportsVision: false,
            supportsToolUse: false,
            supportsImageGeneration: true,
            supportsReasoning: true
        )
        let inferred = ModelCapabilities.inferred(from: "gpt-5.4")
        XCTAssertNotEqual(inferred, custom,
                          "Inferred and custom should differ — caller decides which to use")
    }

    // MARK: - APIStyle (video protocol cases)

    func testAPIStyleVideoProtocolCases() {
        // Verify video protocol cases exist in APIStyle
        XCTAssertTrue(APIStyle.allCases.contains(.googleVeo))
        XCTAssertTrue(APIStyle.allCases.contains(.dashScope))
        XCTAssertTrue(APIStyle.allCases.contains(.kling))
        XCTAssertTrue(APIStyle.allCases.contains(.seedance))
    }

    func testAPIStyleCaseSubsets() {
        XCTAssertEqual(APIStyle.llmCases, [.openAI, .openAIResponses, .anthropic])
        XCTAssertEqual(APIStyle.imageCases, [.openAI, .dashScope])
        XCTAssertTrue(APIStyle.videoCases.contains(.openAI))
        XCTAssertTrue(APIStyle.videoCases.contains(.googleVeo))
        XCTAssertTrue(APIStyle.videoCases.contains(.kling))
    }

    // MARK: - ModelCapabilities with supportsVideoGeneration

    func testCapabilitiesVideoGenBoolCodableRoundTrip() throws {
        let caps = ModelCapabilities(supportsVideoGeneration: true)
        let data = try JSONEncoder().encode(caps)
        let decoded = try JSONDecoder().decode(ModelCapabilities.self, from: data)
        XCTAssertTrue(decoded.supportsVideoGeneration)
        XCTAssertEqual(decoded, caps)
    }

    func testCapabilitiesVideoGenDefaultIsFalse() {
        let caps = ModelCapabilities()
        XCTAssertFalse(caps.supportsVideoGeneration)
    }

    func testCapabilitiesLegacyVideoGenModeMigration() throws {
        // Old data with videoGenerationMode enum should migrate to supportsVideoGeneration bool
        let json = """
        {"supportsVision":false,"supportsToolUse":false,"videoGenerationMode":"seedance"}
        """
        let decoded = try JSONDecoder().decode(ModelCapabilities.self, from: json.data(using: .utf8)!)
        XCTAssertTrue(decoded.supportsVideoGeneration,
                      "Legacy videoGenerationMode != none should migrate to supportsVideoGeneration=true")
    }

    func testCapabilitiesLegacyJSONWithoutVideoGenMode() throws {
        let json = """
        {"supportsVision":true,"supportsToolUse":true,"supportsImageGeneration":false,"supportsReasoning":false}
        """
        let decoded = try JSONDecoder().decode(ModelCapabilities.self, from: json.data(using: .utf8)!)
        XCTAssertFalse(decoded.supportsVideoGeneration,
                       "Legacy data without video fields should default to false")
    }

    // MARK: - ProviderType

    func testProviderTypeCodableRoundTrip() throws {
        for type in ProviderType.allCases {
            let data = try JSONEncoder().encode(type)
            let decoded = try JSONDecoder().decode(ProviderType.self, from: data)
            XCTAssertEqual(decoded, type,
                           "ProviderType.\(type.rawValue) should survive encode/decode")
        }
    }

    @MainActor
    func testProviderTypeDefaultIsLLM() {
        let provider = LLMProvider(name: "Test")
        XCTAssertEqual(provider.providerType, .llm)
        XCTAssertFalse(provider.isVideoOnly)
        XCTAssertFalse(provider.isImageOnly)
        XCTAssertFalse(provider.isMediaOnly)
    }

    @MainActor
    func testProviderTypeVideoOnly() {
        let provider = LLMProvider(name: "Test")
        provider.providerType = .videoOnly
        XCTAssertTrue(provider.isVideoOnly)
        XCTAssertFalse(provider.isImageOnly)
        XCTAssertTrue(provider.isMediaOnly)
    }

    @MainActor
    func testProviderTypeImageOnly() {
        let provider = LLMProvider(name: "Test")
        provider.providerType = .imageOnly
        XCTAssertFalse(provider.isVideoOnly)
        XCTAssertTrue(provider.isImageOnly)
        XCTAssertTrue(provider.isMediaOnly)
    }

    // MARK: - Enabled Models

    @MainActor
    func testEnabledModelsDefault() {
        let provider = LLMProvider(name: "Test", modelName: "gpt-4o")
        XCTAssertTrue(provider.enabledModels.contains("gpt-4o"))
    }

    @MainActor
    func testEnabledModelsWithAdditional() {
        let provider = LLMProvider(name: "Test", modelName: "gpt-4o")
        provider.enabledModels = ["gpt-4o", "gpt-3.5-turbo"]

        let models = provider.enabledModels
        XCTAssertTrue(models.contains("gpt-4o"))
        XCTAssertTrue(models.contains("gpt-3.5-turbo"))
    }

    @MainActor
    func testEnabledModelsAlwaysIncludesDefault() {
        let provider = LLMProvider(name: "Test", modelName: "gpt-4o")
        provider.enabledModels = ["gpt-3.5-turbo"]

        let models = provider.enabledModels
        XCTAssertTrue(models.contains("gpt-4o"), "Default model should always be included")
    }

    // MARK: - Cached Model List

    @MainActor
    func testCachedModelListEmpty() {
        let provider = LLMProvider(name: "Test")
        XCTAssertTrue(provider.cachedModelList.isEmpty)
    }

    @MainActor
    func testCachedModelListRoundTrip() {
        let provider = LLMProvider(name: "Test")
        provider.cachedModelList = ["model-a", "model-b", "model-c"]
        XCTAssertEqual(provider.cachedModelList, ["model-a", "model-b", "model-c"])
    }

    @MainActor
    func testCachedModelListClear() {
        let provider = LLMProvider(name: "Test")
        provider.cachedModelList = ["model-a"]
        provider.cachedModelList = []
        XCTAssertTrue(provider.cachedModelList.isEmpty)
        XCTAssertNil(provider.cachedModelListRaw)
    }

    // MARK: - SwiftData Persistence

    @MainActor
    func testProviderPersistence() throws {
        let provider = LLMProvider(
            name: "Persistent Provider",
            endpoint: "https://example.com/v1",
            apiKey: "test-key",
            modelName: "test-model"
        )
        provider.apiStyle = .anthropic
        provider.setCapabilities(
            ModelCapabilities(supportsVision: true, supportsReasoning: true),
            for: "test-model"
        )

        context.insert(provider)
        try context.save()

        let fetchDescriptor = FetchDescriptor<LLMProvider>(
            predicate: #Predicate { $0.name == "Persistent Provider" }
        )
        let fetched = try context.fetch(fetchDescriptor)
        XCTAssertEqual(fetched.count, 1)

        let retrieved = fetched.first!
        XCTAssertEqual(retrieved.name, "Persistent Provider")
        XCTAssertEqual(retrieved.endpoint, "https://example.com/v1")
        XCTAssertEqual(retrieved.apiStyle, .anthropic)
        XCTAssertTrue(retrieved.capabilities(for: "test-model").supportsVision)
        XCTAssertTrue(retrieved.capabilities(for: "test-model").supportsReasoning)
    }

    // MARK: - ToolCallResult

    func testToolCallResultInit() {
        let result = ToolCallResult("Success")
        XCTAssertEqual(result.text, "Success")
        XCTAssertNil(result.imageAttachments)
    }

    func testToolCallResultCancelled() {
        let result = ToolCallResult.cancelled
        XCTAssertTrue(result.text.contains("Cancelled"))
    }
}
