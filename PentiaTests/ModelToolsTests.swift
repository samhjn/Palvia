import XCTest
import SwiftData
@testable import iClaw

final class ModelToolsTests: XCTestCase {

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

    // MARK: - Helpers

    @MainActor
    private func makeLLMProvider(name: String = "TestLLM", modelName: String = "gpt-4o") -> LLMProvider {
        let p = LLMProvider(name: name, modelName: modelName)
        p.providerType = .llm
        context.insert(p)
        try! context.save()
        return p
    }

    @MainActor
    private func makeImageProvider(name: String = "TestImage", modelName: String = "dall-e-3") -> LLMProvider {
        let p = LLMProvider(name: name, modelName: modelName)
        p.providerType = .imageOnly
        context.insert(p)
        try! context.save()
        return p
    }

    @MainActor
    private func makeVideoProvider(name: String = "TestVideo", modelName: String = "kling-v1") -> LLMProvider {
        let p = LLMProvider(name: name, modelName: modelName)
        p.providerType = .videoOnly
        context.insert(p)
        try! context.save()
        return p
    }

    @MainActor
    private func makeAgent(name: String = "Agent") -> Agent {
        let a = Agent(name: name)
        context.insert(a)
        try! context.save()
        return a
    }

    // MARK: - setModel: primary rejects media-only providers

    @MainActor
    func testSetModelPrimaryRejectsImageProvider() {
        let agent = makeAgent()
        let imgProvider = makeImageProvider()
        let tools = ModelTools(agent: agent, modelContext: context)

        let result = tools.setModel(arguments: [
            "role": "primary",
            "model_id": imgProvider.id.uuidString
        ])

        XCTAssertTrue(result.contains("[Error]"), "Should reject image provider as primary")
        XCTAssertTrue(result.contains("only LLM providers"), result)
        XCTAssertNil(agent.primaryProviderId, "Primary should not be set")
    }

    @MainActor
    func testSetModelPrimaryRejectsVideoProvider() {
        let agent = makeAgent()
        let vidProvider = makeVideoProvider()
        let tools = ModelTools(agent: agent, modelContext: context)

        let result = tools.setModel(arguments: [
            "role": "primary",
            "model_id": vidProvider.id.uuidString
        ])

        XCTAssertTrue(result.contains("[Error]"))
        XCTAssertTrue(result.contains("only LLM providers"))
        XCTAssertNil(agent.primaryProviderId)
    }

    @MainActor
    func testSetModelPrimaryAcceptsLLMProvider() {
        let agent = makeAgent()
        let llmProvider = makeLLMProvider()
        let tools = ModelTools(agent: agent, modelContext: context)

        let result = tools.setModel(arguments: [
            "role": "primary",
            "model_id": llmProvider.id.uuidString
        ])

        XCTAssertFalse(result.contains("[Error]"), result)
        XCTAssertTrue(result.contains("Primary model set to"))
        XCTAssertEqual(agent.primaryProviderId, llmProvider.id)
    }

    @MainActor
    func testSetModelPrimaryWithModelNameOverride() {
        let agent = makeAgent()
        let llm = makeLLMProvider()
        let tools = ModelTools(agent: agent, modelContext: context)

        let result = tools.setModel(arguments: [
            "role": "primary",
            "model_id": llm.id.uuidString,
            "model_name": "gpt-4o-mini"
        ])

        XCTAssertTrue(result.contains("gpt-4o-mini"))
        XCTAssertEqual(agent.primaryModelNameOverride, "gpt-4o-mini")
    }

    // MARK: - setModel: add_fallback rejects media-only providers

    @MainActor
    func testSetModelAddFallbackRejectsImageProvider() {
        let agent = makeAgent()
        let imgProvider = makeImageProvider()
        let tools = ModelTools(agent: agent, modelContext: context)

        let result = tools.setModel(arguments: [
            "role": "add_fallback",
            "model_id": imgProvider.id.uuidString
        ])

        XCTAssertTrue(result.contains("[Error]"))
        XCTAssertTrue(result.contains("only LLM providers"))
        XCTAssertTrue(agent.fallbackProviderIds.isEmpty)
    }

