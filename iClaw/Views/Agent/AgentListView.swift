import SwiftUI
import SwiftData

struct AgentListView: View {
    @Environment(\.modelContext) private var modelContext
    @State private var viewModel: AgentViewModel?
    @State private var showCreateSheet = false
    @State private var newAgentName = ""
    @State private var renamingAgent: Agent?
    @State private var renamingText = ""
    @State private var showRenameAlert = false
    @State private var showDeleteAlert = false

    var body: some View {
        NavigationStack {
            Group {
                if let vm = viewModel {
                    if vm.agents.isEmpty {
                        emptyStateView
                    } else {
                        agentList(vm)
                    }
                } else {
                    ProgressView()
                }
            }
            .navigationTitle(L10n.Agents.title)
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        newAgentName = ""
                        showCreateSheet = true
                    } label: {
                        Image(systemName: "plus.circle.fill")
                    }
                    .accessibilityIdentifier(AccessibilityID.AgentList.createButton)
                }
            }
            .alert(L10n.Agents.newAgent, isPresented: $showCreateSheet) {
                TextField(L10n.Agents.agentName, text: $newAgentName)
                Button(L10n.Common.create) {
                    let name = newAgentName.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !name.isEmpty {
                        _ = viewModel?.createAgent(name: name)
                    }
                }
                Button(L10n.Common.cancel, role: .cancel) {}
            } message: {
                Text(L10n.Agents.enterName)
            }
        }
        .onAppear {
            if viewModel == nil {
                viewModel = AgentViewModel(modelContext: modelContext)
            } else {
                viewModel?.fetchAgents()
            }
        }
    }

    private var emptyStateView: some View {
        ContentUnavailableView {
            Label(L10n.Agents.noAgents, systemImage: "cpu")
        } description: {
            Text(L10n.Agents.createAgentDescription)
        } actions: {
            Button(L10n.Agents.createAgent) {
                newAgentName = ""
                showCreateSheet = true
            }
            .buttonStyle(.borderedProminent)
            .accessibilityIdentifier(AccessibilityID.AgentList.emptyCreateButton)
        }
        .accessibilityIdentifier(AccessibilityID.AgentList.emptyState)
    }

    private func agentList(_ vm: AgentViewModel) -> some View {
        List {
            ForEach(vm.agents, id: \.id) { agent in
                NavigationLink {
                    AgentDetailView(agent: agent, viewModel: vm)
                } label: {
                    let rowData = vm.rowDataCache[agent.id]
                    VStack(alignment: .leading, spacing: 4) {
                        Text(rowData?.name ?? "")
                            .font(.headline)
                        HStack(spacing: 12) {
                            Label("\(rowData?.sessionCount ?? 0)", systemImage: "bubble.left")
                            Label("\(rowData?.activeSkillCount ?? 0)", systemImage: "sparkles")
                            Label("\(rowData?.cronJobCount ?? 0)", systemImage: "clock.badge")
                        }
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 4)
                }
                .accessibilityIdentifier(AccessibilityID.AgentList.agentRow)
                .contextMenu {
                    Button {
                        renamingText = agent.name
                        renamingAgent = agent
                        showRenameAlert = true
                    } label: {
                        Label(L10n.Agents.renameAgent, systemImage: "pencil")
                    }
                    Button(role: .destructive) {
                        vm.agentToDelete = agent
                        showDeleteAlert = true
                    } label: {
                        Label(L10n.Common.delete, systemImage: "trash")
                    }
                }
            }
            .onDelete { offsets in
                guard let first = offsets.first else { return }
                vm.agentToDelete = vm.agents[first]
                showDeleteAlert = true
            }
        }
        .listStyle(.insetGrouped)
        .alert(L10n.Agents.renameAgent, isPresented: $showRenameAlert) {
            TextField(L10n.Common.name, text: $renamingText)
            Button(L10n.Common.save) {
                if let agent = renamingAgent {
                    let trimmed = renamingText.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !trimmed.isEmpty {
                        vm.renameAgent(agent, to: trimmed)
                    }
                }
                renamingAgent = nil
            }
            Button(L10n.Common.cancel, role: .cancel) {
                renamingAgent = nil
            }
        }
        .alert(L10n.Chat.deleteAgentTitle, isPresented: $showDeleteAlert) {
            Button(L10n.Common.delete, role: .destructive) {
                if let agent = vm.agentToDelete {
                    vm.deleteAgent(agent)
                }
                vm.agentToDelete = nil
            }
            Button(L10n.Common.cancel, role: .cancel) {
                vm.agentToDelete = nil
            }
        } message: {
            Text(L10n.Chat.deleteAgentMessage(vm.agentToDelete?.name ?? ""))
        }
    }
}
