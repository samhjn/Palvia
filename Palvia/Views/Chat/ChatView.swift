import SwiftUI
import SwiftData

struct ChatView: View {
    @Environment(\.modelContext) private var modelContext
    let session: Session
    @State private var viewModel: ChatViewModel?
    @State private var showTitleEditor = false
    @State private var editingTitle = ""

    var body: some View {
        ZStack {
            if let vm = viewModel {
                chatBody(vm: vm)
            }
        }
        .onAppear {
            if viewModel == nil {
                viewModel = ChatViewModel(session: session, modelContext: modelContext)
            }
            viewModel?.onViewAppear()
        }
        .onDisappear {
            viewModel?.onViewDisappear()
        }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.didEnterBackgroundNotification)) { _ in
            viewModel?.prepareForBackground()
        }
        .onReceive(NotificationCenter.default.publisher(for: ChatViewModel.pendingAttachmentsDidChange)) { note in
            guard let sid = note.userInfo?["sessionId"] as? UUID, sid == session.id else { return }
            viewModel?.refreshPendingAttachmentsFromCache()
        }
    }

    @ViewBuilder
    private func chatBody(vm: ChatViewModel) -> some View {
        ChatContentView(vm: vm)
        .navigationTitle(session.title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Menu {
                    Button {
                        editingTitle = session.title
                        showTitleEditor = true
                    } label: {
                        Label(L10n.Chat.rename, systemImage: "pencil")
                    }

                    Button {
                        if let url = SessionExporter.exportToFile(session) {
                            Self.presentActivitySheet(items: [url])
                        }
                    } label: {
                        Label(L10n.Chat.exportSession, systemImage: "square.and.arrow.up.on.square")
                    }

                    let stats = vm.compressionStats

                    Section {
                        Button {
                            vm.manualCompress()
                        } label: {
                            Label(L10n.Chat.compressContext, systemImage: "arrow.down.right.and.arrow.up.left")
                        }
                        .disabled(vm.isCompressing || vm.isLoading)
                    }

                    Section {
                        Label {
                            Text(L10n.Chat.tokenUsage(active: stats.activeFormatted, threshold: stats.thresholdFormatted))
                        } icon: {
                            Image(systemName: "gauge.medium")
                        }
                        Label {
                            Text(L10n.Chat.messageStats(total: stats.totalMessages, compressed: stats.compressedCount))
                        } icon: {
                            Image(systemName: "doc.text")
                        }
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                        .font(.body)
                        .frame(minWidth: 32, minHeight: 32)
                        .contentShape(Rectangle())
                }
                .accessibilityIdentifier(AccessibilityID.Chat.menuButton)
            }

            ToolbarItem(placement: .topBarTrailing) {
                ChatDisplayModeMenu(vm: vm, agentName: vm.agentDisplayName)
            }
        }
        .alert(L10n.Chat.renameSession, isPresented: $showTitleEditor) {
            TextField(L10n.Chat.title, text: $editingTitle)
            Button(L10n.Common.save) {
                let trimmed = editingTitle.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty {
                    viewModel?.setCustomTitle(trimmed)
                }
            }
            Button(L10n.Common.cancel, role: .cancel) {}
        }
    }
}

private struct ChatDisplayModeMenu: View {
    @Bindable var vm: ChatViewModel
    let agentName: String?