    @MainActor
    func testSetModelAddFallbackRejectsVideoProvider() {
        let agent = makeAgent()
        let vidProvider = makeVideoProvider()
        let tools = ModelTools(agent: agent, modelContext: context)

        let result = tools.setModel(arguments: [
            "role": "add_fallback",
            "model_id": vidProvider.id.uuidString
        ])

        XCTAssertTrue(result.contains("[Error]"))
        XCTAssertTrue(agent.fallbackProviderIds.isEmpty)
    }

    @MainActor
    func testSetModelAddFallbackAcceptsLLMProvider() {
        let agent = makeAgent()
        let llm = makeLLMProvider()
        let tools = ModelTools(agent: agent, modelContext: context)

        let result = tools.setModel(arguments: [
            "role": "add_fallback",
            "model_id": llm.id.uuidString
        ])

        XCTAssertFalse(result.contains("[Error]"), result)
        XCTAssertTrue(result.contains("Added"))
        XCTAssertEqual(agent.fallbackProviderIds, [llm.id])
    }

    // MARK: - setModel: fallback chain filters out media-only

    @MainActor
    func testSetModelFallbackFiltersMediaProviders() {
        let agent = makeAgent()
        let llm1 = makeLLMProvider(name: "LLM1")
        let img = makeImageProvider()
        let llm2 = makeLLMProvider(name: "LLM2", modelName: "claude-3")
        let tools = ModelTools(agent: agent, modelContext: context)

        let result = tools.setModel(arguments: [
            "role": "fallback",
            "model_ids": [llm1.id.uuidString, img.id.uuidString, llm2.id.uuidString]
        ])

        XCTAssertTrue(result.contains("Fallback chain set to"))
        XCTAssertTrue(result.contains("media-only provider"), "Should warn about rejected media provider")
        XCTAssertEqual(agent.fallbackProviderIds.count, 2)
        XCTAssertTrue(agent.fallbackProviderIds.contains(llm1.id))
        XCTAssertTrue(agent.fallbackProviderIds.contains(llm2.id))
        XCTAssertFalse(agent.fallbackProviderIds.contains(img.id))
    }

    // MARK: - setModel: sub_agent rejects media-only providers

    @MainActor
    func testSetModelSubAgentRejectsImageProvider() {
        let agent = makeAgent()
        let imgProvider = makeImageProvider()
        let tools = ModelTools(agent: agent, modelContext: context)

        let result = tools.setModel(arguments: [
            "role": "sub_agent",
            "model_id": imgProvider.id.uuidString
        ])

        XCTAssertTrue(result.contains("[Error]"))
        XCTAssertTrue(result.contains("only LLM providers"))
        XCTAssertNil(agent.subAgentProviderId)
    }

    @MainActor
    func testSetModelSubAgentAcceptsLLMProvider() {
        let agent = makeAgent()
        let llm = makeLLMProvider()
        let tools = ModelTools(agent: agent, modelContext: context)

        let result = tools.setModel(arguments: [
            "role": "sub_agent",
            "model_id": llm.id.uuidString
        ])

        XCTAssertFalse(result.contains("[Error]"), result)
        XCTAssertEqual(agent.subAgentProviderId, llm.id)
    }

    @MainActor
    func testSetModelSubAgentClear() {
        let agent = makeAgent()
        let llm = makeLLMProvider()
        agent.subAgentProviderId = llm.id
        let tools = ModelTools(agent: agent, modelContext: context)

        let result = tools.setModel(arguments: ["role": "sub_agent"])

        XCTAssertTrue(result.contains("cleared"))
        XCTAssertNil(agent.subAgentProviderId)
    }

    // MARK: - setModel: image role

    @MainActor
    func testSetModelImageSetsProvider() {
        let agent = makeAgent()
        let img = makeImageProvider()
        let tools = ModelTools(agent: agent, modelContext: context)

        let result = tools.setModel(arguments: [
            "role": "image",
            "model_id": img.id.uuidString
        ])

        XCTAssertTrue(result.contains("Image generation model set to"))
        XCTAssertEqual(agent.imageProviderId, img.id)
        XCTAssertNil(agent.imageModelNameOverride)
    }

