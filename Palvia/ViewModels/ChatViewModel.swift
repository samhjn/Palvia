import Foundation
import SwiftData
import Observation
import UIKit
import AVFoundation

@Observable
@MainActor
final class ChatViewModel {
    var messages: [Message] = []
    var inputText: String = "" {
        didSet {
            Self.cachedInputTexts[session.id] = inputText
            // Persist eagerly so draft survives app kill.
            let trimmed = inputText.trimmingCharacters(in: .whitespacesAndNewlines)
            session.draftText = trimmed.isEmpty ? nil : inputText
            // Any keystroke after a slash-command activation clears the
            // transient notice — it's a one-shot hint.
            if slashCommandNotice != nil, oldValue != inputText {
                slashCommandNotice = nil
            }
        }
    }
    var isLoading: Bool = false
    var streamingContent: String = ""
    var streamingThinking: String = ""
    var pendingImages: [ImageAttachment] = []
    var pendingVideos: [VideoAttachment] = []
    var pendingFiles: [FileAttachment] = []
    /// Error message shown when a video fails validation (e.g. too large/long).
    var videoValidationError: String?
    var errorMessage: String? {
        didSet {
            if let errorMessage {
                Self.cachedErrors[session.id] = errorMessage
            } else {
                Self.cachedErrors.removeValue(forKey: session.id)
            }
        }
    }
    var activeModelName: String?

    /// True when the last generation ended with an error or was cancelled,
    /// allowing the user to retry without typing a new message.
    var canRetry: Bool = false

    /// If another session of the same agent is active, this holds the blocking reason.
    var sendBlockedReason: String?

    /// True while a cancel request is being processed.
    var isCancelling: Bool = false

    /// If cancel fails or takes too long, explains why.
    var cancelFailureReason: String?

    /// Shown when images or other modalities were stripped for the current model.
    var modalityWarning: String?

    /// Shown when the primary model does not support tool use (function calling).
    var toolUseWarning: String?

    /// Transient notice surfaced after a `/skill-slug` slash-command (e.g.
    /// "Deep Research activated — ask your question.") that doesn't itself
    /// produce an LLM round-trip. The composer reads + clears this on the
    /// next user input. Set by `sendMessage`'s slash-command preprocessor;
    /// consumed by `ChatView` in Phase 5c.
    var slashCommandNotice: String?

    /// Display mode: verbose (show CoT & tool calls) or silent (hide them). Synced to Agent.
    var isVerbose: Bool = true {
        didSet { session.agent?.isVerbose = isVerbose }
    }

    /// Cached from session.agent so ChatContentView.body doesn't observe
    /// SwiftData model properties directly (prevents save-cascade invalidation).
    private(set) var isImageInputDisabled: Bool = false
    private(set) var agentDisplayName: String?

    /// Silent-mode status — survives ViewModel recreation (SwiftData can recreate the VM mid-generation).
    private static var silentStatuses: [UUID: String] = [:]
    private static var silentRounds: [UUID: Int] = [:]
    /// Last tool that was executed, shown alongside thinking status so brief tool calls aren't missed.
    private static var silentLastTools: [UUID: String] = [:]
    /// Video generation progress — keyed by session ID, updated by the progress callback.
    static var videoProgress: [UUID: VideoGenerationPhase] = [:]

    var silentStatus: String {
        get { Self.silentStatuses[session.id] ?? "" }
        set {
            Self.silentStatuses[session.id] = newValue
            notifyLiveActivityStatusUpdate()
        }
    }
    private var silentRound: Int {
        get { Self.silentRounds[session.id] ?? 0 }
        set { Self.silentRounds[session.id] = newValue }
    }
    var silentLastTool: String? {
        Self.silentLastTools[session.id]
    }

    /// Push the current silent-mode status (`think:N` / `tool:X`) and
    /// last-executed tool to the Live Activity so the Lock Screen / Dynamic
    /// Island can display a brief mirroring the in-app silent-mode banner.
    private func notifyLiveActivityStatusUpdate() {
        let sid = session.id
        let status = Self.silentStatuses[sid] ?? ""
        let lastTool = Self.silentLastTools[sid]
        Task { @MainActor in
            Self.keepAliveManager?.onSessionStatusUpdate(
                sessionId: sid,
                silentStatus: status,
                lastTool: lastTool
            )
        }
    }


    /// Whether a manual compression is running.
    var isCompressing: Bool = false

    /// True while a compression cancel is being processed.
    var isCancellingCompression: Bool = false

    /// The message ID the scroll view should initially restore to.
    var initialScrollTarget: UUID?

    let session: Session
    private var modelContext: ModelContext

    private var agentId: UUID? {
        session.agent.map { AgentFileManager.shared.resolveAgentId(for: $0) }
    }
    private var generationTask: Task<Void, Never>?
    /// Explicit cancel closure for the active SSE stream, bypassing cooperative cancellation.
    private var streamCancelAction: (@Sendable () -> Void)?
    /// The actual compression work task — should NOT be cancelled on view disappear.
    private var compressionTask: Task<Void, Never>?
    /// A lightweight polling task that tracks an orphaned compression (started by a previous ViewModel).
    private var compressionMonitorTask: Task<Void, Never>?
    private var monitoringTask: Task<Void, Never>?
    private var cancelled = false
    /// Coalescing flag: when true a deferred `loadMessages` dispatch is already
    /// queued on the main queue and further calls are no-ops until it fires.
    private var loadMessagesScheduled = false
    /// Images returned by tool calls (e.g. from sub-agents) to be attached
    /// to the next final assistant message for display in the chat UI.
    private var pendingToolImageAttachments: [ImageAttachment] = []
    private var pendingToolVideoAttachments: [VideoAttachment] = []

    /// Survives ViewModel recreation caused by SwiftData-triggered view re-renders.
    private static var cachedErrors: [UUID: String] = [:]
    /// Draft input text — survives ViewModel recreation (e.g. silent-mode toggle, navigation).
    private static var cachedInputTexts: [UUID: String] = [:]

    /// Draft pending images — survives ViewModel recreation.
    private static var cachedPendingImages: [UUID: [ImageAttachment]] = [:]
    /// Draft pending videos — survives ViewModel recreation.
    private static var cachedPendingVideos: [UUID: [VideoAttachment]] = [:]
    /// Draft pending generic files — survives ViewModel recreation.
    private static var cachedPendingFiles: [UUID: [FileAttachment]] = [:]

    /// Return cached pending images for a session (used by file browser to exclude draft files).
    static func cachedPendingImages(for sessionId: UUID) -> [ImageAttachment] {
        cachedPendingImages[sessionId] ?? []
    }

