import SwiftUI
import SwiftData

struct AgentSkillsView: View {
    let agent: Agent
    @Environment(\.modelContext) private var modelContext
    @State private var showLibraryPicker = false
    @State private var showConfigEditor = false
    @State private var editingInstallation: InstalledSkill?

    var body: some View {
        List {
            if agent.installedSkills.isEmpty {
                ContentUnavailableView {
                    Label(L10n.Skills.noSkillsInstalled, systemImage: "sparkles")
                } description: {
                    Text(L10n.Skills.installDescription)
                } actions: {
                    Button(L10n.Skills.browseLibrary) { showLibraryPicker = true }
                        .buttonStyle(.borderedProminent)
                }
            } else {
                Section {
                    ForEach(sortedInstallations, id: \.id) { installation in
                        if let skill = installation.skill {
                            HStack {
                                VStack(alignment: .leading, spacing: 4) {
                                    HStack(spacing: 4) {
                                        Text(skill.effectiveDisplayName)
                                            .font(.headline)
                                        if skill.isBuiltIn {
                                            Text(L10n.Skills.builtIn)
                                                .font(.caption2)
                                                .padding(.horizontal, 4)
                                                .padding(.vertical, 1)
                                                .background(Capsule().fill(.blue.opacity(0.15)))
                                                .foregroundStyle(.blue)
                                        }
                                        if !skill.scripts.isEmpty {
                                            Image(systemName: "terminal")
                                                .font(.caption2)
                                                .foregroundStyle(.orange)
                                        }
                                        if !skill.customTools.isEmpty {
                                            Image(systemName: "wrench.and.screwdriver")
                                                .font(.caption2)
                                                .foregroundStyle(.purple)
                                        }
                                    }
                                    Text(skill.summary)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(2)
                                }
                                Spacer()
                                Toggle("", isOn: Binding(
                                    get: { installation.isEnabled },
                                    set: { _ in
                                        SkillService(modelContext: modelContext).toggleSkill(installation)
                                    }
                                ))
                                .labelsHidden()
                            }
                            .swipeActions(edge: .trailing) {
                                Button(role: .destructive) {
                                    let service = SkillService(modelContext: modelContext)
                                    _ = service.uninstallSkill(skill, from: agent)
                                } label: {
                                    Label(L10n.Skills.uninstall, systemImage: "minus.circle")
                                }
                            }
                            .contextMenu {
                                if !skill.configSchema.isEmpty {
                                    Button {
                                        editingInstallation = installation
                                        showConfigEditor = true
                                    } label: {
                                        Label(L10n.Skills.configure, systemImage: "gear")
                                    }
                                }
                                Button(role: .destructive) {
                                    let service = SkillService(modelContext: modelContext)
                                    _ = service.uninstallSkill(skill, from: agent)
                                } label: {
                                    Label(L10n.Skills.uninstall, systemImage: "minus.circle")
                                }
                            }
                        }
                    }
                } header: {
                    Text(L10n.Skills.activeInstalled(active: agent.activeSkills.count, installed: agent.installedSkills.count))
                }
            }
        }
        .navigationTitle(L10n.Skills.title)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button { showLibraryPicker = true } label: {
                    Image(systemName: "plus.circle.fill")
                }
            }
        }
        .sheet(isPresented: $showLibraryPicker) {
            SkillPickerSheet(agent: agent)
        }
        .sheet(isPresented: $showConfigEditor) {
            if let installation = editingInstallation, let skill = installation.skill {
                SkillConfigEditorSheet(installation: installation, schema: skill.configSchema)
            }
        }
    }

    private var sortedInstallations: [InstalledSkill] {
        agent.installedSkills.sorted { ($0.skill?.name ?? "") < ($1.skill?.name ?? "") }
    }
}

// MARK: - Skill Picker (install from library)

struct SkillPickerSheet: View {
    let agent: Agent
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    @State private var allSkills: [Skill] = []
    @State private var searchText = ""

    var body: some View {
        NavigationStack {
            List {
                ForEach(filteredSkills, id: \.id) { skill in
                    let installed = agent.installedSkills.contains { $0.skill?.id == skill.id }
                    Button {
                        let service = SkillService(modelContext: modelContext)
                        if installed {
                            _ = service.uninstallSkill(skill, from: agent)
                        } else {
                            _ = service.installSkill(skill, on: agent)
                        }
                        reload()
                    } label: {
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                HStack(spacing: 4) {
                                    Text(skill.effectiveDisplayName).font(.headline)
                                    if skill.isBuiltIn {
                                        Text(L10n.Skills.builtIn)
                                            .font(.caption2)
                                            .foregroundStyle(.blue)
                                    }
                                }
                                Text(skill.summary)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                            Spacer()
                            Image(systemName: installed ? "checkmark.circle.fill" : "circle")
                                .foregroundStyle(installed ? .green : .secondary)
                        }
                    }
                    .tint(.primary)
                }
            }
            .searchable(text: $searchText, prompt: L10n.Skills.searchSkills)
            .navigationTitle(L10n.Skills.skillLibrary)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(L10n.Common.done) { dismiss() }
                }
            }
            .onAppear { reload() }
        }
    }

    private var filteredSkills: [Skill] {
        if searchText.isEmpty { return allSkills }
        let q = searchText.lowercased()
        return allSkills.filter {
            $0.name.lowercased().contains(q) ||
            $0.effectiveDisplayName.lowercased().contains(q) ||
            $0.summary.lowercased().contains(q) ||
            $0.tags.contains(where: { $0.lowercased().contains(q) })
        }
    }

    private func reload() {
        let service = SkillService(modelContext: modelContext)
        service.ensureBuiltInSkills()
        service.discoverDiskPackages()
        allSkills = service.fetchAllSkills()
    }
}

// MARK: - Skill Config Editor

struct SkillConfigEditorSheet: View {
    @Bindable var installation: InstalledSkill
    let schema: [SkillConfigField]
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    @State private var values: [String: String] = [:]

    var body: some View {
        NavigationStack {
            Form {
                ForEach(schema, id: \.key) { field in
                    HStack {
                        VStack(alignment: .leading) {
                            Text(field.label)
                                .font(.subheadline)
                            if field.required {
                                Text(L10n.Skills.required)
                                    .font(.caption2)
                                    .foregroundStyle(.red)
                            }
                        }
                        Spacer()
                        TextField(field.defaultValue ?? "", text: Binding(
                            get: { values[field.key] ?? "" },
                            set: { values[field.key] = $0 }
                        ))
                        .multilineTextAlignment(.trailing)
                        .frame(maxWidth: 200)
                    }
                }
            }
            .navigationTitle(L10n.Skills.skillConfiguration)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L10n.Common.cancel) { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(L10n.Common.save) {
                        installation.config = values
                        try? modelContext.save()
                        dismiss()
                    }
                }
            }
            .onAppear {
                // Load existing config values, falling back to schema defaults
                var loaded = installation.config
                for field in schema {
                    if loaded[field.key] == nil, let defaultVal = field.defaultValue {
                        loaded[field.key] = defaultVal
                    }
                }
                values = loaded
            }
        }
    }
}
