import SwiftUI

struct LLMProviderEditView: View {
    let viewModel: SettingsViewModel
    var existingProvider: LLMProvider?

    @Environment(\.dismiss) private var dismiss

    @State private var name: String = ""
    @State private var endpoint: String = "https://api.openai.com/v1"
    @State private var apiKey: String = ""
    @State private var modelName: String = "gpt-5.4"
    @State private var maxTokens: Int = 4096
    @State private var temperature: Double = 0.7
    @State private var apiStyle: APIStyle = .openAI
    @State private var providerType: ProviderType = .llm

    // Per-model capabilities
    @State private var modelCapabilities: [String: ModelCapabilities] = [:]

    @State private var fetchedModels: [String] = []
    @State private var enabledModels: Set<String> = []
    @State private var isFetchingModels = false
    @State private var fetchError: String?

    @State private var showAddModel = false
    @State private var newModelName: String = ""

    @State private var showModelsDevCatalog = false

    // Connection test state
    @State private var isTestingConnection = false
    @State private var connectionTestResult: ConnectionTestResult?

    enum ConnectionTestResult {
        case success(modelCount: Int)
        case failure(String)
    }

    private var isEditing: Bool { existingProvider != nil }

    /// Only show enabled models in pickers.
    private var allKnownModels: [String] {
        Array(enabledModels).sorted()
    }

