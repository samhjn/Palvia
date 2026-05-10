import Foundation
import SwiftData

/// API protocol used by a provider.
///
/// Specifies the wire protocol for all API interactions (chat, image, video).
/// Each case represents a distinct API interface. The provider's `ProviderType`
/// determines which subset of protocols is shown in the UI.
enum APIStyle: String, Codable, CaseIterable {
    // LLM / Image protocols
    /// OpenAI-compatible: `/chat/completions`, `/images/generations`, `/videos/generations`.
    /// Bearer token auth. Used by most third-party providers.
    case openAI = "openai"
    /// OpenAI Responses API: `/responses`. Opt-in because most third-party
    /// OpenAI-compatible providers still only implement Chat Completions.
    case openAIResponses = "openai_responses"
    /// Anthropic: `/messages` endpoint, `x-api-key` header, extended thinking.
    case anthropic = "anthropic"

    // Video-specific protocols
    /// Google Gemini `predictLongRunning` pattern (Veo 2/3/3.1).
    case googleVeo
    /// Alibaba Cloud DashScope async task pattern (Tongyi Wan series).
    case dashScope
    /// Kuaishou Kling API pattern.
    case kling
    /// ByteDance Volcengine Ark pattern (Seedance).
    case seedance

    var displayName: String {
        switch self {
        case .openAI: return L10n.Provider.apiStyleOpenAI
        case .openAIResponses: return L10n.Provider.apiStyleOpenAIResponses
        case .anthropic: return L10n.Provider.apiStyleAnthropic
        case .googleVeo: return L10n.Provider.apiStyleGoogleVeo
        case .dashScope: return L10n.Provider.apiStyleDashScope
        case .kling: return L10n.Provider.apiStyleKling
        case .seedance: return L10n.Provider.apiStyleSeedance
        }
    }

    /// Cases relevant for LLM providers.
    static let llmCases: [APIStyle] = [.openAI, .openAIResponses, .anthropic]
    /// Cases relevant for image-only providers.
    static let imageCases: [APIStyle] = [.openAI, .dashScope]
    /// Cases relevant for video-only providers.
    static let videoCases: [APIStyle] = [.openAI, .googleVeo, .dashScope, .kling, .seedance]

    /// Whether this style supports an LLM adapter.
    var isLLMCapable: Bool { self == .openAI || self == .openAIResponses || self == .anthropic }
}

/// Thinking / reasoning intensity level.
///
/// Maps to provider-specific parameters:
/// - Anthropic effort-aware models (Opus 4.5+, Sonnet 4.6+, Mythos): `output_config.effort`
/// - Anthropic legacy models with manual extended thinking: `thinking.budget_tokens`
/// - OpenAI: `reasoning_effort`
///
/// `.xhigh` is only meaningful on Claude Opus 4.7. `.max` is only meaningful on
/// Claude Opus 4.5+, Sonnet 4.6+, and Mythos. On older endpoints these levels
/// are downgraded to `.high` by the adapter.
enum ThinkingLevel: String, Codable, CaseIterable, Comparable {
    case off = "off"
    case low = "low"
    case medium = "medium"
    case high = "high"
    case xhigh = "xhigh"
    case max = "max"

    var displayName: String {
        switch self {
        case .off: return "Off"
        case .low: return "Low"
        case .medium: return "Medium"
        case .high: return "High"
        case .xhigh: return "Extra High"
        case .max: return "Max"
        }
    }

    /// Anthropic `budget_tokens` for legacy manual extended thinking.
    /// Newer models prefer `effort` via `output_config`; see `anthropicEffort`.
    var anthropicBudgetTokens: Int {
        switch self {
        case .off: return 0
        case .low: return 2048
        case .medium: return 10240
        case .high: return 32768
        case .xhigh: return 49152
        case .max: return 65536
        }
    }

    /// Anthropic `output_config.effort` value, or nil when thinking is off.
    /// `.xhigh` and `.max` may be unsupported on some models — the adapter
    /// clamps them via `EffortLevelSupport` before sending.
    var anthropicEffort: String? {
        switch self {
        case .off: return nil
        case .low: return "low"
        case .medium: return "medium"
        case .high: return "high"
        case .xhigh: return "xhigh"
        case .max: return "max"
        }
    }

    /// OpenAI `reasoning_effort` value, or nil when thinking is off.
    /// OpenAI does not define `xhigh`/`max`; both collapse to `"high"`.
    var openAIReasoningEffort: String? {
        switch self {
        case .off: return nil
        case .low: return "low"
        case .medium: return "medium"
        case .high, .xhigh, .max: return "high"
        }
    }

