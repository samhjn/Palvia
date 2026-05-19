import SwiftUI
import SwiftData

struct SessionListView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismissSearch) private var dismissSearch
    @Environment(PendingSessionRouter.self) private var router
    @State private var viewModel: SessionListViewModel?
    @State private var showNewSessionSheet = false
    @State private var selectedSession: Session?
    @State private var searchText = ""
    @State private var isSearchActive = false
    @State private var columnVisibility: NavigationSplitViewVisibility = .automatic
    @State private var showDeleteSessionAlert = false

    var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            Group {
                if let vm = viewModel {
                    if vm.sessions.isEmpty && isSearchActive {
                        searchEmptyView
                    } else if vm.sessions.isEmpty {
                        emptyStateView
                    } else {
                        sessionsList(vm)
                    }
                } else {
                    ProgressView()
                }
            }
            .navigationTitle(L10n.Sessions.title)
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        showNewSessionSheet = true
                    } label: {
                        Image(systemName: "plus.circle.fill")
                    }
                    .accessibilityIdentifier(AccessibilityID.SessionList.newSessionButton)
                }
            }
            .sheet(isPresented: $showNewSessionSheet) {
                NewSessionSheet { agent in
                    if let vm = viewModel {
                        let session = vm.createSession(agent: agent)
                        selectedSession = session
                    }
                    showNewSessionSheet = false
                }
            }
            .searchable(text: $searchText, isPresented: $isSearchActive, prompt: L10n.Sessions.searchSessions)
            .onChange(of: searchText) { _, newValue in
                viewModel?.searchText = newValue
                viewModel?.applySearch()
            }
            .onChange(of: isSearchActive) { _, active in
                if !active && !searchText.isEmpty {
                    searchText = ""
                    viewModel?.searchText = ""
                    viewModel?.applySearch()
                }
            }
        } detail: {
            if let session = selectedSession {
                ChatView(session: session)
                    .id(session.id)
            } else {
                ContentUnavailableView {
                    Label(L10n.Sessions.selectSession, systemImage: "bubble.left.and.bubble.right")
                } description: {
                    Text(L10n.Sessions.selectSessionDescription)
                }
            }
        }
        .onAppear {
            if viewModel == nil {
                viewModel = SessionListViewModel(modelContext: modelContext)
            } else {
                viewModel?.fetchSessions()
            }
            viewModel?.startAutoRefresh()

            // `onChange(of: router.pendingSession)` only fires on mutations,
            // not on the initial value. If the main-app's foreground sweep
            // already set `pendingSession` before this view mounted, catch
            // it here so the shared session still gets selected.
            if let session = router.pendingSession {
                viewModel?.fetchSessions()
                selectedSession = session
                router.pendingSession = nil
            }
        }
        .onDisappear {
            viewModel?.stopAutoRefresh()
        }
        .onChange(of: selectedSession) { oldValue, newValue in
            if oldValue != nil && newValue == nil {
                viewModel?.fetchSessions()
            }
        }
        .onChange(of: router.pendingSession) { _, newValue in
            guard let session = newValue else { return }
            viewModel?.fetchSessions()
            selectedSession = session
            router.pendingSession = nil
        }
    }

    private var searchEmptyView: some View {
        ContentUnavailableView.search(text: searchText)
    }

    private var emptyStateView: some View {
        ContentUnavailableView {
            Label(L10n.Sessions.noSessions, systemImage: "bubble.left.and.bubble.right")
        } description: {
            Text(L10n.Sessions.noSessionsDescription)
        } actions: {
            Button(L10n.Sessions.newSession) {
                showNewSessionSheet = true
            }
            .buttonStyle(.borderedProminent)
            .accessibilityIdentifier(AccessibilityID.SessionList.emptyNewSessionButton)
        }
        .accessibilityIdentifier(AccessibilityID.SessionList.emptyState)
    }

    private func sessionsList(_ vm: SessionListViewModel) -> some View {
        List(selection: $selectedSession) {
            ForEach(vm.sessions, id: \.id) { session in
                NavigationLink(value: session) {
                    SessionRowView(rowData: vm.rowDataCache[session.id]
                        ?? .empty)
                }
                .accessibilityIdentifier(AccessibilityID.SessionList.sessionRow)
                .contextMenu {
                    Button(role: .destructive) {
                        vm.sessionToDelete = session
                        showDeleteSessionAlert = true
                    } label: {
                        Label(L10n.Common.delete, systemImage: "trash")
                    }
                }
            }
            .onDelete { offsets in
                guard let first = offsets.first else { return }
                vm.sessionToDelete = vm.sessions[first]
                showDeleteSessionAlert = true
            }
        }
        .listStyle(.insetGrouped)
        .refreshable {
            vm.fetchSessions()
        }
        .alert(L10n.Chat.deleteSessionTitle, isPresented: $showDeleteSessionAlert) {
            Button(L10n.Common.delete, role: .destructive) {
                if let session = vm.sessionToDelete {
                    if selectedSession?.id == session.id {
                        selectedSession = nil
                    }
                    vm.deleteSession(session)
                }
                vm.sessionToDelete = nil
            }
            Button(L10n.Common.cancel, role: .cancel) {
                vm.sessionToDelete = nil
            }
        } message: {
            Text(L10n.Chat.deleteSessionMessage)
        }
    }
}

struct NewSessionSheet: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    let onSelect: (Agent) -> Void

    @State private var agents: [Agent] = []

    var body: some View {
        NavigationStack {
            List {
                if agents.isEmpty {
                    ContentUnavailableView {
                        Label(L10n.Sessions.noAgents, systemImage: "cpu")
                    } description: {
                        Text(L10n.Sessions.noAgentsDescription)
                    }
                } else {
                    ForEach(agents, id: \.id) { agent in
                        Button {
                            onSelect(agent)
                        } label: {
                            HStack {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(agent.name)
                                        .font(.headline)
                                    Text(L10n.Sessions.sessionsCount(agent.sessions.count))
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                                Image(systemName: "chevron.right")
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .tint(.primary)
                        .accessibilityIdentifier(AccessibilityID.NewSessionSheet.agentRow)
                    }
                }
            }
            .navigationTitle(L10n.Sessions.selectAgent)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L10n.Common.cancel) { dismiss() }
                        .accessibilityIdentifier(AccessibilityID.NewSessionSheet.cancelButton)
                }
            }
        }
        .onAppear {
            let descriptor = FetchDescriptor<Agent>(
                predicate: #Predicate { $0.parentAgent == nil },
                sortBy: [SortDescriptor(\.name)]
            )
            agents = (try? modelContext.fetch(descriptor)) ?? []
        }
    }
}
