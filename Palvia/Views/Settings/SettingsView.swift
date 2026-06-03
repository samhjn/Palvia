import SwiftUI
import SwiftData

struct SettingsView: View {
    @Environment(\.modelContext) private var modelContext
    @State private var viewModel: SettingsViewModel?
    @State private var showAddProvider = false
    @State private var showDeleteConfirmation = false
    @AppStorage(BackgroundKeepAliveManager.enabledKey) private var keepAliveEnabled = false
    @AppStorage(PromptBuilder.progressiveDisclosureKey) private var progressiveSkillDisclosure = true

    var body: some View {
        NavigationStack {
            Group {
                if let vm = viewModel {
                    settingsList(vm)
                } else {
                    ProgressView()
                }
            }
            .navigationTitle(L10n.Settings.title)
            .sheet(isPresented: $showAddProvider) {
                if let vm = viewModel {
                    LLMProviderEditView(viewModel: vm)
                }
            }
        }
        .onAppear {
            if viewModel == nil {
                viewModel = SettingsViewModel(modelContext: modelContext)
            } else {
                viewModel?.fetchProviders()
            }
        }
    }

    private func settingsList(_ vm: SettingsViewModel) -> some View {
        let llmProviders = vm.providers.filter { (vm.providerRowCache[$0.id]?.providerType ?? .llm) == .llm }
        let imageProviders = vm.providers.filter { (vm.providerRowCache[$0.id]?.providerType ?? .llm) == .imageOnly }
        let videoProviders = vm.providers.filter { (vm.providerRowCache[$0.id]?.providerType ?? .llm) == .videoOnly }

        return List {
            Section {
                NavigationLink {
                    AppleHealthView()
                } label: {
                    Label {
                        Text(L10n.AppleHealth.title)
                    } icon: {
                        Image(systemName: "heart.fill")
                            .foregroundStyle(.pink)
                    }
                }
                .accessibilityIdentifier(AccessibilityID.Settings.appleHealthRow)
            }

            providerSection(vm, providers: llmProviders, header: L10n.Settings.llmProviders, showDefault: true)

            if !imageProviders.isEmpty {
                providerSection(vm, providers: imageProviders, header: L10n.Settings.imageProviders, showDefault: false)
            }

            if !videoProviders.isEmpty {
                providerSection(vm, providers: videoProviders, header: L10n.Settings.videoProviders, showDefault: false)
            }

            Section {
                Button {
                    showAddProvider = true
                } label: {
                    Label(L10n.Settings.addProvider, systemImage: "plus")
                }
                .accessibilityIdentifier(AccessibilityID.Settings.addProviderButton)
            }

            Section {
                Toggle(L10n.Settings.backgroundKeepAlive, isOn: $keepAliveEnabled)
                    .accessibilityIdentifier(AccessibilityID.Settings.backgroundToggle)
            } header: {
                Text(L10n.Settings.backgroundExecution)
            } footer: {
                Text(L10n.Settings.backgroundKeepAliveFooter)
            }

            Section {
                Toggle(L10n.Settings.progressiveSkillDisclosure, isOn: $progressiveSkillDisclosure)
                    .accessibilityIdentifier(AccessibilityID.Settings.skillDisclosureToggle)
            } header: {
                Text(L10n.Settings.skills)
            } footer: {
                Text(L10n.Settings.progressiveSkillDisclosureFooter)
            }

            Section(L10n.Settings.about) {
                NavigationLink {
                    AboutView()
                } label: {
                    HStack {
                        Text(L10n.Settings.about)
                        Spacer()
                        Text(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?")
                            .foregroundStyle(.secondary)
                    }
                }
                .accessibilityIdentifier(AccessibilityID.Settings.aboutRow)
            }
        }
        .listStyle(.insetGrouped)
        .alert(L10n.Settings.deleteProviderTitle, isPresented: $showDeleteConfirmation) {
            Button(L10n.Common.delete, role: .destructive) {
                if let provider = vm.providerToDelete {
                    vm.deleteProvider(provider)
                }
                vm.providerToDelete = nil
                vm.affectedAgentNames = []
            }
            Button(L10n.Common.cancel, role: .cancel) {
                vm.providerToDelete = nil
                vm.affectedAgentNames = []
            }
        } message: {
            if vm.affectedAgentNames.isEmpty {
                Text(L10n.Settings.deleteProviderMessage)
            } else {
                Text(L10n.Settings.deleteProviderAffectedMessage(
                    vm.affectedAgentNames.joined(separator: ", ")
                ))
            }
        }
    }

    @ViewBuilder
    private func providerSection(_ vm: SettingsViewModel, providers: [LLMProvider], header: String, showDefault: Bool) -> some View {
        Section(header) {
            ForEach(providers, id: \.id) { provider in
                NavigationLink {
                    LLMProviderEditView(viewModel: vm, existingProvider: provider)
                } label: {
                    let row = vm.providerRowCache[provider.id]
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(row?.name ?? "")
                                .font(.headline)
                            HStack(spacing: 4) {
                                Text(row?.modelName ?? "")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                if let extra = row?.extraModelCount, extra > 0 {
                                    Text("+\(extra)")
                                        .font(.caption2)
                                        .foregroundStyle(.white)
                                        .padding(.horizontal, 5)
                                        .padding(.vertical, 1)
                                        .background(Capsule().fill(.blue.opacity(0.7)))
                                }
                            }
                            Text(row?.endpoint ?? "")
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                        }
                        Spacer()
                        if showDefault && vm.defaultProviderId == provider.id {
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundStyle(.green)
                        }
                    }
                }
                .accessibilityIdentifier(AccessibilityID.Settings.providerRow)
                .swipeActions(edge: .trailing) {
                    Button(role: .destructive) {
                        vm.confirmDeleteProvider(provider)
                        showDeleteConfirmation = true
                    } label: {
                        Label(L10n.Common.delete, systemImage: "trash")
                    }
                    if showDefault && vm.defaultProviderId != provider.id {
                        Button {
                            vm.setDefault(provider)
                        } label: {
                            Label(L10n.Common.defaultLabel, systemImage: "checkmark")
                        }
                        .tint(.green)
                    }
                }
                .contextMenu {
                    if showDefault && vm.defaultProviderId != provider.id {
                        Button {
                            vm.setDefault(provider)
                        } label: {
                            Label(L10n.Common.defaultLabel, systemImage: "checkmark.circle")
                        }
                    }
                    Button(role: .destructive) {
                        vm.confirmDeleteProvider(provider)
                        showDeleteConfirmation = true
                    } label: {
                        Label(L10n.Common.delete, systemImage: "trash")
                    }
                }
            }
        }
    }
}