    var isEnabled: Bool { self != .off }

    /// Two-character abbreviation used by capability badges. Must stay short
    /// because the badge has tight horizontal padding.
    var shortLabel: String {
        switch self {
        case .off: return ""
        case .low: return "L"
        case .medium: return "Me"
        case .high: return "H"
        case .xhigh: return "XH"
        case .max: return "Mx"
        }
    }

    /// Human-readable suffix shown next to `xhigh` / `max` rows in the
    /// picker, telling the user which models honour the level. Phrasing
    /// differs per dialect: Anthropic talks about Claude tiers, OpenAI
    /// dialect calls out DeepSeek v4.
    func modelRequirement(for apiStyle: APIStyle) -> String? {
        switch self {
        case .xhigh: return apiStyle == .anthropic
            ? L10n.Provider.thinkingLevelXHighSuffix
            : L10n.Provider.thinkingLevelXHighSuffixOpenAI
        case .max: return apiStyle == .anthropic
            ? L10n.Provider.thinkingLevelMaxSuffix
            : L10n.Provider.thinkingLevelMaxSuffixOpenAI
        default: return nil
        }
    }

    /// The picker contents for a (model, apiStyle) pair. Encodes the
    /// per-model capability rules — see the plan in
    /// `~/.claude/plans/ui-case-wondrous-blum.md`.
    static func cases(for model: String, apiStyle: APIStyle) -> [ThinkingLevel] {
        let isDeepSeekV4 = DeepSeekModelInfo.classify(model) == .v4OrLater

        if apiStyle == .anthropic {
            if isDeepSeekV4 {
                return [.off, .low, .medium, .high, .xhigh, .max]
            }
            switch ClaudeModelInfo.classify(model) {
            case .opus47OrLater:
                // Opus 4.7 is adaptive-only for *enabling* thinking — the
                // manual `enabled` form is rejected — but `thinking:
                // disabled` is still accepted. Only future Mythos Preview
                // (which we don't classify yet) explicitly rejects
                // `disabled`; expose `Off` for now.
                return [.off, .low, .medium, .high, .xhigh, .max]
            case .opus46, .sonnet46, .opus45:
                return [.off, .low, .medium, .high, .max]
            case .other:
                return [.off, .low, .medium, .high]
            }
        }
        // OpenAI dialect.
        if isDeepSeekV4 {
            return [.off, .low, .medium, .high, .xhigh, .max]
        }
        return [.off, .low, .medium, .high]
    }

    // MARK: Comparable

    private var sortOrder: Int {
        switch self {
        case .off: return 0
        case .low: return 1
        case .medium: return 2
        case .high: return 3
        case .xhigh: return 4
        case .max: return 5
        }
    }

    static func < (lhs: ThinkingLevel, rhs: ThinkingLevel) -> Bool {
        lhs.sortOrder < rhs.sortOrder
    }
}

/// How a model accepts thinking-related parameters in Anthropic-compat dialect.
///
/// - `manual`: legacy Claude that only understands `thinking.budget_tokens`.
///   `output_config.effort` is not sent.
/// - `manualWithEffort`: Claude Opus 4.5, which keeps manual extended thinking
///   but additionally honours `output_config.effort` for overall token spend.
/// - `adaptive`: Claude Opus 4.6+, Sonnet 4.6+, Opus 4.7+. Uses
///   `thinking: {type: "adaptive"}` + `output_config.effort`. Manual
///   `budget_tokens` is no longer the recommended path (and is forbidden on
///   Opus 4.7), so the adapter never sets it for this strategy.
/// - `effortSwitch`: DeepSeek v4 in Anthropic-compat. Emits an explicit
///   `thinking: {type: "enabled"|"disabled"}` switch (no adaptive form, no
///   `budget_tokens`) plus `output_config.effort`.
enum AnthropicThinkingStrategy {
    case manual
    case manualWithEffort
    case adaptive
    case effortSwitch

    /// Resolve the right strategy for any (model, Anthropic-dialect) pair.
    /// DeepSeek v4 wins over Claude classification because the `deepseek-`
    /// prefix never overlaps with `claude-`, but the explicit precedence
    /// keeps the intent obvious.
    static func resolve(for model: String) -> AnthropicThinkingStrategy {
        if DeepSeekModelInfo.classify(model) == .v4OrLater {
            return .effortSwitch
        }
        return ClaudeModelInfo.classify(model).thinkingStrategy
    }
}