    @MainActor
    func testSetModelImageWithModelName() {
        let agent = makeAgent()
        let img = makeImageProvider()
        let tools = ModelTools(agent: agent, modelContext: context)

        let result = tools.setModel(arguments: [
            "role": "image",
            "model_id": img.id.uuidString,
            "model_name": "dall-e-2"
        ])

        XCTAssertTrue(result.contains("dall-e-2"))
        XCTAssertEqual(agent.imageProviderId, img.id)
        XCTAssertEqual(agent.imageModelNameOverride, "dall-e-2")
    }

    @MainActor
    func testSetModelImageClear() {
        let agent = makeAgent()
        let img = makeImageProvider()
        agent.imageProviderId = img.id
        agent.imageModelNameOverride = "dall-e-2"
        let tools = ModelTools(agent: agent, modelContext: context)

        let result = tools.setModel(arguments: ["role": "image"])

        XCTAssertTrue(result.contains("cleared"))
        XCTAssertNil(agent.imageProviderId)
        XCTAssertNil(agent.imageModelNameOverride)
    }

    // MARK: - setModel: video role

    @MainActor
    func testSetModelVideoSetsProvider() {
        let agent = makeAgent()
        let vid = makeVideoProvider()
        let tools = ModelTools(agent: agent, modelContext: context)

        let result = tools.setModel(arguments: [
            "role": "video",
            "model_id": vid.id.uuidString
        ])

        XCTAssertTrue(result.contains("Video generation (T2V) model set to"))
        XCTAssertEqual(agent.videoProviderId, vid.id)
    }

    @MainActor
    func testSetModelVideoWithModelName() {
        let agent = makeAgent()
        let vid = makeVideoProvider()
        let tools = ModelTools(agent: agent, modelContext: context)

        let result = tools.setModel(arguments: [
            "role": "video",
            "model_id": vid.id.uuidString,
            "model_name": "kling-v2"
        ])

        XCTAssertTrue(result.contains("kling-v2"))
        XCTAssertEqual(agent.videoModelNameOverride, "kling-v2")
    }

    @MainActor
    func testSetModelVideoClear() {
        let agent = makeAgent()
        let vid = makeVideoProvider()
        agent.videoProviderId = vid.id
        let tools = ModelTools(agent: agent, modelContext: context)

        let result = tools.setModel(arguments: ["role": "video"])

        XCTAssertTrue(result.contains("cleared"))
        XCTAssertNil(agent.videoProviderId)
        XCTAssertNil(agent.videoModelNameOverride)
    }

    // MARK: - setModel: i2v role

    @MainActor
    func testSetModelI2VSetsProvider() {
        let agent = makeAgent()
        let vid = makeVideoProvider(name: "I2VProvider", modelName: "kling-i2v")
        let tools = ModelTools(agent: agent, modelContext: context)

        let result = tools.setModel(arguments: [
            "role": "i2v",
            "model_id": vid.id.uuidString
        ])

        XCTAssertTrue(result.contains("Video generation (I2V) model set to"))
        XCTAssertEqual(agent.i2vProviderId, vid.id)
    }

    @MainActor
    func testSetModelI2VClear() {
        let agent = makeAgent()
        let vid = makeVideoProvider()
        agent.i2vProviderId = vid.id
        let tools = ModelTools(agent: agent, modelContext: context)

        let result = tools.setModel(arguments: ["role": "i2v"])

        XCTAssertTrue(result.contains("cleared"))
        XCTAssertTrue(result.contains("inherit"))
        XCTAssertNil(agent.i2vProviderId)
    }

    // MARK: - setModel: invalid role

    @MainActor
    func testSetModelInvalidRole() {
        let agent = makeAgent()
        let tools = ModelTools(agent: agent, modelContext: context)

        let result = tools.setModel(arguments: ["role": "unknown"])

        XCTAssertTrue(result.contains("[Error]"))
        XCTAssertTrue(result.contains("Invalid role"))
        XCTAssertTrue(result.contains("image"))
        XCTAssertTrue(result.contains("video"))
        XCTAssertTrue(result.contains("i2v"))
    }

    // MARK: - setModel: missing / invalid provider

