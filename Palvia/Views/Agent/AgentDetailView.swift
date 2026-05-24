import SwiftUI

struct AgentDetailView: View {
    @Bindable var agent: Agent
    let viewModel: AgentViewModel
    @State private var selectedConfig: ConfigType = .soul
    @State private var showRename = false
    @State private var editingName = ""

    enum ConfigType: String, CaseIterable {
        case soul = "SOUL"
        case memory = "MEMORY"
        case user = "USER"
    }

    var body: some View {
        VStack(spacing: 0) {
            Picker("Config", selection: $selectedConfig) {
                ForEach(ConfigType.allCases, id: \.self) { type in
                    Text(type.rawValue).tag(type)
                }
            }
            .pickerStyle(.segmented)
            .padding()

            MarkdownEditorView(
                content: bindingForConfig(selectedConfig),
                title: "\(selectedConfig.rawValue).md"
            )
        }
        .navigationTitle(agent.name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Menu {
                    Button {
                        editingName = agent.name
                        showRename = true
                    } label: {
                        Label(L10n.Agents.renameAgent, systemImage: "pencil")
                    }
                    NavigationLink(L10n.AgentDetail.modelConfig) {
                        AgentModelConfigView(agent: agent)
                    }
                    NavigationLink(L10n.AgentDetail.toolPermissions) {
                        AgentToolPermissionsView(agent: agent)
                    }
                    NavigationLink(L10n.AgentDetail.skills) {
                        AgentSkillsView(agent: agent)
                    }
                    NavigationLink(L10n.AgentDetail.cronJobs) {
                        CronJobListView(agent: agent)
                    }
                    NavigationLink(L10n.AgentFiles.title) {
                        AgentFileBrowserView(agent: agent)
                    }
                    NavigationLink(L10n.AgentDetail.customConfigs) {
                        CustomConfigsView(agent: agent)
                    }
                    NavigationLink(L10n.AgentDetail.subAgents) {
                        SubAgentListView(parentAgent: agent)
                    }
                    NavigationLink(L10n.AgentDetail.codeSnippets) {
                        CodeSnippetListView(agent: agent)
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
            }
        }
        .alert(L10n.Agents.renameAgent, isPresented: $showRename) {
            TextField(L10n.Common.name, text: $editingName)
            Button(L10n.Common.save) {
                let trimmed = editingName.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty {
                    viewModel.renameAgent(agent, to: trimmed)
                }
            }
            Button(L10n.Common.cancel, role: .cancel) {}
        }
        .onChange(of: agent.soulMarkdown) { _, _ in viewModel.updateAgent(agent) }
        .onChange(of: agent.memoryMarkdown) { _, _ in viewModel.updateAgent(agent) }
        .onChange(of: agent.userMarkdown) { _, _ in viewModel.updateAgent(agent) }
    }

    private func bindingForConfig(_ type: ConfigType) -> Binding<String> {
        switch type {
        case .soul: return $agent.soulMarkdown
        case .memory: return $agent.memoryMarkdown
        case .user: return $agent.userMarkdown
        }
    }
}

struct CustomConfigsView: View {
    let agent: Agent
    @Environment(\.modelContext) private var modelContext
    @State private var showAddSheet = false
    @State private var newKey = ""
    @State private var newContent = ""

    var body: some View {
        List {
            ForEach(agent.customConfigs, id: \.id) { config in
                NavigationLink {
                    MarkdownEditorView(
                        content: Binding(
                            get: { config.content },
                            set: {
                                config.content = $0
                                config.updatedAt = Date()
                                try? modelContext.save()
                            }
                        ),
                        title: config.key
                    )
                } label: {
                    VStack(alignment: .leading) {
                        Text(config.key).font(.headline)
                        Text(config.content.prefix(80))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }
                }
            }
        }
        .navigationTitle(L10n.AgentDetail.customConfigs)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button { showAddSheet = true } label: {
                    Image(systemName: "plus")
                }
            }
        }
        .alert(L10n.AgentDetail.newConfig, isPresented: $showAddSheet) {
            TextField(L10n.AgentDetail.keyPlaceholder, text: $newKey)
            Button(L10n.Common.create) {
                let key = newKey.trimmingCharacters(in: .whitespacesAndNewlines)
                if !key.isEmpty {
                    let config = AgentConfig(key: key, content: "")
                    modelContext.insert(config)
                    agent.customConfigs.append(config)
                    try? modelContext.save()
                }
                newKey = ""
            }
            Button(L10n.Common.cancel, role: .cancel) { newKey = "" }
        }
    }
}

struct SubAgentListView: View {
    let parentAgent: Agent
    @Environment(\.modelContext) private var modelContext
    @State private var renamingSubAgent: Agent?
    @State private var subAgentRenameText = ""
    @State private var showRenameAlert = false