/// Per-model effort support across both Anthropic and OpenAI dialects.
/// Used by the adapter to clamp `xhigh`/`max` and decide whether to emit the
/// explicit `thinking` switch (a DeepSeek extension on the OpenAI dialect).
struct EffortLevelSupport {
    let supportsEffort: Bool
    let supportsXHigh: Bool
    let supportsMax: Bool
    /// Whether the endpoint accepts `{"thinking": {"type": "enabled"|"disabled"}}`.
    /// True for Claude on Anthropic and DeepSeek v4 on either dialect; false
    /// for plain OpenAI o-series, OpenRouter, Ollama, and other passthroughs.
    let supportsExplicitThinkingSwitch: Bool

    static let none = EffortLevelSupport(
        supportsEffort: false, supportsXHigh: false,
        supportsMax: false, supportsExplicitThinkingSwitch: false
    )

    static func forModel(_ model: String, apiStyle: APIStyle) -> EffortLevelSupport {
        // DeepSeek v4 — full effort + explicit switch on both dialects.
        // The wire accepts `xhigh`/`max` even though DeepSeek collapses
        // `low`/`medium` → `high` and `xhigh` → `max` server-side.
        if DeepSeekModelInfo.classify(model) == .v4OrLater {
            return EffortLevelSupport(
                supportsEffort: true,
                supportsXHigh: true,
                supportsMax: true,
                supportsExplicitThinkingSwitch: true
            )
        }
        if apiStyle == .anthropic {
            switch ClaudeModelInfo.classify(model) {
            case .opus47OrLater:
                return EffortLevelSupport(
                    supportsEffort: true, supportsXHigh: true,
                    supportsMax: true, supportsExplicitThinkingSwitch: true
                )
            case .opus46, .sonnet46, .opus45:
                return EffortLevelSupport(
                    supportsEffort: true, supportsXHigh: false,
                    supportsMax: true, supportsExplicitThinkingSwitch: true
                )
            case .other:
                // Legacy / unknown Anthropic-compat. We still need the
                // explicit thinking switch so DeepSeek's Anthropic-compat
                // (and any other shim) can't silently default to enabled.
                return EffortLevelSupport(
                    supportsEffort: false, supportsXHigh: false,
                    supportsMax: false, supportsExplicitThinkingSwitch: true
                )
            }
        }
        // OpenAI dialect, non-DeepSeek. Standard `reasoning_effort` only;
        // `xhigh`/`max` collapse to `"high"` client-side.
        return EffortLevelSupport(
            supportsEffort: true, supportsXHigh: false,
            supportsMax: false, supportsExplicitThinkingSwitch: false
        )
    }
}

/// Coarse classification of a DeepSeek model name. Mirrors
/// `ClaudeModelInfo` and is used to decide whether to emit DeepSeek's
/// non-standard effort/thinking extensions.
enum DeepSeekModelInfo {
    case v4OrLater
    case v3
    case other

    static func classify(_ model: String) -> DeepSeekModelInfo {
        let name = model.split(separator: "/").last.map { String($0).lowercased() } ?? model.lowercased()
        guard name.hasPrefix("deepseek") else { return .other }

        // `deepseek-chat` and `deepseek-reasoner` are aliases that DeepSeek
        // routes to whichever model is current — at the time of writing, v4.
        if name == "deepseek-chat" || name == "deepseek-reasoner" {
            return .v4OrLater
        }

        // Versioned names: `deepseek-v4-...`, `deepseek-v4.1`, etc.
        guard name.hasPrefix("deepseek-v") else { return .other }
        let rest = name.dropFirst("deepseek-v".count)
        guard let major = rest.first?.wholeNumberValue else { return .other }
        switch major {
        case 4...: return .v4OrLater
        case 3: return .v3
        default: return .other
        }
    }
}

/// Coarse classification of a Claude model name. The adapter cares about
/// thinking-parameter capabilities, not the model family per se.
enum ClaudeModelInfo {
    case opus47OrLater
    case opus46
    case sonnet46
    case opus45
    case other

