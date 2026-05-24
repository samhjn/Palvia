import SwiftUI
import SwiftData

/// Represents a provider + specific model combination for selection.
struct ProviderModel: Identifiable, Hashable {
    let provider: LLMProvider
    let modelName: String

    var id: String { "\(provider.id.uuidString):\(modelName)" }
    var displayName: String { "\(provider.name) — \(modelName)" }
    var isDefault: Bool { modelName == provider.modelName }

    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }

    static func == (lhs: ProviderModel, rhs: ProviderModel) -> Bool {
        lhs.id == rhs.id
    }
}

struct AgentModelConfigView: View {
    @Bindable var agent: Agent
    @Environment(\.modelContext) private var modelContext
    /// Providers are loaded into @State instead of @Query so that
    /// external saves (e.g. provider deletion on the Settings tab)
    /// don't auto-fire a complex multi-section List batch update
    /// while another List is mid-update → UICollectionView crash.
    @State private var allProviders: [LLMProvider] = []

    /// Only show models that are explicitly enabled by the user.
    private var allProviderModels: [ProviderModel] {
        allProviders.flatMap { provider in
            provider.enabledModels.map { model in
                ProviderModel(provider: provider, modelName: model)
            }
        }
    }

    /// Provider+model combos excluding media-only providers (for LLM pickers).
    private var llmProviderModels: [ProviderModel] {
        allProviderModels.filter { !$0.provider.isMediaOnly }
    }

    /// Group ProviderModels by provider for sectioned picker display.
    private func groupedByProvider(_ models: [ProviderModel]) -> [(provider: LLMProvider, models: [ProviderModel])] {
        var seen = Set<UUID>()
        var groups: [(provider: LLMProvider, models: [ProviderModel])] = []
        for pm in models {
            if !seen.contains(pm.provider.id) {
                seen.insert(pm.provider.id)
                let providerModels = models.filter { $0.provider.id == pm.provider.id }
                groups.append((provider: pm.provider, models: providerModels))
            }
        }
        return groups
    }

    /// Builds grouped picker options with provider sections.
    @ViewBuilder
    private func groupedPickerOptions(_ models: [ProviderModel]) -> some View {
        let groups = groupedByProvider(models)
        if groups.count <= 1 {
            // Single provider: no need for sections
            ForEach(models) { pm in
                Text(pm.modelName).tag(pm.id)
            }
        } else {
            ForEach(groups, id: \.provider.id) { group in
                Section(group.provider.name) {
                    ForEach(group.models) { pm in
                        Text(pm.modelName).tag(pm.id)
                    }
                }
            }
        }
    }

    private var hasWhitelist: Bool { !agent.allowedModelIds.isEmpty }
    private var whitelistSet: Set<String> { Set(agent.allowedModelIds) }

    private var isPrimaryBlockedByWhitelist: Bool {
        guard hasWhitelist, let pmId = resolvePrimaryModelId() else { return false }
        return !whitelistSet.contains(pmId)
    }

    private var isSubAgentBlockedByWhitelist: Bool {
        guard hasWhitelist, let smId = resolveSubAgentModelId() else { return false }
        return !whitelistSet.contains(smId)
    }

    var body: some View {
        List {
            primarySection
            thinkingLevelSection
            fallbackSection
            subAgentSection
            imageGenerationSection
            videoGenerationSection
            modelWhitelistSection
            compressionSection
            resolutionPreviewSection
        }
        .navigationTitle(L10n.ModelConfig.title)
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { refreshProviders() }
    }

    private func refreshProviders() {
        let descriptor = FetchDescriptor<LLMProvider>(sortBy: [SortDescriptor(\.name)])
        allProviders = (try? modelContext.fetch(descriptor)) ?? []
    }

    // MARK: - Primary model

    @ViewBuilder
    private var primarySection: some View {
        Section {
            Picker(L10n.ModelConfig.primaryModel, selection: primaryBinding) {
                Text(L10n.ModelConfig.globalDefault).tag("" as String)
                groupedPickerOptions(llmProviderModels)
            }
            if isPrimaryBlockedByWhitelist {
                whitelistWarningRow(
                    icon: "exclamationmark.triangle.fill",
                    color: .red,
                    text: L10n.ModelConfig.whitelistMissingPrimary
                )
            }
        } header: {
            Text(L10n.ModelConfig.primaryModel)
        } footer: {
            Text(L10n.ModelConfig.primaryModelFooter)
        }
    }

