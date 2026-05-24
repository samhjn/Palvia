import Foundation
import WebKit
import os.log

private let bridgeLog = OSLog(subsystem: "com.iclaw.jsruntime", category: "apple-bridge")

/// Bridges Apple ecosystem APIs into the WKWebView JS sandbox.
///
/// Uses WKScriptMessageHandlerWithReply so JavaScript can call native APIs
/// synchronously via `window.webkit.messageHandlers.appleBridge.postMessage()`
/// and receive results inline.
///
/// The bridge installs two global objects:
/// - `fs` — Node-aligned file system API:
///   - Whole-file: `fs.list`, `fs.readFile`, `fs.writeFile`, `fs.appendFile`, `fs.delete`/`fs.unlink`,
///     `fs.stat`, `fs.exists`, `fs.mkdir`, `fs.cp`, `fs.mv`/`fs.rename`, `fs.truncate`
///   - POSIX fd: `fs.open`, `fs.close`, `fs.read(fd,...)`, `fs.write(fd,...)`, `fs.seek`, `fs.tell`,
///     `fs.fstat`, `fs.fsync`. fd's are auto-closed at the end of the JS execution.
///   - Legacy `fs.read(path)` / `fs.write(path, content)` still work (arg-type dispatch).
/// - `apple` — Apple ecosystem APIs: `apple.calendar.*`, `apple.reminders.*`, `apple.contacts.*`,
///   `apple.clipboard.*`, `apple.notifications.*`, `apple.location.*`, `apple.maps.*`, `apple.health.*`
///
/// Per-agent permissions are enforced in two layers:
/// 1. **JS layer**: blocked actions are injected into the preamble and rejected before `postMessage`.
/// 2. **Native layer**: each execution registers a permission checker keyed by `execId`;
///    `dispatch` looks up the checker and rejects unauthorized calls even if JS was tampered with.
@MainActor
final class AppleEcosystemBridge: NSObject, WKScriptMessageHandlerWithReply {

    static let shared = AppleEcosystemBridge()
    private override init() { super.init() }

    static let messageHandlerName = "appleBridge"

    /// Execution contexts keyed by execution ID.
    /// Each JS execution registers a context before running and removes it after.
    private var executionContexts: [String: ExecutionContext] = [:]

    /// Cap on simultaneously-open file descriptors per execution context.
    static let maxFdsPerContext = 32

    /// Per-execution open-file descriptor entry. Each JS execution has its own fd space,
    /// and all entries are force-closed when the execution context is unregistered.
    final class FDEntry {
        let url: URL
        let handle: FileHandle
        let mode: OpenMode
        var position: UInt64

        init(url: URL, handle: FileHandle, mode: OpenMode, position: UInt64) {
            self.url = url
            self.handle = handle
            self.mode = mode
            self.position = position
        }
    }

    enum OpenMode: String {
        case read       // "r"
        case readWrite  // "r+"
        case writeTrunc // "w"
        case writePlus  // "w+"
        case append     // "a"
        case appendPlus // "a+"

        var canRead: Bool {
            switch self {
            case .read, .readWrite, .writePlus, .appendPlus: return true
            case .writeTrunc, .append: return false
            }
        }

        var canWrite: Bool {
            switch self {
            case .read: return false
            case .readWrite, .writeTrunc, .writePlus, .append, .appendPlus: return true
            }
        }

        static func parse(_ flag: String) throws -> OpenMode {
            switch flag {
            case "r": return .read
            case "r+": return .readWrite
            case "w": return .writeTrunc
            case "w+": return .writePlus
            case "a": return .append
            case "a+": return .appendPlus
            default: throw FileToolError.invalidFlag(flag)
            }
        }
    }

    /// Resolved snippet payload exposed to the bridge.
    struct SnippetInfo {
        let name: String
        let language: String
        let code: String
    }

    final class ExecutionContext {
        let permissionChecker: (String) -> Bool
        let agentId: UUID?
        var fdTable: [Int: FDEntry] = [:]
        var nextFdId: Int = 3  // reserve 0-2 for conventional stdio slots

        /// Looks up a snippet by name for `snippets.invoke`. Nil when the executor
        /// was not given agent context (e.g. tests, non-agent callers).
        let snippetResolver: ((String) -> SnippetInfo?)?
        /// Enumerates all callable snippets for `snippets.list`.
        let snippetLister: (() -> [SnippetInfo])?
        /// Bridge actions blocked for the agent; propagated into nested call contexts
        /// so restrictions apply transitively.
        let blockedActions: Set<String>
        /// Depth in the snippet call tree. 0 at the root execution; +1 per nested invoke.
        let callDepth: Int
        /// Wall-clock stamp of the root execution; inherited unchanged by nested contexts.
        let rootStartedAt: Date
        /// Total call-tree budget (seconds); inherited unchanged by nested contexts.
        let totalBudget: TimeInterval

        init(
            permissionChecker: @escaping (String) -> Bool,
            agentId: UUID?,
            snippetResolver: ((String) -> SnippetInfo?)? = nil,
            snippetLister: (() -> [SnippetInfo])? = nil,
            blockedActions: Set<String> = [],
            callDepth: Int = 0,
            rootStartedAt: Date = Date(),
            totalBudget: TimeInterval = 60
        ) {
            self.permissionChecker = permissionChecker
            self.agentId = agentId
            self.snippetResolver = snippetResolver
            self.snippetLister = snippetLister
            self.blockedActions = blockedActions
            self.callDepth = callDepth
            self.rootStartedAt = rootStartedAt
            self.totalBudget = totalBudget
        }
    }

    /// Hard cap on nested `snippets.invoke` levels. Recursive calls are allowed
    /// below this; beyond it the bridge aborts with a readable error.
    static let maxSnippetCallDepth = 16

    /// Per-agent permission name controlling writes to **user** slugs under
    /// the `skills/` mount. Built-in slugs are always read-only — this flag
    /// only opt-in/out an agent's ability to author or modify user skills.
    /// Independent of the broader `files.writeFile`/etc. permissions so an
    /// agent can have general file write access but no skill authoring.
    static let fsSkillWriteAction = "fs_skill_write"

    /// True when `path` (as accepted by the JS API — either `skills/...` or
    /// `/skills/...`) targets a user (non-built-in) slug. The mount root
    /// (`skills` / `/skills` with no slug) returns false — listing the mount
    /// root is always allowed.
    static func touchesUserSkillsMount(_ path: String) -> Bool {
        // Normalize a single leading slash on the skills prefix only.
        let p: String
        if path == "/" + AgentFileManager.skillsMountComponent
            || path.hasPrefix("/" + AgentFileManager.skillsMountComponent + "/") {
            p = String(path.dropFirst())
        } else {
            p = path
        }
        guard AgentFileManager.isSkillsMountPath(p), p != AgentFileManager.skillsMountComponent else {
            return false
        }
        let remainder = String(p.dropFirst(AgentFileManager.skillsMountComponent.count + 1))
        let slug = remainder.split(separator: "/", maxSplits: 1).first.map(String.init) ?? remainder
        return !BuiltInSkills.shippedSlugs.contains(slug)
    }