    var body: some View {
        Menu {
            Section {
                Button {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        vm.isVerbose = true
                    }
                } label: {
                    Label {
                        Text(L10n.Chat.verbose)
                    } icon: {
                        if vm.isVerbose {
                            Image(systemName: "checkmark")
                        }
                    }
                }
                .accessibilityIdentifier(AccessibilityID.Chat.verboseOption)
                Button {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        vm.isVerbose = false
                    }
                } label: {
                    Label {
                        Text(L10n.Chat.silent)
                    } icon: {
                        if !vm.isVerbose {
                            Image(systemName: "checkmark")
                        }
                    }
                }
                .accessibilityIdentifier(AccessibilityID.Chat.silentOption)
            } header: {
                if let agentName {
                    Text(L10n.Chat.displayModeScope(agentName))
                }
            }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: vm.isVerbose ? "speaker.wave.2.fill" : "speaker.slash.fill")
                    .font(.caption2)
                Text(vm.isVerbose ? L10n.Chat.verbose : L10n.Chat.silent)
                    .font(.caption2.weight(.medium))
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(
                Capsule()
                    .fill(vm.isVerbose ? Color.accentColor.opacity(0.12) : Color(.systemGray5))
            )
            .foregroundStyle(vm.isVerbose ? Color.accentColor : .secondary)
        }
        .accessibilityIdentifier(AccessibilityID.Chat.displayModeCapsule)
    }
}

@Observable
final class ChatScrollState {
    var isNearBottom = true
    /// Set only by user gesture (drag/track), not by content growth.
    /// Prevents auto-scroll from stopping due to rendering-induced position shifts.
    var userDidScrollAway = false
    /// True only while the scroll view is handling a real pan gesture or the
    /// deceleration that follows it. Programmatic content growth should not set it.
    var userScrollInFlight = false
    /// Incremented by the contentSize observer when the scroll view's content
    /// grows while the view should be at bottom. SwiftUI reacts via onChange
    /// to re-scroll, replacing fragile timer-based corrections.
    var bottomCorrectionTick = 0
    weak var scrollView: UIScrollView?
}

private struct ChatContentView: View {
    @Bindable var vm: ChatViewModel
    @State private var scrollPosition: String?
    @State private var hasRestoredScroll = false
    @State private var forceScrollToBottom = false
    @State private var scrollState = ChatScrollState()
    @State private var displayMessages: [Message] = []
    @State private var lastKnownMessageCount = 0
    @State private var isFollowingTail = true

    /// Compute the filtered message list from current view-model state.
    /// The result is stored in `displayMessages` (`@State`) so that SwiftUI
    /// always has a stable snapshot during collection-view batch updates.
    private func filteredMessages() -> [Message] {
        if vm.isVerbose { return vm.messages }
        return vm.messages.filter { msg in
            if msg.role == .tool { return false }
            if msg.role == .assistant,
               let data = msg.toolCallsData,
               data.count > 2,
               (msg.content ?? "").isEmpty {
                return false
            }
            return true
        }
    }

    private func nearestVisibleId(to target: UUID) -> UUID? {
        let displayed = displayMessages
        if displayed.contains(where: { $0.id == target }) { return target }
        let all = vm.messages
        guard let idx = all.firstIndex(where: { $0.id == target }) else { return displayed.last?.id }
        let visibleIds = Set(displayed.map(\.id))
        for i in stride(from: idx, through: 0, by: -1) {
            if visibleIds.contains(all[i].id) { return all[i].id }
        }
        return displayed.first?.id
    }

    private var shouldAutoFollowTail: Bool {
        isFollowingTail && !scrollState.userDidScrollAway && !scrollState.userScrollInFlight
    }

    private func scroll(_ proxy: ScrollViewProxy, to target: String, animated: Bool = true) {
        let action = {
            proxy.scrollTo(target, anchor: .bottom)
        }
        if animated {
            withAnimation { action() }
        } else {
            action()
        }
    }

    private func scrollToLastMessage(_ proxy: ScrollViewProxy, animated: Bool = true) {
        guard let lastId = displayMessages.last?.id.uuidString else { return }
        scroll(proxy, to: lastId, animated: animated)
    }

