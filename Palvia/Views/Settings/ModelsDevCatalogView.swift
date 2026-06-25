import SwiftUI

/// The configuration produced when the user imports a provider from the
/// Models.dev catalog. Applied back onto the provider edit form.
struct ModelsDevImport {
    let providerName: String
    /// Empty when Models.dev doesn't tell us the endpoint — the caller should
    /// leave the existing endpoint untouched in that case.
    let endpoint: String
    let apiStyle: APIStyle
    let defaultModel: String
    /// Selected models mapped to inferred capabilities.
    let models: [String: ModelCapabilities]
}

/// A browsable catalog of LLM providers and models sourced from Models.dev.
///
/// Presented as a sheet from `LLMProviderEditView`. The user picks a provider,
/// selects the models they want, and imports them — endpoint, API protocol, and
/// per-model capabilities are filled in automatically from the catalog metadata.
struct ModelsDevCatalogView: View {
    let onImport: (ModelsDevImport) -> Void

    @Environment(\.dismiss) private var dismiss

    enum LoadState {
        case loading
        case loaded([ModelsDevProvider])
        case failed(String)
    }

    @State private var state: LoadState = .loading
    @State private var searchText = ""

    var body: some View {
        NavigationStack {
            content
                .navigationTitle(L10n.Provider.modelsDevTitle)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button(L10n.Common.cancel) { dismiss() }
                    }
                    ToolbarItem(placement: .primaryAction) {
                        Button {
                            Task { await load(forceRefresh: true) }
                        } label: {
                            Image(systemName: "arrow.clockwise")
                        }
                    }
                }
        }
        .task {
            if case .loading = state {
                await load(forceRefresh: false)
            }
        }
    }

    @ViewBuilder
    private var content: some View {
        switch state {
        case .loading:
            ProgressView(L10n.Provider.modelsDevLoading)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .failed(let message):
            ContentUnavailableView {
                Label(L10n.Provider.modelsDevFailed, systemImage: "wifi.exclamationmark")
            } description: {
                Text(message)
            } actions: {
                Button(L10n.Common.refresh) {
                    Task { await load(forceRefresh: true) }
                }
            }
        case .loaded(let providers):
            providerList(providers)
        }
    }

    private func providerList(_ providers: [ModelsDevProvider]) -> some View {
        List(filtered(providers)) { provider in
            NavigationLink {
                ModelsDevProviderDetailView(provider: provider, onImport: { result in
                    onImport(result)
                    dismiss()
                })
            } label: {
                VStack(alignment: .leading, spacing: 2) {
                    Text(provider.displayName)
                        .font(.body)
                    Text(L10n.Provider.modelsDevModelCount(provider.models.count))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .searchable(text: $searchText, prompt: L10n.Provider.modelsDevSearch)
        .listStyle(.plain)
    }

    private func filtered(_ providers: [ModelsDevProvider]) -> [ModelsDevProvider] {
        let trimmed = searchText.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return providers }
        return providers.filter { provider in
            if provider.displayName.localizedCaseInsensitiveContains(trimmed) { return true }
            if provider.id.localizedCaseInsensitiveContains(trimmed) { return true }
            // Match against model names too, so "gpt" surfaces OpenAI etc.
            return provider.models.contains { $0.displayName.localizedCaseInsensitiveContains(trimmed) }
        }
    }

    @MainActor
    private func load(forceRefresh: Bool) async {
        if forceRefresh { state = .loading }
        do {
            let catalog = try await ModelsDevService.shared.catalog(forceRefresh: forceRefresh)
            state = .loaded(catalog.providers)
        } catch {
            state = .failed(error.localizedDescription)
        }
    }
}

/// Model selection screen for a single catalog provider.
private struct ModelsDevProviderDetailView: View {
    let provider: ModelsDevProvider
    let onImport: (ModelsDevImport) -> Void

    @State private var selected: Set<String> = []
    @State private var modelSearch = ""

    private var resolvedEndpoint: String { ModelsDevMapping.endpoint(for: provider) }
    private var resolvedStyle: APIStyle { ModelsDevMapping.apiStyle(for: provider) }

    private var filteredModels: [ModelsDevModel] {
        let trimmed = modelSearch.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return provider.models }
        return provider.models.filter {
            $0.displayName.localizedCaseInsensitiveContains(trimmed)
                || $0.id.localizedCaseInsensitiveContains(trimmed)
        }
    }

    var body: some View {
        Form {
            Section {
                LabeledContent(L10n.Provider.apiStyle, value: resolvedStyle.displayName)
                if resolvedEndpoint.isEmpty {
                    LabeledContent(L10n.Provider.endpoint) {
                        Text(L10n.Provider.modelsDevNoEndpoint)
                            .foregroundStyle(.secondary)
                    }
                } else {
                    LabeledContent(L10n.Provider.endpoint, value: resolvedEndpoint)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                if let env = provider.env?.first {
                    LabeledContent(L10n.Provider.apiKey, value: env)
                        .font(.caption)
                }
            } footer: {
                Text(L10n.Provider.modelsDevImportFooter)
            }

            Section {
                ForEach(filteredModels) { model in
                    modelRow(model)
                }
            } header: {
                HStack {
                    Text(L10n.Provider.modelsDevModels)
                    Spacer()
                    Button(selected.count == provider.models.count
                           ? L10n.Provider.modelsDevDeselectAll
                           : L10n.Provider.modelsDevSelectAll) {
                        toggleSelectAll()
                    }
                    .font(.caption)
                }
            }
        }
        .searchable(text: $modelSearch, prompt: L10n.Provider.modelsDevSearchModels)
        .navigationTitle(provider.displayName)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button(L10n.Common.import) { performImport() }
                    .disabled(selected.isEmpty)
            }
        }
    }

    @ViewBuilder
    private func modelRow(_ model: ModelsDevModel) -> some View {
        Button {
            toggle(model.id)
        } label: {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text(model.displayName)
                        .font(.subheadline)
                        .foregroundStyle(.primary)
                    Text(model.id)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    capabilityBadges(model)
                }
                Spacer()
                Image(systemName: selected.contains(model.id) ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(selected.contains(model.id) ? Color.accentColor : Color.secondary)
            }
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private func capabilityBadges(_ model: ModelsDevModel) -> some View {
        HStack(spacing: 4) {
            if model.supportsImageInput { badge("eye", .green) }
            if model.supportsVideoInput { badge("video", .green) }
            if model.toolCall == true { badge("wrench", .blue) }
            if model.reasoning == true { badge("brain", .purple) }
            if model.generatesImages { badge("paintbrush", .orange) }
        }
    }

    private func badge(_ systemName: String, _ color: Color) -> some View {
        Image(systemName: systemName)
            .font(.system(size: 9))
            .foregroundStyle(color)
            .padding(3)
            .background(color.opacity(0.1), in: Circle())
    }

    private func toggle(_ id: String) {
        if selected.contains(id) { selected.remove(id) } else { selected.insert(id) }
    }

    private func toggleSelectAll() {
        if selected.count == provider.models.count {
            selected.removeAll()
        } else {
            selected = Set(provider.models.map(\.id))
        }
    }

    private func performImport() {
        let chosen = provider.models.filter { selected.contains($0.id) }
        guard !chosen.isEmpty else { return }
        var caps: [String: ModelCapabilities] = [:]
        for model in chosen {
            caps[model.id] = model.capabilities()
        }
        onImport(ModelsDevImport(
            providerName: provider.displayName,
            endpoint: resolvedEndpoint,
            apiStyle: resolvedStyle,
            defaultModel: chosen.first?.id ?? "",
            models: caps
        ))
    }
}
