import Foundation
import SwiftData
import Observation

/// Pre-computed row data — avoids @Model property reads in ForEach rows
/// which register SwiftData observation that conflicts with batch updates.
struct ProviderRowData {
    let name: String
    let modelName: String
    let extraModelCount: Int
    let endpoint: String
    let providerType: ProviderType
}

@Observable
final class SettingsViewModel {
    var providers: [LLMProvider] = []
    var providerRowCache: [UUID: ProviderRowData] = [:]

    /// UUID of the current default provider for display purposes.
    var defaultProviderId: UUID?

    /// Set by the View to trigger a deletion confirmation alert.
    var providerToDelete: LLMProvider?

    /// Names of agents that reference the provider pending deletion (for the alert message).
    var affectedAgentNames: [String] = []

    private(set) var modelContext: ModelContext

    init(modelContext: ModelContext) {
        self.modelContext = modelContext
        fetchProviders()
    }

    func fetchProviders() {
        let descriptor = FetchDescriptor<LLMProvider>(
            sortBy: [SortDescriptor(\.createdAt)]
        )
        providers = (try? modelContext.fetch(descriptor)) ?? []
        defaultProviderId = providers.first(where: \.isDefault)?.id
            ?? providers.first?.id
        rebuildRowCache()
    }

    private func rebuildRowCache() {
        var cache: [UUID: ProviderRowData] = [:]
        for p in providers {
            cache[p.id] = ProviderRowData(
                name: p.name,
                modelName: p.modelName,
                extraModelCount: p.enabledModels.count - 1,
                endpoint: p.endpoint,
                providerType: p.providerType
            )
        }
        providerRowCache = cache
    }

    func addProvider(
        name: String,
        endpoint: String,
        apiKey: String,
        modelName: String
    ) {
        let isFirst = providers.isEmpty
        let provider = LLMProvider(
            name: name,
            endpoint: endpoint,
            apiKey: apiKey,
            modelName: modelName,
            isDefault: isFirst
        )
        modelContext.insert(provider)
        try? modelContext.save()
        fetchProviders()
    }

    func setDefault(_ provider: LLMProvider) {
        for p in providers {
            p.isDefault = (p.id == provider.id)
        }
        try? modelContext.save()
        fetchProviders()
    }

    /// Returns the names of agents that reference this provider (as primary, fallback, or sub-agent default).
    func agentNamesUsing(provider: LLMProvider) -> [String] {
        let providerId = provider.id.uuidString
        let agents = (try? modelContext.fetch(FetchDescriptor<Agent>())) ?? []
        return agents.compactMap { agent in
            let usesPrimary = agent.primaryProviderIdRaw == providerId
            let usesFallback = agent.fallbackProviderIdsRaw?.contains(providerId) == true
            let usesSubAgent = agent.subAgentProviderIdRaw == providerId
            guard usesPrimary || usesFallback || usesSubAgent else { return nil }
            return agent.name
        }
    }

    /// Prepare for provider deletion: populate affectedAgentNames and set providerToDelete.
    func confirmDeleteProvider(_ provider: LLMProvider) {
        affectedAgentNames = agentNamesUsing(provider: provider)
        providerToDelete = provider
    }

    func deleteProvider(_ provider: LLMProvider) {
        // ── 1. Update ONLY ForEach-driving state ────────────────────
        // Do NOT set providerToDelete = nil here. The alert's
        // isPresented binding will clear it when SwiftUI dismisses
        // the alert AFTER this action returns. Setting it inside
        // deleteProvider() causes a re-entrant dispatchImmediately
        // during the same render cycle → batch update conflict.
        let deletedId = provider.id
        providers = providers.filter { $0.id != deletedId }
        providerRowCache.removeValue(forKey: deletedId)
        defaultProviderId = providers.first(where: \.isDefault)?.id
            ?? providers.first?.id

        // ── 2. Persist deletion ─────────────────────────────────────
        modelContext.delete(provider)
        try? modelContext.save()
    }

    func updateProvider(_ provider: LLMProvider) {
        try? modelContext.save()
        fetchProviders()
    }

    func addProviderDirectly(_ provider: LLMProvider) {
        modelContext.insert(provider)
        try? modelContext.save()
        fetchProviders()
    }

    // MARK: - Remote Model Fetching

    @MainActor
    func fetchRemoteModels(for provider: LLMProvider) async throws -> [String] {
        let models = try await LLMService.fetchModels(
            endpoint: provider.endpoint,
            apiKey: provider.apiKey,
            apiStyle: provider.apiStyle
        )
        provider.cachedModelList = models
        provider.cachedModelListDate = Date()
        try? modelContext.save()
        return models
    }

    func toggleModel(_ modelName: String, enabled: Bool, for provider: LLMProvider) {
        var current = provider.enabledModels
        if enabled {
            if !current.contains(modelName) {
                current.append(modelName)
            }
        } else {
            if modelName != provider.modelName {
                current.removeAll { $0 == modelName }
            }
        }
        provider.enabledModels = current
        try? modelContext.save()
        fetchProviders()
    }

    func setDefaultModel(_ modelName: String, for provider: LLMProvider) {
        let oldDefault = provider.modelName
        provider.modelName = modelName
        var enabled = provider.enabledModels
        if !enabled.contains(oldDefault) {
            enabled.append(oldDefault)
        }
        provider.enabledModels = enabled
        try? modelContext.save()
        fetchProviders()
    }
}