    /// Returns nil when the write may proceed, or an error string to return
    /// to JS. Combines:
    ///   - the per-agent `fs_skill_write` permission (only when `path` is in
    ///     the user skills mount)
    /// Built-in writes are NOT checked here — they're rejected at the
    /// resolver via `FileToolError.readOnlySkill`.
    private static func enforceSkillWritePermission(
        path: String,
        context: ExecutionContext?
    ) -> String? {
        guard let ctx = context else { return nil }
        guard touchesUserSkillsMount(path) else { return nil }
        if !ctx.permissionChecker(fsSkillWriteAction) {
            return "[Error] Action '\(fsSkillWriteAction)' is not permitted for this agent."
        }
        return nil
    }

    /// Extract the user-skill slug from a (possibly leading-slashed) path
    /// targeting the skills mount. Returns nil when the path is the mount
    /// root, a built-in slug, or not in the mount at all.
    private static func userSkillSlug(forPath path: String) -> String? {
        let p: String
        if path == "/" + AgentFileManager.skillsMountComponent
            || path.hasPrefix("/" + AgentFileManager.skillsMountComponent + "/") {
            p = String(path.dropFirst())
        } else {
            p = path
        }
        guard AgentFileManager.isSkillsMountPath(p), p != AgentFileManager.skillsMountComponent else {
            return nil
        }
        let remainder = String(p.dropFirst(AgentFileManager.skillsMountComponent.count + 1))
        let slug = remainder.split(separator: "/", maxSplits: 1).first.map(String.init) ?? remainder
        if slug.isEmpty || BuiltInSkills.shippedSlugs.contains(slug) { return nil }
        return slug
    }

    /// Post `Notification.Name.skillsMountWrite` for `path` if (a) it targets
    /// a user-skill slug and (b) `result` indicates the write succeeded.
    /// Idempotent: built-in writes never reach a success result; mount-root
    /// writes don't fire because there's no slug.
    static func notifySkillsMountWriteIfSucceeded(path: String, result: String) {
        guard !result.hasPrefix("[Error]"), let slug = userSkillSlug(forPath: path) else { return }
        NotificationCenter.default.post(
            name: .skillsMountWrite,
            object: nil,
            userInfo: ["slug": slug]
        )
    }

    /// Permission checkers keyed by execution ID (legacy accessor).
    private var permissionCheckers: [String: (String) -> Bool] {
        executionContexts.mapValues { $0.permissionChecker }
    }

    /// Install the bridge on a WKWebView configuration before the web view is created.
    func install(on configuration: WKWebViewConfiguration) {
        configuration.userContentController.addScriptMessageHandler(
            self, contentWorld: .page, name: Self.messageHandlerName)
    }

    /// Remove the bridge when tearing down.
    func uninstall(from configuration: WKWebViewConfiguration) {
        configuration.userContentController.removeScriptMessageHandler(
            forName: Self.messageHandlerName, contentWorld: .page)
    }

    // MARK: - Permission Registration

    /// Register a permission checker for a JS execution context.
    func registerPermissions(execId: String, checker: @escaping (String) -> Bool) {
        executionContexts[execId] = ExecutionContext(permissionChecker: checker, agentId: nil)
    }

    /// Register a full execution context with permissions and agent ID (for file operations).
    func registerContext(execId: String, agentId: UUID?, checker: @escaping (String) -> Bool) {
        executionContexts[execId] = ExecutionContext(permissionChecker: checker, agentId: agentId)
    }

    /// Register an execution context with snippet-calling capabilities. Used by
    /// `CodeExecutionTools` to enable `snippets.invoke` / `snippets.list` inside
    /// the running JS.
    func registerContext(
        execId: String,
        agentId: UUID?,
        blockedActions: Set<String>,
        totalBudget: TimeInterval,
        snippetResolver: @escaping (String) -> SnippetInfo?,
        snippetLister: @escaping () -> [SnippetInfo],
        checker: @escaping (String) -> Bool
    ) {
        executionContexts[execId] = ExecutionContext(
            permissionChecker: checker,
            agentId: agentId,
            snippetResolver: snippetResolver,
            snippetLister: snippetLister,
            blockedActions: blockedActions,
            callDepth: 0,
            rootStartedAt: Date(),
            totalBudget: totalBudget
        )
    }

    /// Unregister the execution context after completion. Force-closes any fds the JS
    /// execution left open (logging a warning for visibility).
    func unregisterPermissions(execId: String) {
        guard let ctx = executionContexts.removeValue(forKey: execId) else { return }
        if !ctx.fdTable.isEmpty {
            os_log(.info, log: bridgeLog, "[Bridge] Leaked fds on execId=%{public}@: %d",
                   execId, ctx.fdTable.count)
            for (_, entry) in ctx.fdTable {
                try? entry.handle.close()
            }
        }
    }

    /// Internal entry point for tests: invoke a bridge action without going through
    /// a live WKWebView. Enforces the same permission check as the real handler.
    func dispatchForTesting(action: String, args: [String: Any], execId: String) async -> String {
        guard let ctx = executionContexts[execId] else {
            return "[Error] No execution context for execId \(execId)."
        }
        guard ctx.permissionChecker(action) else {
            return "[Error] Action '\(action)' is not permitted for this agent."
        }
        return await dispatch(action: action, args: args, context: ctx)
    }

    /// Internal read-only accessor used by tests to observe fd-table state.
    func fdCount(execId: String) -> Int {
        executionContexts[execId]?.fdTable.count ?? 0
    }

    // MARK: - WKScriptMessageHandlerWithReply

    nonisolated func userContentController(
        _ userContentController: WKUserContentController,
        didReceive message: WKScriptMessage,
        replyHandler: @escaping (Any?, String?) -> Void
    ) {
        Task { @MainActor in
            guard let body = message.body as? [String: Any],
                  let action = body["action"] as? String,
                  let args = body["args"] as? [String: Any] else {
                replyHandler(nil, "Invalid bridge call: expected {action, args}")
                return
            }

            let execId = body["execId"] as? String

            // Native-layer permission check (defense-in-depth)
            let ctx = execId.flatMap { executionContexts[$0] }
            if let execId, let ctx, !ctx.permissionChecker(action) {
                os_log(.info, log: bridgeLog, "[Bridge] BLOCKED action=%{public}@ execId=%{public}@", action, execId)
                replyHandler("[Error] Action '\(action)' is not permitted for this agent.", nil)
                return
            }

            os_log(.info, log: bridgeLog, "[Bridge] action=%{public}@", action)
            let result = await dispatch(action: action, args: args, context: ctx)
            replyHandler(result, nil)
        }
    }

    // MARK: - Dispatch