    @MainActor
    func testSetModelPrimaryMissingModelId() {
        let agent = makeAgent()
        let tools = ModelTools(agent: agent, modelContext: context)

        let result = tools.setModel(arguments: ["role": "primary"])

        XCTAssertTrue(result.contains("[Error]"))
        XCTAssertTrue(result.contains("Missing or invalid model_id"))
    }

    @MainActor
    func testSetModelPrimaryNonexistentProvider() {
        let agent = makeAgent()
        let tools = ModelTools(agent: agent, modelContext: context)

        let result = tools.setModel(arguments: [
            "role": "primary",
            "model_id": UUID().uuidString
        ])

        XCTAssertTrue(result.contains("[Error]"))
        XCTAssertTrue(result.contains("No provider found"))
    }

    // MARK: - setModel: whitelist enforcement for LLM roles

    @MainActor
    func testSetModelPrimaryBlockedByWhitelist() {
        let agent = makeAgent()
        let llm = makeLLMProvider()
        agent.allowedModelIds = ["\(UUID().uuidString):other-model"]
        let tools = ModelTools(agent: agent, modelContext: context)

        let result = tools.setModel(arguments: [
            "role": "primary",
            "model_id": llm.id.uuidString
        ])

        XCTAssertTrue(result.contains("[Error]"))
        XCTAssertTrue(result.contains("whitelist"))
        XCTAssertNil(agent.primaryProviderId)
    }

    // MARK: - getModel: categorized output

    @MainActor
    func testGetModelShowsAllCategories() {
        let agent = makeAgent()
        let llm = makeLLMProvider(name: "MyLLM")
        let img = makeImageProvider(name: "MyImageGen")
        let vid = makeVideoProvider(name: "MyVideoGen")
        let i2v = makeVideoProvider(name: "MyI2V", modelName: "i2v-model")

        agent.primaryProviderId = llm.id
        agent.primaryModelNameOverride = "custom-llm"
        agent.imageProviderId = img.id
        agent.imageModelNameOverride = "custom-img"
        agent.videoProviderId = vid.id
        agent.videoModelNameOverride = "custom-vid"
        agent.i2vProviderId = i2v.id
        agent.i2vModelNameOverride = "custom-i2v"

        let tools = ModelTools(agent: agent, modelContext: context)
        let result = tools.getModel(arguments: [:])

        // Section headers
        XCTAssertTrue(result.contains("### LLM Models"))
        XCTAssertTrue(result.contains("### Image Generation"))
        XCTAssertTrue(result.contains("### Video Generation"))

        // LLM section
        XCTAssertTrue(result.contains("Primary"))
        XCTAssertTrue(result.contains("custom-llm"))

        // Image section
        XCTAssertTrue(result.contains("Image model"))
        XCTAssertTrue(result.contains("custom-img"))

        // Video section
        XCTAssertTrue(result.contains("Video model (T2V)"))
        XCTAssertTrue(result.contains("custom-vid"))
        XCTAssertTrue(result.contains("Video model (I2V)"))
        XCTAssertTrue(result.contains("custom-i2v"))
    }

    @MainActor
    func testGetModelShowsDefaultsWhenUnconfigured() {
        let agent = makeAgent()
        let tools = ModelTools(agent: agent, modelContext: context)
        let result = tools.getModel(arguments: [:])

        XCTAssertTrue(result.contains("(global default)"))
        XCTAssertTrue(result.contains("(none)"))  // fallback chain
        XCTAssertTrue(result.contains("(not configured)"))  // image
        XCTAssertTrue(result.contains("(inherits from primary)"))  // sub-agent
        XCTAssertTrue(result.contains("(inherits from T2V)"))  // i2v
    }

    @MainActor
    func testGetModelShowsFallbackWithModelOverrides() {
        let agent = makeAgent()
        let llm1 = makeLLMProvider(name: "Provider1")
        let llm2 = makeLLMProvider(name: "Provider2", modelName: "base-model")

        agent.fallbackProviderIds = [llm1.id, llm2.id]
        agent.fallbackModelNames = ["override-1", "override-2"]

        let tools = ModelTools(agent: agent, modelContext: context)
        let result = tools.getModel(arguments: [:])

        XCTAssertTrue(result.contains("override-1"))
        XCTAssertTrue(result.contains("override-2"))
    }