    static func classify(_ model: String) -> ClaudeModelInfo {
        let name = model.split(separator: "/").last.map { String($0).lowercased() } ?? model.lowercased()
        guard name.hasPrefix("claude") else { return .other }

        // New naming: claude-{variant}-{major}-{minor}, e.g. claude-opus-4-7
        for variant in ["opus", "sonnet", "haiku"] {
            let prefix = "claude-\(variant)-"
            guard name.hasPrefix(prefix) else { continue }
            let rest = name.dropFirst(prefix.count)
            // Parse leading "<major>-<minor>" or "<major>.<minor>" or just "<major>".
            guard let major = rest.first?.wholeNumberValue, major >= 4 else { return .other }
            // Find the minor digit (skip the major + separator).
            let afterMajor = rest.dropFirst()
            let minor: Int?
            if let sep = afterMajor.first, sep == "-" || sep == "." {
                minor = afterMajor.dropFirst().first?.wholeNumberValue
            } else {
                minor = 0
            }
            switch (variant, major, minor ?? 0) {
            case ("opus", 4, let m) where m >= 7: return .opus47OrLater
            case ("opus", let M, _) where M >= 5: return .opus47OrLater
            case ("opus", 4, 6): return .opus46
            case ("opus", 4, 5): return .opus45
            case ("sonnet", 4, let m) where m >= 6: return .sonnet46
            default: return .other
            }
        }
        return .other
    }

    var thinkingStrategy: AnthropicThinkingStrategy {
        switch self {
        case .opus47OrLater, .opus46, .sonnet46:
            return .adaptive
        case .opus45:
            return .manualWithEffort
        case .other:
            return .manual
        }
    }
}

/// Image generation mode for a model.
enum ImageGenMode: String, Codable, CaseIterable {
    /// Model does not support image generation.
    case none
    /// Generates images inline via chat completions with `modalities: ["image","text"]` (e.g. Gemini Image).
    case chatInline
    /// Generates images via dedicated `/images/generations` endpoint (e.g. DALL-E, FLUX, SD3).
    case dedicatedAPI
    /// Generates images via DashScope async task API (e.g. wan2.7-image-pro, wan2.7-image).
    case dashScope

    var displayName: String {
        switch self {
        case .none: return L10n.Provider.imageGenModeNone
        case .chatInline: return L10n.Provider.imageGenModeChatInline
        case .dedicatedAPI: return L10n.Provider.imageGenModeDedicatedAPI
        case .dashScope: return L10n.Provider.imageGenModeDashScope
        }
    }
}

/// Provider type: distinguishes LLM chat, image generation, and video generation providers.
///
/// Non-LLM providers hide irrelevant fields (apiStyle, maxTokens, temperature)
/// and show only relevant capability toggles in the edit UI.
enum ProviderType: String, Codable, CaseIterable {
    /// Standard LLM chat/completion provider.
    case llm = "llm"
    /// Image generation only (DALL-E, Flux, SD3, etc.).
    case imageOnly = "image"
    /// Video generation only (Kling, Veo, DashScope, Sora, etc.).
    case videoOnly = "video"

    var displayName: String {
        switch self {
        case .llm: return L10n.Provider.providerTypeLLM
        case .imageOnly: return L10n.Provider.providerTypeImage
        case .videoOnly: return L10n.Provider.providerTypeVideo
        }
    }
}

/// Per-model capability flags and parameter overrides.
struct ModelCapabilities: Codable, Equatable {
    var supportsVision: Bool = false
    var supportsToolUse: Bool = true
    var imageGenerationMode: ImageGenMode = .none
    /// Whether this model supports video input (e.g. Gemini 2+, Qwen-VL).
    var supportsVideoInput: Bool = false
    /// Whether this model supports video generation.
    /// The video API protocol is determined by the provider's `apiStyle`, not per-model.
    var supportsVideoGeneration: Bool = false
    /// Legacy flag kept for backward compatibility with existing persisted data.
    /// New code should use `thinkingLevel` instead.
    var supportsReasoning: Bool = false
    /// The default thinking level for this model. `.off` means no thinking support.
    var thinkingLevel: ThinkingLevel = .off
    /// Per-model max output tokens override. `nil` = use provider default.
    var maxTokens: Int? = nil
    /// Per-model temperature override. `nil` = use provider default.
    var temperature: Double? = nil

    /// Backward-compatible computed property.
    var supportsImageGeneration: Bool {
        get { imageGenerationMode != .none }
        set { imageGenerationMode = newValue ? .chatInline : .none }
    }

    static let `default` = ModelCapabilities()

    enum CodingKeys: String, CodingKey {
        case supportsVision, supportsToolUse, imageGenerationMode, supportsVideoInput
        case supportsVideoGeneration
        case supportsReasoning, thinkingLevel
        case maxTokens, temperature
        case _legacyImageGen = "supportsImageGeneration"
        case _legacyVideoGenMode = "videoGenerationMode"
    }