    private func scrollToCurrentTail(_ proxy: ScrollViewProxy, animated: Bool = true) {
        if vm.isLoading && (!vm.streamingContent.isEmpty || (vm.isVerbose && !vm.streamingThinking.isEmpty)) {
            scroll(proxy, to: "streaming", animated: animated)
        } else if vm.isLoading && !vm.isCompressing {
            scroll(proxy, to: "loading", animated: animated)
        } else {
            scrollToLastMessage(proxy, animated: animated)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 12) {
                        ForEach(displayMessages, id: \.id) { message in
                            MessageBubbleView(message: message, isVerbose: vm.isVerbose)
                                .id(message.id.uuidString)
                                .accessibilityIdentifier(AccessibilityID.Chat.messageBubble)
                        }

                        if vm.isLoading && (!vm.streamingContent.isEmpty || (vm.isVerbose && !vm.streamingThinking.isEmpty)) {
                            MessageBubbleView(
                                streamingContent: vm.streamingContent,
                                streamingThinking: vm.isVerbose ? vm.streamingThinking : nil,
                                isVerbose: vm.isVerbose
                            )
                            .id("streaming")
                            .accessibilityIdentifier(AccessibilityID.Chat.streamingBubble)
                        }

                        if vm.isLoading && vm.streamingContent.isEmpty && (vm.isVerbose ? vm.streamingThinking.isEmpty : true) && !vm.isCompressing {
                            HStack {
                                ProgressView()
                                    .padding(.trailing, 4)
                                if vm.isCancelling {
                                    Text(L10n.Chat.cancelling)
                                        .font(.subheadline)
                                        .foregroundStyle(.orange)
                                } else if !vm.isVerbose {
                                    TimelineView(.periodic(from: .now, by: 0.3)) { _ in
                                        silentLabel(for: vm.silentStatus)
                                    }
                                } else {
                                    Text(L10n.Chat.thinking)
                                        .font(.subheadline)
                                        .foregroundStyle(.secondary)
                                }
                            }
                        .padding()
                        .id("loading")
                        .accessibilityIdentifier(AccessibilityID.Chat.loadingIndicator)
                    }

                        if vm.isCompressing {
                            CompressionPanel(stats: vm.compressionStats, isCancelling: vm.isCancellingCompression) {
                                vm.cancelCompression()
                            }
                            .id("compressing")
                        }
                    }
                    .padding()
                    .background(ScrollViewOffsetObserver(scrollState: scrollState))
                }
                .scrollPosition(id: $scrollPosition, anchor: .center)
                .onChange(of: vm.messages, initial: true) {
                    let updated = filteredMessages()
                    // Only assign when the identity list actually changed;
                    // skipping no-op reassignments avoids kicking off a
                    // UICollectionView batch update with a zero diff that
                    // can race with an in-flight animation completion.
                    if updated.map(\.id) != displayMessages.map(\.id) {
                        let isInitialPopulation = displayMessages.isEmpty && lastKnownMessageCount == 0
                        displayMessages = updated
                        if isInitialPopulation {
                            lastKnownMessageCount = updated.count
                        }
                    }
                }
                .onChange(of: vm.isVerbose) {
                    let wasFollowingTail = shouldAutoFollowTail
                    // Capture the currently visible message before the list changes.
                    let anchorId = scrollPosition
                    displayMessages = filteredMessages()
                    lastKnownMessageCount = displayMessages.count
                    if wasFollowingTail {
                        DispatchQueue.main.async {
                            scrollToCurrentTail(proxy, animated: false)
                        }
                        return
                    }
                    // After the filtered list updates, restore scroll to the same
                    // message. This replaces the old ratio-based setContentOffset
                    // which broke when rows were removed from the middle.
                    if let anchorId {
                        DispatchQueue.main.async {
                            proxy.scrollTo(anchorId, anchor: .center)
                        }
                    }
                }
                .onAppear {
                    if !hasRestoredScroll {
                        hasRestoredScroll = true
                        if let target = vm.initialScrollTarget,
                           let resolved = nearestVisibleId(to: target) {
                            isFollowingTail = resolved == displayMessages.last?.id
                            DispatchQueue.main.async {
                                proxy.scrollTo(resolved.uuidString, anchor: .center)
                            }
                        } else if let lastId = displayMessages.last?.id {
                            isFollowingTail = true
                            DispatchQueue.main.async {
                                proxy.scrollTo(lastId.uuidString, anchor: .bottom)
                            }
                            // Subsequent corrections as markdown renders to full
                            // height are handled reactively by the contentSize
                            // KVO → bottomCorrectionTick → onChange pipeline.
                        }
                    }
                }
                .onChange(of: displayMessages.count) {
                    let newCount = displayMessages.count
                    let oldCount = lastKnownMessageCount
                    lastKnownMessageCount = newCount

                    // Count decrease = mode switch removed tool messages.
                    // Position is handled by the isVerbose onChange; don't fight it.
                    guard newCount > oldCount || forceScrollToBottom else { return }

                    let shouldForce = forceScrollToBottom
                    forceScrollToBottom = false
                    guard shouldForce || !scrollState.userDidScrollAway else { return }
                    if shouldForce {
                        isFollowingTail = true
                    }
                    scrollToLastMessage(proxy)
                }
                .onChange(of: vm.streamingContent) {
                    guard shouldAutoFollowTail, !vm.streamingContent.isEmpty else { return }
                    scrollToCurrentTail(proxy, animated: false)
                }
                .onChange(of: vm.streamingThinking) {
                    guard shouldAutoFollowTail, vm.isVerbose, !vm.streamingThinking.isEmpty else { return }
                    scrollToCurrentTail(proxy, animated: false)
                }
                .onChange(of: vm.isLoading) { oldValue, newValue in
                    guard oldValue, !newValue, shouldAutoFollowTail else { return }
                    DispatchQueue.main.async {
                        scrollToLastMessage(proxy, animated: false)
                    }
                }
                .onChange(of: scrollState.bottomCorrectionTick) {
                    guard shouldAutoFollowTail else { return }
                    scrollToCurrentTail(proxy, animated: false)
                }
                .onChange(of: scrollState.userDidScrollAway) { _, didScrollAway in
                    if didScrollAway {
                        isFollowingTail = false
                    } else if scrollState.isNearBottom {
                        isFollowingTail = true
                    }
                }
                .onChange(of: scrollState.isNearBottom) { _, isNearBottom in
                    guard isNearBottom, !scrollState.userDidScrollAway else { return }
                    isFollowingTail = true
                }
                
