import Foundation

/// Decoded representation of the Models.dev catalog (`https://models.dev/api.json`).
///
/// Models.dev publishes an open, community-maintained database of LLM providers
/// and their models. The wire format is a JSON object keyed by provider id:
///
/// ```json
/// { "anthropic": { "id": "anthropic", "name": "Anthropic",
///                  "npm": "@ai-sdk/anthropic", "models": { "claude-…": { … } } } }
/// ```
///
/// We decode the whole thing into `[String: ModelsDevProvider]` and expose a
/// sorted, UI-friendly `providers` array. The catalog is purely descriptive —
/// mapping a Models.dev entry onto Palvia's own `APIStyle` / endpoint /
/// `ModelCapabilities` happens in `ModelsDevMapping` and the per-model helpers
/// below, so the raw decode stays a faithful mirror of the upstream shape.
struct ModelsDevCatalog: Decodable {
    /// Providers keyed by Models.dev id (e.g. `"anthropic"`, `"deepseek"`).
    let byID: [String: ModelsDevProvider]

    /// Providers that expose at least one model, sorted by display name. The
    /// list omits empty providers since they offer nothing to import.
    var providers: [ModelsDevProvider] {
        byID.values
            .filter { !$0.models.isEmpty }
            .sorted { lhs, rhs in
                lhs.displayName.localizedCaseInsensitiveCompare(rhs.displayName) == .orderedAscending
            }
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        byID = try container.decode([String: ModelsDevProvider].self)
    }

    /// Test/seam initializer.
    init(byID: [String: ModelsDevProvider]) {
        self.byID = byID
    }
}

/// A single provider entry from the Models.dev catalog.
struct ModelsDevProvider: Decodable, Identifiable {
    let id: String
    let name: String?
    /// AI-SDK npm package id (e.g. `@ai-sdk/anthropic`). Used to infer the wire
    /// protocol when `api` is absent — Models.dev omits `api` for first-party
    /// providers like OpenAI / Anthropic / Google.
    let npm: String?
    /// Base API URL. Present for OpenAI-compatible gateways, often absent for
    /// first-party SDKs.
    let api: String?
    /// Documentation URL, surfaced as a "Learn more" link in the catalog UI.
    let doc: String?
    /// Environment variable names that hold the provider's API key, shown as a
    /// hint to the user about which key to paste.
    let env: [String]?
    let modelsByID: [String: ModelsDevModel]

    var displayName: String { name ?? id }

    /// Models sorted newest-first (by release date, then name) for the UI.
    var models: [ModelsDevModel] {
        modelsByID.values.sorted { lhs, rhs in
            let l = lhs.releaseDate ?? ""
            let r = rhs.releaseDate ?? ""
            if l != r { return l > r }
            return lhs.displayName.localizedCaseInsensitiveCompare(rhs.displayName) == .orderedAscending
        }
    }

    enum CodingKeys: String, CodingKey {
        case id, name, npm, api, doc, env
        case modelsByID = "models"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        name = try c.decodeIfPresent(String.self, forKey: .name)
        npm = try c.decodeIfPresent(String.self, forKey: .npm)
        api = try c.decodeIfPresent(String.self, forKey: .api)
        doc = try c.decodeIfPresent(String.self, forKey: .doc)
        env = try c.decodeIfPresent([String].self, forKey: .env)
        modelsByID = try c.decodeIfPresent([String: ModelsDevModel].self, forKey: .modelsByID) ?? [:]
    }

    /// Test/seam initializer.
    init(id: String, name: String? = nil, npm: String? = nil, api: String? = nil,
         doc: String? = nil, env: [String]? = nil, modelsByID: [String: ModelsDevModel] = [:]) {
        self.id = id
        self.name = name
        self.npm = npm
        self.api = api
        self.doc = doc
        self.env = env
        self.modelsByID = modelsByID
    }
}

/// A single model entry from the Models.dev catalog.
struct ModelsDevModel: Decodable, Identifiable {
    let id: String
    let name: String?
    let family: String?
    /// Whether the model supports extended thinking / reasoning.
    let reasoning: Bool?
    /// Whether the model supports function calling / tool use.
    let toolCall: Bool?
    let temperature: Bool?
    let releaseDate: String?
    let knowledge: String?
    let modalities: Modalities?
    let limit: Limit?

    var displayName: String { name ?? id }

    struct Modalities: Decodable {
        let input: [String]?
        let output: [String]?
    }

    struct Limit: Decodable {
        let context: Int?
        let output: Int?
    }

    enum CodingKeys: String, CodingKey {
        case id, name, family, reasoning, temperature, knowledge, modalities, limit
        case toolCall = "tool_call"
        case releaseDate = "release_date"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        name = try c.decodeIfPresent(String.self, forKey: .name)
        family = try c.decodeIfPresent(String.self, forKey: .family)
        reasoning = try c.decodeIfPresent(Bool.self, forKey: .reasoning)
        toolCall = try c.decodeIfPresent(Bool.self, forKey: .toolCall)
        temperature = try c.decodeIfPresent(Bool.self, forKey: .temperature)
        releaseDate = try c.decodeIfPresent(String.self, forKey: .releaseDate)
        knowledge = try c.decodeIfPresent(String.self, forKey: .knowledge)
        modalities = try c.decodeIfPresent(Modalities.self, forKey: .modalities)
        limit = try c.decodeIfPresent(Limit.self, forKey: .limit)
    }