    private var primaryBinding: Binding<String> {
        Binding(
            get: {
                guard let pid = agent.primaryProviderId else { return "" }
                let modelOverride = agent.primaryModelNameOverride
                if let modelOverride {
                    return "\(pid.uuidString):\(modelOverride)"
                }
                if let provider = allProviders.first(where: { $0.id == pid }) {
                    return "\(pid.uuidString):\(provider.modelName)"
                }
                return ""
            },
            set: { newValue in
                if newValue.isEmpty {
                    agent.primaryProviderId = nil
                    agent.primaryModelNameOverride = nil
                } else {
                    let parts = newValue.split(separator: ":", maxSplits: 1)
                    if parts.count == 2, let uid = UUID(uuidString: String(parts[0])) {
                        let modelName = String(parts[1])
                        agent.primaryProviderId = uid
                        if let provider = allProviders.first(where: { $0.id == uid }),
                           modelName == provider.modelName {
                            agent.primaryModelNameOverride = nil
                        } else {
                            agent.primaryModelNameOverride = modelName
                        }
                    }
                }
                agent.updatedAt = Date()
                try? modelContext.save()
            }
        )
    }

    // MARK: - Thinking level override

    @ViewBuilder
    private var thinkingLevelSection: some View {
        // Agent overrides are model-agnostic (the model is chosen at chat
        // time and may even fall back). We always show all six levels and
        // rely on the runtime adapters to clamp `xhigh`/`max` when the
        // resolved primary model can't honour them. The xhigh/max rows
        // carry a localized suffix so the user understands when they may
        // clamp.
        let primaryStyle: APIStyle = primaryProviderForOverride()?.apiStyle ?? .anthropic
        Section {
            Picker(L10n.ModelConfig.thinkingLevel, selection: thinkingLevelBinding) {
                Text(L10n.ModelConfig.thinkingLevelUseModelDefault).tag("" as String)
                ForEach(ThinkingLevel.allCases, id: \.self) { level in
                    if let req = level.modelRequirement(for: primaryStyle) {
                        HStack(spacing: 4) {
                            Text(level.displayName)
                            Text(req)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                        .tag(level.rawValue)
                    } else {
                        Text(level.displayName).tag(level.rawValue)
                    }
                }
            }
        } header: {
            Text(L10n.ModelConfig.thinkingLevel)
        } footer: {
            Text(L10n.ModelConfig.thinkingLevelFooter)
        }
    }

    /// The provider whose dialect is used to phrase the requirement
    /// suffixes ("Opus 4.7 / DeepSeek v4" vs "DeepSeek v4 (else High)").
    private func primaryProviderForOverride() -> LLMProvider? {
        if let pid = agent.primaryProviderId,
           let provider = allProviders.first(where: { $0.id == pid }) {
            return provider
        }
        return allProviders.first(where: { $0.isDefault }) ?? allProviders.first
    }

    private var thinkingLevelBinding: Binding<String> {
        Binding(
            get: { agent.thinkingLevelOverride?.rawValue ?? "" },
            set: { newValue in
                agent.thinkingLevelOverride = newValue.isEmpty ? nil : ThinkingLevel(rawValue: newValue)
                agent.updatedAt = Date()
                try? modelContext.save()
            }
        )
    }

    // MARK: - Fallback chain

    @ViewBuilder
    private var fallbackSection: some View {
        Section {
            let chain = buildFallbackChain()
            if chain.isEmpty {
                Text(L10n.ModelConfig.noFallback)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(Array(chain.enumerated()), id: \.offset) { index, pm in
                    HStack {
                        Text("\(index + 1).")
                            .foregroundStyle(.secondary)
                            .frame(width: 24, alignment: .leading)
                        VStack(alignment: .leading) {
                            Text(pm.provider.name).font(.body)
                            Text(pm.modelName).font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button(role: .destructive) {
                            removeFallback(at: index)
                        } label: {
                            Image(systemName: "minus.circle.fill")
                                .foregroundStyle(.red)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .onMove { source, destination in
                    var ids = agent.fallbackProviderIds
                    var names = agent.fallbackModelNames
                    ids.move(fromOffsets: source, toOffset: destination)
                    while names.count < ids.count { names.append("") }
                    names.move(fromOffsets: source, toOffset: destination)
                    agent.fallbackProviderIds = ids
                    agent.fallbackModelNames = names
                    agent.updatedAt = Date()
                    try? modelContext.save()
                }
            }

            Menu {
                let groups = groupedByProvider(availableFallbackModels)
                if groups.count <= 1 {
                    ForEach(availableFallbackModels) { pm in
                        Button(pm.modelName) { addFallback(pm) }
                    }
                } else {
                    ForEach(groups, id: \.provider.id) { group in
                        Section(group.provider.name) {
                            ForEach(group.models) { pm in
                                Button(pm.modelName) { addFallback(pm) }
                            }
                        }
                    }
                }
            } label: {
                Label(L10n.ModelConfig.addFallback, systemImage: "plus.circle")
            }
            .disabled(availableFallbackModels.isEmpty)
        } header: {
            Text(L10n.ModelConfig.fallbackChain)
        } footer: {
            Text(L10n.ModelConfig.fallbackFooter)
        }
    }

    private func buildFallbackChain() -> [ProviderModel] {
        let ids = agent.fallbackProviderIds
        let names = agent.fallbackModelNames
        return ids.enumerated().compactMap { (i, uid) -> ProviderModel? in
            guard let p = allProviders.first(where: { $0.id == uid }) else { return nil }
            let modelName = i < names.count && !names[i].isEmpty ? names[i] : p.modelName
            return ProviderModel(provider: p, modelName: modelName)
        }
    }

    private var availableFallbackModels: [ProviderModel] {
        let existingIds = Set(buildFallbackChain().map(\.id))
        let primaryId = primaryBinding.wrappedValue
        return llmProviderModels.filter { pm in
            pm.id != primaryId && !existingIds.contains(pm.id)
        }
    }

    private func addFallback(_ pm: ProviderModel) {
        var ids = agent.fallbackProviderIds
        var names = agent.fallbackModelNames
        ids.append(pm.provider.id)
        while names.count < ids.count - 1 { names.append("") }
        names.append(pm.modelName == pm.provider.modelName ? "" : pm.modelName)
        agent.fallbackProviderIds = ids
        agent.fallbackModelNames = names
        agent.updatedAt = Date()
        try? modelContext.save()
    }

    private func removeFallback(at index: Int) {
        var ids = agent.fallbackProviderIds
        var names = agent.fallbackModelNames
        ids.remove(at: index)
        if index < names.count { names.remove(at: index) }
        agent.fallbackProviderIds = ids
        agent.fallbackModelNames = names
        agent.updatedAt = Date()
        try? modelContext.save()
    }

    // MARK: - Sub-agent model

    @ViewBuilder
    private var subAgentSection: some View {
        Section {
            Picker(L10n.ModelConfig.subAgentModel, selection: subAgentBinding) {
                Text(L10n.ModelConfig.inheritFromPrimary).tag("" as String)
                groupedPickerOptions(llmProviderModels)
            }
            if isSubAgentBlockedByWhitelist {
                whitelistWarningRow(
                    icon: "exclamationmark.triangle.fill",
                    color: .orange,
                    text: L10n.ModelConfig.whitelistMissingSubAgent
                )
            }
        } header: {
            Text(L10n.ModelConfig.subAgentDefault)
        } footer: {
            Text(L10n.ModelConfig.subAgentFooter)
        }
    }

    private var subAgentBinding: Binding<String> {
        Binding(
            get: {
                guard let sid = agent.subAgentProviderId else { return "" }
                let override = agent.subAgentModelNameOverride
                if let override {
                    return "\(sid.uuidString):\(override)"
                }
                if let provider = allProviders.first(where: { $0.id == sid }) {
                    return "\(sid.uuidString):\(provider.modelName)"
                }
                return ""
            },
            set: { newValue in
                if newValue.isEmpty {
                    agent.subAgentProviderId = nil
                    agent.subAgentModelNameOverride = nil
                } else {
                    let parts = newValue.split(separator: ":", maxSplits: 1)
                    if parts.count == 2, let uid = UUID(uuidString: String(parts[0])) {
                        let modelName = String(parts[1])
                        agent.subAgentProviderId = uid
                        if let provider = allProviders.first(where: { $0.id == uid }),
                           modelName == provider.modelName {
                            agent.subAgentModelNameOverride = nil
                        } else {
                            agent.subAgentModelNameOverride = modelName
                        }
                    }
                }
                agent.updatedAt = Date()
                try? modelContext.save()
            }
        )
    }

    // MARK: - Image Generation

    @ViewBuilder
    private var imageGenerationSection: some View {
        Section {
            Picker(L10n.ModelConfig.imageProvider, selection: imageProviderBinding) {
                Text(L10n.ModelConfig.imageProviderNone).tag("" as String)
                groupedPickerOptions(imageCapableProviderModels)
            }
        } header: {
            Text(L10n.ModelConfig.imageGenerationHeader)
        } footer: {
            Text(L10n.ModelConfig.imageProviderFooter)
        }
    }

    /// Provider+model combos that have image generation capabilities.
    private var imageCapableProviderModels: [ProviderModel] {
        allProviderModels.filter { pm in
            let caps = pm.provider.capabilities(for: pm.modelName)
            return caps.imageGenerationMode != .none
        }
    }

    private var imageProviderBinding: Binding<String> {
        Binding(
            get: {
                guard let pid = agent.imageProviderId else { return "" }
                let override = agent.imageModelNameOverride
                if let override {
                    return "\(pid.uuidString):\(override)"
                }
                if let provider = allProviders.first(where: { $0.id == pid }) {
                    return "\(pid.uuidString):\(provider.modelName)"
                }
                return ""
            },
            set: { newValue in
                if newValue.isEmpty {
                    agent.imageProviderId = nil
                    agent.imageModelNameOverride = nil
                } else {
                    let parts = newValue.split(separator: ":", maxSplits: 1)
                    if parts.count == 2, let uid = UUID(uuidString: String(parts[0])) {
                        let modelName = String(parts[1])
                        agent.imageProviderId = uid
                        if let provider = allProviders.first(where: { $0.id == uid }),
                           modelName == provider.modelName {
                            agent.imageModelNameOverride = nil
                        } else {
                            agent.imageModelNameOverride = modelName
                        }
                    }
                }
                agent.updatedAt = Date()
                try? modelContext.save()
            }
        )
    }

    // MARK: - Video Generation

    @ViewBuilder
    private var videoGenerationSection: some View {
        Section {
            Picker(L10n.ModelConfig.videoProvider, selection: videoProviderBinding) {
                Text(L10n.ModelConfig.videoProviderNone).tag("" as String)
                groupedPickerOptions(videoCapableProviderModels)
            }
            if agent.videoProviderId != nil {
                Picker(L10n.ModelConfig.i2vProvider, selection: i2vProviderBinding) {
                    Text(L10n.ModelConfig.i2vSameAsT2V).tag("" as String)
                    groupedPickerOptions(videoCapableProviderModels)
                }
            }
        } header: {
            Text(L10n.ModelConfig.videoGenerationHeader)
        } footer: {
            Text(L10n.ModelConfig.videoProviderFooter)
        }
    }

    /// Provider+model combos that have video generation capabilities.
    private var videoCapableProviderModels: [ProviderModel] {
        allProviderModels.filter { pm in
            let caps = pm.provider.capabilities(for: pm.modelName)
            return caps.supportsVideoGeneration
        }
    }

    private var videoProviderBinding: Binding<String> {
        Binding(
            get: {
                guard let pid = agent.videoProviderId else { return "" }
                let override = agent.videoModelNameOverride
                if let override {
                    return "\(pid.uuidString):\(override)"
                }
                if let provider = allProviders.first(where: { $0.id == pid }) {
                    return "\(pid.uuidString):\(provider.modelName)"
                }
                return ""
            },
            set: { newValue in
                if newValue.isEmpty {
                    agent.videoProviderId = nil
                    agent.videoModelNameOverride = nil
                    // Clear I2V when T2V is disabled
                    agent.i2vProviderId = nil
                    agent.i2vModelNameOverride = nil
                } else {
                    let parts = newValue.split(separator: ":", maxSplits: 1)
                    if parts.count == 2, let uid = UUID(uuidString: String(parts[0])) {
                        let modelName = String(parts[1])
                        agent.videoProviderId = uid
                        if let provider = allProviders.first(where: { $0.id == uid }),
                           modelName == provider.modelName {
                            agent.videoModelNameOverride = nil
                        } else {
                            agent.videoModelNameOverride = modelName
                        }
                    }
                }
                agent.updatedAt = Date()
                try? modelContext.save()
            }
        )
    }

    private var i2vProviderBinding: Binding<String> {
        Binding(
            get: {
                guard let pid = agent.i2vProviderId else { return "" }
                let override = agent.i2vModelNameOverride
                if let override {
                    return "\(pid.uuidString):\(override)"
                }
                if let provider = allProviders.first(where: { $0.id == pid }) {
                    return "\(pid.uuidString):\(provider.modelName)"
                }
                return ""
            },
            set: { newValue in
                if newValue.isEmpty {
                    agent.i2vProviderId = nil
                    agent.i2vModelNameOverride = nil
                } else {
                    let parts = newValue.split(separator: ":", maxSplits: 1)
                    if parts.count == 2, let uid = UUID(uuidString: String(parts[0])) {
                        let modelName = String(parts[1])
                        agent.i2vProviderId = uid
                        if let provider = allProviders.first(where: { $0.id == uid }),
                           modelName == provider.modelName {
                            agent.i2vModelNameOverride = nil
                        } else {
                            agent.i2vModelNameOverride = modelName
                        }
                    }
                }
                agent.updatedAt = Date()
                try? modelContext.save()
            }
        )
    }

    // MARK: - Model Whitelist

    @ViewBuilder
    private var modelWhitelistSection: some View {
        Section {
            let currentWhitelist = agent.allowedModelIds
            let whitelistPMs = currentWhitelist.compactMap { idStr -> ProviderModel? in
                let parts = idStr.split(separator: ":", maxSplits: 1)
                guard parts.count == 2,
                      let uid = UUID(uuidString: String(parts[0])) else { return nil }
                let modelName = String(parts[1])
                guard let provider = allProviders.first(where: { $0.id == uid }) else { return nil }
                return ProviderModel(provider: provider, modelName: modelName)
            }

            if currentWhitelist.isEmpty {
                Text(L10n.ModelConfig.whitelistAllModels)
                    .foregroundStyle(.secondary)
            } else {
                let staleCount = currentWhitelist.count - whitelistPMs.count
                if staleCount > 0 {
                    whitelistWarningRow(
                        icon: "trash.circle.fill",
                        color: .orange,
                        text: L10n.ModelConfig.whitelistStaleWarning(staleCount)
                    )
                }

                if isPrimaryBlockedByWhitelist {
                    whitelistWarningRow(
                        icon: "exclamationmark.triangle.fill",
                        color: .red,
                        text: L10n.ModelConfig.whitelistMissingPrimary
                    )
                }

                if isSubAgentBlockedByWhitelist {
                    whitelistWarningRow(
                        icon: "exclamationmark.triangle.fill",
                        color: .orange,
                        text: L10n.ModelConfig.whitelistMissingSubAgent
                    )
                }

                ForEach(whitelistPMs) { pm in
                    HStack {
                        VStack(alignment: .leading) {
                            Text(pm.provider.name).font(.body)
                            Text(pm.modelName).font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button(role: .destructive) {
                            removeFromWhitelist(pm)
                        } label: {
                            Image(systemName: "minus.circle.fill")
                                .foregroundStyle(.red)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }

            Menu {
                let existingIds = Set(currentWhitelist)
                let available = llmProviderModels.filter { !existingIds.contains($0.id) }
                let groups = groupedByProvider(available)
                if groups.count <= 1 {
                    ForEach(available) { pm in
                        Button(pm.modelName) { addToWhitelist(pm) }
                    }
                } else {
                    ForEach(groups, id: \.provider.id) { group in
                        Section(group.provider.name) {
                            ForEach(group.models) { pm in
                                Button(pm.modelName) { addToWhitelist(pm) }
                            }
                        }
                    }
                }
            } label: {
                Label(L10n.ModelConfig.addToWhitelist, systemImage: "plus.circle")
            }

            if !currentWhitelist.isEmpty {
                Button(L10n.ModelConfig.clearWhitelist) {
                    agent.allowedModelIds = []
                    agent.updatedAt = Date()
                    try? modelContext.save()
                }
                .font(.caption)
                .foregroundStyle(.red)
            }
        } header: {
            Text(L10n.ModelConfig.modelWhitelist)
        } footer: {
            Text(L10n.ModelConfig.whitelistFooter)
        }
    }

    private func whitelistWarningRow(icon: String, color: Color, text: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .foregroundStyle(color)
                .font(.body)
            Text(text)
                .font(.caption)
                .foregroundStyle(color)
        }
        .padding(.vertical, 4)
    }

    /// Returns the `providerId:modelName` key for the current primary model.
    private func resolvePrimaryModelId() -> String? {
        if let pid = agent.primaryProviderId,
           let provider = allProviders.first(where: { $0.id == pid }) {
            let model = agent.primaryModelNameOverride ?? provider.modelName
            return "\(pid.uuidString):\(model)"
        }
        // Global default
        if let globalDefault = allProviders.first(where: { $0.isDefault }) ?? allProviders.first {
            return "\(globalDefault.id.uuidString):\(globalDefault.modelName)"
        }
        return nil
    }

    /// Returns the `providerId:modelName` key for the sub-agent default model.
    private func resolveSubAgentModelId() -> String? {
        if let sid = agent.subAgentProviderId,
           let provider = allProviders.first(where: { $0.id == sid }) {
            let model = agent.subAgentModelNameOverride ?? provider.modelName
            return "\(sid.uuidString):\(model)"
        }
        // Inherits from primary
        return resolvePrimaryModelId()
    }

    private func addToWhitelist(_ pm: ProviderModel) {
        var list = agent.allowedModelIds
        let entry = pm.id
        guard !list.contains(entry) else { return }
        list.append(entry)
        agent.allowedModelIds = list
        agent.updatedAt = Date()
        try? modelContext.save()
    }

    private func removeFromWhitelist(_ pm: ProviderModel) {
        var list = agent.allowedModelIds
        list.removeAll { $0 == pm.id }
        agent.allowedModelIds = list
        agent.updatedAt = Date()
        try? modelContext.save()
    }

    // MARK: - Compression

    private static let thresholdPresets: [(label: String, value: Int)] = [
        ("4k", 4_000),
        ("8k", 8_000),
        ("16k", 16_000),
        ("24k", 24_000),
        ("32k", 32_000),
        ("64k", 64_000),
        ("128k", 128_000),
        ("200k", 200_000),
        ("500k", 500_000),
        ("1M", 1_000_000),
    ]

    @State private var customThresholdText: String = ""
    @State private var showCustomInput: Bool = false

    @ViewBuilder
    private var compressionSection: some View {
        Section {
            HStack {
                Text(L10n.ModelConfig.compressionThreshold)
                Spacer()
                Text(agent.compressionThreshold > 0
                     ? Self.formatTokenCount(agent.compressionThreshold)
                     : L10n.ModelConfig.defaultThreshold(ContextManager.compressionThreshold))
                    .foregroundStyle(.secondary)
            }

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(Self.thresholdPresets, id: \.value) { preset in
                        let isSelected = agent.compressionThreshold == preset.value
                        Button {
                            agent.compressionThreshold = preset.value
                            agent.updatedAt = Date()
                            try? modelContext.save()
                        } label: {
                            Text(preset.label)
                                .font(.caption.weight(isSelected ? .bold : .regular))
                                .padding(.horizontal, 10)
                                .padding(.vertical, 6)
                                .background(isSelected ? Color.accentColor.opacity(0.15) : Color(.systemGray6))
                                .foregroundStyle(isSelected ? Color.accentColor : .primary)
                                .clipShape(Capsule())
                        }
                        .buttonStyle(.plain)
                    }

                    let isCustom = agent.compressionThreshold > 0
                        && !Self.thresholdPresets.contains(where: { $0.value == agent.compressionThreshold })
                    Button {
                        customThresholdText = agent.compressionThreshold > 0
                            ? "\(agent.compressionThreshold)" : ""
                        showCustomInput = true
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "pencil")
                                .font(.caption2)
                            if isCustom {
                                Text(Self.formatTokenCount(agent.compressionThreshold))
                                    .font(.caption.weight(.bold))
                            }
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(isCustom ? Color.accentColor.opacity(0.15) : Color(.systemGray6))
                        .foregroundStyle(isCustom ? Color.accentColor : .primary)
                        .clipShape(Capsule())
                    }
                    .buttonStyle(.plain)
                }
            }

            if agent.compressionThreshold > 0 {
                Button(L10n.ModelConfig.resetDefault) {
                    agent.compressionThreshold = 0
                    agent.updatedAt = Date()
                    try? modelContext.save()
                }
                .font(.caption)
            }
        } header: {
            Text(L10n.ModelConfig.contextCompression)
        } footer: {
            Text(L10n.ModelConfig.compressionFooter)
        }
        .alert(L10n.ModelConfig.compressionThreshold, isPresented: $showCustomInput) {
            TextField("tokens", text: $customThresholdText)
                .keyboardType(.numberPad)
            Button(L10n.Common.save) {
                if let value = Int(customThresholdText.trimmingCharacters(in: .whitespaces)),
                   value >= 1000 {
                    agent.compressionThreshold = value
                    agent.updatedAt = Date()
                    try? modelContext.save()
                }
            }
            Button(L10n.Common.cancel, role: .cancel) {}
        }
    }

    private static func formatTokenCount(_ n: Int) -> String {
        if n >= 1_000_000 {
            let v = Double(n) / 1_000_000.0
            return v.truncatingRemainder(dividingBy: 1) == 0
                ? "\(Int(v))M" : String(format: "%.1fM", v)
        } else if n >= 1_000 {
            let v = Double(n) / 1_000.0
            return v.truncatingRemainder(dividingBy: 1) == 0
                ? "\(Int(v))k" : String(format: "%.1fk", v)
        }
        return "\(n)"
    }

    // MARK: - Preview

    @ViewBuilder
    private var resolutionPreviewSection: some View {
        Section {
            let router = ModelRouter(modelContext: modelContext)
            let chain = router.resolveProviderChainWithModels(for: agent)

            if chain.isEmpty {
                if !agent.allowedModelIds.isEmpty {
                    Text(L10n.ChatError.whitelistBlocked)
                        .foregroundStyle(.red)
                } else {
                    Text(L10n.ModelConfig.noModels)
                        .foregroundStyle(.red)
                }
            } else {
                ForEach(Array(chain.enumerated()), id: \.offset) { index, entry in
                    let effectiveModel = entry.modelName ?? entry.provider.modelName
                    let isOverride = entry.modelName != nil && entry.modelName != entry.provider.modelName
                    let caps = entry.provider.capabilities(for: effectiveModel)

                    HStack(spacing: 10) {
                        ZStack {
                            Circle()
                                .fill(index == 0 ? Color.yellow.opacity(0.2) : Color.secondary.opacity(0.1))
                                .frame(width: 28, height: 28)
                            if index == 0 {
                                Image(systemName: "star.fill")
                                    .foregroundStyle(.yellow)
                                    .font(.system(size: 12))
                            } else {
                                Text("\(index + 1)")
                                    .font(.caption2.bold())
                                    .foregroundStyle(.secondary)
                            }
                        }

                        VStack(alignment: .leading, spacing: 2) {
                            Text(effectiveModel)
                                .font(.subheadline.bold())
                            HStack(spacing: 4) {
                                Text(entry.provider.name)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                if isOverride {
                                    Text(L10n.ModelConfig.override)
                                        .font(.caption2)
                                        .foregroundStyle(.orange)
                                }
                            }
                            if !caps.supportsToolUse {
                                Text(L10n.ModelConfig.noToolUse(effectiveModel))
                                    .font(.caption2)
                                    .foregroundStyle(.orange)
                            }
                            let resolvedLevel = agent.thinkingLevelOverride ?? caps.thinkingLevel
                            if resolvedLevel.isEnabled {
                                let support = EffortLevelSupport.forModel(
                                    effectiveModel,
                                    apiStyle: entry.provider.apiStyle
                                )
                                let wouldClamp =
                                    (resolvedLevel == .xhigh && !support.supportsXHigh) ||
                                    (resolvedLevel == .max && !support.supportsMax)
                                HStack(spacing: 2) {
                                    Image(systemName: "brain")
                                        .font(.system(size: 9))
                                    Text(resolvedLevel.displayName)
                                        .font(.caption2)
                                    if agent.thinkingLevelOverride != nil {
                                        Text("(\(L10n.ModelConfig.override))")
                                            .font(.caption2)
                                    }
                                    if wouldClamp {
                                        Image(systemName: "exclamationmark.triangle.fill")
                                            .font(.system(size: 9))
                                            .foregroundStyle(.orange)
                                            .help("Clamps to high on this model.")
                                    }
                                }
                                .foregroundStyle(.purple)
                            }
                        }

                        Spacer()

                        if index == 0 {
                            Text(L10n.ModelConfig.primary)
                                .font(.caption2)
                                .foregroundStyle(.white)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(Capsule().fill(.blue))
                        } else {
                            Text(L10n.ModelConfig.fallback)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(Capsule().stroke(.secondary.opacity(0.3)))
                        }
                    }
                    .padding(.vertical, 2)
                }
            }

            // Sub-agent preview: resolve what a sub-agent would actually use
            let subProviderInfo: (provider: LLMProvider, modelName: String)? = {
                if let subId = agent.subAgentProviderId,
                   let p = allProviders.first(where: { $0.id == subId }) {
                    return (p, agent.subAgentModelNameOverride ?? p.modelName)
                }
                // "Inherit from primary" — same as primary in the chain above
                if let primary = chain.first {
                    return (primary.provider, primary.modelName ?? primary.provider.modelName)
                }
                return nil
            }()
            let isSubAgentInWhitelist: Bool = {
                guard hasWhitelist, let info = subProviderInfo else { return true }
                return whitelistSet.contains("\(info.provider.id.uuidString):\(info.modelName)")
            }()
            if let info = subProviderInfo {
                let isInherited = agent.subAgentProviderId == nil
                let blocked = !isSubAgentInWhitelist
                Divider()
                HStack(spacing: 10) {
                    ZStack {
                        Circle()
                            .fill(blocked ? Color.red.opacity(0.15) : Color.orange.opacity(0.15))
                            .frame(width: 28, height: 28)
                        Image(systemName: blocked ? "xmark" : "person.2")
                            .font(.system(size: 11))
                            .foregroundStyle(blocked ? .red : .orange)
                    }
                    VStack(alignment: .leading, spacing: 2) {
                        Text(info.modelName)
                            .font(.subheadline.bold())
                            .foregroundStyle(blocked ? .red : .primary)
                        HStack(spacing: 4) {
                            Text("\(info.provider.name) · Sub-Agent")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            if isInherited && !blocked {
                                Text("= Primary")
                                    .font(.caption2)
                                    .foregroundStyle(.blue.opacity(0.7))
                            }
                        }
                        if blocked {
                            Text(L10n.ModelConfig.whitelistMissingSubAgent)
                                .font(.caption2)
                                .foregroundStyle(.red)
                        }
                    }
                    Spacer()
                    Text(L10n.ModelConfig.subAgent)
                        .font(.caption2)
                        .foregroundStyle(blocked ? .red : .orange)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Capsule().stroke(blocked ? .red.opacity(0.4) : .orange.opacity(0.4)))
                }
                .padding(.vertical, 2)
            }
        } header: {
            Text(L10n.ModelConfig.resolutionOrder)
        } footer: {
            Text(L10n.ModelConfig.resolutionFooter)
        }
    }
}