    // MARK: - listModels: categorized output

    @MainActor
    func testListModelsGroupsByCategory() {
        _ = makeLLMProvider(name: "OpenAI")
        _ = makeImageProvider(name: "DALL-E")
        _ = makeVideoProvider(name: "Kling")

        let agent = makeAgent()
        let tools = ModelTools(agent: agent, modelContext: context)
        let result = tools.listModels(arguments: [:])

        XCTAssertTrue(result.contains("## LLM Models"))
        XCTAssertTrue(result.contains("## Image Generation Models"))
        XCTAssertTrue(result.contains("## Video Generation Models"))
        XCTAssertTrue(result.contains("OpenAI"))
        XCTAssertTrue(result.contains("DALL-E"))
        XCTAssertTrue(result.contains("Kling"))
    }

    @MainActor
    func testListModelsEmptyCategories() {
        // Create only an LLM provider so image/video categories are empty
        _ = makeLLMProvider(name: "OnlyLLM")
        let agent = makeAgent()
        let tools = ModelTools(agent: agent, modelContext: context)
        let result = tools.listModels(arguments: [:])

        // Image and Video sections should show "(none)"
        XCTAssertTrue(result.contains("## Image Generation Models\n(none)"),
                      "Empty image section should show (none)")
        XCTAssertTrue(result.contains("## Video Generation Models\n(none)"),
                      "Empty video section should show (none)")
    }

    @MainActor
    func testListModelsLLMSectionShowsCapabilities() {
        let llm = makeLLMProvider(name: "GPTProvider")

        let agent = makeAgent()
        let tools = ModelTools(agent: agent, modelContext: context)
        let result = tools.listModels(arguments: [:])

        XCTAssertTrue(result.contains("Provider ID: `\(llm.id.uuidString)`"))
        XCTAssertTrue(result.contains("capabilities:"))
    }

    @MainActor
    func testListModelsVideoSectionShowsAPIStyle() {
        _ = makeVideoProvider(name: "VidGen")

        let agent = makeAgent()
        let tools = ModelTools(agent: agent, modelContext: context)
        let result = tools.listModels(arguments: [:])

        XCTAssertTrue(result.contains("API Style:"))
    }

    @MainActor
    func testListModelsWhitelistFiltersLLMOnly() {
        let llm = makeLLMProvider(name: "LLM1", modelName: "allowed-model")
        _ = makeLLMProvider(name: "LLM2", modelName: "blocked-model")
        _ = makeImageProvider(name: "ImgProvider")

        let agent = makeAgent()
        agent.allowedModelIds = ["\(llm.id.uuidString):allowed-model"]

        let tools = ModelTools(agent: agent, modelContext: context)
        let result = tools.listModels(arguments: [:])

        // LLM section should only show whitelisted model
        XCTAssertTrue(result.contains("LLM1"))
        XCTAssertTrue(result.contains("allowed-model"))
        // LLM2 should be filtered out (its model is not in whitelist)
        XCTAssertFalse(result.contains("LLM2"), "Non-whitelisted LLM should be filtered")
        // Image providers are unaffected by LLM whitelist
        XCTAssertTrue(result.contains("ImgProvider"))
    }

    @MainActor
    func testListModelsNoProviders() {
        let agent = makeAgent()
        let tools = ModelTools(agent: agent, modelContext: context)
        let result = tools.listModels(arguments: [:])

        XCTAssertTrue(result.contains("No providers configured"))
    }

    // MARK: - Tool definitions

    func testSetModelToolDefinitionIncludesAllRoles() {
        let tool = ToolDefinitions.setModelTool
        let props = tool.function.parameters.properties!
        let roleEnum = props["role"]!.enumValues!

        XCTAssertTrue(roleEnum.contains("primary"))
        XCTAssertTrue(roleEnum.contains("fallback"))
        XCTAssertTrue(roleEnum.contains("add_fallback"))
        XCTAssertTrue(roleEnum.contains("sub_agent"))
        XCTAssertTrue(roleEnum.contains("image"))
        XCTAssertTrue(roleEnum.contains("video"))
        XCTAssertTrue(roleEnum.contains("i2v"))
        XCTAssertEqual(roleEnum.count, 7)
    }