    init(supportsVision: Bool = false, supportsToolUse: Bool = true,
         imageGenerationMode: ImageGenMode = .none, supportsVideoInput: Bool = false,
         supportsVideoGeneration: Bool = false,
         supportsReasoning: Bool = false, thinkingLevel: ThinkingLevel = .off,
         maxTokens: Int? = nil, temperature: Double? = nil) {
        self.supportsVision = supportsVision
        self.supportsToolUse = supportsToolUse
        self.imageGenerationMode = imageGenerationMode
        self.supportsVideoInput = supportsVideoInput
        self.supportsVideoGeneration = supportsVideoGeneration
        self.supportsReasoning = supportsReasoning
        self.thinkingLevel = thinkingLevel
        self.maxTokens = maxTokens
        self.temperature = temperature
    }

    /// Legacy init for backward compatibility with callers using the old Bool parameter.
    init(supportsVision: Bool, supportsToolUse: Bool,
         supportsImageGeneration: Bool, supportsReasoning: Bool) {
        self.supportsVision = supportsVision
        self.supportsToolUse = supportsToolUse
        self.imageGenerationMode = supportsImageGeneration ? .chatInline : .none
        self.supportsReasoning = supportsReasoning
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        supportsVision = try c.decodeIfPresent(Bool.self, forKey: .supportsVision) ?? false
        supportsToolUse = try c.decodeIfPresent(Bool.self, forKey: .supportsToolUse) ?? true
        supportsVideoInput = try c.decodeIfPresent(Bool.self, forKey: .supportsVideoInput) ?? false
        // Video generation: try new bool first, migrate from legacy VideoGenMode enum
        if let videoGen = try c.decodeIfPresent(Bool.self, forKey: .supportsVideoGeneration) {
            supportsVideoGeneration = videoGen
        } else if let legacyRaw = try? c.decodeIfPresent(String.self, forKey: ._legacyVideoGenMode),
                  legacyRaw != "none" {
            supportsVideoGeneration = true
        } else {
            supportsVideoGeneration = false
        }
        supportsReasoning = try c.decodeIfPresent(Bool.self, forKey: .supportsReasoning) ?? false
        // ImageGenMode: try new enum first, fall back to legacy bool
        if let mode = try? c.decodeIfPresent(ImageGenMode.self, forKey: .imageGenerationMode) {
            imageGenerationMode = mode
        } else if let legacy = try? c.decodeIfPresent(Bool.self, forKey: ._legacyImageGen), legacy {
            imageGenerationMode = .chatInline
        } else {
            imageGenerationMode = .none
        }
        // ThinkingLevel: migration from supportsReasoning bool
        if let level = try c.decodeIfPresent(ThinkingLevel.self, forKey: .thinkingLevel) {
            thinkingLevel = level
        } else {
            thinkingLevel = supportsReasoning ? .medium : .off
        }
        maxTokens = try c.decodeIfPresent(Int.self, forKey: .maxTokens)
        temperature = try c.decodeIfPresent(Double.self, forKey: .temperature)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(supportsVision, forKey: .supportsVision)
        try container.encode(supportsToolUse, forKey: .supportsToolUse)
        try container.encode(imageGenerationMode, forKey: .imageGenerationMode)
        try container.encode(supportsVideoInput, forKey: .supportsVideoInput)
        try container.encode(supportsVideoGeneration, forKey: .supportsVideoGeneration)
        try container.encode(supportsReasoning, forKey: .supportsReasoning)
        try container.encode(thinkingLevel, forKey: .thinkingLevel)
        try container.encodeIfPresent(maxTokens, forKey: .maxTokens)
        try container.encodeIfPresent(temperature, forKey: .temperature)
    }

    /// Infer default capabilities from a model name.
    ///
    /// Vision: GPT-4+, Claude 3.5+, Qwen-VL/Omni/3.5+, Gemini 1.5+
    /// Video: Gemini 1.5+, Qwen-VL/Omni, InternVL, Pixtral, LLaVA-Video
    /// Image generation (chatInline): gemini-*-image-* models
    /// Image generation (dedicatedAPI): dall-e-*, gpt-image-*, flux-*, sd3-*, sdxl-*
    /// Thinking level: Claude (new naming) → `.medium`; DeepSeek v4 → `.high`.
    /// All other reasoning capabilities default to `.off` so the user opts in.
    static func inferred(from modelName: String) -> ModelCapabilities {
        var caps = inferredBase(from: modelName)
        // Layer thinking-level inference on top, but only for non-image,
        // non-video-generation models (image/video models don't reason).
        if caps.imageGenerationMode == .none && !caps.supportsVideoGeneration {
            if ClaudeModelInfo.classify(modelName) != .other {
                caps.thinkingLevel = .medium
                caps.supportsReasoning = true
            } else if DeepSeekModelInfo.classify(modelName) == .v4OrLater {
                caps.thinkingLevel = .high
                caps.supportsReasoning = true
            }
        }
        return caps
    }

