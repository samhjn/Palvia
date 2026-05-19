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
    }
}

@Observable
final class ChatScrollState {
    var isNearBottom = true
    weak var scrollView: UIScrollView?
}

private struct ChatContentView: View {
    @Bindable var vm: ChatViewModel
    @State private var scrollPosition: String?
    @State private var hasRestoredScroll = false
    @State private var forceScrollToBottom = false
    @State private var scrollState = ChatScrollState()
    @State private var displayMessages: [Message] = []

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
                        displayMessages = updated
                    }
                }
                .onChange(of: vm.isVerbose) {
                    displayMessages = filteredMessages()
                }
                .onAppear {
                    if !hasRestoredScroll {
                        hasRestoredScroll = true
                        if let target = vm.initialScrollTarget,
                           let resolved = nearestVisibleId(to: target) {
                            DispatchQueue.main.async {
                                proxy.scrollTo(resolved.uuidString, anchor: .center)
                            }
                        } else if let lastId = displayMessages.last?.id {
                            DispatchQueue.main.async {
                                proxy.scrollTo(lastId.uuidString, anchor: .bottom)
                            }
                        }
                    }
                }
                .onChange(of: displayMessages.count) {
                    let shouldForce = forceScrollToBottom
                    forceScrollToBottom = false
                    guard shouldForce || scrollState.isNearBottom else { return }
                    withAnimation {
                        proxy.scrollTo(displayMessages.last?.id.uuidString, anchor: .bottom)
                    }
                }
                .onChange(of: vm.streamingContent) {
                    guard scrollState.isNearBottom, !vm.streamingContent.isEmpty else { return }
                    withAnimation {
                        proxy.scrollTo("streaming", anchor: .bottom)
                    }
                }
                .onChange(of: vm.streamingThinking) {
                    guard scrollState.isNearBottom, vm.isVerbose, !vm.streamingThinking.isEmpty else { return }
                    withAnimation {
                        proxy.scrollTo("streaming", anchor: .bottom)
                    }
                }
                .onChange(of: vm.isVerbose) { _, newValue in
                    guard newValue else { return }
                    guard let sv = scrollState.scrollView else { return }
                    let savedOffset = sv.contentOffset.y
                    let savedHeight = sv.contentSize.height
                    guard savedHeight > 0 else { return }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                        let newHeight = sv.contentSize.height
                        guard abs(newHeight - savedHeight) > 1 else { return }
                        let newOffset = savedOffset * (newHeight / savedHeight)
                        let maxScroll = max(0, newHeight - sv.bounds.height)
                        sv.setContentOffset(
                            CGPoint(x: 0, y: min(max(0, newOffset), maxScroll)),
                            animated: false
                        )
                    }
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
                    Button {
                        if let sv = scrollState.scrollView, sv.isDecelerating {
                            sv.setContentOffset(sv.contentOffset, animated: false)
                        }
                        withAnimation {
                            if vm.isLoading && !vm.streamingContent.isEmpty {
                                proxy.scrollTo("streaming", anchor: .bottom)
                            } else if let lastId = displayMessages.last?.id {
                                proxy.scrollTo(lastId.uuidString, anchor: .bottom)
                            }
                        }
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
                    .opacity(scrollState.isNearBottom ? 0 : 1)
                    .scaleEffect(scrollState.isNearBottom ? 0.5 : 1)
                    .animation(.easeInOut(duration: 0.2), value: scrollState.isNearBottom)
                    .allowsHitTesting(!scrollState.isNearBottom)
                    .accessibilityIdentifier(AccessibilityID.Chat.scrollToBottom)
                }
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
        private var displayLink: CADisplayLink?
        private var pendingNearBottom: Bool?

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
                let threshold: CGFloat = (sv.isTracking || sv.isDragging) ? 50 : 200
                let near = distance <= threshold
                if near != self.scrollState.isNearBottom {
                    self.pendingNearBottom = near
                    self.displayLink?.isPaused = false
                } else {
                    self.pendingNearBottom = nil
                }
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
            displayLink?.invalidate()
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