                .onDisappear {
                    if let visibleId = scrollPosition,
                       let uuid = UUID(uuidString: visibleId) {
                        vm.saveScrollPosition(uuid)
                    } else if let lastId = displayMessages.last?.id {
                        vm.saveScrollPosition(lastId)
                    }
                }
                .overlay(alignment: .bottomTrailing) {
                    if scrollState.userDidScrollAway {
                        Button {
                            isFollowingTail = true
                            scrollState.userDidScrollAway = false
                            if let sv = scrollState.scrollView, sv.isDecelerating {
                                sv.setContentOffset(sv.contentOffset, animated: false)
                            }
                            scrollToCurrentTail(proxy)
                            // Further corrections as content renders are handled
                            // by the contentSize KVO → bottomCorrectionTick pipeline.
                        } label: {
                            Image(systemName: "chevron.down")
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundStyle(.secondary)
                                .frame(width: 34, height: 34)
                                .background(.ultraThinMaterial, in: Circle())
                                .shadow(color: .black.opacity(0.08), radius: 4, y: 2)
                        }
                        .padding(.trailing, 16)
                        .padding(.bottom, 8)
                        .transition(.scale(scale: 0.5).combined(with: .opacity))
                        .accessibilityIdentifier(AccessibilityID.Chat.scrollToBottom)
                    }
                }
                .animation(.easeInOut(duration: 0.2), value: scrollState.userDidScrollAway)
            }

            if let error = vm.errorMessage {
                HStack {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(3)
                    Spacer()
                    Button {
                        vm.retryGeneration()
                    } label: {
                        Label(L10n.Chat.retry, systemImage: "arrow.clockwise")
                            .font(.caption)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 6)
                            .contentShape(Rectangle())
                    }
                    .tint(.accentColor)
                    .disabled(vm.isLoading)
                    Button {
                        UIPasteboard.general.string = error
                    } label: {
                        Image(systemName: "doc.on.doc")
                            .font(.caption)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 6)
                            .contentShape(Rectangle())
                    }
                    Button {
                        vm.dismissRetry()
                    } label: {
                        Text(L10n.Common.dismiss)
                            .font(.caption)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 6)
                            .contentShape(Rectangle())
                    }
                }
                .padding(.horizontal)
                .padding(.vertical, 4)
                .background(.ultraThinMaterial)
                .transition(.move(edge: .bottom).combined(with: .opacity))
            } else if vm.canRetry && !vm.isLoading {
                HStack(spacing: 4) {
                    Image(systemName: "arrow.clockwise.circle.fill")
                        .font(.caption)
                        .foregroundStyle(Color.accentColor)
                    Text(L10n.Chat.retryHint)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button {
                        vm.retryGeneration()
                    } label: {
                        Text(L10n.Chat.retry)
                            .font(.caption.weight(.medium))
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                            .contentShape(Rectangle())
                    }
                    .tint(.accentColor)
                    .disabled(vm.isLoading)
                    Button {
                        vm.dismissRetry()
                    } label: {
                        Text(L10n.Common.dismiss)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 6)
                            .contentShape(Rectangle())
                    }
                }
                .padding(.horizontal)
                .padding(.vertical, 4)
                .background(Color.accentColor.opacity(0.06))
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }

            if let warning = vm.modalityWarning {
                HStack(spacing: 6) {
                    Image(systemName: "eye.slash.fill")
                        .font(.caption)
                        .foregroundStyle(.yellow)
                    Text(warning)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button(L10n.Common.dismiss) {
                        vm.modalityWarning = nil
                    }
                    .font(.caption)
                }
                .padding(.horizontal)
                .padding(.vertical, 8)
                .background(Color.yellow.opacity(0.08))
            }

            if let warning = vm.toolUseWarning {
                HStack(spacing: 6) {
                    Image(systemName: "wrench.trianglebadge.exclamationmark")
                        .font(.caption)
                        .foregroundStyle(.orange)
                    Text(warning)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button(L10n.Common.dismiss) {
                        vm.toolUseWarning = nil
                    }
                    .font(.caption)
                }
                .padding(.horizontal)
                .padding(.vertical, 8)
                .background(Color.orange.opacity(0.08))
            }

            if let reason = vm.sendBlockedReason {
                HStack(spacing: 8) {
                    Image(systemName: "lock.fill")
                        .font(.caption)
                        .foregroundStyle(.orange)
                    Text(reason)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button {
                        vm.checkActiveSessionLock()
                    } label: {
                        Text(L10n.Common.refresh)
                            .font(.caption)
                    }
                }
                .padding(.horizontal)
                .padding(.vertical, 8)
                .background(Color.orange.opacity(0.08))
            }


            if let modelName = vm.activeModelName {
                Text(modelName)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal)
                    .padding(.vertical, 2)
            }

            // Slash-command autocomplete chip strip. Shows installed-and-
            // enabled skills that match the in-progress `/<prefix>` and
            // dismisses itself when the input no longer starts with `/`.
            if let suggestions = vm.slashCommandSuggestions {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(suggestions) { suggestion in
                            Button {
                                vm.applySlashSuggestion(suggestion.slug)
                            } label: {
                                HStack(spacing: 4) {
                                    Text("/\(suggestion.slug)")
                                        .font(.caption.monospaced())
                                    Text("·")
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                    Text(suggestion.displayName)
                                        .font(.caption)
                                }
                                .padding(.horizontal, 10)
                                .padding(.vertical, 5)
                                .background(Color.accentColor.opacity(0.12))
                                .clipShape(Capsule())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.horizontal)
                    .padding(.vertical, 4)
                }
            }

            // Slash-command activation notice (positive feedback after a
            // bare `/skill-slug` that doesn't trigger a generation).
            if let notice = vm.slashCommandNotice {
                HStack(spacing: 6) {
                    Image(systemName: "sparkles")
                        .font(.caption)
                        .foregroundStyle(.green)
                    Text(notice)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                }
                .padding(.horizontal)
                .padding(.vertical, 8)
                .background(Color.green.opacity(0.08))
            }

            InputBarView(
                text: $vm.inputText,
                isLoading: vm.isLoading,
                isCompressing: vm.isCompressing && !vm.isLoading,
                isBlocked: !vm.canSend,
                isCancelling: vm.isCancelling,
                canRetry: vm.canRetry,
                cancelFailureReason: vm.cancelFailureReason,
                pendingImages: vm.pendingImages,
                pendingVideos: vm.pendingVideos,
                pendingFiles: vm.pendingFiles,
                isImageDisabled: vm.isImageInputDisabled,
                isVideoDisabled: vm.isImageInputDisabled,
                onSend: {
                    isFollowingTail = true
                    forceScrollToBottom = true
                    vm.sendMessage()
                },
                onStop: { vm.cancelGeneration() },
                onStopCompression: { vm.cancelCompression() },
                onRetry: { vm.retryGeneration() },
                onDismissKeyboard: {},
                onAddImage: { vm.addImage($0) },
                onRemoveImage: { vm.removeImage(id: $0) },
                onAddVideo: { vm.addVideo(from: $0) },
                onRemoveVideo: { vm.removeVideo(id: $0) },
                onAddFile: { vm.addFile(from: $0) },
                onRemoveFile: { vm.removeFile(id: $0) }
            )
        }
        .animation(.easeInOut(duration: 0.25), value: vm.canRetry)
        .animation(.easeInOut(duration: 0.25), value: vm.isLoading)
        .animation(.easeInOut(duration: 0.25), value: vm.errorMessage)
    }

    @ViewBuilder
    private func silentLabel(for status: String) -> some View {
        if status == "tool:generate_video", let phase = ChatViewModel.videoProgress[vm.session.id] {
            videoProgressLabel(phase: phase)
        } else if status.hasPrefix("tool:") {
            let name = String(status.dropFirst(5))
            let meta = ToolMeta.resolve(name)
            HStack(spacing: 6) {
                Image(systemName: meta.icon)
                    .font(.caption)
                    .foregroundStyle(meta.color)
                Text(meta.displayName)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        } else if status.hasPrefix("think:"), let n = Int(status.dropFirst(6)), n > 1 {
            HStack(spacing: 6) {
                Text(L10n.Chat.silentThinking(n))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                if let lastTool = vm.silentLastTool {
                    let meta = ToolMeta.resolve(lastTool)
                    Image(systemName: meta.icon)
                        .font(.caption2)
                        .foregroundStyle(meta.color.opacity(0.6))
                }
            }
        } else {
            Text(L10n.Chat.thinking)
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private func videoProgressLabel(phase: VideoGenerationPhase) -> some View {
        let meta = ToolMeta.resolve("generate_video")
        HStack(spacing: 6) {
            Image(systemName: meta.icon)
                .font(.caption)
                .foregroundStyle(meta.color)
            switch phase {
            case .submitting:
                Text(L10n.Chat.videoSubmitting)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            case .submitted:
                Text(L10n.Chat.videoSubmitted)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            case .polling(_, let elapsed):
                TimelineView(.periodic(from: .now, by: 1.0)) { _ in
                    Text(L10n.Chat.videoGenerating(Int(elapsed)))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            case .downloading:
                Text(L10n.Chat.videoDownloading)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            case .completed:
                Text(L10n.Chat.videoCompleted)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            case .failed(let reason):
                Text(L10n.Chat.videoFailed(reason))
                    .font(.subheadline)
                    .foregroundStyle(.red)
            }
        }
    }
}

// MARK: - Compression Panel

private struct CompressionPanel: View {
    let stats: CompressionStats
    let isCancelling: Bool
    let onCancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                ProgressView()
                    .scaleEffect(0.8)

                Text(L10n.Chat.compressingContext)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.primary)

                Spacer()

                Button(action: onCancel) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.body)
                        .symbolRenderingMode(.hierarchical)
                        .foregroundStyle(.secondary)
                }
                .disabled(isCancelling)
            }

            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(Color(.systemGray5))

                    Capsule()
                        .fill(tokenColor(for: stats.tokenRatio))
                        .frame(width: geo.size.width * min(CGFloat(stats.tokenRatio), 1.0))
                }
            }
            .frame(height: 6)

            HStack {
                Text(L10n.Chat.tokenUsage(active: stats.activeFormatted, threshold: stats.thresholdFormatted))
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Spacer()

                if stats.pendingCount > 0 {
                    Text(L10n.Chat.pendingCompression(stats.pendingCount))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(12)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
        .padding(.horizontal, 4)
    }
}