    private static func inferredBase(from modelName: String) -> ModelCapabilities {
        let base = modelName.split(separator: "/").last.map { String($0).lowercased() }
            ?? modelName.lowercased()

        // Gemini image models: chatInline mode (no tool use)
        if base.contains("gemini") && base.contains("image") {
            return ModelCapabilities(
                supportsVision: true,
                supportsToolUse: false,
                imageGenerationMode: .chatInline,
                supportsVideoInput: true,
                supportsReasoning: false
            )
        }

        // DashScope image generation models (wan2.7-image series)
        if inferDashScopeImageGen(base) {
            return ModelCapabilities(
                supportsVision: false,
                supportsToolUse: false,
                imageGenerationMode: .dashScope,
                supportsReasoning: false
            )
        }

        // Dedicated image generation models
        if inferDedicatedImageGen(base) {
            return ModelCapabilities(
                supportsVision: false,
                supportsToolUse: false,
                imageGenerationMode: .dedicatedAPI,
                supportsReasoning: false
            )
        }

        // Dedicated video generation models
        if inferVideoGenModel(base) {
            return ModelCapabilities(
                supportsVision: false,
                supportsToolUse: false,
                supportsVideoGeneration: true,
                supportsReasoning: false
            )
        }

        let videoCapable = inferVideoInput(base)

        // Video capability implies vision capability
        if videoCapable {
            return ModelCapabilities(
                supportsVision: true,
                supportsToolUse: true,
                imageGenerationMode: .none,
                supportsVideoInput: true,
                supportsReasoning: false
            )
        }

        if inferVision(base) {
            return ModelCapabilities(
                supportsVision: true,
                supportsToolUse: true,
                imageGenerationMode: .none,
                supportsVideoInput: false,
                supportsReasoning: false
            )
        }

        return .default
    }

    /// Detect dedicated video generation models.
    /// The API protocol is determined by the provider's `apiStyle`, not the model name.
    private static func inferVideoGenModel(_ name: String) -> Bool {
        name.hasPrefix("sora")
            || name.hasPrefix("veo-") || name.hasPrefix("veo_")
            || (name.hasPrefix("wan") && (name.contains("-t2v") || name.contains("-i2v")
                || name.contains("-r2v") || name.contains("-kf2v")
                || name.contains("-s2v") || name.contains("-vace")))
            || name.hasPrefix("runway-") || name.hasPrefix("gen-3") || name.hasPrefix("gen-4")
            || name.hasPrefix("luma-") || name.hasPrefix("dream-machine") || name.hasPrefix("ray-")
            || name.hasPrefix("kling")
            || (name.hasPrefix("minimax") && name.contains("video")) || name.hasPrefix("hailuo")
            || name.hasPrefix("doubao-seedance")
    }

    /// Detect DashScope image generation models (wan2.7-image series).
    private static func inferDashScopeImageGen(_ name: String) -> Bool {
        name.hasPrefix("wan") && name.contains("image")
    }

    /// Detect models that use the dedicated /images/generations API.
    private static func inferDedicatedImageGen(_ name: String) -> Bool {
        name.hasPrefix("dall-e")
            || name.hasPrefix("gpt-image")
            || name.hasPrefix("flux")
            || name.hasPrefix("stable-diffusion")
            || name.hasPrefix("sd3")
            || name.hasPrefix("sdxl")
            || name.contains("imagen")
    }

    /// Detect models that support video input.
    /// Gemini 1.5+, Qwen-VL/Omni, InternVL, Pixtral, LLaVA-Video support video natively.
    private static func inferVideoInput(_ name: String) -> Bool {
        // Gemini 1.5+ supports video input
        if name.hasPrefix("gemini-") {
            let rest = name.dropFirst(7)
            if let version = parseLeadingVersion(String(rest)), version >= 1.5 {
                return true
            }
        }
        // Qwen-VL and Qwen-Omni support video
        if name.contains("qwen") && (name.contains("-vl") || name.contains("-omni")) {
            return true
        }
        // InternVL supports video
        if name.contains("internvl") {
            return true
        }
        // Pixtral (Mistral) supports video
        if name.contains("pixtral") {
            return true
        }
        // LLaVA-Video / LLaVA-Next-Video
        if name.contains("llava") && name.contains("video") {
            return true
        }
        return false
    }