    var body: some View {
        List {
            if parentAgent.subAgents.isEmpty {
                ContentUnavailableView(
                    L10n.AgentDetail.noSubAgents,
                    systemImage: "cpu",
                    description: Text(L10n.AgentDetail.subAgentsDescription)
                )
            } else {
                ForEach(parentAgent.subAgents, id: \.id) { sub in
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Text(sub.name).font(.headline)
                            Spacer()
                            Text(sub.subAgentType ?? L10n.Common.unknown)
                                .font(.caption2)
                                .foregroundStyle(.white)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(
                                    Capsule().fill(sub.isTempSubAgent ? .orange : .blue)
                                )
                        }

                        HStack(spacing: 12) {
                            let hasActive = sub.sessions.contains { $0.isActive }
                            if hasActive {
                                HStack(spacing: 4) {
                                    Circle().fill(.green).frame(width: 6, height: 6)
                                    Text(L10n.Common.active)
                                        .font(.caption2)
                                        .foregroundStyle(.green)
                                }
                            }

                            Text(L10n.AgentDetail.sessionsCount(sub.sessions.count))
                                .font(.caption)
                                .foregroundStyle(.secondary)

                            if let lastSession = sub.sessions.sorted(by: { $0.updatedAt > $1.updatedAt }).first {
                                Text(L10n.AgentDetail.msgsCount(lastSession.messages.count))
                                    .font(.caption)
                                    .foregroundStyle(.tertiary)
                            }
                        }
                    }
                    .padding(.vertical, 2)
                    .swipeActions(edge: .trailing) {
                        Button(role: .destructive) {
                            modelContext.delete(sub)
                            try? modelContext.save()
                        } label: {
                            Label(L10n.Common.delete, systemImage: "trash")
                        }
                    }
                    .contextMenu {
                        Button {
                            subAgentRenameText = sub.name
                            renamingSubAgent = sub
                            showRenameAlert = true
                        } label: {
                            Label(L10n.Agents.renameAgent, systemImage: "pencil")
                        }
                        Button(role: .destructive) {
                            modelContext.delete(sub)
                            try? modelContext.save()
                        } label: {
                            Label(L10n.Common.delete, systemImage: "trash")
                        }
                    }
                }
            }
        }
        .navigationTitle(L10n.AgentDetail.subAgentsTitle(parentAgent.subAgents.count))
        .alert(L10n.Agents.renameAgent, isPresented: $showRenameAlert) {
            TextField(L10n.Common.name, text: $subAgentRenameText)
            Button(L10n.Common.save) {
                if let sub = renamingSubAgent {
                    let trimmed = subAgentRenameText.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !trimmed.isEmpty {
                        sub.name = trimmed
                        sub.updatedAt = Date()
                        try? modelContext.save()
                    }
                }
                renamingSubAgent = nil
            }
            Button(L10n.Common.cancel, role: .cancel) {
                renamingSubAgent = nil
            }
        }
    }
}

struct CodeSnippetListView: View {
    let agent: Agent
    @Environment(\.modelContext) private var modelContext
    @State private var showNewSnippet = false

    var body: some View {
        List {
            if agent.codeSnippets.isEmpty {
                ContentUnavailableView(
                    L10n.AgentDetail.noCodeSnippets,
                    systemImage: "doc.text",
                    description: Text(L10n.AgentDetail.codeSnippetsDescription)
                )
            } else {
                ForEach(agent.codeSnippets.sorted(by: { $0.updatedAt > $1.updatedAt }), id: \.id) { snippet in
                    NavigationLink {
                        CodeSnippetEditView(snippet: snippet)
                    } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                Text(snippet.name).font(.headline)
                                Spacer()
                                Text(snippet.language)
                                    .font(.caption)
                                    .padding(.horizontal, 8)
                                    .padding(.vertical, 2)
                                    .background(Capsule().fill(.secondary.opacity(0.2)))
                            }
                            Text(snippet.code.prefix(120))
                                .font(.system(.caption, design: .monospaced))
                                .foregroundStyle(.secondary)
                                .lineLimit(3)
                        }
                        .padding(.vertical, 2)
                    }
                    .swipeActions(edge: .trailing) {
                        Button(role: .destructive) {
                            modelContext.delete(snippet)
                            try? modelContext.save()
                        } label: {
                            Label(L10n.Common.delete, systemImage: "trash")
                        }
                    }
                }
            }
        }
        .navigationTitle(L10n.AgentDetail.codeSnippets)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button { showNewSnippet = true } label: {
                    Image(systemName: "plus")
                }
            }
        }
        .sheet(isPresented: $showNewSnippet) {
            NavigationStack {
                CodeSnippetEditView(agent: agent)
            }
        }
    }
}

struct CodeSnippetEditView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss

    private let snippet: CodeSnippet?
    private let agent: Agent?

    @State private var name: String
    @State private var language: String
    @State private var code: String

    private var isNewSnippet: Bool { snippet == nil }

    init(snippet: CodeSnippet) {
        self.snippet = snippet
        self.agent = nil
        _name = State(initialValue: snippet.name)
        _language = State(initialValue: snippet.language)
        _code = State(initialValue: snippet.code)
    }

    init(agent: Agent) {
        self.snippet = nil
        self.agent = agent
        _name = State(initialValue: "")
        _language = State(initialValue: "javascript")
        _code = State(initialValue: "")
    }

    var body: some View {
        Form {
            Section(L10n.AgentDetail.snippetInfo) {
                TextField(L10n.AgentDetail.snippetName, text: $name)
                TextField(L10n.AgentDetail.snippetLanguage, text: $language)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
            }

            Section(L10n.AgentDetail.snippetCode) {
                HighlightedTextEditor(text: $code, language: language)
            }
        }
        .navigationTitle(isNewSnippet ? L10n.AgentDetail.newSnippet : name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if isNewSnippet {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L10n.Common.cancel) { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(L10n.Common.create) {
                        createSnippet()
                        dismiss()
                    }
                    .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            } else {
                ToolbarItem(placement: .confirmationAction) {
                    Button(L10n.Common.save) {
                        saveSnippet()
                        dismiss()
                    }
                    .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
    }

    private func createSnippet() {
        guard let agent else { return }
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else { return }
        let newSnippet = CodeSnippet(name: trimmedName, language: language, code: code)
        modelContext.insert(newSnippet)
        agent.codeSnippets.append(newSnippet)
        try? modelContext.save()
    }

    private func saveSnippet() {
        guard let snippet else { return }
        snippet.name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        snippet.language = language
        snippet.code = code
        snippet.updatedAt = Date()
        try? modelContext.save()
    }
}