private func tokenColor(for ratio: Double) -> Color {
    switch ratio {
    case ..<0.6: return .green
    case ..<0.85: return .yellow
    case ..<1.0: return .orange
    default: return .red
    }
}

// MARK: - Helpers

// MARK: - Scroll Offset Observer

struct ScrollViewOffsetObserver: UIViewRepresentable {
    let scrollState: ChatScrollState

    func makeUIView(context: Context) -> UIView {
        let view = UIView(frame: .zero)
        view.isHidden = true
        view.isUserInteractionEnabled = false
        DispatchQueue.main.async {
            guard let scrollView = Self.findScrollView(from: view) else { return }
            scrollState.scrollView = scrollView
            context.coordinator.observe(scrollView)
        }
        return view
    }

    func updateUIView(_ uiView: UIView, context: Context) {}

    func makeCoordinator() -> Coordinator {
        Coordinator(scrollState: scrollState)
    }

    private static func findScrollView(from view: UIView) -> UIScrollView? {
        var current: UIView? = view.superview
        while let sv = current {
            if let scrollView = sv as? UIScrollView { return scrollView }
            current = sv.superview
        }
        return nil
    }

    final class Coordinator: NSObject {
        let scrollState: ChatScrollState
        private var offsetObservation: NSKeyValueObservation?
        private var contentSizeObservation: NSKeyValueObservation?
        private var boundsObservation: NSKeyValueObservation?
        private var contentInsetObservation: NSKeyValueObservation?
        private var displayLink: CADisplayLink?
        private var pendingNearBottom: Bool?
        private var userScrollGestureInProgress = false