    // MARK: - Private inference helpers

    /// Detect vision-only models (no video). Video models are handled separately by `inferVideoInput`.
    private static func inferVision(_ name: String) -> Bool {
        isGPTVisionCapable(name)
            || isClaudeVisionCapable(name)
            || isQwenVisionCapable(name)
            || isGeminiVisionCapable(name)
    }

    /// GPT-4.x and above
    private static func isGPTVisionCapable(_ name: String) -> Bool {
        guard name.hasPrefix("gpt-") else { return false }
        let rest = name.dropFirst(4)
        guard let digit = rest.first, let num = digit.wholeNumberValue else { return false }
        return num >= 4
    }

    /// Claude 3.5 and above
    private static func isClaudeVisionCapable(_ name: String) -> Bool {
        guard name.hasPrefix("claude") else { return false }

        // New naming: claude-{variant}-{version} (e.g. claude-sonnet-4-6, claude-opus-4)
        for variant in ["sonnet", "opus", "haiku"] {
            let prefix = "claude-\(variant)-"
            if name.hasPrefix(prefix) {
                let rest = name.dropFirst(prefix.count)
                if let digit = rest.first, let num = digit.wholeNumberValue, num >= 4 {
                    return true
                }
            }
        }

        // Old naming: claude-{version}-{variant} (e.g. claude-3.5-sonnet, claude-3-5-sonnet)
        guard name.hasPrefix("claude-") else { return false }
        let rest = name.dropFirst(7) // "claude-"
        guard let digit = rest.first, let num = digit.wholeNumberValue else { return false }
        if num > 3 { return true }
        if num == 3 {
            let afterDigit = rest.dropFirst(1)
            if afterDigit.hasPrefix(".5") || afterDigit.hasPrefix("-5") { return true }
        }
        return false
    }

    /// Qwen-VL, Qwen-Omni, or Qwen 3.5+
    private static func isQwenVisionCapable(_ name: String) -> Bool {
        guard name.contains("qwen") else { return false }
        if name.contains("-vl") || name.contains("-omni") { return true }

        // Version directly after "qwen" (no dash): qwen3.5, qwen4, etc.
        guard let range = name.range(of: "qwen") else { return false }
        let afterQwen = name[range.upperBound...]
        guard let first = afterQwen.first, first.isNumber else { return false }
        if let version = parseLeadingVersion(String(afterQwen)), version >= 3.5 {
            return true
        }
        return false
    }

    /// Gemini 1.5 and above
    private static func isGeminiVisionCapable(_ name: String) -> Bool {
        guard name.hasPrefix("gemini-") else { return false }
        let rest = name.dropFirst(7)
        if let version = parseLeadingVersion(String(rest)), version >= 1.5 {
            return true
        }
        return false
    }

    private static func parseLeadingVersion(_ str: String) -> Double? {
        var numStr = ""
        var hasDot = false
        for ch in str {
            if ch.isNumber {
                numStr.append(ch)
            } else if ch == "." && !hasDot {
                hasDot = true
                numStr.append(ch)
            } else {
                break
            }
        }
        return numStr.isEmpty ? nil : Double(numStr)
    }
}

@Model
final class LLMProvider {
    var id: UUID
    var name: String
    var endpoint: String
    var apiKey: String
    var modelName: String
    var isDefault: Bool
    var maxTokens: Int
    var temperature: Double
    var createdAt: Date

    /// All model names enabled for this provider (in addition to modelName).
    /// Stored as comma-separated string for SwiftData compatibility.
    var enabledModelsRaw: String?

    /// Cached model list fetched from the API.
    /// Stored as comma-separated string.
    var cachedModelListRaw: String?

    /// When the model list was last fetched.
    var cachedModelListDate: Date?

    /// Legacy provider-level flags (kept for backward compatibility with existing data).
    var supportsVision: Bool = false
    var supportsToolUse: Bool = true
    var supportsImageGeneration: Bool = false

    /// API communication style: "openai" or "anthropic".
    var apiStyleRaw: String = "openai"

    /// Provider type: "llm" (default) or "video" (video-only).
    var providerTypeRaw: String = "llm"

    /// Per-model capabilities, stored as JSON: {"model-name": {...}}
    var modelCapabilitiesJSON: String?

    // MARK: - Computed

    var apiStyle: APIStyle {
        get { APIStyle(rawValue: apiStyleRaw) ?? .openAI }
        set { apiStyleRaw = newValue.rawValue }
    }