    var body: some View {
        NavigationStack {
            Form {
                providerTypeSection
                presetsSection
                providerSection
                apiStyleSection
                authSection
                connectionTestSection
                defaultModelSection
                enabledModelsSection
                if providerType == .llm {
                    remoteModelsSection
                    parametersSection
                }
            }
            .navigationTitle(isEditing ? L10n.Provider.editProvider : L10n.Provider.addProvider)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L10n.Common.cancel) { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(L10n.Common.save) {
                        save()
                        dismiss()
                    }
                    .disabled(name.isEmpty || endpoint.isEmpty || modelName.isEmpty)
                }
            }
            .alert(L10n.Provider.addModel, isPresented: $showAddModel) {
                TextField(L10n.Provider.modelNamePlaceholder, text: $newModelName)
                    .autocapitalization(.none)
                Button(L10n.Common.add) {
                    let trimmed = newModelName.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !trimmed.isEmpty {
                        enableModel(trimmed)
                    }
                    newModelName = ""
                }
                Button(L10n.Common.cancel, role: .cancel) { newModelName = "" }
            }
            .sheet(isPresented: $showModelsDevCatalog) {
                ModelsDevCatalogView(onImport: applyModelsDevImport)
            }
        }
        .onAppear {
            if let p = existingProvider {
                name = p.name
                endpoint = p.endpoint
                apiKey = p.apiKey
                modelName = p.modelName
                maxTokens = p.maxTokens
                temperature = p.temperature
                apiStyle = APIStyle(rawValue: p.apiStyleRaw) ?? .openAI
                providerType = ProviderType(rawValue: p.providerTypeRaw) ?? .llm
                enabledModels = Set(p.enabledModels)
                fetchedModels = p.cachedModelList

                // Load model capabilities from raw JSON
                if let json = p.modelCapabilitiesJSON,
                   let data = json.data(using: .utf8),
                   let dict = try? JSONDecoder().decode([String: ModelCapabilities].self, from: data) {
                    modelCapabilities = dict
                }

                // Auto-infer capabilities for models without explicit entries
                for model in p.enabledModels where modelCapabilities[model] == nil {
                    modelCapabilities[model] = ModelCapabilities.inferred(from: model)
                }
            } else {
                enableModel(modelName)
            }
        }
    }

    // MARK: - Sections

    private var providerTypeSection: some View {
        Section {
            Picker(L10n.Provider.providerType, selection: $providerType) {
                ForEach(ProviderType.allCases, id: \.self) { type in
                    Text(type.displayName).tag(type)
                }
            }
        } footer: {
            Text(L10n.Provider.providerTypeFooter)
        }
    }

    private var providerSection: some View {
        Section(L10n.Provider.provider) {
            TextField(L10n.Common.name, text: $name)
            TextField(L10n.Provider.endpoint, text: $endpoint)
                .textContentType(.URL)
                .autocapitalization(.none)
                .keyboardType(.URL)
        }
    }

    /// API style cases filtered by current provider type.
    private var relevantAPIStyles: [APIStyle] {
        switch providerType {
        case .llm: return APIStyle.llmCases
        case .imageOnly: return APIStyle.imageCases
        case .videoOnly: return APIStyle.videoCases
        }
    }

    /// Valid ImageGenMode options based on current apiStyle and providerType.
    /// - DashScope apiStyle: only `.dashScope`
    /// - Image-only providers: exclude `.none` (they must generate images)
    /// - LLM providers: all modes
    private var relevantImageGenModes: [ImageGenMode] {
        if apiStyle == .dashScope {
            return [.dashScope]
        }
        if providerType == .imageOnly {
            return ImageGenMode.allCases.filter { $0 != .none && $0 != .dashScope }
        }
        return ImageGenMode.allCases.filter { $0 != .dashScope }
    }

    private var apiStyleSection: some View {
        Section {
            Picker(L10n.Provider.apiStyle, selection: $apiStyle) {
                ForEach(relevantAPIStyles, id: \.self) { style in
                    Text(style.displayName).tag(style)
                }
            }
        } header: {
            Text(L10n.Provider.apiStyle)
        } footer: {
            Text(L10n.Provider.apiStyleFooter)
        }
    }

    private var authSection: some View {
        Section(L10n.Provider.authentication) {
            SecureField(L10n.Provider.apiKey, text: $apiKey)
                .autocapitalization(.none)
        }
    }

    private var connectionTestSection: some View {
        Section {
            HStack {
                Button {
                    testConnection()
                } label: {
                    HStack(spacing: 6) {
                        if isTestingConnection {
                            ProgressView()
                                .controlSize(.small)
                        } else {
                            Image(systemName: "bolt.horizontal")
                        }
                        Text(L10n.Provider.testConnection)
                    }
                }
                .disabled(endpoint.isEmpty || isTestingConnection)

                Spacer()

                if let result = connectionTestResult {
                    switch result {
                    case .success(let count):
                        HStack(spacing: 4) {
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundStyle(.green)
                            Text(count > 0 ? L10n.Provider.testConnectionSuccess(count) : L10n.Provider.testConnectionOK)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    case .failure(let msg):
                        HStack(spacing: 4) {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundStyle(.red)
                            Text(msg)
                                .font(.caption)
                                .foregroundStyle(.red)
                                .lineLimit(1)
                        }
                    }
                }
            }
        }
    }

    private func testConnection() {
        isTestingConnection = true
        connectionTestResult = nil

        Task {
            do {
                let models = try await LLMService.fetchModels(
                    endpoint: endpoint,
                    apiKey: apiKey,
                    apiStyle: apiStyle
                )
                await MainActor.run {
                    connectionTestResult = .success(modelCount: models.count)
                    isTestingConnection = false
                }
            } catch {
                await MainActor.run {
                    let msg = if let apiErr = error as? LLMError,
                                 case .apiError(let code, _) = apiErr {
                        "HTTP \(code)"
                    } else {
                        error.localizedDescription
                    }
                    connectionTestResult = .failure(String(msg.prefix(40)))
                    isTestingConnection = false
                }
            }
        }
    }

    private var defaultModelSection: some View {
        Section {
            HStack {
                TextField(L10n.Provider.defaultModel, text: $modelName)
                    .autocapitalization(.none)
                if !allKnownModels.isEmpty {
                    Menu {
                        ForEach(allKnownModels, id: \.self) { model in
                            Button(model) {
                                modelName = model
                                enableModel(model)
                            }
                        }
                    } label: {
                        Image(systemName: "chevron.up.chevron.down")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        } header: {
            Text(L10n.Provider.defaultModel)
        } footer: {
            Text(L10n.Provider.defaultModelFooter)
        }
    }

    private var enabledModelsSection: some View {
        Section {
            if enabledModels.isEmpty {
                Text(L10n.Provider.noModelsEnabled)
                    .foregroundStyle(.secondary)
                    .font(.subheadline)
            } else {
                ForEach(Array(enabledModels).sorted(), id: \.self) { model in
                    modelRow(model)
                }
            }

            Button {
                showAddModel = true
            } label: {
                Label(L10n.Provider.manuallyAddModel, systemImage: "plus")
            }
        } header: {
            HStack {
                Text(L10n.Provider.enabledModels)
                Spacer()
                Text("\(enabledModels.count)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        } footer: {
            Text(L10n.Provider.enabledModelsFooter)
        }
    }

    /// Inline model row with expandable capabilities toggles.
    /// Toggles shown depend on provider type — media-only providers hide irrelevant LLM toggles.
    @ViewBuilder
    private func modelRow(_ model: String) -> some View {
        DisclosureGroup {
            let binding = capabilitiesBinding(for: model)
            switch providerType {
            case .llm:
                Toggle(L10n.Provider.supportsVision, isOn: binding.supportsVision)
                Toggle(L10n.Provider.supportsVideoInput, isOn: binding.supportsVideoInput)
                Toggle(L10n.Provider.supportsToolUse, isOn: binding.supportsToolUse)
                Picker(L10n.Provider.supportsImageGeneration, selection: binding.imageGenerationMode) {
                    ForEach(relevantImageGenModes, id: \.self) { mode in
                        Text(mode.displayName).tag(mode)
                    }
                }
                Picker(L10n.Provider.thinkingLevel, selection: thinkingLevelBinding(for: model)) {
                    ForEach(ThinkingLevel.cases(for: model, apiStyle: apiStyle), id: \.self) { level in
                        if let req = level.modelRequirement(for: apiStyle) {
                            HStack(spacing: 4) {
                                Text(level.displayName)
                                Text(req)
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                            .tag(level)
                        } else {
                            Text(level.displayName).tag(level)
                        }
                    }
                }
                .onChange(of: apiStyle) { _, newStyle in
                    clampThinkingLevelIfUnsupported(for: model, apiStyle: newStyle)
                }
                perModelParametersView(for: model)
            case .imageOnly:
                Picker(L10n.Provider.supportsImageGeneration, selection: binding.imageGenerationMode) {
                    ForEach(relevantImageGenModes, id: \.self) { mode in
                        Text(mode.displayName).tag(mode)
                    }
                }
            case .videoOnly:
                Toggle(L10n.Provider.supportsVideoGeneration, isOn: binding.supportsVideoGeneration)
            }
        } label: {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(model)
                        .font(.subheadline)
                    if model == modelName {
                        Text(L10n.Common.defaultLabel)
                            .font(.caption2)
                            .foregroundStyle(.blue)
                    }
                    HStack(spacing: 4) {
                        let c = modelCapabilities[model] ?? .default
                        if providerType == .llm {
                            if c.supportsVision { capBadge("eye", color: .green) }
                            if c.supportsVideoInput { capBadge("video", color: .green) }
                            if c.supportsToolUse { capBadge("wrench", color: .blue) }
                            if c.thinkingLevel.isEnabled { thinkingLevelBadge(c.thinkingLevel) }
                        }
                        if c.imageGenerationMode == .chatInline { capBadge("paintbrush", color: .orange) }
                        if c.imageGenerationMode == .dedicatedAPI { capBadge("photo", color: .orange) }
                        if c.imageGenerationMode == .dashScope { capBadge("photo", color: .orange) }
                        if c.supportsVideoGeneration { capBadge("film", color: .purple) }
                    }
                }
                Spacer()
                if model == modelName {
                    Image(systemName: "star.fill")
                        .font(.caption)
                        .foregroundStyle(.yellow)
                }
            }
        }
        .swipeActions(edge: .trailing) {
            if model != modelName {
                Button(role: .destructive) {
                    enabledModels.remove(model)
                    modelCapabilities.removeValue(forKey: model)
                } label: {
                    Label(L10n.Common.disable, systemImage: "xmark")
                }
            }
        }
        .swipeActions(edge: .leading) {
            if model != modelName {
                Button(L10n.Provider.setDefault) {
                    modelName = model
                }
                .tint(.blue)
            }
        }
        .contextMenu {
            if model != modelName {
                Button {
                    modelName = model
                } label: {
                    Label(L10n.Provider.setDefault, systemImage: "star")
                }
                Button(role: .destructive) {
                    enabledModels.remove(model)
                    modelCapabilities.removeValue(forKey: model)
                } label: {
                    Label(L10n.Common.disable, systemImage: "xmark")
                }
            }
        }
    }

    /// Create individual Bool bindings for each capability field of a model.
    private func capabilitiesBinding(for model: String) -> CapabilitiesBindings {
        CapabilitiesBindings(
            supportsVision: Binding(
                get: { (modelCapabilities[model] ?? .default).supportsVision },
                set: { newVal in
                    var caps = modelCapabilities[model] ?? .default
                    caps.supportsVision = newVal
                    modelCapabilities[model] = caps
                }
            ),
            supportsVideoInput: Binding(
                get: { (modelCapabilities[model] ?? .default).supportsVideoInput },
                set: { newVal in
                    var caps = modelCapabilities[model] ?? .default
                    caps.supportsVideoInput = newVal
                    modelCapabilities[model] = caps
                }
            ),
            supportsToolUse: Binding(
                get: { (modelCapabilities[model] ?? .default).supportsToolUse },
                set: { newVal in
                    var caps = modelCapabilities[model] ?? .default
                    caps.supportsToolUse = newVal
                    modelCapabilities[model] = caps
                }
            ),
            imageGenerationMode: Binding(
                get: { (modelCapabilities[model] ?? .default).imageGenerationMode },
                set: { newVal in
                    var caps = modelCapabilities[model] ?? .default
                    caps.imageGenerationMode = newVal
                    modelCapabilities[model] = caps
                }
            ),
            supportsVideoGeneration: Binding(
                get: { (modelCapabilities[model] ?? .default).supportsVideoGeneration },
                set: { newVal in
                    var caps = modelCapabilities[model] ?? .default
                    caps.supportsVideoGeneration = newVal
                    modelCapabilities[model] = caps
                }
            )
        )
    }

    /// ThinkingLevel binding for a specific model.
    private func thinkingLevelBinding(for model: String) -> Binding<ThinkingLevel> {
        Binding(
            get: { (modelCapabilities[model] ?? .default).thinkingLevel },
            set: { newVal in
                var caps = modelCapabilities[model] ?? .default
                caps.thinkingLevel = newVal
                // Keep legacy flag in sync
                caps.supportsReasoning = newVal.isEnabled
                modelCapabilities[model] = caps
            }
        )
    }

    /// If the persisted thinking level for `model` falls outside the
    /// allowed set under `apiStyle` (e.g. user flipped a Claude provider
    /// from Anthropic to OpenAI dialect), clamp to the highest level still
    /// supported. Mutates state — only call when the user has explicitly
    /// re-targeted the row's binding to a different `apiStyle`.
    private func clampThinkingLevelIfUnsupported(for model: String, apiStyle: APIStyle) {
        let allowed = ThinkingLevel.cases(for: model, apiStyle: apiStyle)
        let current = (modelCapabilities[model] ?? .default).thinkingLevel
        guard !allowed.contains(current) else { return }
        let target = allowed.last ?? .high
        var caps = modelCapabilities[model] ?? .default
        caps.thinkingLevel = target
        caps.supportsReasoning = target.isEnabled
        modelCapabilities[model] = caps
    }

    @ViewBuilder
    private func capBadge(_ systemName: String, color: Color) -> some View {
        Image(systemName: systemName)
            .font(.system(size: 9))
            .foregroundStyle(color)
            .padding(3)
            .background(color.opacity(0.1), in: Circle())
    }

    @ViewBuilder
    private func thinkingLevelBadge(_ level: ThinkingLevel) -> some View {
        HStack(spacing: 1) {
            Image(systemName: "brain")
                .font(.system(size: 9))
            // `shortLabel` disambiguates Medium ("Me") from Max ("Mx") and
            // Extra High ("XH") from High ("H") — `displayName.prefix(1)`
            // collapsed both pairs to the same letter.
            Text(level.shortLabel)
                .font(.system(size: 7, weight: .bold))
        }
        .foregroundStyle(.purple)
        .padding(.horizontal, 4)
        .padding(.vertical, 3)
        .background(.purple.opacity(0.1), in: Capsule())
    }

    /// Per-model maxTokens / temperature overrides (nil = use provider default).
    @ViewBuilder
    private func perModelParametersView(for model: String) -> some View {
        let caps = modelCapabilities[model] ?? .default
        let hasMaxTokensOverride = caps.maxTokens != nil
        let hasTempOverride = caps.temperature != nil

        // Max Tokens override
        HStack {
            Toggle(isOn: Binding(
                get: { hasMaxTokensOverride },
                set: { enabled in
                    var c = modelCapabilities[model] ?? .default
                    c.maxTokens = enabled ? maxTokens : nil
                    modelCapabilities[model] = c
                }
            )) {
                Text(L10n.Provider.perModelMaxTokens)
            }
        }
        if hasMaxTokensOverride {
            Stepper(
                L10n.Provider.maxTokens(caps.maxTokens ?? maxTokens),
                value: Binding(
                    get: { caps.maxTokens ?? maxTokens },
                    set: { newVal in
                        var c = modelCapabilities[model] ?? .default
                        c.maxTokens = newVal
                        modelCapabilities[model] = c
                    }
                ),
                in: 256...128000,
                step: 256
            )
        }

        // Temperature override
        HStack {
            Toggle(isOn: Binding(
                get: { hasTempOverride },
                set: { enabled in
                    var c = modelCapabilities[model] ?? .default
                    c.temperature = enabled ? temperature : nil
                    modelCapabilities[model] = c
                }
            )) {
                Text(L10n.Provider.perModelTemperature)
            }
        }
        if hasTempOverride {
            HStack {
                Text("\(caps.temperature ?? temperature, specifier: "%.2f")")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(width: 36, alignment: .trailing)
                Slider(
                    value: Binding(
                        get: { caps.temperature ?? temperature },
                        set: { newVal in
                            var c = modelCapabilities[model] ?? .default
                            c.temperature = newVal
                            modelCapabilities[model] = c
                        }
                    ),
                    in: 0...2,
                    step: 0.05
                )
            }
        }
    }

    private var remoteModelsSection: some View {
        Section {
            Button {
                fetchModels()
            } label: {
                HStack {
                    Label(L10n.Provider.fetchFromAPI, systemImage: "arrow.triangle.2.circlepath")
                    Spacer()
                    if isFetchingModels {
                        ProgressView()
                            .controlSize(.small)
                    }
                }
            }
            .disabled(endpoint.isEmpty || isFetchingModels)

            if let error = fetchError {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
            }

            if let cachedDate = existingProvider?.cachedModelListDate {
                Text("Last fetched: \(cachedDate, style: .relative) ago")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }

            if !fetchedModels.isEmpty {
                let notEnabled = fetchedModels.filter { !enabledModels.contains($0) }
                if !notEnabled.isEmpty {
                    DisclosureGroup(L10n.Provider.availableToEnable(notEnabled.count)) {
                        ForEach(notEnabled, id: \.self) { model in
                            HStack {
                                Text(model)
                                    .font(.subheadline)
                                Spacer()
                                Button {
                                    enableModel(model)
                                } label: {
                                    Image(systemName: "plus.circle.fill")
                                        .foregroundStyle(.green)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                } else {
                    Text(L10n.Provider.allModelsEnabled(fetchedModels.count))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Button(L10n.Provider.enableAll) {
                    for m in fetchedModels {
                        enableModel(m)
                    }
                }
                .font(.subheadline)
            }
        } header: {
            Text(L10n.Provider.remoteModels)
        } footer: {
            Text(L10n.Provider.remoteModelsFooter)
        }
    }

    private var anyModelHasThinking: Bool {
        modelCapabilities.values.contains { $0.thinkingLevel.isEnabled }
    }

    private var parametersSection: some View {
        Section {
            Stepper(L10n.Provider.maxTokens(maxTokens), value: $maxTokens, in: 256...128000, step: 256)
            HStack {
                Text(L10n.Provider.temperature(temperature))
                Slider(value: $temperature, in: 0...2, step: 0.05)
            }
        } header: {
            Text(L10n.Provider.parameters)
        } footer: {
            Text(L10n.Provider.parametersFooter)
        }
    }

    private var presetsSection: some View {
        Section {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    switch providerType {
                    case .llm: llmPresetChips
                    case .imageOnly: imagePresetChips
                    case .videoOnly: videoPresetChips
                    }
                }
                .padding(.vertical, 4)
            }
        } header: {
            Text(L10n.Provider.presets)
        }
    }

    private func presetChip(_ label: String, icon: String? = nil, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 4) {
                if let icon {
                    Image(systemName: icon)
                        .font(.system(size: 11))
                }
                Text(label)
                    .font(.subheadline.weight(.medium))
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .background(.blue.opacity(0.1), in: Capsule())
            .foregroundStyle(.blue)
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private var llmPresetChips: some View {
        presetChip(L10n.Provider.modelsDevBrowse, icon: "square.grid.2x2") {
            showModelsDevCatalog = true
        }
        presetChip("OpenAI") {
            name = name.isEmpty ? "OpenAI" : name
            endpoint = "https://api.openai.com/v1"
            modelName = "gpt-5.4"
            apiStyle = .openAIResponses
            enableModel("gpt-5.4")
        }
        presetChip("Anthropic") {
            name = name.isEmpty ? "Anthropic" : name
            endpoint = "https://api.anthropic.com/v1"
            modelName = "claude-sonnet-4-6"
            apiStyle = .anthropic
            enableModel("claude-sonnet-4-6")
            modelCapabilities["claude-sonnet-4-6"]?.thinkingLevel = .medium
            modelCapabilities["claude-sonnet-4-6"]?.supportsReasoning = true
            // Also enable Opus 4.7 — adaptive thinking, .high default
            // (xhigh would be a deliberate cost opt-in by the user).
            enableModel("claude-opus-4-7")
            modelCapabilities["claude-opus-4-7"]?.thinkingLevel = .high
            modelCapabilities["claude-opus-4-7"]?.supportsReasoning = true
        }
        presetChip("DeepSeek") {
            name = name.isEmpty ? "DeepSeek" : name
            endpoint = "https://api.deepseek.com/v1"
            modelName = "deepseek-v4-pro"
            apiStyle = .openAI
            enableModel("deepseek-v4-flash")
            enableModel("deepseek-v4-pro")
            for model in ["deepseek-v4-flash", "deepseek-v4-pro"] {
                modelCapabilities[model]?.thinkingLevel = .high
                modelCapabilities[model]?.supportsReasoning = true
            }
        }
        presetChip("OpenRouter") {
            name = name.isEmpty ? "OpenRouter" : name
            endpoint = "https://openrouter.ai/api/v1"
            modelName = "anthropic/claude-sonnet-4.6"
            apiStyle = .openAI
            enableModel("anthropic/claude-sonnet-4.6")
            enableModel("openai/gpt-5.4")
        }
        presetChip("Ollama", icon: "desktopcomputer") {
            name = name.isEmpty ? "Ollama" : name
            endpoint = "http://localhost:11434/v1"
            modelName = "llama3"
            apiKey = "ollama"
            apiStyle = .openAI
            enableModel("llama3")
        }
    }

    @ViewBuilder
    private var videoPresetChips: some View {
        presetChip("Kling") {
            name = name.isEmpty ? "Kling" : name
            endpoint = "https://api.klingai.com"
            apiStyle = .kling
            modelName = "kling-v2"
            enableVideoModel("kling-v2")
        }
        presetChip("DashScope") {
            name = name.isEmpty ? "DashScope" : name
            endpoint = "https://dashscope.aliyuncs.com/api/v1"
            apiStyle = .dashScope
            modelName = "wan2.6-t2v"
            enableVideoModel("wan2.6-t2v")
            enableVideoModel("wan2.6-i2v")
        }
        presetChip("Google Veo") {
            name = name.isEmpty ? "Google Veo" : name
            endpoint = "https://generativelanguage.googleapis.com/v1beta"
            apiStyle = .googleVeo
            modelName = "veo-3"
            enableVideoModel("veo-3")
        }
        presetChip("Sora") {
            name = name.isEmpty ? "OpenAI Sora" : name
            endpoint = "https://api.openai.com/v1"
            apiStyle = .openAI
            modelName = "sora-2"
            enableVideoModel("sora-2")
        }
        presetChip("Seedance") {
            name = name.isEmpty ? "Seedance" : name
            endpoint = "https://ark.cn-beijing.volces.com/api/v3"
            apiStyle = .seedance
            modelName = "doubao-seedance-2-0"
            enableVideoModel("doubao-seedance-2-0")
        }
    }

    @ViewBuilder
    private var imagePresetChips: some View {
        presetChip("OpenAI") {
            name = name.isEmpty ? "OpenAI Image" : name
            endpoint = "https://api.openai.com/v1"
            modelName = "gpt-image-1"
            enableImageModel("gpt-image-1", mode: .dedicatedAPI)
            enableImageModel("dall-e-3", mode: .dedicatedAPI)
        }
        presetChip("Gemini Imagen") {
            name = name.isEmpty ? "Google Imagen" : name
            endpoint = "https://generativelanguage.googleapis.com/v1beta"
            modelName = "gemini-2.0-flash-preview-image-generation"
            enableImageModel("gemini-2.0-flash-preview-image-generation", mode: .chatInline)
        }
        presetChip("Seedream") {
            name = name.isEmpty ? "Seedream" : name
            endpoint = "https://ark.cn-beijing.volces.com/api/v3"
            modelName = "doubao-seedream-4.5"
            enableImageModel("doubao-seedream-4.5", mode: .dedicatedAPI)
        }
        presetChip("DashScope") {
            name = name.isEmpty ? "DashScope Image" : name
            endpoint = "https://dashscope.aliyuncs.com/api/v1"
            apiStyle = .dashScope
            modelName = "wan2.7-image-pro"
            enableImageModel("wan2.7-image-pro", mode: .dashScope)
            enableImageModel("wan2.7-image", mode: .dashScope)
        }
        presetChip("Flux") {
            name = name.isEmpty ? "Flux" : name
            endpoint = "https://api.us1.bfl.ai/v1"
            modelName = "flux-pro-1.1"
            enableImageModel("flux-pro-1.1", mode: .dedicatedAPI)
        }
        presetChip("Stable Diffusion") {
            name = name.isEmpty ? "Stable Diffusion" : name
            endpoint = "https://api.stability.ai/v1"
            modelName = "sd3-medium"
            enableImageModel("sd3-medium", mode: .dedicatedAPI)
        }
    }

    /// Enable a model with image generation capability pre-configured.
    private func enableImageModel(_ model: String, mode: ImageGenMode) {
        enabledModels.insert(model)
        var caps = modelCapabilities[model] ?? ModelCapabilities.inferred(from: model)
        caps.imageGenerationMode = mode
        caps.supportsToolUse = false
        modelCapabilities[model] = caps
    }

    /// Enable a model with video generation capability pre-configured.
    private func enableVideoModel(_ model: String) {
        enabledModels.insert(model)
        var caps = modelCapabilities[model] ?? ModelCapabilities.inferred(from: model)
        caps.supportsVideoGeneration = true
        caps.supportsToolUse = false
        modelCapabilities[model] = caps
    }

    // MARK: - Actions

    /// Insert model into enabled set and auto-infer capabilities if not already configured.
    private func enableModel(_ model: String) {
        enabledModels.insert(model)
        if modelCapabilities[model] == nil {
            modelCapabilities[model] = ModelCapabilities.inferred(from: model)
        }
    }

    /// Apply a provider imported from the Models.dev catalog. Fills in name
    /// (only when blank, to respect a name the user already typed), endpoint,
    /// and API protocol, then enables each selected model with its catalog-
    /// inferred capabilities and promotes the first selection to default.
    private func applyModelsDevImport(_ result: ModelsDevImport) {
        if name.trimmingCharacters(in: .whitespaces).isEmpty {
            name = result.providerName
        }
        if !result.endpoint.isEmpty {
            endpoint = result.endpoint
        }
        apiStyle = result.apiStyle

        for (model, caps) in result.models {
            enabledModels.insert(model)
            modelCapabilities[model] = caps
        }
        if !result.defaultModel.isEmpty {
            modelName = result.defaultModel
            enableModel(result.defaultModel)
        }
    }

    private func save() {
        enableModel(modelName)

        // Encode capabilities JSON directly to avoid computed property setter issues with SwiftData
        let capsJSON: String? = {
            guard !modelCapabilities.isEmpty,
                  let data = try? JSONEncoder().encode(modelCapabilities),
                  let json = String(data: data, encoding: .utf8)
            else { return nil }
            return json
        }()

        if let p = existingProvider {
            p.name = name
            p.endpoint = endpoint
            p.apiKey = apiKey
            p.modelName = modelName
            p.maxTokens = maxTokens
            p.temperature = temperature
            // Write raw stored properties directly (not through computed setters)
            p.apiStyleRaw = apiStyle.rawValue
            p.providerTypeRaw = providerType.rawValue
            p.modelCapabilitiesJSON = capsJSON
            p.enabledModels = Array(enabledModels)
            p.cachedModelList = fetchedModels

            viewModel.updateProvider(p)
        } else {
            let provider = LLMProvider(
                name: name,
                endpoint: endpoint,
                apiKey: apiKey,
                modelName: modelName,
                isDefault: viewModel.providers.isEmpty,
                maxTokens: maxTokens,
                temperature: temperature
            )
            // Write raw stored properties directly
            provider.apiStyleRaw = apiStyle.rawValue
            provider.providerTypeRaw = providerType.rawValue
            provider.modelCapabilitiesJSON = capsJSON

            provider.enabledModels = Array(enabledModels)
            provider.cachedModelList = fetchedModels
            viewModel.addProviderDirectly(provider)
        }
    }

    private func fetchModels() {
        isFetchingModels = true
        fetchError = nil

        Task {
            do {
                let models = try await LLMService.fetchModels(
                    endpoint: endpoint,
                    apiKey: apiKey,
                    apiStyle: apiStyle
                )
                await MainActor.run {
                    fetchedModels = models
                    enableModel(modelName)
                    isFetchingModels = false

                    if let p = existingProvider {
                        p.cachedModelList = models
                        p.cachedModelListDate = Date()
                        try? viewModel.modelContext.save()
                    }
                }
            } catch {
                await MainActor.run {
                    fetchError = error.localizedDescription
                    isFetchingModels = false
                }
            }
        }
    }
}

/// Helper to bundle multiple Bool bindings for model capabilities.
private struct CapabilitiesBindings {
    let supportsVision: Binding<Bool>
    let supportsVideoInput: Binding<Bool>
    let supportsToolUse: Binding<Bool>
    let imageGenerationMode: Binding<ImageGenMode>
    let supportsVideoGeneration: Binding<Bool>
}
