import Foundation
import SwiftData

@Model
final class Session {
    var id: UUID
    var agent: Agent?
    var title: String
    @Relationship(deleteRule: .cascade, inverse: \Message.session)
    var messages: [Message]
    var compressedContext: String?
    var compressedUpToIndex: Int
    var isArchived: Bool
    var createdAt: Date
    var updatedAt: Date

    /// Whether this session is currently active (agent is generating / processing).
    var isActive: Bool = false

    /// Whether context compression is currently in progress.
    var isCompressingContext: Bool = false

    /// Whether the user has manually renamed this session's title.
    var isTitleCustomized: Bool = false

    /// UUID of the last message visible when the user left this session (for scroll restoration).
    var lastViewedMessageIdRaw: String?

    var lastViewedMessageId: UUID? {
        get { lastViewedMessageIdRaw.flatMap { UUID(uuidString: $0) } }
        set { lastViewedMessageIdRaw = newValue?.uuidString }
    }

    /// Partial streaming content from assistant (persisted so re-entry can display progress).
    var pendingStreamingContent: String?

    /// Draft text the user was typing but hasn't sent yet (persisted across app quit / session exit).
    var draftText: String?

    /// Draft image attachments (JSON-encoded [ImageAttachment]) persisted across app quit / session exit.
    var draftImagesData: Data?

    /// Draft video attachments (JSON-encoded [VideoAttachment]) persisted across app quit / session exit.
    var draftVideosData: Data?

    /// Pipe-separated UUIDs of related sessions (computed once at session start, persisted for stable prompt).
    var relatedSessionIdsRaw: String?

    /// UUID of the parent session that spawned this sub-agent session (for content relay).
    var parentSessionIdRaw: String?

    /// Pipe-separated slugs of skills the user activated for this session via
    /// the `/skill-slug` slash-command (or that the LLM activated implicitly
    /// by calling one of the skill's `skill_<slug>_*` tools — Phase 6 will
    /// wire that branch). Read by `PromptBuilder` to decide whether to expand
    /// each installed skill's body into the system prompt (progressive
    /// disclosure) or just surface its name + description.
    var activatedSkillSlugsRaw: String = ""

    var activatedSkillSlugs: Set<String> {
        get {
            guard !activatedSkillSlugsRaw.isEmpty else { return [] }
            return Set(activatedSkillSlugsRaw.split(separator: "|").map(String.init))
        }
        set {
            activatedSkillSlugsRaw = newValue.isEmpty ? "" : newValue.sorted().joined(separator: "|")
        }
    }

    var relatedSessionIds: [UUID] {
        get {
            guard let raw = relatedSessionIdsRaw, !raw.isEmpty else { return [] }
            return raw.components(separatedBy: "|").compactMap { UUID(uuidString: $0) }
        }
        set {
            relatedSessionIdsRaw = newValue.isEmpty ? nil : newValue.map(\.uuidString).joined(separator: "|")
        }
    }

    var parentSessionId: UUID? {
        get { parentSessionIdRaw.flatMap { UUID(uuidString: $0) } }
        set { parentSessionIdRaw = newValue?.uuidString }
    }

    init(title: String) {
        self.id = UUID()
        self.title = title
        self.messages = []
        self.compressedContext = nil
        self.compressedUpToIndex = 0
        self.isArchived = false
        self.isActive = false
        self.isTitleCustomized = false
        self.lastViewedMessageIdRaw = nil
        self.parentSessionIdRaw = nil
        self.createdAt = Date()
        self.updatedAt = Date()
    }

    @Transient private var _sortedCache: [Message] = []
    @Transient private var _sortedCacheCount: Int = -1

    var sortedMessages: [Message] {
        let count = messages.count
        if count == _sortedCacheCount { return _sortedCache }
        let sorted = messages.sorted { $0.timestamp < $1.timestamp }
        _sortedCache = sorted
        _sortedCacheCount = count
        return sorted
    }

    func invalidateMessageCache() {
        _sortedCacheCount = -1
    }
}