    private func dispatch(action: String, args: [String: Any], context: ExecutionContext? = nil) async -> String {
        switch action {

        // --- Files (whole-file, Node-style) ---
        case "files.list":
            guard let agentId = context?.agentId else { return "[Error] No agent context for file operations." }
            let path = (args["path"] as? String) ?? ""
            let files = AgentFileManager.shared.listFiles(agentId: agentId, path: path)
            if files.isEmpty { return "[]" }
            let items = files.map {
                "{\"name\":\"\($0.name)\",\"size\":\($0.size),\"is_image\":\($0.isImage),\"is_dir\":\($0.isDirectory)}"
            }
            return "[\(items.joined(separator: ","))]"
        case "files.readFile":
            return readFileDispatch(args: args, context: context)
        case "files.writeFile":
            if let path = filePathArg(args),
               let err = Self.enforceSkillWritePermission(path: path, context: context) {
                return err
            }
            let result = writeFileDispatch(args: args, context: context, append: false)
            if let path = filePathArg(args) {
                Self.notifySkillsMountWriteIfSucceeded(path: path, result: result)
            }
            return result
        case "files.appendFile":
            if let path = filePathArg(args),
               let err = Self.enforceSkillWritePermission(path: path, context: context) {
                return err
            }
            let result = writeFileDispatch(args: args, context: context, append: true)
            if let path = filePathArg(args) {
                Self.notifySkillsMountWriteIfSucceeded(path: path, result: result)
            }
            return result
        case "files.delete":
            guard let agentId = context?.agentId else { return "[Error] No agent context for file operations." }
            guard let path = filePathArg(args) else { return "[Error] Missing 'path' argument." }
            if let err = Self.enforceSkillWritePermission(path: path, context: context) { return err }
            do {
                try AgentFileManager.shared.deleteFile(agentId: agentId, name: path)
                Self.notifySkillsMountWriteIfSucceeded(path: path, result: "OK")
                return "OK"
            } catch { return "[Error] \(error.localizedDescription)" }
        case "files.info", "files.stat":
            guard let agentId = context?.agentId else { return "[Error] No agent context for file operations." }
            guard let path = filePathArg(args) else { return "[Error] Missing 'path' argument." }
            guard let info = AgentFileManager.shared.fileInfo(agentId: agentId, name: path) else { return "[Error] File not found." }
            let mtime = Int64(info.modifiedAt.timeIntervalSince1970 * 1000)
            let ctime = Int64(info.createdAt.timeIntervalSince1970 * 1000)
            let isFile = !info.isDirectory
            let jsonPath = jsonEscape(path)
            let jsonName = jsonEscape(info.name)
            return "{\"name\":\"\(jsonName)\",\"path\":\"\(jsonPath)\",\"size\":\(info.size),\"is_file\":\(isFile),\"is_dir\":\(info.isDirectory),\"is_image\":\(info.isImage),\"mtime_ms\":\(mtime),\"ctime_ms\":\(ctime)}"
        case "files.exists":
            guard let agentId = context?.agentId else { return "[Error] No agent context for file operations." }
            guard let path = filePathArg(args) else { return "[Error] Missing 'path' argument." }
            return AgentFileManager.shared.fileExists(agentId: agentId, name: path) ? "true" : "false"
        case "files.mkdir":
            guard let agentId = context?.agentId else { return "[Error] No agent context for file operations." }
            guard let path = filePathArg(args) else { return "[Error] Missing 'path' argument." }
            if let err = Self.enforceSkillWritePermission(path: path, context: context) { return err }
            do {
                try AgentFileManager.shared.makeDirectory(agentId: agentId, path: path)
                Self.notifySkillsMountWriteIfSucceeded(path: path, result: "OK")
                return "OK"
            } catch { return "[Error] \(error.localizedDescription)" }
        case "files.cp":
            guard let agentId = context?.agentId else { return "[Error] No agent context for file operations." }
            guard let src = args["src"] as? String, !src.isEmpty else { return "[Error] Missing 'src' argument." }
            guard let dest = args["dest"] as? String, !dest.isEmpty else { return "[Error] Missing 'dest' argument." }
            // Reading from a built-in (the fork-then-edit pattern) is allowed —
            // only the destination is gated by `fs_skill_write`.
            if let err = Self.enforceSkillWritePermission(path: dest, context: context) { return err }
            let recursive = (args["recursive"] as? Bool) ?? true
            do {
                try AgentFileManager.shared.copyFile(agentId: agentId, src: src, dest: dest, recursive: recursive)
                Self.notifySkillsMountWriteIfSucceeded(path: dest, result: "OK")
                return "OK"
            } catch { return "[Error] \(error.localizedDescription)" }
        case "files.mv":
            guard let agentId = context?.agentId else { return "[Error] No agent context for file operations." }
            guard let src = args["src"] as? String, !src.isEmpty else { return "[Error] Missing 'src' argument." }
            guard let dest = args["dest"] as? String, !dest.isEmpty else { return "[Error] Missing 'dest' argument." }
            // Move removes the source, so both sides need write permission.
            if let err = Self.enforceSkillWritePermission(path: src, context: context) { return err }
            if let err = Self.enforceSkillWritePermission(path: dest, context: context) { return err }
            do {
                try AgentFileManager.shared.moveFile(agentId: agentId, src: src, dest: dest)
                // Move can affect both the source slug (deletion) and the
                // destination slug (creation/modification). Fire reload for
                // each — the SkillService.reload path is idempotent and a
                // missing source slug (no Skill row) is a no-op.
                Self.notifySkillsMountWriteIfSucceeded(path: src, result: "OK")
                Self.notifySkillsMountWriteIfSucceeded(path: dest, result: "OK")
                return "OK"
            } catch { return "[Error] \(error.localizedDescription)" }
        case "files.truncate":
            guard let agentId = context?.agentId, let ctx = context else { return "[Error] No agent context for file operations." }
            let length = UInt64(max(intArg(args["length"]) ?? 0, 0))
            if let fd = intArg(args["fd"]) {
                guard let entry = ctx.fdTable[fd] else { return "[Error] \(FileToolError.invalidFd(fd).localizedDescription)" }
                guard entry.mode.canWrite else { return "[Error] fd \(fd) is read-only." }
                do {
                    try entry.handle.truncate(atOffset: length)
                    if entry.position > length { entry.position = length }
                    return "OK"
                } catch { return "[Error] \(error.localizedDescription)" }
            }
            guard let path = filePathArg(args) else { return "[Error] Missing 'path' or 'fd' argument." }
            if let err = Self.enforceSkillWritePermission(path: path, context: context) { return err }
            do {
                try AgentFileManager.shared.truncateFile(agentId: agentId, path: path, length: length)
                Self.notifySkillsMountWriteIfSucceeded(path: path, result: "OK")
                return "OK"
            } catch { return "[Error] \(error.localizedDescription)" }

        // --- Files (POSIX fd-based) ---
        case "files.open":
            return openFdDispatch(args: args, context: context)
        case "files.close":
            return closeFdDispatch(args: args, context: context)
        case "files.read":
            return readFdDispatch(args: args, context: context)
        case "files.write":
            return writeFdDispatch(args: args, context: context)
        case "files.seek":
            return seekFdDispatch(args: args, context: context)
        case "files.tell":
            return tellFdDispatch(args: args, context: context)
        case "files.fstat":
            return fstatFdDispatch(args: args, context: context)
        case "files.fsync":
            return fsyncFdDispatch(args: args, context: context)

        // --- Calendar ---
        case "calendar.listCalendars":
            return await AppleCalendarTools().listCalendars(arguments: args)
        case "calendar.createEvent":
            return await AppleCalendarTools().createEvent(arguments: args)
        case "calendar.searchEvents":
            return await AppleCalendarTools().searchEvents(arguments: args)
        case "calendar.updateEvent":
            return await AppleCalendarTools().updateEvent(arguments: args)
        case "calendar.deleteEvent":
            return await AppleCalendarTools().deleteEvent(arguments: args)

        // --- Reminders ---
        case "reminders.list":
            return await AppleReminderTools().listReminders(arguments: args)
        case "reminders.lists":
            return await AppleReminderTools().listReminderLists(arguments: args)
        case "reminders.create":
            return await AppleReminderTools().createReminder(arguments: args)
        case "reminders.complete":
            return await AppleReminderTools().completeReminder(arguments: args)
        case "reminders.delete":
            return await AppleReminderTools().deleteReminder(arguments: args)

        // --- Contacts ---
        case "contacts.search":
            return await AppleContactsTools().searchContacts(arguments: args)
        case "contacts.getDetail":
            return await AppleContactsTools().getContactDetail(arguments: args)

        // --- Clipboard ---
        case "clipboard.read":
            return await MainActor.run { AppleClipboardTools().readClipboard(arguments: args) }
        case "clipboard.write":
            return await MainActor.run { AppleClipboardTools().writeClipboard(arguments: args) }

        // --- Notifications ---
        case "notifications.schedule":
            return await AppleNotificationTools().scheduleNotification(arguments: args)
        case "notifications.cancel":
            return await AppleNotificationTools().cancelNotification(arguments: args)
        case "notifications.list":
            return await AppleNotificationTools().listNotifications(arguments: args)

        // --- Location ---
        case "location.getCurrent":
            return await AppleLocationTools().getCurrentLocation(arguments: args)
        case "location.geocode":
            return await AppleLocationTools().geocode(arguments: args)
        case "location.reverseGeocode":
            return await AppleLocationTools().reverseGeocode(arguments: args)

        // --- Maps ---
        case "maps.searchPlaces":
            return await AppleMapTools().searchPlaces(arguments: args)
        case "maps.getDirections":
            return await AppleMapTools().getDirections(arguments: args)

        // --- Health (Read) ---
        case "health.readSteps":
            return await AppleHealthTools().readSteps(arguments: args)
        case "health.readHeartRate":
            return await AppleHealthTools().readHeartRate(arguments: args)
        case "health.readSleep":
            return await AppleHealthTools().readSleep(arguments: args)
        case "health.readBodyMass":
            return await AppleHealthTools().readBodyMass(arguments: args)
        case "health.readBloodPressure":
            return await AppleHealthTools().readBloodPressure(arguments: args)
        case "health.readBloodGlucose":
            return await AppleHealthTools().readBloodGlucose(arguments: args)
        case "health.readBloodOxygen":
            return await AppleHealthTools().readBloodOxygen(arguments: args)
        case "health.readBodyTemperature":
            return await AppleHealthTools().readBodyTemperature(arguments: args)
        // --- Health (Write) ---
        case "health.writeDietaryEnergy":
            return await AppleHealthTools().writeDietaryEnergy(arguments: args)
        case "health.writeBodyMass":
            return await AppleHealthTools().writeBodyMass(arguments: args)
        case "health.writeDietaryWater":
            return await AppleHealthTools().writeDietaryWater(arguments: args)
        case "health.writeDietaryCarbohydrates":
            return await AppleHealthTools().writeDietaryCarbohydrates(arguments: args)
        case "health.writeDietaryProtein":
            return await AppleHealthTools().writeDietaryProtein(arguments: args)
        case "health.writeDietaryFat":
            return await AppleHealthTools().writeDietaryFat(arguments: args)
        case "health.writeBloodPressure":
            return await AppleHealthTools().writeBloodPressure(arguments: args)
        case "health.writeBodyFat":
            return await AppleHealthTools().writeBodyFat(arguments: args)
        case "health.writeHeight":
            return await AppleHealthTools().writeHeight(arguments: args)
        case "health.writeBloodGlucose":
            return await AppleHealthTools().writeBloodGlucose(arguments: args)
        case "health.writeBloodOxygen":
            return await AppleHealthTools().writeBloodOxygen(arguments: args)
        case "health.writeBodyTemperature":
            return await AppleHealthTools().writeBodyTemperature(arguments: args)
        case "health.writeHeartRate":
            return await AppleHealthTools().writeHeartRate(arguments: args)
        case "health.writeWorkout":
            return await AppleHealthTools().writeWorkout(arguments: args)

        // --- Inter-snippet calling ---
        case "snippets.invoke":
            return await invokeSnippetDispatch(args: args, context: context)
        case "snippets.list":
            return listSnippetsDispatch(context: context)

        default:
            return "[Error] Unknown bridge action: \(action)"
        }
    }