    /// Test/seam initializer.
    init(id: String, name: String? = nil, family: String? = nil, reasoning: Bool? = nil,
         toolCall: Bool? = nil, temperature: Bool? = nil, releaseDate: String? = nil,
         knowledge: String? = nil, modalities: Modalities? = nil, limit: Limit? = nil) {
        self.id = id
        self.name = name
        self.family = family
        self.reasoning = reasoning
        self.toolCall = toolCall
        self.temperature = temperature
        self.releaseDate = releaseDate
        self.knowledge = knowledge
        self.modalities = modalities
        self.limit = limit
    }

    // MARK: - Capability mapping

    private var inputModalities: [String] { modalities?.input ?? [] }
    private var outputModalities: [String] { modalities?.output ?? [] }

    /// Whether the model accepts image input.
    var supportsImageInput: Bool { inputModalities.contains("image") }
    /// Whether the model accepts video input.
    var supportsVideoInput: Bool { inputModalities.contains("video") }
    /// Whether the model emits images (e.g. Gemini image, gpt-image).
    var generatesImages: Bool { outputModalities.contains("image") }

    /// Map this catalog entry onto Palvia's per-model `ModelCapabilities`.
    ///
    /// Starts from the existing name-based inference (which seeds sensible
    /// thinking-level defaults for Claude / DeepSeek) and then overlays the
    /// authoritative Models.dev flags. Modality data wins over name guesses;
    /// `tool_call` and `reasoning` only ever *add* capability so a curated
    /// `true` never silently disables a model the heuristic already trusted.
    func capabilities() -> ModelCapabilities {
        var caps = ModelCapabilities.inferred(from: id)

        if modalities != nil {
            caps.supportsVision = supportsImageInput || supportsVideoInput
            caps.supportsVideoInput = supportsVideoInput
            if generatesImages {
                // Models.dev doesn't distinguish chat-inline vs dedicated image
                // APIs; inline is the common case for chat-capable image models
                // and matches how the name-based heuristic treats Gemini image.
                if caps.imageGenerationMode == .none {
                    caps.imageGenerationMode = .chatInline
                }
            }
        }

        if let toolCall {
            caps.supportsToolUse = toolCall
        }

        // Reasoning support is additive: if Models.dev says the model reasons
        // but the heuristic left thinking off, default it to a modest level.
        if reasoning == true, !caps.thinkingLevel.isEnabled,
           caps.imageGenerationMode == .none, !caps.supportsVideoGeneration {
            caps.thinkingLevel = .medium
            caps.supportsReasoning = true
        }

        return caps
    }
}

/// Maps a Models.dev provider onto Palvia's endpoint + `APIStyle`.
///
/// Models.dev frequently omits the base `api` URL for first-party providers and
/// never speaks Palvia's `APIStyle` vocabulary, so we keep a small curated table
/// for the providers users actually reach for, and fall back to the catalog's
/// own `api`/`npm` fields for the long tail.
enum ModelsDevMapping {
    /// Curated endpoint + protocol for well-known providers, keyed by Models.dev
    /// id. These mirror the hand-built presets in `LLMProviderEditView` so a
    /// catalog import lands on exactly the same configuration.
    static let known: [String: (endpoint: String, apiStyle: APIStyle)] = [
        "openai": ("https://api.openai.com/v1", .openAIResponses),
        "anthropic": ("https://api.anthropic.com/v1", .anthropic),
        "deepseek": ("https://api.deepseek.com/v1", .openAI),
        "openrouter": ("https://openrouter.ai/api/v1", .openAI),
        "google": ("https://generativelanguage.googleapis.com/v1beta/openai", .openAI),
        "xai": ("https://api.x.ai/v1", .openAI),
        "mistral": ("https://api.mistral.ai/v1", .openAI),
        "groq": ("https://api.groq.com/openai/v1", .openAI),
        "togetherai": ("https://api.together.xyz/v1", .openAI),
        "fireworks-ai": ("https://api.fireworks.ai/inference/v1", .openAI),
        "cerebras": ("https://api.cerebras.ai/v1", .openAI),
        "perplexity": ("https://api.perplexity.ai", .openAI),
        "moonshotai": ("https://api.moonshot.ai/v1", .openAI),
        "zhipuai": ("https://open.bigmodel.cn/api/paas/v4", .openAI),
    ]

    /// Resolve the API protocol for a provider: curated table first, then an
    /// npm-based guess (anything Anthropic-flavoured), else OpenAI-compatible —
    /// the broadest fit for the OpenAI-compatible gateways that dominate the
    /// catalog.
    static func apiStyle(for provider: ModelsDevProvider) -> APIStyle {
        if let known = known[provider.id]?.apiStyle { return known }
        if let npm = provider.npm?.lowercased(), npm.contains("anthropic") {
            return .anthropic
        }
        return .openAI
    }

    /// Resolve the endpoint for a provider: curated table first, then the
    /// catalog's own `api` field, else empty (the user fills it in).
    static func endpoint(for provider: ModelsDevProvider) -> String {
        if let known = known[provider.id]?.endpoint { return known }
        if let api = provider.api, !api.isEmpty {
            return api.hasSuffix("/") ? String(api.dropLast()) : api
        }
        return ""
    }

    /// Whether this provider can be imported as a ready-to-use LLM provider
    /// (i.e. we know — or the catalog tells us — where to send requests).
    static func hasEndpoint(for provider: ModelsDevProvider) -> Bool {
        !endpoint(for: provider).isEmpty
    }
}