    var providerType: ProviderType {
        get { ProviderType(rawValue: providerTypeRaw) ?? .llm }
        set { providerTypeRaw = newValue.rawValue }
    }

    /// Whether this provider is exclusively for video generation.
    var isVideoOnly: Bool { providerType == .videoOnly }

    /// Whether this provider is exclusively for image generation.
    var isImageOnly: Bool { providerType == .imageOnly }

    /// Whether this provider is a media-only provider (not usable for chat).
    var isMediaOnly: Bool { providerType != .llm }

    var enabledModels: [String] {
        get {
            var models = Set<String>()
            models.insert(modelName)
            if let raw = enabledModelsRaw, !raw.isEmpty {
                raw.components(separatedBy: "|||").forEach { models.insert($0) }
            }
            return Array(models).sorted()
        }
        set {
            let filtered = newValue.filter { $0 != modelName }
            enabledModelsRaw = filtered.isEmpty ? nil : filtered.joined(separator: "|||")
        }
    }

    var cachedModelList: [String] {
        get {
            guard let raw = cachedModelListRaw, !raw.isEmpty else { return [] }
            return raw.components(separatedBy: "|||")
        }
        set {
            cachedModelListRaw = newValue.isEmpty ? nil : newValue.joined(separator: "|||")
        }
    }

    // MARK: - Capabilities Cache

    /// Transient cache for decoded capabilities. Not persisted by SwiftData.
    @Transient private var _capabilitiesCache: [String: ModelCapabilities]?
    @Transient private var _capabilitiesCacheKey: String?

    /// Decode and cache the capabilities dictionary, invalidating on JSON change.
    private func decodedCapabilities() -> [String: ModelCapabilities] {
        if let cache = _capabilitiesCache, _capabilitiesCacheKey == modelCapabilitiesJSON {
            return cache
        }
        guard let json = modelCapabilitiesJSON,
              let data = json.data(using: .utf8),
              let dict = try? JSONDecoder().decode([String: ModelCapabilities].self, from: data)
        else {
            _capabilitiesCache = [:]
            _capabilitiesCacheKey = modelCapabilitiesJSON
            return [:]
        }
        _capabilitiesCache = dict
        _capabilitiesCacheKey = modelCapabilitiesJSON
        return dict
    }

    /// Invalidate the transient cache (called after writes).
    private func invalidateCapabilitiesCache() {
        _capabilitiesCache = nil
        _capabilitiesCacheKey = nil
    }

    /// Per-model capabilities dictionary.
    var allModelCapabilities: [String: ModelCapabilities] {
        get { decodedCapabilities() }
        set {
            guard let data = try? JSONEncoder().encode(newValue),
                  let json = String(data: data, encoding: .utf8)
            else { modelCapabilitiesJSON = nil; invalidateCapabilitiesCache(); return }
            modelCapabilitiesJSON = json
            invalidateCapabilitiesCache()
        }
    }

    /// Get capabilities for a specific model.
    /// Falls back to `ModelCapabilities.inferred(from:)` when no per-model entry exists.
    func capabilities(for model: String) -> ModelCapabilities {
        if let caps = decodedCapabilities()[model] {
            return caps
        }
        // Infer from model name instead of using legacy provider-level bools
        return ModelCapabilities.inferred(from: model)
    }

    /// Set capabilities for a specific model.
    func setCapabilities(_ caps: ModelCapabilities, for model: String) {
        var dict = decodedCapabilities()
        dict[model] = caps
        if let data = try? JSONEncoder().encode(dict),
           let json = String(data: data, encoding: .utf8) {
            modelCapabilitiesJSON = json
            invalidateCapabilitiesCache()
        }
    }

    init(
        name: String,
        endpoint: String = "https://api.openai.com/v1",
        apiKey: String = "",
        modelName: String = "gpt-5.4",
        isDefault: Bool = false,
        maxTokens: Int = 4096,
        temperature: Double = 0.7
    ) {
        self.id = UUID()
        self.name = name
        self.endpoint = endpoint
        self.apiKey = apiKey
        self.modelName = modelName
        self.isDefault = isDefault
        self.maxTokens = maxTokens
        self.temperature = temperature
        self.createdAt = Date()
        self.enabledModelsRaw = nil
        self.cachedModelListRaw = nil
        self.cachedModelListDate = nil
        self.supportsVision = false
        self.apiStyleRaw = "openai"
        self.providerTypeRaw = "llm"
        self.modelCapabilitiesJSON = nil
    }
}