    // MARK: - Snippet Dispatch Helpers

    /// Runs another snippet from inside the currently-executing snippet.
    /// Produces a JSON response `{ok, result, stdout, stderr}` on success or
    /// `{ok:false, error, stdout, stderr}` on failure — the caller-side JS wrapper
    /// unpacks this and either appends the output or returns it to the user.
    private func invokeSnippetDispatch(args: [String: Any], context: ExecutionContext?) async -> String {
        guard let ctx = context else { return "[Error] No execution context." }
        guard let resolver = ctx.snippetResolver else {
            return "[Error] Snippet invocation is unavailable in this context."
        }
        guard let name = args["name"] as? String, !name.isEmpty else {
            return "[Error] Missing 'name' argument."
        }

        if ctx.callDepth >= Self.maxSnippetCallDepth {
            return "[Error] Snippet call depth exceeded (\(Self.maxSnippetCallDepth))."
        }

        let elapsed = Date().timeIntervalSince(ctx.rootStartedAt)
        let remaining = ctx.totalBudget - elapsed
        if remaining <= 0 {
            return "[Error] Snippet call-tree time budget exhausted."
        }

        guard let info = resolver(name) else {
            let available = ctx.snippetLister?().map { $0.name }.joined(separator: ", ") ?? ""
            return "[Error] Snippet '\(name)' not found. Available: \(available.isEmpty ? "(none)" : available)"
        }
        guard info.language == "javascript" else {
            return "[Error] Only JavaScript snippets can be invoked via snippets.invoke. '\(name)' is \(info.language)."
        }

        guard let jsExecutor = CodeExecutorRegistry.shared.executor(for: "javascript") as? JavaScriptExecutor else {
            return "[Error] JavaScript executor is not available."
        }

        let childExecId = UUID().uuidString
        executionContexts[childExecId] = ExecutionContext(
            permissionChecker: ctx.permissionChecker,
            agentId: ctx.agentId,
            snippetResolver: ctx.snippetResolver,
            snippetLister: ctx.snippetLister,
            blockedActions: ctx.blockedActions,
            callDepth: ctx.callDepth + 1,
            rootStartedAt: ctx.rootStartedAt,
            totalBudget: ctx.totalBudget
        )
        defer {
            if let childCtx = executionContexts.removeValue(forKey: childExecId), !childCtx.fdTable.isEmpty {
                for (_, entry) in childCtx.fdTable { try? entry.handle.close() }
            }
        }

        let calleeArgs = (args["args"] as? [String: Any]) ?? [:]
        let calleeStdin = (args["stdin"] as? String) ?? ""
        let nestedTimeout = max(1, remaining)

        do {
            let result = try await jsExecutor.executeCallable(
                code: info.code,
                timeout: nestedTimeout,
                blockedBridgeActions: ctx.blockedActions,
                execId: childExecId,
                args: calleeArgs,
                stdin: calleeStdin
            )
            return Self.serializeCallableResponse(result)
        } catch CodeExecutorError.timeout {
            return "[Error] Snippet '\(name)' exceeded the call-tree time budget."
        } catch CodeExecutorError.runtimeCrashed {
            return "[Error] Snippet '\(name)' crashed the JS runtime (OOM or similar)."
        } catch is CancellationError {
            return "[Error] Snippet '\(name)' was cancelled."
        } catch {
            return "[Error] Snippet '\(name)' failed: \(error.localizedDescription)"
        }
    }