    func testSetModelToolDefinitionHasProviderIdParam() {
        let tool = ToolDefinitions.setModelTool
        let props = tool.function.parameters.properties!
        XCTAssertNotNil(props["model_id"])
        XCTAssertNotNil(props["model_name"])
        XCTAssertNotNil(props["model_ids"])
    }

    func testGetModelToolDefinitionMentionsAllCategories() {
        let tool = ToolDefinitions.getModelTool
        let desc = tool.function.description
        XCTAssertTrue(desc.contains("LLM"))
        XCTAssertTrue(desc.contains("image"))
        XCTAssertTrue(desc.contains("video"))
    }

    func testListModelsToolDefinitionMentionsCategories() {
        let tool = ToolDefinitions.listModelsTool
        let desc = tool.function.description
        XCTAssertTrue(desc.contains("LLM"))
        XCTAssertTrue(desc.contains("image"))
        XCTAssertTrue(desc.contains("video"))
    }

    func testGenerateImageToolHasOverrideParams() {
        let tool = ToolDefinitions.generateImageTool
        let props = tool.function.parameters.properties!
        XCTAssertNotNil(props["provider_id"], "generate_image should have provider_id param")
        XCTAssertNotNil(props["model_name"], "generate_image should have model_name param")
    }

    func testGenerateVideoToolHasOverrideParams() {
        let tool = ToolDefinitions.generateVideoTool
        let props = tool.function.parameters.properties!
        XCTAssertNotNil(props["provider_id"], "generate_video should have provider_id param")
        XCTAssertNotNil(props["model_name"], "generate_video should have model_name param")
    }

    // MARK: - setModel: image/video roles accept any provider (no type restriction)

    @MainActor
    func testSetModelImageAcceptsLLMProvider() {
        // LLM providers with image_gen capability can also be used for image generation (e.g. Gemini)
        let agent = makeAgent()
        let llm = makeLLMProvider(name: "Gemini")
        let tools = ModelTools(agent: agent, modelContext: context)

        let result = tools.setModel(arguments: [
            "role": "image",
            "model_id": llm.id.uuidString
        ])

        XCTAssertFalse(result.contains("[Error]"), "Image role should accept any provider type")
        XCTAssertEqual(agent.imageProviderId, llm.id)
    }

    @MainActor
    func testSetModelVideoAcceptsVideoProvider() {
        let agent = makeAgent()
        let vid = makeVideoProvider()
        let tools = ModelTools(agent: agent, modelContext: context)

        let result = tools.setModel(arguments: [
            "role": "video",
            "model_id": vid.id.uuidString
        ])

        XCTAssertFalse(result.contains("[Error]"))
        XCTAssertEqual(agent.videoProviderId, vid.id)
    }

    @MainActor
    func testSetModelI2VWithModelNameOverride() {
        let agent = makeAgent()
        let vid = makeVideoProvider()
        let tools = ModelTools(agent: agent, modelContext: context)

        let result = tools.setModel(arguments: [
            "role": "i2v",
            "model_id": vid.id.uuidString,
            "model_name": "kling-i2v-v2"
        ])

        XCTAssertTrue(result.contains("kling-i2v-v2"))
        XCTAssertEqual(agent.i2vProviderId, vid.id)
        XCTAssertEqual(agent.i2vModelNameOverride, "kling-i2v-v2")
    }

    // MARK: - setModel: image/video roles with nonexistent provider

    @MainActor
    func testSetModelImageNonexistentProvider() {
        let agent = makeAgent()
        let tools = ModelTools(agent: agent, modelContext: context)

        let result = tools.setModel(arguments: [
            "role": "image",
            "model_id": UUID().uuidString
        ])

        XCTAssertTrue(result.contains("[Error]"))
        XCTAssertTrue(result.contains("No provider found"))
    }

    @MainActor
    func testSetModelVideoNonexistentProvider() {
        let agent = makeAgent()
        let tools = ModelTools(agent: agent, modelContext: context)

        let result = tools.setModel(arguments: [
            "role": "video",
            "model_id": UUID().uuidString
        ])

        XCTAssertTrue(result.contains("[Error]"))
        XCTAssertTrue(result.contains("No provider found"))
    }
}