        init(scrollState: ChatScrollState) {
            self.scrollState = scrollState
        }

        func observe(_ scrollView: UIScrollView) {
            // Use a CADisplayLink to coalesce contentOffset KVO updates into
            // at most one state change per frame. This prevents a layout
            // feedback loop where KVO → state change → view invalidation →
            // layout → KVO would block the main thread (0x8BADF00D watchdog).
            let link = CADisplayLink(target: self, selector: #selector(displayLinkFired))
            link.add(to: .main, forMode: .common)
            link.isPaused = true
            displayLink = link

            offsetObservation = scrollView.observe(\.contentOffset, options: .new) { [weak self] sv, _ in
                guard let self else { return }
                let distance = max(0, sv.contentSize.height - sv.contentOffset.y - sv.bounds.height)
                let panIsScrolling = self.isUserScrollGestureActive(on: sv)
                if panIsScrolling {
                    self.userScrollGestureInProgress = true
                }
                let isUserScrolling = panIsScrolling || (sv.isDragging && self.userScrollGestureInProgress)
                // Deceleration after a user flick is still user-driven.
                let isUserDriven = isUserScrolling || (self.userScrollGestureInProgress && sv.isDecelerating)
                self.setUserScrollInFlight(isUserDriven)
                let threshold: CGFloat = isUserScrolling ? 50 : 200
                let near = distance <= threshold

                // userDidScrollAway uses a fixed tight threshold (50pt) for
                // both setting and clearing — independent of the wider
                // isNearBottom threshold that varies by interaction mode.
                // This prevents the deceleration-phase 200pt threshold from
                // immediately resetting userDidScrollAway after it was just set.
                let awayFromBottom = distance > 50
                if isUserDriven && awayFromBottom {
                    if !self.scrollState.userDidScrollAway {
                        DispatchQueue.main.async {
                            self.scrollState.userDidScrollAway = true
                        }
                    }
                } else if !awayFromBottom && self.scrollState.userDidScrollAway && isUserDriven {
                    DispatchQueue.main.async {
                        self.scrollState.userDidScrollAway = false
                    }
                }

                if near != self.scrollState.isNearBottom {
                    self.pendingNearBottom = near
                    self.displayLink?.isPaused = false
                } else {
                    self.pendingNearBottom = nil
                }

                if !sv.isDragging, !sv.isDecelerating, !panIsScrolling {
                    self.userScrollGestureInProgress = false
                    self.setUserScrollInFlight(false)
                }
            }

            contentSizeObservation = scrollView.observe(\.contentSize) { [weak self] sv, _ in
                guard let self else { return }
                let isUserDriven = self.isUserScrollGestureActive(on: sv) ||
                    (sv.isDragging && self.userScrollGestureInProgress) ||
                    (self.userScrollGestureInProgress && sv.isDecelerating)
                guard !self.scrollState.userDidScrollAway, !isUserDriven else { return }
                let distance = max(0, sv.contentSize.height - sv.contentOffset.y - sv.bounds.height)
                if distance > 50 {
                    DispatchQueue.main.async {
                        self.scrollState.bottomCorrectionTick &+= 1
                    }
                }
            }

            boundsObservation = scrollView.observe(\.bounds, options: .new) { [weak self] _, _ in
                self?.requestBottomCorrectionIfNeeded()
            }

            contentInsetObservation = scrollView.observe(\.contentInset, options: .new) { [weak self] _, _ in
                self?.requestBottomCorrectionIfNeeded()
            }
        }

        @objc private func displayLinkFired() {
            displayLink?.isPaused = true
            guard let near = pendingNearBottom else { return }
            pendingNearBottom = nil
            if near != scrollState.isNearBottom {
                scrollState.isNearBottom = near
            }
        }

        deinit {
            offsetObservation?.invalidate()
            contentSizeObservation?.invalidate()
            boundsObservation?.invalidate()
            contentInsetObservation?.invalidate()
            displayLink?.invalidate()
        }

        private func setUserScrollInFlight(_ inFlight: Bool) {
            DispatchQueue.main.async {
                let endedNearTail = self.scrollState.userScrollInFlight && !inFlight && !self.scrollState.userDidScrollAway
                guard self.scrollState.userScrollInFlight != inFlight else { return }
                self.scrollState.userScrollInFlight = inFlight
                if endedNearTail {
                    self.scrollState.bottomCorrectionTick += 1
                }
            }
        }

        private func requestBottomCorrectionIfNeeded() {
            DispatchQueue.main.async {
                guard !self.scrollState.userDidScrollAway else { return }
                self.scrollState.bottomCorrectionTick &+= 1
            }
        }

        private func isUserScrollGestureActive(on scrollView: UIScrollView) -> Bool {
            guard scrollView.panGestureRecognizer.state.isUserScrollGesture else { return false }
            let translation = scrollView.panGestureRecognizer.translation(in: scrollView)
            return abs(translation.y) > 1
        }
    }
}

private extension UIGestureRecognizer.State {
    var isUserScrollGesture: Bool {
        switch self {
        case .began, .changed:
            return true
        default:
            return false
        }
    }
}

private extension ChatView {
    static func presentActivitySheet(items: [Any]) {
        guard let windowScene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
              let rootVC = windowScene.windows.first?.rootViewController else { return }
        var topVC = rootVC
        while let presented = topVC.presentedViewController { topVC = presented }
        let activityVC = UIActivityViewController(activityItems: items, applicationActivities: nil)
        if let popover = activityVC.popoverPresentationController {
            popover.sourceView = topVC.view
            popover.sourceRect = CGRect(x: topVC.view.bounds.midX, y: topVC.view.bounds.midY, width: 0, height: 0)
            popover.permittedArrowDirections = []
        }
        topVC.present(activityVC, animated: true)
    }
}