    private func listSnippetsDispatch(context: ExecutionContext?) -> String {
        guard let lister = context?.snippetLister else { return "[]" }
        let items: [[String: String]] = lister().map { ["name": $0.name, "language": $0.language] }
        guard let data = try? JSONSerialization.data(withJSONObject: items, options: []),
              let s = String(data: data, encoding: .utf8) else {
            return "[]"
        }
        return s
    }

    /// Serialize a `CallableResult` into the JSON shape consumed by the JS `snippets.invoke` wrapper.
    nonisolated private static func serializeCallableResponse(_ result: CallableResult) -> String {
        var dict: [String: Any] = [
            "stdout": result.stdout,
            "stderr": result.stderr
        ]
        if let err = result.error {
            dict["ok"] = false
            dict["error"] = err
        } else {
            dict["ok"] = true
            dict["result"] = result.value ?? NSNull()
        }
        guard let data = try? JSONSerialization.data(withJSONObject: dict, options: []),
              let s = String(data: data, encoding: .utf8) else {
            return "{\"ok\":false,\"error\":\"Failed to serialize snippet response.\",\"stdout\":\"\",\"stderr\":\"\"}"
        }
        return s
    }

    // MARK: - File Dispatch Helpers

    /// Whole-file read. Supports optional byte-slice via `offset`/`size`; when neither is
    /// supplied, returns the entire file (no truncation note). Modes: `text` / `base64` / `hex`.
    private func readFileDispatch(args: [String: Any], context: ExecutionContext?) -> String {
        guard let agentId = context?.agentId else { return "[Error] No agent context for file operations." }
        guard let path = filePathArg(args) else { return "[Error] Missing 'path' argument." }
        let mode = args["mode"] as? String ?? "text"
        let requestedSize = intArg(args["size"])
        let offset = max(0, intArg(args["offset"]) ?? 0)
        do {
            let data = try AgentFileManager.shared.readFile(agentId: agentId, name: path)
            let total = data.count
            let start = min(offset, total)
            let size = requestedSize ?? (total - start)
            let end = min(start + max(size, 0), total)
            let slice = data.subdata(in: start..<end)
            let truncated = requestedSize != nil && end < total
            let suffix = truncated ? "\n[truncated: read \(end - start) of \(total) bytes, next offset=\(end)]" : ""
            switch mode {
            case "base64": return slice.base64EncodedString() + suffix
            case "hex": return HexDump.format(slice, startOffset: start) + suffix
            default:
                if let text = String(data: slice, encoding: .utf8) { return text + suffix }
                return "[Error] Binary file; use mode='hex' or mode='base64'."
            }
        } catch { return "[Error] \(error.localizedDescription)" }
    }

    /// Whole-file write (or append). `encoding`: `text` (default) or `base64`.
    private func writeFileDispatch(args: [String: Any], context: ExecutionContext?, append: Bool) -> String {
        guard let agentId = context?.agentId else { return "[Error] No agent context for file operations." }
        guard let path = filePathArg(args) else { return "[Error] Missing 'path' argument." }
        let content = args["content"] as? String ?? ""
        let encoding = args["encoding"] as? String ?? "text"
        let data: Data
        if encoding == "base64" {
            guard let d = Data(base64Encoded: content, options: .ignoreUnknownCharacters) else { return "[Error] Invalid base64." }
            data = d
        } else { data = Data(content.utf8) }
        do {
            if append { try AgentFileManager.shared.appendFile(agentId: agentId, name: path, data: data) }
            else { try AgentFileManager.shared.writeFile(agentId: agentId, name: path, data: data) }
            return "OK"
        } catch { return "[Error] \(error.localizedDescription)" }
    }

    /// Open a file and allocate an fd within the current execution context.
    private func openFdDispatch(args: [String: Any], context: ExecutionContext?) -> String {
        guard let ctx = context, let agentId = ctx.agentId else {
            return "[Error] No agent context for file operations."
        }
        guard let path = filePathArg(args) else { return "[Error] Missing 'path' argument." }
        let flagStr = (args["flags"] as? String) ?? "r"
        let mode: OpenMode
        do { mode = try OpenMode.parse(flagStr) }
        catch { return "[Error] \(error.localizedDescription)" }

        if ctx.fdTable.count >= Self.maxFdsPerContext {
            return "[Error] \(FileToolError.tooManyFds.localizedDescription)"
        }

        // The fd open mode determines whether this is a write op — built-in
        // skills under `skills/<slug>/` reject writes at the resolver.
        let url: URL
        do {
            url = try AgentFileManager.shared.resolvedURL(
                agentId: agentId,
                path: path,
                forWriting: mode.canWrite
            )
        } catch { return "[Error] \(error.localizedDescription)" }

        // Per-agent permission gate for writes to user skills under the
        // `skills/` mount. Independent of the broader files.* permission so
        // an agent can be granted general file writes but denied skill
        // authoring.
        if mode.canWrite, !ctx.permissionChecker(Self.fsSkillWriteAction),
           Self.touchesUserSkillsMount(path) {
            return "[Error] Action '\(Self.fsSkillWriteAction)' is not permitted for this agent."
        }

        let fm = FileManager.default
        var isDir: ObjCBool = false
        let exists = fm.fileExists(atPath: url.path, isDirectory: &isDir)
        if exists && isDir.boolValue { return "[Error] \(FileToolError.isDirectory(path).localizedDescription)" }

        do {
            switch mode {
            case .read:
                guard exists else { return "[Error] \(FileToolError.fileNotFound(path).localizedDescription)" }
            case .readWrite:
                guard exists else { return "[Error] \(FileToolError.fileNotFound(path).localizedDescription)" }
            case .writeTrunc, .writePlus:
                // Ensure parent directory exists; truncate by replacing contents.
                let parent = url.deletingLastPathComponent()
                if !fm.fileExists(atPath: parent.path) {
                    try fm.createDirectory(at: parent, withIntermediateDirectories: true)
                }
                try Data().write(to: url, options: .atomic)
            case .append, .appendPlus:
                let parent = url.deletingLastPathComponent()
                if !fm.fileExists(atPath: parent.path) {
                    try fm.createDirectory(at: parent, withIntermediateDirectories: true)
                }
                if !exists { try Data().write(to: url, options: .atomic) }
            }

            let handle: FileHandle
            switch mode {
            case .read: handle = try FileHandle(forReadingFrom: url)
            case .readWrite, .writePlus, .appendPlus: handle = try FileHandle(forUpdating: url)
            case .writeTrunc, .append: handle = try FileHandle(forWritingTo: url)
            }
            var position: UInt64 = 0
            if mode == .append || mode == .appendPlus {
                position = try handle.seekToEnd()
            }
            let fd = ctx.nextFdId
            ctx.nextFdId += 1
            ctx.fdTable[fd] = FDEntry(url: url, handle: handle, mode: mode, position: position)
            return "\(fd)"
        } catch {
            return "[Error] \(error.localizedDescription)"
        }
    }