    /// Check whether there is a non-empty cached draft for a session (used by session list).
    static func hasCachedInput(for sessionId: UUID) -> Bool {
        if let text = cachedInputTexts[sessionId], !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return true
        }
        if let images = cachedPendingImages[sessionId], !images.isEmpty {
            return true
        }
        if let videos = cachedPendingVideos[sessionId], !videos.isEmpty {
            return true
        }
        if let files = cachedPendingFiles[sessionId], !files.isEmpty {
            return true
        }
        return false
    }

    // MARK: - Share-handoff seeds

    /// Notification broadcast whenever the pending-attachment cache is
    /// updated from outside the ViewModel (e.g. by async video metadata
    /// extraction in `ShareHandoff`). Live ViewModels subscribe so their
    /// `pendingImages` / `pendingVideos` / `pendingFiles` stay in sync.
    static let pendingAttachmentsDidChange = Notification.Name("PalviaPendingAttachmentsDidChange")

    private static func notifyPendingAttachmentsChanged(sessionId: UUID) {
        NotificationCenter.default.post(
            name: pendingAttachmentsDidChange,
            object: nil,
            userInfo: ["sessionId": sessionId]
        )
    }

    /// Append images to the pending-attachment cache for a session. Used by
    /// `ShareHandoff` to pre-populate the compose area of a newly-created
    /// session before its `ChatViewModel` is constructed.
    static func seedPendingImages(for sessionId: UUID, append images: [ImageAttachment]) {
        guard !images.isEmpty else { return }
        var current = cachedPendingImages[sessionId] ?? []
        current.append(contentsOf: images)
        cachedPendingImages[sessionId] = current
        notifyPendingAttachmentsChanged(sessionId: sessionId)
    }

    /// Append videos — parallel to `seedPendingImages`.
    static func seedPendingVideos(for sessionId: UUID, append videos: [VideoAttachment]) {
        guard !videos.isEmpty else { return }
        var current = cachedPendingVideos[sessionId] ?? []
        current.append(contentsOf: videos)
        cachedPendingVideos[sessionId] = current
        notifyPendingAttachmentsChanged(sessionId: sessionId)
    }

    /// Append generic file attachments — parallel to `seedPendingImages`.
    static func seedPendingFiles(for sessionId: UUID, append files: [FileAttachment]) {
        guard !files.isEmpty else { return }
        var current = cachedPendingFiles[sessionId] ?? []
        current.append(contentsOf: files)
        cachedPendingFiles[sessionId] = current
        notifyPendingAttachmentsChanged(sessionId: sessionId)
    }
    /// Sessions where the user explicitly dismissed the retry/error banner.
    private static var dismissedSessions: Set<UUID> = []
    /// Active generation tasks keyed by session ID — survives ViewModel recreation
    /// so a new ViewModel instance can still cancel an orphaned generation.
    private static var activeGenerations: [UUID: Task<Void, Never>] = [:]
    /// Explicit stream-cancel closures keyed by session ID — survives ViewModel recreation.
    private static var activeStreamCancels: [UUID: @Sendable () -> Void] = [:]
    /// Optional keep-alive manager; set by the app to receive session lifecycle events.
    static var keepAliveManager: BackgroundKeepAliveManager?
    /// Maps active generation session IDs to their display names.
    private static var activeSessionNames: [UUID: String] = [:]

    // MARK: - Streaming Relay

    /// Bridges real-time streaming content from the generating VM to any
    /// monitoring (replacement) VM for the same session, avoiding the 1-second
    /// polling degradation when the original ViewModel is destroyed mid-generation.
    @MainActor
    final class StreamingRelay {
        private(set) var content: String = ""
        private(set) var thinking: String = ""
        var messagesDidChange: Bool = false
        private var continuation: AsyncStream<Void>.Continuation?
        private var finished = false

        func send(content: String, thinking: String) {
            self.content = content
            self.thinking = thinking
            continuation?.yield()
        }

        func notifyMessagesChanged() {
            messagesDidChange = true
            continuation?.yield()
        }

        func finish() {
            finished = true
            continuation?.finish()
            continuation = nil
        }

        /// Returns a stream that yields whenever new content or messages are
        /// available.  Only one subscriber at a time; a new call replaces the
        /// previous one (the old continuation is finished first).
        func makeSubscription() -> AsyncStream<Void> {
            continuation?.finish()
            continuation = nil
            guard !finished else {
                return AsyncStream { $0.finish() }
            }
            let (stream, cont) = AsyncStream<Void>.makeStream()
            self.continuation = cont
            return stream
        }
    }

    /// Per-session relays — survives ViewModel recreation so a new monitoring
    /// VM can subscribe to real-time streaming from the orphaned generation.
    private static var streamingRelays: [UUID: StreamingRelay] = [:]

    /// Cancel and clear any active generation for the given session.
    /// Called before session/agent deletion to prevent writes to deleted objects.
    static func cancelAndClearGeneration(for sessionId: UUID) {
        activeStreamCancels[sessionId]?()
        activeStreamCancels.removeValue(forKey: sessionId)
        let wasActive = activeGenerations[sessionId] != nil
        activeGenerations[sessionId]?.cancel()
        activeGenerations.removeValue(forKey: sessionId)
        streamingRelays[sessionId]?.finish()
        streamingRelays.removeValue(forKey: sessionId)
        dismissedSessions.remove(sessionId)
        if wasActive {
            let name = activeSessionNames.removeValue(forKey: sessionId) ?? ""
            Task { @MainActor in
                keepAliveManager?.onSessionCompleted(sessionId: sessionId, sessionName: name, isError: false)
            }
        }
    }

    #if DEBUG
    /// Cancel and clear any active generation for the given session. Test-only alias.
    static func _clearActiveGeneration(for sessionId: UUID) {
        cancelAndClearGeneration(for: sessionId)
    }

    /// Whether a generation is active for the session. Test-only.
    static func _hasActiveGeneration(for sessionId: UUID) -> Bool {
        activeGenerations[sessionId] != nil
    }

    /// Inject a placeholder active generation entry. Test-only.
    static func _simulateActiveGeneration(for sessionId: UUID) {
        activeGenerations[sessionId] = Task {}
    }

    /// Whether a streaming relay exists for the session. Test-only.
    static func _hasStreamingRelay(for sessionId: UUID) -> Bool {
        streamingRelays[sessionId] != nil
    }

    /// Inject a streaming relay and return it so the test can drive it. Test-only.
    @discardableResult
    static func _simulateStreamingRelay(for sessionId: UUID) -> StreamingRelay {
        let relay = StreamingRelay()
        streamingRelays[sessionId] = relay
        return relay
    }

    /// Finish and remove the streaming relay for the session. Test-only.
    static func _clearStreamingRelay(for sessionId: UUID) {
        streamingRelays[sessionId]?.finish()
        streamingRelays.removeValue(forKey: sessionId)
    }
    #endif

    init(session: Session, modelContext: ModelContext) {
        self.session = session
        self.modelContext = modelContext
        self.isVerbose = session.agent?.isVerbose ?? true
        self.isImageInputDisabled = session.agent.map { $0.permissionLevel(for: .files) == .disabled } ?? false
        self.agentDisplayName = session.agent?.name
        // Restore draft text: prefer in-memory cache (more up-to-date), fall back to persisted value.
        if let cached = Self.cachedInputTexts[session.id], !cached.isEmpty {
            self.inputText = cached
        } else if let draft = session.draftText, !draft.isEmpty {
            self.inputText = draft
            Self.cachedInputTexts[session.id] = draft
        }
        // Restore draft images.
        if let cached = Self.cachedPendingImages[session.id], !cached.isEmpty {
            self.pendingImages = cached
        } else if let data = session.draftImagesData,
                  let images = try? JSONDecoder().decode([ImageAttachment].self, from: data), !images.isEmpty {
            self.pendingImages = images
            Self.cachedPendingImages[session.id] = images
        }
        // Restore draft videos.
        if let cached = Self.cachedPendingVideos[session.id], !cached.isEmpty {
            self.pendingVideos = cached
        } else if let data = session.draftVideosData,
                  let videos = try? JSONDecoder().decode([VideoAttachment].self, from: data), !videos.isEmpty {
            self.pendingVideos = videos
            Self.cachedPendingVideos[session.id] = videos
        }
        // Restore draft files. Cache-only — generic files don't persist to
        // Session.draft* yet; the cache is populated by the share-extension
        // handoff and by addFile(_:) during the chat session.
        if let cached = Self.cachedPendingFiles[session.id], !cached.isEmpty {
            self.pendingFiles = cached.filter { !$0.isFileDeleted }
            if self.pendingFiles.count != cached.count {
                Self.cachedPendingFiles[session.id] = self.pendingFiles
            }
        }
        // Load messages synchronously during init so subsequent recovery
        // methods see the current message list immediately.
        messages = session.sortedMessages
        migrateInlineImages()
        refreshCompressionStats()

        checkActiveSessionLock()
        recoverStaleActiveState()
        recoverCompressionState()
        recoverRetryState()
        recoverActiveModelName()
        startMonitoringIfNeeded()
        checkToolUseCapability()
        initialScrollTarget = session.lastViewedMessageId
    }

    /// Reload messages from the persistent session.
    ///
    /// By default, multiple calls within the same main-queue drain cycle are
    /// coalesced into a single update.  This prevents SwiftUI's internal
    /// `UpdateCoalescingCollectionView` from receiving a batch-update while
    /// the item count is still changing, which would otherwise crash with
    /// `_Bug_Detected_In_Client_Of_UICollectionView_Invalid_Number_Of_Items_In_Section`.
    ///
    /// Pass `immediate: true` to bypass coalescing and reload synchronously
    /// (used in unit tests that assert on `messages` right after the call).
    func loadMessages(immediate: Bool = false) {
        if immediate {
            loadMessagesScheduled = false
            messages = session.sortedMessages
            migrateInlineImages()
            refreshCompressionStats()
            if generationTask != nil {
                Self.streamingRelays[session.id]?.notifyMessagesChanged()
            }
            return
        }
        guard !loadMessagesScheduled else { return }
        loadMessagesScheduled = true
        Task { [weak self] in
            guard let self else { return }
            self.loadMessagesScheduled = false
            self.messages = self.session.sortedMessages
            self.migrateInlineImages()
            self.refreshCompressionStats()
            if self.generationTask != nil {
                Self.streamingRelays[self.session.id]?.notifyMessagesChanged()
            }
        }
    }

    /// One-time migration: extract inline base64 images from existing assistant messages
    /// into the unified `imageAttachmentsData` storage.
    private func migrateInlineImages() {
        var needsSave = false
        for msg in messages where msg.role == .assistant {
            if msg.extractAndStoreInlineImages(agentId: agentId) {
                needsSave = true
            }
        }
        if needsSave {
            try? modelContext.save()
        }
    }

    // MARK: - Scroll Position Tracking

    func saveScrollPosition(_ messageId: UUID?) {
        session.lastViewedMessageId = messageId
        try? modelContext.save()
    }

    // MARK: - Active Session Lock

    func checkActiveSessionLock() {
        guard let agent = session.agent else {
            sendBlockedReason = nil
            return
        }

        let otherActive = agent.sessions.first { s in
            s.id != session.id && s.isActive
        }

        if let blocking = otherActive {
            sendBlockedReason = L10n.Chat.sessionBlocked(blocking.title)
        } else {
            sendBlockedReason = nil
        }
    }

    var canSend: Bool {
        sendBlockedReason == nil
    }

    // MARK: - Tool Use Capability Check

    func checkToolUseCapability() {
        guard let agent = session.agent else {
            toolUseWarning = nil
            return
        }
        let router = ModelRouter(modelContext: modelContext)
        let chain = router.resolveProviderChainWithModels(for: agent)
        guard let primary = chain.first else {
            toolUseWarning = nil
            return
        }
        let effectiveModel = primary.modelName ?? primary.provider.modelName
        let caps = primary.provider.capabilities(for: effectiveModel)
        if !caps.supportsToolUse {
            toolUseWarning = L10n.Chat.toolUseUnsupported(effectiveModel)
        } else {
            toolUseWarning = nil
        }
    }

    // MARK: - Cancel Generation

    private var cancelWatchdog: Task<Void, Never>?

    func cancelGeneration() {
        guard isLoading else { return }
        let localTask = generationTask
        let staticTask = Self.activeGenerations[session.id]
        guard localTask != nil || staticTask != nil else { return }

        isCancelling = true
        cancelFailureReason = nil
        cancelled = true
        canRetry = true

        streamCancelAction?()
        Self.activeStreamCancels[session.id]?()
        streamCancelAction = nil
        Self.activeStreamCancels.removeValue(forKey: session.id)

        localTask?.cancel()
        if localTask == nil { staticTask?.cancel() }
        Self.activeGenerations.removeValue(forKey: session.id)

        cancelWatchdog?.cancel()
        cancelWatchdog = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(8))
            guard let self, !Task.isCancelled, self.isCancelling, self.isLoading else { return }
            self.cancelFailureReason = L10n.Chat.cancelStuckReason

            try? await Task.sleep(for: .seconds(15))
            guard !Task.isCancelled, self.isCancelling, self.isLoading else { return }
            self.forceStopGeneration()
        }
    }

    @MainActor
    private func forceStopGeneration() {
        streamCancelAction?()
        Self.activeStreamCancels[session.id]?()
        streamCancelAction = nil
        Self.activeStreamCancels.removeValue(forKey: session.id)
        generationTask?.cancel()
        let wasActive = Self.activeGenerations[session.id] != nil
        Self.activeGenerations[session.id]?.cancel()
        Self.streamingRelays[session.id]?.finish()
        Self.streamingRelays.removeValue(forKey: session.id)
        generationTask = nil
        Self.activeGenerations.removeValue(forKey: session.id)
        isLoading = false
        isCancelling = false
        isCompressing = false
        session.isActive = false
        session.isCompressingContext = false
        session.pendingStreamingContent = nil
        cancelFailureReason = nil
        cancelWatchdog?.cancel()
        cancelWatchdog = nil
        compressionTask?.cancel()
        compressionTask = nil
        compressionMonitorTask?.cancel()
        compressionMonitorTask = nil
        BrowserService.shared.releaseLock(sessionId: session.id)
        if wasActive {
            let name = Self.activeSessionNames.removeValue(forKey: session.id) ?? session.title
            Self.keepAliveManager?.onSessionCompleted(sessionId: session.id, sessionName: name, isError: true)
        }

        let forceStopMsg = Message(
            role: .assistant,
            content: L10n.Chat.forceStoppedContent
        )
        modelContext.insert(forceStopMsg)
        session.messages.append(forceStopMsg)
        session.updatedAt = Date()
        canRetry = true
        try? modelContext.save()
        loadMessages()
    }

    // MARK: - Retry Generation

    /// Dismiss both error and natural retry banners persistently.
    func dismissRetry() {
        errorMessage = nil
        canRetry = false
        Self.dismissedSessions.insert(session.id)
    }

    /// Retry the last generation attempt. Works after API errors or user-initiated cancellation.
    func retryGeneration() {
        guard !isLoading, Self.activeGenerations[session.id] == nil else { return }

        checkActiveSessionLock()
        guard canSend else { return }

        isLoading = true
        Self.dismissedSessions.remove(session.id)
        errorMessage = nil
        canRetry = false
        cancelled = false
        silentRound = 1
        silentStatus = "think:1"

        removeTrailingAbortedMessages()

        session.isActive = true
        Self.streamingRelays[session.id] = StreamingRelay()
        let task = Task { await generateResponse() }
        generationTask = task
        Self.activeGenerations[session.id] = task
        Self.activeSessionNames[session.id] = session.title
        let sid = session.id
        let sname = session.title
        Task { @MainActor in Self.keepAliveManager?.onSessionStarted(sessionId: sid, sessionName: sname) }
    }

    /// Strips partial/aborted assistant messages from the tail of the session
    /// so a retry doesn't feed broken context to the model.
    private func removeTrailingAbortedMessages() {
        let sorted = session.sortedMessages
        var toRemove: [Message] = []
        for msg in sorted.reversed() {
            if msg.role == .user { break }
            if msg.role == .assistant,
               let content = msg.content,
               (content.contains(L10n.Chat.aborted) || content.contains(L10n.Chat.forceStoppedContent)) {
                toRemove.append(msg)
            } else {
                break
            }
        }
        for msg in toRemove {
            session.messages.removeAll { $0.id == msg.id }
            modelContext.delete(msg)
        }
        if !toRemove.isEmpty {
            try? modelContext.save()
            loadMessages()
        }
    }

    // MARK: - Slash-command preprocessing

    /// Run the `/skill-slug` parser against the (already trimmed) input,
    /// resolved against the current agent's installed-and-enabled skills.
    /// Wrapped here so `sendMessage` stays focused on send mechanics.
    private func processSlashCommand(_ text: String) -> SlashCommandResult {
        guard let agent = session.agent else { return .none }
        let installed = Set(
            agent.activeSkills.compactMap { $0.skill }
                .map { SkillPackage.derivedSlug(forName: $0.name) }
        )
        return SlashCommandParser.parse(text) { installed.contains($0) }
    }

    /// Reverse-lookup the user-facing display name for an active skill by its
    /// derived slug. Used to render the `/skill-slug` activation hint with
    /// the same name the user sees in the library, not the slug itself.
    private func activeSkillDisplayName(forSlug slug: String) -> String? {
        guard let agent = session.agent else { return nil }
        for installation in agent.activeSkills {
            guard let skill = installation.skill else { continue }
            if SkillPackage.derivedSlug(forName: skill.name) == slug {
                return skill.effectiveDisplayName
            }
        }
        return nil
    }

    /// One row in the composer's slash-command autocomplete chip strip.
    struct SlashCommandSuggestion: Identifiable, Equatable {
        let slug: String
        let displayName: String
        var id: String { slug }
    }

    /// Suggestions for the autocomplete chip strip rendered above the
    /// composer when the input starts with `/`. Returns `nil` (not empty)
    /// when the strip should be hidden so SwiftUI can collapse the layout.
    var slashCommandSuggestions: [SlashCommandSuggestion]? {
        let trimmed = inputText.drop { $0.isWhitespace }
        guard trimmed.first == "/" else { return nil }
        guard let agent = session.agent else { return nil }
        // Substring after `/` up to the first whitespace — the in-progress
        // prefix the user is filtering by. Underscores are normalized to
        // hyphens to match the parser's slug normalization.
        let afterSlash = trimmed.dropFirst()
        let prefixEnd = afterSlash.firstIndex(where: { $0.isWhitespace }) ?? afterSlash.endIndex
        let prefix = String(afterSlash[..<prefixEnd])
            .lowercased()
            .replacingOccurrences(of: "_", with: "-")

        let matches = agent.activeSkills.compactMap { installation -> SlashCommandSuggestion? in
            guard let skill = installation.skill else { return nil }
            let slug = SkillPackage.derivedSlug(forName: skill.name)
            if !prefix.isEmpty, !slug.hasPrefix(prefix) { return nil }
            return SlashCommandSuggestion(slug: slug, displayName: skill.effectiveDisplayName)
        }
        return matches.isEmpty ? nil : matches.sorted { $0.slug < $1.slug }
    }

    /// Apply the user's tap on an autocomplete chip. Replaces the in-progress
    /// `/prefix` with `/slug ` (trailing space so the user can immediately
    /// type the rest of the message).
    func applySlashSuggestion(_ slug: String) {
        let trimmedLeading = inputText.drop { $0.isWhitespace }
        // Preserve any trailing remainder past the first whitespace — so a
        // user typing `/dee what is X?` and tapping `deep-research` lands on
        // `/deep-research what is X?` rather than losing the tail.
        let afterSlash = trimmedLeading.dropFirst()
        let prefixEnd = afterSlash.firstIndex(where: { $0.isWhitespace }) ?? afterSlash.endIndex
        let tail = String(afterSlash[prefixEnd...]).drop { $0.isWhitespace }
        let suffix = tail.isEmpty ? " " : " " + String(tail)
        inputText = "/" + slug + suffix
    }

    // MARK: - Send Message

    func sendMessage() {
        var text = inputText.trimmingCharacters(in: .whitespacesAndNewlines)

        // Slash-command preprocessing — `/skill-slug ...` activates a skill
        // for this session and (when there's a tail) sends only the tail to
        // the LLM. Run before the empty-text guard so a bare `/skill-slug`
        // can still mark the slug active without sending an empty message.
        switch processSlashCommand(text) {
        case .none:
            break
        case .activate(let slug, let remaining):
            session.activatedSkillSlugs.insert(slug)
            text = remaining
        case .activateOnly(let slug):
            session.activatedSkillSlugs.insert(slug)
            // Clear input BEFORE setting the notice — the inputText didSet
            // clears any pending notice on every keystroke, and assigning ""
            // counts. Reordering keeps the notice visible.
            inputText = ""
            session.draftText = nil
            let displayName = activeSkillDisplayName(forSlug: slug) ?? slug
            slashCommandNotice = L10n.Chat.skillActivated(displayName)
            try? modelContext.save()
            return
        }

        guard !text.isEmpty || !pendingImages.isEmpty || !pendingVideos.isEmpty || !pendingFiles.isEmpty else { return }
        guard !isLoading, Self.activeGenerations[session.id] == nil else { return }

        checkActiveSessionLock()
        guard canSend else { return }

        isLoading = true
        inputText = ""
        session.draftText = nil
        Self.dismissedSessions.remove(session.id)
        canRetry = false
        errorMessage = nil
        silentRound = 1
        silentStatus = "think:1"

        // Promote inline draft images to file-backed attachments now that the message is being sent.
        let finalImages: [ImageAttachment] = pendingImages.compactMap { attachment in
            if attachment.fileReference != nil { return attachment }
            guard let agent = session.agent else { return attachment }
            let aid = AgentFileManager.shared.resolveAgentId(for: agent)
            guard let image = attachment.uiImage else { return attachment }
            return ImageAttachment.from(image: image, agentId: aid) ?? attachment
        }
        let imageData: Data? = finalImages.isEmpty ? nil : try? JSONEncoder().encode(finalImages)
        pendingImages = []
        Self.cachedPendingImages.removeValue(forKey: session.id)
        session.draftImagesData = nil

        // Finalize pending video attachments (already file-backed from addVideo).
        let finalVideos = pendingVideos.filter { !$0.isFileDeleted }
        let videoData: Data? = finalVideos.isEmpty ? nil : try? JSONEncoder().encode(finalVideos)
        pendingVideos = []
        Self.cachedPendingVideos.removeValue(forKey: session.id)
        session.draftVideosData = nil

        // Finalize pending file attachments (already file-backed from addFile).
        let finalFiles = pendingFiles.filter { !$0.isFileDeleted }
        let fileData: Data? = finalFiles.isEmpty ? nil : try? JSONEncoder().encode(finalFiles)
        pendingFiles = []
        Self.cachedPendingFiles.removeValue(forKey: session.id)

        // Embed agentfile:// refs into message content so images are part of the
        // file/ref system and visible in the AI context via resolveAgentFileImages.
        var messageContent = text
        for img in finalImages {
            if let ref = img.fileReference {
                messageContent += "\n![image](\(ref))"
            }
        }
        // Append generic file references so the agent can read them from disk.
        for f in finalFiles {
            messageContent += "\n[\(f.name)](\(f.fileReference))"
        }

        let userMessage = Message(role: .user, content: messageContent)
        userMessage.imageAttachmentsData = imageData
        userMessage.videoAttachmentsData = videoData
        userMessage.fileAttachmentsData = fileData
        if imageData != nil || videoData != nil { userMessage.recalculateTokenEstimate() }
        modelContext.insert(userMessage)
        session.messages.append(userMessage)
        session.updatedAt = Date()

        if !session.isTitleCustomized && session.title == L10n.Chat.newChat {
            let titleText = text.prefix(40)
            session.title = titleText.count < text.count ? "\(titleText)..." : String(titleText)
        }

        try? modelContext.save()
        loadMessages()

        cancelled = false
        session.isActive = true
        Self.streamingRelays[session.id] = StreamingRelay()
        let task = Task { await generateResponse() }
        generationTask = task
        Self.activeGenerations[session.id] = task
        Self.activeSessionNames[session.id] = session.title
        let sid = session.id
        let sname = session.title
        Task { @MainActor in Self.keepAliveManager?.onSessionStarted(sessionId: sid, sessionName: sname) }
    }

    private var generationDepth = 0

    @MainActor
    func generateResponse() async {
        let isTopLevel = generationDepth == 0
        generationDepth += 1

        if isTopLevel {
            isLoading = true
            streamingContent = ""
            streamingThinking = ""
            errorMessage = nil
            canRetry = false
            session.isActive = true
            try? modelContext.save()
        } else {
            silentRound += 1
            silentStatus = "think:\(silentRound)"
            streamingContent = ""
            streamingThinking = ""
        }

        defer {
            generationDepth -= 1
            if generationDepth == 0 {
                isLoading = false
                streamingContent = ""
                streamingThinking = ""
                isCancelling = false
                cancelFailureReason = nil
                cancelWatchdog?.cancel()
                cancelWatchdog = nil
                streamCancelAction = nil
                Self.streamingRelays[session.id]?.finish()
                Self.streamingRelays.removeValue(forKey: session.id)
                Self.activeGenerations.removeValue(forKey: session.id)
                Self.activeStreamCancels.removeValue(forKey: session.id)
                Self.silentStatuses.removeValue(forKey: session.id)
                Self.silentRounds.removeValue(forKey: session.id)
                Self.silentLastTools.removeValue(forKey: session.id)
                Self.videoProgress.removeValue(forKey: session.id)
                session.isActive = false
                session.pendingStreamingContent = nil
                generationTask = nil
                if cancelled || Task.isCancelled {
                    canRetry = true
                }
                try? modelContext.save()
                BrowserService.shared.releaseLock(sessionId: session.id)

                let sessionName = Self.activeSessionNames.removeValue(forKey: session.id) ?? session.title
                Self.keepAliveManager?.onSessionCompleted(
                    sessionId: session.id,
                    sessionName: sessionName,
                    isError: errorMessage != nil
                )

                // Update embedding after generation completes (handles continued sessions)
                SessionVectorStore(modelContext: modelContext)
                    .updateEmbedding(for: session)
            }
        }

        guard let agent = session.agent else {
            errorMessage = L10n.Chat.noAgent
            return
        }

        do {
            let router = ModelRouter(modelContext: modelContext)
            let promptBuilder = PromptBuilder()
            let contextManager = ContextManager()

            // Compress BEFORE building context so the LLM always gets a
            // right-sized window instead of a bloated or empty one.
            await compressIfNeeded(agent: agent, router: router)

            guard !Task.isCancelled, !cancelled else { return }

            // Compute related sessions once at session start (first generation)
            // and persist them so the system prompt stays stable across turns.
            let relatedSessions: [(id: UUID, title: String, updatedAt: Date)]
            if agent.permissionLevel(for: .sessions) != .disabled {
                relatedSessions = Self.resolveRelatedSessions(
                    session: session,
                    modelContext: modelContext
                )
            } else {
                relatedSessions = []
            }

            let systemPrompt = promptBuilder.buildSystemPrompt(
                for: agent,
                isSubAgent: agent.parentAgent != nil,
                relatedSessions: relatedSessions,
                activatedSkillSlugs: session.activatedSkillSlugs
            )
            var contextMessages = contextManager.buildContextWindow(
                session: session,
                systemPrompt: systemPrompt
            )

            let chain = router.resolveProviderChainWithModels(for: agent)
            var supportsVision = false
            if let primary = chain.first {
                let effectiveModel = primary.modelName ?? primary.provider.modelName
                let caps = primary.provider.capabilities(for: effectiveModel)
                supportsVision = caps.supportsVision
                let stripped = Self.stripUnsupportedModalities(from: &contextMessages, capabilities: caps)
                if stripped.total > 0 {
                    if stripped.videos > 0 && stripped.images == 0 {
                        modalityWarning = "\(stripped.videos) video(s) removed — \(effectiveModel) does not support video input."
                    } else if stripped.images > 0 && stripped.videos == 0 {
                        modalityWarning = L10n.Chat.modalityStripped(stripped.images, effectiveModel)
                    } else {
                        modalityWarning = L10n.Chat.modalityStripped(stripped.total, effectiveModel)
                    }
                } else {
                    modalityWarning = nil
                }
                if !caps.supportsToolUse {
                    toolUseWarning = L10n.Chat.toolUseUnsupported(effectiveModel)
                } else {
                    toolUseWarning = nil
                }
            }

            let toolDefs = ToolDefinitions.tools(for: agent, supportsVision: supportsVision)

            var fullContent = ""
            var fullThinking = ""
            var thinkingSignature: String?
            var pendingToolCalls: [LLMToolCall] = []
            var lastUsage: LLMUsage?

            let (stream, providerName, _, cancelStream) = try await router.chatCompletionStreamWithFailover(
                agent: agent,
                messages: contextMessages,
                tools: toolDefs
            )
            streamCancelAction = cancelStream
            Self.activeStreamCancels[session.id] = cancelStream
            activeModelName = providerName

            var lastPersistTime = Date.distantPast

            for await chunk in stream {
            if Task.isCancelled || cancelled {
                if !fullContent.isEmpty || !pendingToolImageAttachments.isEmpty || !pendingToolVideoAttachments.isEmpty {
                    let partialMsg = Message(
                        role: .assistant,
                        content: fullContent.isEmpty ? nil : fullContent + L10n.Chat.aborted
                    )
                    partialMsg.extractAndStoreInlineImages(agentId: agentId)
                    attachPendingToolMedia(to: partialMsg)
                    modelContext.insert(partialMsg)
                    session.messages.append(partialMsg)
                    session.updatedAt = Date()
                    session.pendingStreamingContent = nil
                    try? modelContext.save()
                    loadMessages()
                }
                canRetry = true
                return
            }

                switch chunk {
                case .thinking(let text):
                    fullThinking += text
                    streamingThinking = fullThinking
                    Self.streamingRelays[session.id]?.send(content: streamingContent, thinking: fullThinking)
                case .thinkingSignature(let sig):
                    thinkingSignature = sig
                case .content(let text):
                    fullContent += text
                    streamingContent = fullContent
                    Self.streamingRelays[session.id]?.send(content: fullContent, thinking: streamingThinking)
                    let now = Date()
                    let isFirstChunk = lastPersistTime == Date.distantPast
                    if isFirstChunk || now.timeIntervalSince(lastPersistTime) >= 1.0 {
                        session.pendingStreamingContent = fullContent
                        session.updatedAt = now
                        try? modelContext.save()
                        lastPersistTime = now
                    }
                case .toolCall(let toolCall):
                    pendingToolCalls.append(toolCall)
                case .usage(let usage):
                    lastUsage = usage
                case .done:
                    break
                case .error(let error):
                    errorMessage = error
                    canRetry = true
                    return
                }
            }

            session.pendingStreamingContent = nil

            if Task.isCancelled || cancelled {
                if !fullContent.isEmpty || !pendingToolImageAttachments.isEmpty || !pendingToolVideoAttachments.isEmpty {
                    let partialMsg = Message(
                        role: .assistant,
                        content: fullContent.isEmpty ? nil : fullContent + L10n.Chat.aborted
                    )
                    partialMsg.extractAndStoreInlineImages(agentId: agentId)
                    attachPendingToolMedia(to: partialMsg)
                    modelContext.insert(partialMsg)
                    session.messages.append(partialMsg)
                    session.updatedAt = Date()
                    try? modelContext.save()
                    loadMessages()
                }
                canRetry = true
                return
            }

            let (cleanedContent, thinkingFromTags) = Self.extractThinkTags(from: fullContent)
            let combinedThinking: String? = {
                var parts: [String] = []
                if !fullThinking.isEmpty { parts.append(fullThinking) }
                if !thinkingFromTags.isEmpty { parts.append(thinkingFromTags) }
                return parts.isEmpty ? nil : parts.joined(separator: "\n\n")
            }()
            let finalContent = thinkingFromTags.isEmpty ? fullContent : cleanedContent

            if !pendingToolCalls.isEmpty {
                streamingContent = ""
                streamingThinking = ""
                Self.streamingRelays[session.id]?.send(content: "", thinking: "")

                let assistantMsg = Message(
                    role: .assistant,
                    content: finalContent.isEmpty ? nil : finalContent,
                    toolCallsData: try? JSONEncoder().encode(pendingToolCalls)
                )
                assistantMsg.thinkingContent = combinedThinking
                assistantMsg.thinkingSignature = thinkingSignature
                assistantMsg.extractAndStoreInlineImages(agentId: agentId)
                Self.applyAPIUsage(lastUsage, to: assistantMsg)
                modelContext.insert(assistantMsg)
                session.messages.append(assistantMsg)
                try? modelContext.save()
                loadMessages()

                await processToolCalls(pendingToolCalls, router: router, agent: agent)
            } else if !finalContent.isEmpty || combinedThinking != nil {
                let assistantMsg = Message(role: .assistant, content: finalContent.isEmpty ? nil : finalContent)
                assistantMsg.thinkingContent = combinedThinking
                assistantMsg.thinkingSignature = thinkingSignature
                assistantMsg.extractAndStoreInlineImages(agentId: agentId)
                attachPendingToolMedia(to: assistantMsg)
                Self.applyAPIUsage(lastUsage, to: assistantMsg)
                modelContext.insert(assistantMsg)
                session.messages.append(assistantMsg)
                session.updatedAt = Date()
                try? modelContext.save()
                loadMessages()
            } else if !pendingToolImageAttachments.isEmpty || !pendingToolVideoAttachments.isEmpty {
                let assistantMsg = Message(role: .assistant, content: nil)
                attachPendingToolMedia(to: assistantMsg)
                Self.applyAPIUsage(lastUsage, to: assistantMsg)
                modelContext.insert(assistantMsg)
                session.messages.append(assistantMsg)
                session.updatedAt = Date()
                try? modelContext.save()
                loadMessages()
            }
        } catch {
            if Task.isCancelled || cancelled {
                if !(error is CancellationError) {
                    errorMessage = error.localizedDescription
                }
            } else {
                errorMessage = error.localizedDescription
            }
            canRetry = true
            pendingToolImageAttachments = []
            pendingToolVideoAttachments = []
        }
    }

    @MainActor
    private func processToolCalls(
        _ toolCalls: [LLMToolCall],
        router: ModelRouter,
        agent: Agent
    ) async {
        let fnRouter = FunctionCallRouter(agent: agent, modelContext: modelContext, sessionId: session.id)

        // Wire video generation progress callback for real-time UI updates
        let sessionId = session.id
        fnRouter.videoProgressCallback = { @Sendable phase in
            Task { @MainActor in
                ChatViewModel.videoProgress[sessionId] = phase
            }
        }

        if Task.isCancelled || cancelled {
            let cancelMsg = Message(
                role: .assistant,
                content: L10n.Chat.toolCallAborted
            )
            modelContext.insert(cancelMsg)
            session.messages.append(cancelMsg)
            try? modelContext.save()
            loadMessages()
            return
        }

        // Safety rule:
        // - Only `message_sub_agent` is allowed to run in parallel.
        // - All other tools (including `create_sub_agent`) stay sequential to avoid
        //   concurrent SwiftData writes and ordering issues.
        var results: [(Int, LLMToolCall, ToolCallResult)] = []
        var index = 0
        while index < toolCalls.count {
            let current = toolCalls[index]
            if current.function.name == "message_sub_agent" {
                var parallelBatch: [(Int, LLMToolCall)] = []
                var cursor = index
                while cursor < toolCalls.count, toolCalls[cursor].function.name == "message_sub_agent" {
                    parallelBatch.append((cursor, toolCalls[cursor]))
                    cursor += 1
                }

                if parallelBatch.count == 1, let only = parallelBatch.first {
                    silentStatus = "tool:\(only.1.function.name)"
                    let result = await fnRouter.execute(toolCall: only.1)
                    results.append((only.0, only.1, result))
                } else {
                    silentStatus = "tool:message_sub_agent"
                    await withTaskGroup(of: (Int, LLMToolCall, ToolCallResult).self) { group in
                        for (batchIndex, toolCall) in parallelBatch {
                            group.addTask { @MainActor in
                                let result = await fnRouter.execute(toolCall: toolCall)
                                return (batchIndex, toolCall, result)
                            }
                        }
                        for await item in group {
                            results.append(item)
                        }
                    }
                }

                index = cursor
            } else {
                silentStatus = "tool:\(current.function.name)"
                let result = await fnRouter.execute(toolCall: current)
                results.append((index, current, result))
                index += 1
            }

            if Task.isCancelled || cancelled {
                let cancelMsg = Message(
                    role: .assistant,
                    content: L10n.Chat.toolCallAborted
                )
                modelContext.insert(cancelMsg)
                session.messages.append(cancelMsg)
                try? modelContext.save()
                loadMessages()
                return
            }
        }

        results.sort { $0.0 < $1.0 }

        if Task.isCancelled || cancelled {
            let cancelMsg = Message(
                role: .assistant,
                content: L10n.Chat.toolCallAborted
            )
            modelContext.insert(cancelMsg)
            session.messages.append(cancelMsg)
            try? modelContext.save()
            loadMessages()
            return
        }

        for (_, toolCall, result) in results {
            let toolMsg = Message(
                role: .tool,
                content: result.text,
                toolCallId: toolCall.id,
                name: toolCall.function.name
            )
            if let images = result.imageAttachments, !images.isEmpty {
                if let data = try? JSONEncoder().encode(images) {
                    toolMsg.imageAttachmentsData = data
                    toolMsg.recalculateTokenEstimate()
                }
                pendingToolImageAttachments.append(contentsOf: images)
            }
            if let videos = result.videoAttachments, !videos.isEmpty {
                if let data = try? JSONEncoder().encode(videos) {
                    toolMsg.videoAttachmentsData = data
                    toolMsg.recalculateTokenEstimate()
                }
                pendingToolVideoAttachments.append(contentsOf: videos)
            }
            modelContext.insert(toolMsg)
            session.messages.append(toolMsg)
        }

        if let lastCall = results.last {
            Self.silentLastTools[session.id] = lastCall.1.function.name
        }
        // Setting silentStatus triggers notifyLiveActivityStatusUpdate, which
        // will also pick up the freshly-recorded last-tool icon above.
        silentStatus = "think:\(silentRound)"
        try? modelContext.save()
        loadMessages()

        if Task.isCancelled || cancelled {
            pendingToolImageAttachments = []
            pendingToolVideoAttachments = []
            return
        }

        await generateResponse()
    }

    /// Merge any images and videos accumulated from tool calls into the given assistant message.
    private func attachPendingToolMedia(to message: Message) {
        guard !pendingToolImageAttachments.isEmpty || !pendingToolVideoAttachments.isEmpty else { return }

        if !pendingToolImageAttachments.isEmpty {
            let existing: [ImageAttachment] = message.imageAttachmentsData.flatMap {
                try? JSONDecoder().decode([ImageAttachment].self, from: $0)
            } ?? []
            let all = existing + pendingToolImageAttachments
            message.imageAttachmentsData = try? JSONEncoder().encode(all)
            pendingToolImageAttachments = []
        }

        if !pendingToolVideoAttachments.isEmpty {
            let existing: [VideoAttachment] = message.videoAttachmentsData.flatMap {
                try? JSONDecoder().decode([VideoAttachment].self, from: $0)
            } ?? []
            let all = existing + pendingToolVideoAttachments
            message.videoAttachmentsData = try? JSONEncoder().encode(all)
            pendingToolVideoAttachments = []
        }

        message.recalculateTokenEstimate()
    }

    /// Compress context if active tokens exceed the threshold.
    /// Called BEFORE each LLM call so the context window stays right-sized.
    @MainActor
    private func compressIfNeeded(agent: Agent, router: ModelRouter) async {
        guard !Task.isCancelled, !cancelled else { return }
        let threshold = agent.effectiveCompressionThreshold
        let compressor = SessionCompressor(compressionThreshold: threshold)
        let contextManager = ContextManager()
        let activeTokens = contextManager.activeContextTokens(session: session)

        guard compressor.shouldCompress(session: session) else {
            print("[AutoCompress] Not needed — activeTokens=\(activeTokens), threshold=\(threshold)")
            return
        }

        print("[AutoCompress] Triggered — activeTokens=\(activeTokens) > threshold=\(threshold)")

        isCompressing = true
        session.isCompressingContext = true
        try? modelContext.save()
        defer {
            isCompressing = false
            session.isCompressingContext = false
            try? modelContext.save()
        }

        guard let provider = router.primaryProvider(for: agent) else {
            print("[AutoCompress] FAIL: No provider available for compression")
            return
        }

        let llmService = LLMService(provider: provider)
        let result = await compressor.compress(session: session, llmService: llmService)

        guard !Task.isCancelled, !cancelled else {
            print("[AutoCompress] Cancelled after compress() returned")
            return
        }

        if let result {
            compressor.commit(result: result, to: session, modelContext: modelContext)
            compressor.autoGenerateTitleIfNeeded(session: session, llmService: llmService, modelContext: modelContext)
            // Update vector embedding after compression
            SessionVectorStore(modelContext: modelContext)
                .updateEmbedding(for: session)
            let newTokens = contextManager.activeContextTokens(session: session)
            print("[AutoCompress] Committed — tokens \(activeTokens) → \(newTokens)")
        } else {
            print("[AutoCompress] compress() returned nil — compression was not applied, continuing with uncompressed context (\(activeTokens) tokens)")
        }
        loadMessages()
    }

    // MARK: - Manual Compression

    func manualCompress() {
        guard !isCompressing, compressionTask == nil else { return }
        guard let agent = session.agent else { return }

        isCompressing = true
        isCancellingCompression = false
        session.isCompressingContext = true
        try? modelContext.save()

        let session = self.session
        let modelContext = self.modelContext

        compressionTask = Task { @MainActor [weak self] in
            guard let self else {
                session.isCompressingContext = false
                try? modelContext.save()
                return
            }

            defer {
                self.isCompressing = false
                self.isCancellingCompression = false
                session.isCompressingContext = false
                self.compressionTask = nil
                try? modelContext.save()
            }

            let router = ModelRouter(modelContext: modelContext)
            guard let provider = router.primaryProvider(for: agent) else {
                self.errorMessage = L10n.Chat.noCompressModel
                return
            }

            let threshold = agent.effectiveCompressionThreshold
            let compressor = SessionCompressor(compressionThreshold: threshold)
            let contextManager = ContextManager()
            let beforeTokens = contextManager.activeContextTokens(session: session)
            print("[ManualCompress] Start — activeTokens=\(beforeTokens), threshold=\(threshold)")

            let llmService = LLMService(provider: provider)
            let result = await compressor.compress(session: session, llmService: llmService)

            guard !Task.isCancelled else {
                print("[ManualCompress] Cancelled")
                return
            }

            if let result {
                compressor.commit(result: result, to: session, modelContext: modelContext)
                compressor.autoGenerateTitleIfNeeded(session: session, llmService: llmService, modelContext: modelContext)
                // Update vector embedding after manual compression
                SessionVectorStore(modelContext: modelContext)
                    .updateEmbedding(for: session)
                let afterTokens = contextManager.activeContextTokens(session: session)
                print("[ManualCompress] Committed — tokens \(beforeTokens) → \(afterTokens)")
            } else {
                print("[ManualCompress] compress() returned nil — no changes applied")
            }
            self.loadMessages()
        }
    }

    func cancelCompression() {
        guard isCompressing else { return }
        isCancellingCompression = true
        compressionTask?.cancel()
        compressionTask = nil
        compressionMonitorTask?.cancel()
        compressionMonitorTask = nil
        isCompressing = false
        isCancellingCompression = false
        session.isCompressingContext = false
        try? modelContext.save()
    }

    // MARK: - View Lifecycle

    func onViewAppear() {
        loadMessages()
        checkActiveSessionLock()
        recoverStaleActiveState()
        recoverCompressionState()
        if !session.isActive && generationTask == nil && Self.activeGenerations[session.id] == nil {
            isLoading = false
            streamingContent = ""
        }
        recoverRetryState()
        startMonitoringIfNeeded()
        checkToolUseCapability()
        refreshPendingAttachmentsFromCache()
    }

    private func recoverRetryState() {
        guard !isLoading, !canRetry, generationTask == nil else { return }
        guard !session.isActive else { return }
        guard !Self.dismissedSessions.contains(session.id) else { return }
        guard let last = session.sortedMessages.last else { return }

        if last.role == .user {
            canRetry = true
            if errorMessage == nil, let cached = Self.cachedErrors[session.id] {
                errorMessage = cached
            }
        } else if last.role == .assistant,
                  let content = last.content,
                  content.contains(L10n.Chat.aborted) || content.contains(L10n.Chat.forceStoppedContent) {
            canRetry = true
        }
    }

    private func recoverActiveModelName() {
        guard activeModelName == nil, let agent = session.agent else { return }
        let router = ModelRouter(modelContext: modelContext)
        let chain = router.resolveProviderChainWithModels(for: agent)
        guard let primary = chain.first else { return }
        let effectiveModel = primary.modelName ?? primary.provider.modelName
        activeModelName = "\(primary.provider.name) (\(effectiveModel))"
    }

    func onViewDisappear() {
        stopMonitoring()
        compressionMonitorTask?.cancel()
        compressionMonitorTask = nil
        isCompressing = false
        cancelWatchdog?.cancel()
        cancelWatchdog = nil
        // Flush draft text to disk so it survives app quit.
        try? modelContext.save()
    }

    /// Prepare for app suspension/termination. When keep-alive is enabled and
    /// sessions are active, streams are preserved so background execution can
    /// continue. Otherwise, streams are cancelled to free the main thread for
    /// the system's exit signal.
    func prepareForBackground() {
        if Self.keepAliveManager?.shouldPreserveStreams == true {
            // Keep-alive active — let the generation continue in the background
            return
        }
        streamCancelAction?()
        Self.activeStreamCancels[session.id]?()
    }

    // MARK: - Stale Active State Recovery

    /// If the session is marked active but no task is running and this is a fresh
    /// ViewModel (app was killed / navigated away for a long time), reset the flag.
    private func recoverStaleActiveState() {
        guard session.isActive, generationTask == nil else { return }

        // A generation started by a previous ViewModel instance is still running
        // in the static dictionary — don't reset the session state.
        if Self.activeGenerations[session.id] != nil { return }

        let lastUpdate = session.updatedAt
        let staleDuration: TimeInterval = 120
        if Date().timeIntervalSince(lastUpdate) > staleDuration {
            session.isActive = false
            session.pendingStreamingContent = nil
            try? modelContext.save()
            let sessionId = session.id
            Task { @MainActor in
                BrowserService.shared.releaseLock(sessionId: sessionId)
            }
        }
    }

    // MARK: - Compression State Recovery

    /// Recover the UI compression indicator when the persistent flag is set
    /// but this ViewModel doesn't own the task (e.g. view was recreated).
    private func recoverCompressionState() {
        if session.isCompressingContext {
            if compressionTask != nil {
                // We own the real task — just restore the UI flag.
                isCompressing = true
            } else {
                // We don't own the task; either it's running from a previous
                // ViewModel instance, or it's stale.
                let staleDuration: TimeInterval = 120
                if Date().timeIntervalSince(session.updatedAt) > staleDuration {
                    session.isCompressingContext = false
                    try? modelContext.save()
                    isCompressing = false
                } else {
                    isCompressing = true
                    startCompressionMonitoring()
                }
            }
        } else {
            isCompressing = false
        }
    }

    /// Poll the persistent flag to track an orphaned compression task.
    private func startCompressionMonitoring() {
        guard compressionMonitorTask == nil else { return }
        let session = self.session
        let modelContext = self.modelContext
        compressionMonitorTask = Task { @MainActor [weak self] in
            var ticks = 0
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                guard !Task.isCancelled else { break }
                if !session.isCompressingContext {
                    self?.loadMessages()
                    break
                }
                if !session.isActive && ticks > 5 {
                    session.isCompressingContext = false
                    try? modelContext.save()
                    self?.loadMessages()
                    break
                }
                ticks += 1
                if ticks > 120 {
                    session.isCompressingContext = false
                    try? modelContext.save()
                    break
                }
            }
            self?.isCompressing = false
            self?.compressionMonitorTask = nil
        }
    }

    // MARK: - Orphaned Loop Monitoring

    private func startMonitoringIfNeeded() {
        guard session.isActive, generationTask == nil, monitoringTask == nil else { return }
        isLoading = true

        streamingContent = session.pendingStreamingContent ?? ""

        monitoringTask = Task { @MainActor [weak self] in
            defer {
                self?.isLoading = false
                self?.streamingContent = ""
                self?.streamingThinking = ""
                self?.canRetry = false
                if let self, !self.session.isCompressingContext {
                    self.isCompressing = false
                }
                self?.loadMessages()
                self?.checkActiveSessionLock()
                self?.recoverRetryState()
                self?.monitoringTask = nil
            }

            // ── Fast path: relay subscription (token-level updates) ──
            if let self,
               let relay = Self.streamingRelays[self.session.id] {
                self.streamingContent = relay.content.isEmpty
                    ? (self.session.pendingStreamingContent ?? "")
                    : relay.content
                self.streamingThinking = relay.thinking

                let subscription = relay.makeSubscription()
                for await _ in subscription {
                    guard !Task.isCancelled else { return }
                    self.streamingContent = relay.content
                    self.streamingThinking = relay.thinking
                    if relay.messagesDidChange {
                        relay.messagesDidChange = false
                        self.loadMessages()
                    }
                }
                return
            }

            // ── Slow path: poll pendingStreamingContent (generation was
            //    started by a previous app launch with no in-process relay) ──
            var tickCount = 0
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                guard let self, !Task.isCancelled else { return }
                self.loadMessages()

                self.streamingContent = self.session.pendingStreamingContent ?? ""

                if !self.session.isCompressingContext && self.isCompressing && self.compressionTask == nil {
                    self.isCompressing = false
                }

                tickCount += 1

                // Check activeGenerations as well to avoid the race where
                // the old VM's defer block clears isActive before the
                // generation has fully wound down.
                guard self.session.isActive || Self.activeGenerations[self.session.id] != nil else { return }

                let hasLiveGeneration = Self.activeGenerations[self.session.id] != nil
                if tickCount > 300 && !hasLiveGeneration {
                    self.session.isActive = false
                    try? self.modelContext.save()
                    return
                }
            }
        }
    }

    private func stopMonitoring() {
        monitoringTask?.cancel()
        monitoringTask = nil
    }

    // MARK: - Manual Title

    func setCustomTitle(_ title: String) {
        session.title = title
        session.isTitleCustomized = true
        session.updatedAt = Date()
        // Defer save so the SwiftData observation cascade doesn't block
        // the current SwiftUI update cycle (prevents main-thread hang
        // when ForEach children are invalidated synchronously).
        Task { @MainActor [modelContext] in
            try? modelContext.save()
        }
    }

    // MARK: - Image Management

    func addImage(_ uiImage: UIImage) {
        // Keep draft images inline-only (no file written to agent folder)
        // so they don't appear in the file browser before the message is sent.
        // They will be promoted to file-backed attachments in sendMessage().
        guard let attachment = ImageAttachment.from(image: uiImage) else { return }
        pendingImages.append(attachment)
        persistDraftImages()
    }

    func removeImage(id: UUID) {
        pendingImages.removeAll { $0.id == id }
        persistDraftImages()
    }

    private func persistDraftImages() {
        Self.cachedPendingImages[session.id] = pendingImages
        session.draftImagesData = pendingImages.isEmpty ? nil : try? JSONEncoder().encode(pendingImages)
    }

    // MARK: - Video Management

    /// True while a video is being preprocessed (transcoded/trimmed).
    var isProcessingVideo: Bool = false

    /// Add a video from a file URL. Copies the video to the agent's file folder and creates a VideoAttachment.
    /// If the video exceeds size/duration limits, automatically preprocesses (transcodes/trims) it.
    func addVideo(from url: URL) {
        guard let agent = session.agent else { return }
        let agentId = AgentFileManager.shared.resolveAgentId(for: agent)
        let ext = (url.pathExtension).lowercased()
        guard VideoAttachment.supportedExtensions.contains(ext) || ext == "hevc" || ext == "3gp" else {
            videoValidationError = "Unsupported video format: .\(ext)"
            return
        }

        // All AVFoundation metadata loading is async; dispatch into a Task.
        isProcessingVideo = true
        videoValidationError = nil
        let videoURL = url
        Task { @MainActor in
            let asset = AVURLAsset(url: videoURL)
            let fileSize = (try? FileManager.default.attributesOfItem(atPath: videoURL.path)[.size] as? Int64) ?? 0
            let duration: TimeInterval
            if let cmDuration = try? await asset.load(.duration) {
                duration = CMTimeGetSeconds(cmDuration)
            } else {
                duration = 0
            }
            let needsPreprocessing = fileSize > VideoAttachment.maxInlineFileSize || duration > VideoAttachment.maxDurationSeconds

            if needsPreprocessing {
                do {
                    let processedURL = try await VideoPreprocessor.preprocess(url: videoURL)
                    self.isProcessingVideo = false
                    self.finalizeVideoAdd(from: processedURL, agentId: agentId)
                } catch {
                    self.isProcessingVideo = false
                    self.videoValidationError = "Video preprocessing failed: \(error.localizedDescription)"
                }
            } else {
                self.isProcessingVideo = false
                self.finalizeVideoAdd(from: videoURL, agentId: agentId)
            }
        }
    }

    private func finalizeVideoAdd(from url: URL, agentId: UUID) {
        let filename = "video_\(UUID().uuidString).\(url.pathExtension.lowercased().isEmpty ? "mp4" : url.pathExtension.lowercased())"

        guard let data = try? Data(contentsOf: url) else {
            videoValidationError = "Failed to read video file."
            return
        }

        Task { @MainActor in
            guard let attachment = await VideoAttachment.from(data: data, filename: filename, agentId: agentId) else {
                videoValidationError = "Failed to process video."
                return
            }

            videoValidationError = nil
            pendingVideos.append(attachment)
            persistDraftVideos()
        }
    }

    func removeVideo(id: UUID) {
        pendingVideos.removeAll { $0.id == id }
        persistDraftVideos()
    }

    private func persistDraftVideos() {
        Self.cachedPendingVideos[session.id] = pendingVideos
        session.draftVideosData = pendingVideos.isEmpty ? nil : try? JSONEncoder().encode(pendingVideos)
    }

    // MARK: - Generic File Management

    /// Attach a generic file from a source URL by copying it into the agent's
    /// file folder. Used by the document picker and any other in-app flow;
    /// the share extension seeds `cachedPendingFiles` directly and does not
    /// call this.
    func addFile(from url: URL) {
        guard let agent = session.agent else { return }
        let agentId = AgentFileManager.shared.resolveAgentId(for: agent)
        let accessed = url.startAccessingSecurityScopedResource()
        defer { if accessed { url.stopAccessingSecurityScopedResource() } }
        guard let attachment = FileAttachment.from(url: url, agentId: agentId) else { return }
        pendingFiles.append(attachment)
        persistPendingFiles()
    }

    func removeFile(id: UUID) {
        pendingFiles.removeAll { $0.id == id }
        persistPendingFiles()
    }

    /// File attachments are cache-only (no Session.draft* yet); persistence
    /// across ViewModel recreation is handled via `cachedPendingFiles`.
    private func persistPendingFiles() {
        Self.cachedPendingFiles[session.id] = pendingFiles
    }

    /// Refresh pending attachments from the shared static cache. Called from
    /// `onViewAppear` so session handoffs whose async work (e.g. video
    /// metadata extraction) lands after the ViewModel was constructed are
    /// picked up on the next view appearance.
    func refreshPendingAttachmentsFromCache() {
        if let cachedImgs = Self.cachedPendingImages[session.id],
           cachedImgs.map(\.id) != pendingImages.map(\.id) {
            pendingImages = cachedImgs
        }
        if let cachedVids = Self.cachedPendingVideos[session.id],
           cachedVids.map(\.id) != pendingVideos.map(\.id) {
            pendingVideos = cachedVids
        }
        if let cachedFiles = Self.cachedPendingFiles[session.id],
           cachedFiles.map(\.id) != pendingFiles.map(\.id) {
            pendingFiles = cachedFiles
        }
    }

    // MARK: - Think Tag Extraction

    /// Extracts `<think>...</think>` blocks from content, returning cleaned content and extracted thinking.
    static func extractThinkTags(from content: String) -> (cleanedContent: String, thinking: String) {
        let pattern = "<think>(.*?)</think>"
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.dotMatchesLineSeparators]) else {
            return (content, "")
        }
        let range = NSRange(content.startIndex..., in: content)
        let matches = regex.matches(in: content, range: range)
        guard !matches.isEmpty else { return (content, "") }

        var thinkingParts: [String] = []
        for match in matches {
            if let thinkRange = Range(match.range(at: 1), in: content) {
                let extracted = String(content[thinkRange]).trimmingCharacters(in: .whitespacesAndNewlines)
                if !extracted.isEmpty {
                    thinkingParts.append(extracted)
                }
            }
        }

        let cleaned = regex.stringByReplacingMatches(in: content, range: range, withTemplate: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return (cleaned, thinkingParts.joined(separator: "\n\n"))
    }

    // MARK: - API Usage

    /// Store vendor-reported token counts on the message and update the token
    /// estimate to the API-reported completion tokens when available.
    private static func applyAPIUsage(_ usage: LLMUsage?, to message: Message) {
        guard let usage else { return }
        message.apiPromptTokens = usage.promptTokens
        message.apiCompletionTokens = usage.completionTokens
        message.apiCacheReadTokens = usage.cacheReadInputTokens
        message.apiCacheWriteTokens = usage.cacheCreationInputTokens
        if let completionTokens = usage.completionTokens, completionTokens > 0 {
            message.tokenEstimate = completionTokens
        }
    }

    // MARK: - Info

    private(set) var compressionStats = CompressionStats(
        activeTokens: 0, threshold: 0, totalMessages: 0,
        compressedCount: 0, pendingCount: 0
    )

    func refreshCompressionStats() {
        let contextManager = ContextManager()
        let active = contextManager.activeContextTokens(session: session)
        let threshold = session.agent?.effectiveCompressionThreshold ?? ContextManager.compressionThreshold
        let compressedIdx = session.compressedUpToIndex
        let totalMsgs = session.messages.count

        let pendingEnd = max(totalMsgs - 3, compressedIdx)
        let pendingCount = max(pendingEnd - compressedIdx, 0)

        compressionStats = CompressionStats(
            activeTokens: active,
            threshold: threshold,
            totalMessages: totalMsgs,
            compressedCount: compressedIdx,
            pendingCount: pendingCount
        )
    }

    // MARK: - Related Sessions (RAG)

    /// Resolve related sessions: use persisted IDs if available, otherwise compute and persist.
    /// Called once per session start so the system prompt stays stable across turns.
    static func resolveRelatedSessions(
        session: Session,
        modelContext: ModelContext
    ) -> [(id: UUID, title: String, updatedAt: Date)] {
        // If already computed, look up the persisted session objects
        let existingIds = session.relatedSessionIds
        if !existingIds.isEmpty {
            return lookupSessions(ids: existingIds, modelContext: modelContext)
        }

        // First generation — compute via hybrid search (local vector + keyword) and persist
        let sessionService = SessionService(modelContext: modelContext)
        let found = sessionService.findRelatedSessionsHybrid(for: session, maxResults: 5)
        if !found.isEmpty {
            session.relatedSessionIds = found.map(\.id)
            try? modelContext.save()
        }
        return found
    }

    private static func lookupSessions(
        ids: [UUID],
        modelContext: ModelContext
    ) -> [(id: UUID, title: String, updatedAt: Date)] {
        var results: [(id: UUID, title: String, updatedAt: Date)] = []
        for sessionId in ids {
            var descriptor = FetchDescriptor<Session>()
            descriptor.predicate = #Predicate { $0.id == sessionId }
            descriptor.fetchLimit = 1
            if let session = (try? modelContext.fetch(descriptor))?.first {
                results.append((id: session.id, title: session.title, updatedAt: session.updatedAt))
            }
        }
        return results
    }

    // MARK: - Modality Stripping

    /// Result of modality stripping — counts by media type.
    struct StrippedModalities {
        var images: Int = 0
        var videos: Int = 0
        var total: Int { images + videos }
    }

    /// Removes image and/or video content parts from context messages when the target model
    /// lacks vision or video support. Also strips `agentfile://` image refs from text content
    /// (replacing with `[Image: description]`). Returns counts of stripped media by type.
    @discardableResult
    nonisolated static func stripUnsupportedModalities(
        from messages: inout [LLMChatMessage],
        capabilities: ModelCapabilities
    ) -> StrippedModalities {
        // If the model supports both vision and video, nothing to strip
        let needsImageStrip = !capabilities.supportsVision
        let needsVideoStrip = !capabilities.supportsVideoInput
        guard needsImageStrip || needsVideoStrip else { return StrippedModalities() }

        var stripped = StrippedModalities()
        var indicesToRemove: [Int] = []
        for i in messages.indices {
            var didModify = false

            // Strip agentfile:// image refs from text content when vision unsupported
            if needsImageStrip, let content = messages[i].content, content.contains("agentfile://") {
                let stripped = ContextManager.stripAgentFileImageRefs(content)
                if stripped != content {
                    messages[i] = LLMChatMessage(
                        role: messages[i].role,
                        content: stripped,
                        contentParts: messages[i].contentParts,
                        toolCalls: messages[i].toolCalls,
                        toolCallId: messages[i].toolCallId,
                        name: messages[i].name,
                        reasoningContent: messages[i].reasoningContent,
                        thinkingSignature: messages[i].thinkingSignature
                    )
                    didModify = true
                }
            }

            guard let parts = messages[i].contentParts else { continue }
            let imageCount = needsImageStrip ? parts.filter({ if case .imageURL = $0 { return true }; return false }).count : 0
            let videoCount = needsVideoStrip ? parts.filter({ if case .videoURL = $0 { return true }; return false }).count : 0
            let totalStripped = imageCount + videoCount
            guard totalStripped > 0 else { continue }
            stripped.images += imageCount
            stripped.videos += videoCount

            // Filter out unsupported parts, keeping the rest
            let filteredParts = parts.filter { part in
                if needsImageStrip, case .imageURL = part { return false }
                if needsVideoStrip, case .videoURL = part { return false }
                return true
            }

            let hasTextContent = !(messages[i].content ?? "").isEmpty
            let hasToolCalls = messages[i].toolCalls != nil
            let hasRemainingParts = !filteredParts.isEmpty && filteredParts.contains(where: {
                if case .text = $0 { return false }; return true
            })
            if !hasTextContent && !hasToolCalls && messages[i].toolCallId == nil && !hasRemainingParts {
                indicesToRemove.append(i)
            } else {
                messages[i] = LLMChatMessage(
                    role: messages[i].role,
                    content: messages[i].content,
                    contentParts: hasRemainingParts ? filteredParts : nil,
                    toolCalls: messages[i].toolCalls,
                    toolCallId: messages[i].toolCallId,
                    name: messages[i].name,
                    reasoningContent: messages[i].reasoningContent,
                    thinkingSignature: messages[i].thinkingSignature
                )
            }
            _ = didModify
        }
        for i in indicesToRemove.reversed() {
            messages.remove(at: i)
        }
        return stripped
    }
}

struct CompressionStats {
    let activeTokens: Int
    let threshold: Int
    let totalMessages: Int
    let compressedCount: Int
    /// Messages eligible for the next compression pass.
    let pendingCount: Int

    var activeFormatted: String { Self.fmt(activeTokens) }
    var thresholdFormatted: String { Self.fmt(threshold) }

    var tokenRatio: Double {
        guard threshold > 0 else { return 0 }
        return Double(activeTokens) / Double(threshold)
    }

    private static func fmt(_ n: Int) -> String {
        n >= 1000 ? String(format: "%.1fk", Double(n) / 1000.0) : "\(n)"
    }
}

enum ChatError: LocalizedError {
    case noProviderConfigured
    case noAgentAssociated
    case whitelistBlockedAllModels

    var errorDescription: String? {
        switch self {
        case .noProviderConfigured:
            return L10n.ChatError.noProvider
        case .noAgentAssociated:
            return L10n.ChatError.noAgent
        case .whitelistBlockedAllModels:
            return L10n.ChatError.whitelistBlocked
        }
    }
}