    private func closeFdDispatch(args: [String: Any], context: ExecutionContext?) -> String {
        guard let ctx = context else { return "[Error] No agent context for file operations." }
        guard let fd = intArg(args["fd"]) else { return "[Error] Missing 'fd' argument." }
        guard let entry = ctx.fdTable.removeValue(forKey: fd) else {
            return "[Error] \(FileToolError.invalidFd(fd).localizedDescription)"
        }
        do { try entry.handle.close(); return "OK" }
        catch { return "[Error] \(error.localizedDescription)" }
    }

    /// POSIX read from fd. Reads up to `length` bytes at optional `position` (defaults to
    /// current). Mode/encoding: `text` (default, UTF-8), `base64`, or `hex`.
    private func readFdDispatch(args: [String: Any], context: ExecutionContext?) -> String {
        guard let ctx = context else { return "[Error] No agent context for file operations." }
        guard let fd = intArg(args["fd"]) else { return "[Error] Missing 'fd' argument." }
        guard let entry = ctx.fdTable[fd] else {
            return "[Error] \(FileToolError.invalidFd(fd).localizedDescription)"
        }
        guard entry.mode.canRead else { return "[Error] fd \(fd) is not readable." }
        let length = max(intArg(args["length"]) ?? 0, 0)
        if length == 0 { return "" }
        let mode = (args["encoding"] as? String) ?? (args["mode"] as? String) ?? "text"
        do {
            if let pos = intArg(args["position"]) {
                try entry.handle.seek(toOffset: UInt64(max(pos, 0)))
                entry.position = UInt64(max(pos, 0))
            } else {
                try entry.handle.seek(toOffset: entry.position)
            }
            let data = try entry.handle.read(upToCount: length) ?? Data()
            entry.position = try entry.handle.offset()
            switch mode {
            case "base64": return data.base64EncodedString()
            case "hex": return HexDump.format(data, startOffset: Int(entry.position) - data.count)
            default:
                if let text = String(data: data, encoding: .utf8) { return text }
                return "[Error] Binary data; use encoding='hex' or 'base64'."
            }
        } catch { return "[Error] \(error.localizedDescription)" }
    }

    /// POSIX write to fd. `content` is UTF-8 text by default; set `encoding='base64'` for
    /// binary data. Optional `position` seeks before writing. Returns `OK <bytes>`.
    private func writeFdDispatch(args: [String: Any], context: ExecutionContext?) -> String {
        guard let ctx = context else { return "[Error] No agent context for file operations." }
        guard let fd = intArg(args["fd"]) else { return "[Error] Missing 'fd' argument." }
        guard let entry = ctx.fdTable[fd] else {
            return "[Error] \(FileToolError.invalidFd(fd).localizedDescription)"
        }
        guard entry.mode.canWrite else { return "[Error] fd \(fd) is not writable." }
        let content = args["content"] as? String ?? ""
        let encoding = (args["encoding"] as? String) ?? "text"
        let data: Data
        if encoding == "base64" {
            guard let d = Data(base64Encoded: content, options: .ignoreUnknownCharacters) else { return "[Error] Invalid base64." }
            data = d
        } else {
            data = Data(content.utf8)
        }
        do {
            if entry.mode == .append || entry.mode == .appendPlus {
                // Append mode always writes at end regardless of requested position.
                entry.position = try entry.handle.seekToEnd()
            } else if let pos = intArg(args["position"]) {
                try entry.handle.seek(toOffset: UInt64(max(pos, 0)))
                entry.position = UInt64(max(pos, 0))
            } else {
                try entry.handle.seek(toOffset: entry.position)
            }
            try entry.handle.write(contentsOf: data)
            entry.position = try entry.handle.offset()
            return "OK \(data.count)"
        } catch { return "[Error] \(error.localizedDescription)" }
    }

    /// POSIX lseek analog. `whence`: `start` (0) / `current` (1) / `end` (2).
    private func seekFdDispatch(args: [String: Any], context: ExecutionContext?) -> String {
        guard let ctx = context else { return "[Error] No agent context for file operations." }
        guard let fd = intArg(args["fd"]) else { return "[Error] Missing 'fd' argument." }
        guard let entry = ctx.fdTable[fd] else {
            return "[Error] \(FileToolError.invalidFd(fd).localizedDescription)"
        }
        let offset = Int64(intArg(args["offset"]) ?? 0)
        let whence = args["whence"] as? String ?? "start"
        do {
            let base: Int64
            switch whence {
            case "start", "0": base = 0
            case "current", "1": base = Int64(try entry.handle.offset())
            case "end", "2": base = Int64(try entry.handle.seekToEnd())
            default: return "[Error] Invalid 'whence': use 'start', 'current', or 'end'."
            }
            let newPos = max(base + offset, 0)
            try entry.handle.seek(toOffset: UInt64(newPos))
            entry.position = UInt64(newPos)
            return "\(newPos)"
        } catch { return "[Error] \(error.localizedDescription)" }
    }

    private func tellFdDispatch(args: [String: Any], context: ExecutionContext?) -> String {
        guard let ctx = context else { return "[Error] No agent context for file operations." }
        guard let fd = intArg(args["fd"]) else { return "[Error] Missing 'fd' argument." }
        guard let entry = ctx.fdTable[fd] else {
            return "[Error] \(FileToolError.invalidFd(fd).localizedDescription)"
        }
        do {
            entry.position = try entry.handle.offset()
            return "\(entry.position)"
        } catch { return "[Error] \(error.localizedDescription)" }
    }

    private func fstatFdDispatch(args: [String: Any], context: ExecutionContext?) -> String {
        guard let ctx = context, let agentId = ctx.agentId else {
            return "[Error] No agent context for file operations."
        }
        guard let fd = intArg(args["fd"]) else { return "[Error] Missing 'fd' argument." }
        guard let entry = ctx.fdTable[fd] else {
            return "[Error] \(FileToolError.invalidFd(fd).localizedDescription)"
        }
        // Re-derive relative path by trimming the agent root.
        let rootPath = AgentFileManager.shared.agentDirectory(for: agentId).standardizedFileURL.path
        var rel = entry.url.standardizedFileURL.path
        if rel.hasPrefix(rootPath + "/") { rel.removeFirst(rootPath.count + 1) }
        guard let info = AgentFileManager.shared.fileInfo(agentId: agentId, name: rel) else {
            return "[Error] File not found for fd \(fd)."
        }
        let mtime = Int64(info.modifiedAt.timeIntervalSince1970 * 1000)
        let ctime = Int64(info.createdAt.timeIntervalSince1970 * 1000)
        let isFile = !info.isDirectory
        let jsonPath = jsonEscape(rel)
        let jsonName = jsonEscape(info.name)
        return "{\"name\":\"\(jsonName)\",\"path\":\"\(jsonPath)\",\"size\":\(info.size),\"is_file\":\(isFile),\"is_dir\":\(info.isDirectory),\"is_image\":\(info.isImage),\"mtime_ms\":\(mtime),\"ctime_ms\":\(ctime),\"position\":\(entry.position)}"
    }

    private func fsyncFdDispatch(args: [String: Any], context: ExecutionContext?) -> String {
        guard let ctx = context else { return "[Error] No agent context for file operations." }
        guard let fd = intArg(args["fd"]) else { return "[Error] Missing 'fd' argument." }
        guard let entry = ctx.fdTable[fd] else {
            return "[Error] \(FileToolError.invalidFd(fd).localizedDescription)"
        }
        do { try entry.handle.synchronize(); return "OK" }
        catch { return "[Error] \(error.localizedDescription)" }
    }

    // MARK: - Argument Helpers

    /// Accept `path` as the canonical key, fall back to legacy `name`.
    private func filePathArg(_ args: [String: Any]) -> String? {
        if let p = args["path"] as? String, !p.isEmpty { return p }
        if let n = args["name"] as? String, !n.isEmpty { return n }
        return nil
    }

    private func intArg(_ value: Any?) -> Int? {
        if let i = value as? Int { return i }
        if let i = value as? Int64 { return Int(i) }
        if let d = value as? Double { return Int(d) }
        if let s = value as? String, let i = Int(s) { return i }
        return nil
    }

    /// Minimal JSON string escaping for `\"` and `\\` inside double-quoted values.
    private func jsonEscape(_ s: String) -> String {
        s.replacingOccurrences(of: "\\", with: "\\\\")
         .replacingOccurrences(of: "\"", with: "\\\"")
    }

    // MARK: - JavaScript Preamble

    /// Generate a JS preamble for the `apple.*` API with per-execution permission enforcement.
    ///
    /// - Parameters:
    ///   - blockedActions: Set of bridge action names to block (e.g. `{"calendar.createEvent", "health.writeBodyMass"}`).
    ///   - execId: Unique execution ID included in every bridge call for native-side permission verification.
    nonisolated static func jsPreamble(blockedActions: Set<String>, execId: String) -> String {
        let blockedArray = blockedActions.map { "'\($0)'" }.joined(separator: ",")
        return """
        var __blockedActions = new Set([\(blockedArray)]);
        var __execId = '\(execId)';

        async function __bridgeCall(action, args) {
            if (__blockedActions.has(action)) {
                return '[Error] Action \\'' + action + '\\' is not permitted for this agent.';
            }
            try {
                return await window.webkit.messageHandlers.appleBridge.postMessage({action: action, args: args || {}, execId: __execId});
            } catch(e) {
                return '[Error] Bridge call failed: ' + e.message;
            }
        }

        var fs = {
            // Directory listing (JSON array).
            list: function(path) { return __bridgeCall('files.list', {path: path || ''}); },
            readdir: function(path) { return __bridgeCall('files.list', {path: path || ''}); },

            // Whole-file read/write (Node's fs.promises.readFile / writeFile shape).
            readFile: function(path, opts) { var a = opts || {}; a.path = path; return __bridgeCall('files.readFile', a); },
            writeFile: function(path, content, opts) { var a = opts || {}; a.path = path; a.content = content; return __bridgeCall('files.writeFile', a); },
            appendFile: function(path, content, opts) { var a = opts || {}; a.path = path; a.content = content; return __bridgeCall('files.appendFile', a); },

            // Unlink / delete.
            delete: function(path) { return __bridgeCall('files.delete', {path: path}); },
            unlink: function(path) { return __bridgeCall('files.delete', {path: path}); },
            rmdir: function(path) { return __bridgeCall('files.delete', {path: path}); },
            rm: function(path) { return __bridgeCall('files.delete', {path: path}); },

            // Metadata.
            stat: function(path) { return __bridgeCall('files.stat', {path: path}); },
            info: function(path) { return __bridgeCall('files.stat', {path: path}); },
            exists: function(path) { return __bridgeCall('files.exists', {path: path}).then(function(r){return r==='true';}); },

            // Directory + file-management.
            mkdir: function(path, opts) { return __bridgeCall('files.mkdir', {path: path}); },
            cp: function(src, dest, opts) {
                var o = opts || {};
                return __bridgeCall('files.cp', {src: src, dest: dest, recursive: o.recursive !== false});
            },
            mv: function(src, dest) { return __bridgeCall('files.mv', {src: src, dest: dest}); },
            rename: function(src, dest) { return __bridgeCall('files.mv', {src: src, dest: dest}); },

            // Truncate: accepts either a path or an fd as first arg.
            truncate: function(pathOrFd, length) {
                if (typeof pathOrFd === 'number') {
                    return __bridgeCall('files.truncate', {fd: pathOrFd, length: length || 0});
                }
                return __bridgeCall('files.truncate', {path: pathOrFd, length: length || 0});
            },
            ftruncate: function(fd, length) { return __bridgeCall('files.truncate', {fd: fd, length: length || 0}); },

            // POSIX-style file descriptor operations.
            open: function(path, flags) { return __bridgeCall('files.open', {path: path, flags: flags || 'r'}); },
            close: function(fd) { return __bridgeCall('files.close', {fd: fd}); },
            fsync: function(fd) { return __bridgeCall('files.fsync', {fd: fd}); },
            fstat: function(fd) { return __bridgeCall('files.fstat', {fd: fd}); },
            seek: function(fd, offset, whence) {
                return __bridgeCall('files.seek', {fd: fd, offset: offset || 0, whence: whence || 'start'});
            },
            tell: function(fd) { return __bridgeCall('files.tell', {fd: fd}); },

            // Overloaded read/write: fd-based when first arg is a number, path-based otherwise.
            read: function(a, b, c) {
                if (typeof a === 'number') {
                    var args = {fd: a, length: b || 0};
                    if (c !== undefined && c !== null) args.position = c;
                    return __bridgeCall('files.read', args);
                }
                var opts = b || {}; opts.path = a;
                return __bridgeCall('files.readFile', opts);
            },
            write: function(a, b, c, d) {
                if (typeof a === 'number') {
                    var args = {fd: a, content: b};
                    if (c !== undefined && c !== null) args.position = c;
                    if (d) args.encoding = d;
                    return __bridgeCall('files.write', args);
                }
                var opts = c || {}; opts.path = a; opts.content = b;
                return __bridgeCall('files.writeFile', opts);
            }
        };

        var apple = (function() {
            return {
                calendar: {
                    listCalendars: function() { return __bridgeCall('calendar.listCalendars', {}); },
                    createEvent: function(opts) { return __bridgeCall('calendar.createEvent', opts); },
                    searchEvents: function(opts) { return __bridgeCall('calendar.searchEvents', opts || {}); },
                    updateEvent: function(opts) { return __bridgeCall('calendar.updateEvent', opts); },
                    deleteEvent: function(eventId) { return __bridgeCall('calendar.deleteEvent', {event_id: eventId}); }
                },
                reminders: {
                    list: function(opts) { return __bridgeCall('reminders.list', opts || {}); },
                    lists: function() { return __bridgeCall('reminders.lists', {}); },
                    create: function(opts) { return __bridgeCall('reminders.create', opts); },
                    complete: function(reminderId, completed) {
                        return __bridgeCall('reminders.complete', {reminder_id: reminderId, completed: completed !== false});
                    },
                    delete: function(reminderId) { return __bridgeCall('reminders.delete', {reminder_id: reminderId}); }
                },
                contacts: {
                    search: function(query) { return __bridgeCall('contacts.search', {query: query}); },
                    getDetail: function(contactId) { return __bridgeCall('contacts.getDetail', {contact_id: contactId}); }
                },
                clipboard: {
                    read: function() { return __bridgeCall('clipboard.read', {}); },
                    write: function(text) { return __bridgeCall('clipboard.write', {text: text}); }
                },
                notifications: {
                    schedule: function(opts) { return __bridgeCall('notifications.schedule', opts); },
                    cancel: function(id) { return __bridgeCall('notifications.cancel', {id: id}); },
                    cancelAll: function() { return __bridgeCall('notifications.cancel', {cancel_all: true}); },
                    list: function() { return __bridgeCall('notifications.list', {}); }
                },
                location: {
                    getCurrent: function(includeAddress) {
                        return __bridgeCall('location.getCurrent', {include_address: includeAddress !== false});
                    },
                    geocode: function(address) { return __bridgeCall('location.geocode', {address: address}); },
                    reverseGeocode: function(lat, lon) {
                        return __bridgeCall('location.reverseGeocode', {latitude: lat, longitude: lon});
                    }
                },
                maps: {
                    searchPlaces: function(query, opts) {
                        var args = opts || {};
                        args.query = query;
                        return __bridgeCall('maps.searchPlaces', args);
                    },
                    getDirections: function(opts) { return __bridgeCall('maps.getDirections', opts); }
                },
                health: {
                    readSteps: function(opts) { return __bridgeCall('health.readSteps', opts || {}); },
                    readHeartRate: function(opts) { return __bridgeCall('health.readHeartRate', opts || {}); },
                    readSleep: function(opts) { return __bridgeCall('health.readSleep', opts || {}); },
                    readBodyMass: function(opts) { return __bridgeCall('health.readBodyMass', opts || {}); },
                    readBloodPressure: function(opts) { return __bridgeCall('health.readBloodPressure', opts || {}); },
                    readBloodGlucose: function(opts) { return __bridgeCall('health.readBloodGlucose', opts || {}); },
                    readBloodOxygen: function(opts) { return __bridgeCall('health.readBloodOxygen', opts || {}); },
                    readBodyTemperature: function(opts) { return __bridgeCall('health.readBodyTemperature', opts || {}); },
                    writeDietaryEnergy: function(opts) { return __bridgeCall('health.writeDietaryEnergy', opts || {}); },
                    writeBodyMass: function(opts) { return __bridgeCall('health.writeBodyMass', opts || {}); },
                    writeDietaryWater: function(opts) { return __bridgeCall('health.writeDietaryWater', opts || {}); },
                    writeDietaryCarbohydrates: function(opts) { return __bridgeCall('health.writeDietaryCarbohydrates', opts || {}); },
                    writeDietaryProtein: function(opts) { return __bridgeCall('health.writeDietaryProtein', opts || {}); },
                    writeDietaryFat: function(opts) { return __bridgeCall('health.writeDietaryFat', opts || {}); },
                    writeBloodPressure: function(opts) { return __bridgeCall('health.writeBloodPressure', opts || {}); },
                    writeBodyFat: function(opts) { return __bridgeCall('health.writeBodyFat', opts || {}); },
                    writeHeight: function(opts) { return __bridgeCall('health.writeHeight', opts || {}); },
                    writeBloodGlucose: function(opts) { return __bridgeCall('health.writeBloodGlucose', opts || {}); },
                    writeBloodOxygen: function(opts) { return __bridgeCall('health.writeBloodOxygen', opts || {}); },
                    writeBodyTemperature: function(opts) { return __bridgeCall('health.writeBodyTemperature', opts || {}); },
                    writeHeartRate: function(opts) { return __bridgeCall('health.writeHeartRate', opts || {}); },
                    writeWorkout: function(opts) { return __bridgeCall('health.writeWorkout', opts || {}); }
                }
            };
        })();

        // --- Inter-snippet calling ---
        // `snippets.invoke(name, args, opts)` runs another snippet inside the current
        // execution. The callee body is wrapped in an async IIFE, so a top-level
        // `return value;` yields the return value. Default opts append the callee's
        // stdout/stderr to the caller's output; pass `{capture: true}` to receive a
        // structured `{result, stdout, stderr}` instead. Pass `{stdin: "..."}` to
        // expose a `stdin` global string to the callee.
        var snippets = {
            invoke: async function(name, callArgs, opts) {
                opts = opts || {};
                var raw = await __bridgeCall('snippets.invoke', {
                    name: name,
                    args: callArgs || {},
                    stdin: (typeof opts.stdin === 'string') ? opts.stdin : ''
                });
                if (typeof raw === 'string' && raw.indexOf('[Error]') === 0) {
                    throw new Error(raw);
                }
                var resp;
                try { resp = (typeof raw === 'string') ? JSON.parse(raw) : raw; }
                catch(e) { throw new Error('[Error] Invalid snippet response: ' + e.message); }
                if (!resp || resp.ok === false) {
                    if (!opts.capture) {
                        if (resp && resp.stdout) __appendOut(resp.stdout);
                        if (resp && resp.stderr) __appendErr(resp.stderr);
                    }
                    throw new Error(resp && resp.error ? resp.error : '[Error] snippet failed');
                }
                if (opts.capture) {
                    return { result: resp.result, stdout: resp.stdout || '', stderr: resp.stderr || '' };
                }
                if (resp.stdout) __appendOut(resp.stdout);
                if (resp.stderr) __appendErr(resp.stderr);
                return resp.result;
            },
            pipe: async function(names, pipeArgs) {
                if (!Array.isArray(names) || names.length === 0) {
                    throw new Error('[Error] snippets.pipe requires a non-empty array of snippet names');
                }
                var carry = { result: undefined, stdout: '', stderr: '' };
                for (var i = 0; i < names.length; i++) {
                    carry = await snippets.invoke(names[i], pipeArgs || {}, { stdin: carry.stdout, capture: true });
                }
                return carry;
            },
            list: async function() {
                var raw = await __bridgeCall('snippets.list', {});
                try { return (typeof raw === 'string') ? JSON.parse(raw) : raw; }
                catch(e) { return []; }
            }
        };
        """
    }

    /// Convenience: preamble with no restrictions (backward compatible for non-agent contexts).
    nonisolated static var jsPreambleUnrestricted: String {
        jsPreamble(blockedActions: [], execId: "")
    }
}
