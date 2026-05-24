import Foundation
import SwiftData

/// Rich result from a tool call, carrying text and optional multimodal attachments.
struct ToolCallResult {
    let text: String
    let imageAttachments: [ImageAttachment]?
    let videoAttachments: [VideoAttachment]?

    init(_ text: String, imageAttachments: [ImageAttachment]? = nil, videoAttachments: [VideoAttachment]? = nil) {
        self.text = text
        self.imageAttachments = imageAttachments
        self.videoAttachments = videoAttachments
    }

    static let cancelled = ToolCallResult("[Cancelled] Operation was cancelled.")
}

@MainActor
final class FunctionCallRouter {
    let agent: Agent
    let modelContext: ModelContext
    let sessionId: UUID?
    let nestingDepth: Int
    private let agentService: AgentService
    private let subAgentManager: SubAgentManager

    init(agent: Agent, modelContext: ModelContext, sessionId: UUID? = nil, nestingDepth: Int = 0) {
        self.agent = agent
        self.modelContext = modelContext
        self.sessionId = sessionId
        self.nestingDepth = nestingDepth
        self.agentService = AgentService(modelContext: modelContext)
        self.subAgentManager = SubAgentManager(modelContext: modelContext, nestingDepth: nestingDepth)
    }

    // MARK: - Public API

    /// Execute a tool call with automatic cancellation support.
    ///
    /// Cancellation is checked before and after tool execution. Tool implementations
    /// that are cancellation-aware (browser, code execution, sub-agents) will also
    /// respond to cancellation mid-flight. Returns `.cancelled` if interrupted.
    func execute(toolCall: LLMToolCall) async -> ToolCallResult {
        do {
            try Task.checkCancellation()
            let result = try await dispatchTool(toolCall: toolCall)
            try Task.checkCancellation()
            return result
        } catch is CancellationError {
            return .cancelled
        } catch {
            return ToolCallResult("[Error] \(error.localizedDescription)")
        }
    }

    // MARK: - Tool Dispatch

    // ┌──────────────────────────────────────────────────────────────────────┐
    // │  HOW TO ADD A NEW TOOL                                              │
    // │                                                                     │
    // │  1. Synchronous → return ToolCallResult(...) directly.              │
    // │  2. Async, non-throwing → wrap with `runAsync { ... }`.             │
    // │  3. Async, throwing → wrap with `runAsyncThrowing { ... }`          │
    // │     or call directly with `try await` (CancellationError will       │
    // │     propagate automatically).                                       │
    // │  4. Long-running async tools MUST check Task.isCancelled or use     │
    // │     cancellation-aware APIs (withTaskCancellationHandler) internally.│
    // │                                                                     │
    // │  `execute()` guarantees cancellation checks before & after dispatch,│
    // │  `runAsync` / `runAsyncThrowing` add a post-completion check, and   │
    // │  CancellationError from any layer is caught and mapped to           │
    // │  `.cancelled`.                                                      │
    // └──────────────────────────────────────────────────────────────────────┘

    private func dispatchTool(toolCall: LLMToolCall) async throws -> ToolCallResult {
        let name = toolCall.function.name

        if ToolCategory.allRegisteredToolNames.contains(name) && !agent.isToolAllowed(name) {
            let category = ToolCategory.category(for: name)
            let categoryName = category?.displayName ?? name
            return ToolCallResult(L10n.PermissionError.toolNotPermitted(name, categoryName))
        }

        let arguments = parseArguments(toolCall.function.arguments)

        switch name {

        // --- Sub-Agent ---
        case "message_sub_agent":
            return try await subAgentTools.messageSubAgent(arguments: arguments)
        case "collect_sub_agent_output":
            return subAgentTools.collectSubAgentOutput(arguments: arguments)
        case "create_sub_agent":
            return ToolCallResult(subAgentTools.createSubAgent(arguments: arguments))
        case "list_sub_agents":
            return ToolCallResult(subAgentTools.listSubAgents(arguments: arguments))
        case "stop_sub_agent":
            return ToolCallResult(subAgentTools.stopSubAgent(arguments: arguments))
        case "delete_sub_agent":
            return ToolCallResult(subAgentTools.deleteSubAgent(arguments: arguments))

        // --- Session RAG ---
        case "search_sessions":
            return ToolCallResult(
                SessionRAGTools(agent: agent, modelContext: modelContext, currentSessionId: sessionId)
                    .searchSessions(arguments: arguments))
        case "recall_session":
            return ToolCallResult(
                SessionRAGTools(agent: agent, modelContext: modelContext, currentSessionId: sessionId)
                    .recallSession(arguments: arguments))

        // --- Config ---
        case "read_config":
            return ToolCallResult(
                ConfigTools(agentService: agentService, agent: agent)
                    .readConfig(arguments: arguments))
        case "write_config":
            return ToolCallResult(
                ConfigTools(agentService: agentService, agent: agent)
                    .writeConfig(arguments: arguments))

        // --- Code Execution ---
        case "execute_javascript":
            return try await runAsyncThrowing {
                try await CodeExecutionTools(agent: self.agent, modelContext: self.modelContext)
                    .executeJavaScript(arguments: arguments)
            }
        case "save_code":
            return ToolCallResult(
                CodeExecutionTools(agent: agent, modelContext: modelContext)
                    .saveCode(arguments: arguments))
        case "load_code":
            return ToolCallResult(
                CodeExecutionTools(agent: agent, modelContext: modelContext)
                    .loadCode(arguments: arguments))
        case "list_code":
            return ToolCallResult(
                CodeExecutionTools(agent: agent, modelContext: modelContext)
                    .listCode())
        case "run_snippet":
            // Phase 6: a skill-owned snippet (`skill:<name>:<script>`) counts
            // as an activation — same rationale as a `skill_<slug>_*` tool
            // call. Hand-rolled snippets aren't tied to a skill so they
            // don't activate anything.
            if let snippetName = arguments["name"] as? String,
               snippetName.hasPrefix("skill:") {
                let parts = snippetName.split(separator: ":", maxSplits: 2).map(String.init)
                if parts.count >= 2 {
                    activateSkillForSession(skillName: parts[1])
                }
            }
            return try await runAsyncThrowing {
                try await CodeExecutionTools(agent: self.agent, modelContext: self.modelContext)
                    .runSnippet(arguments: arguments)
            }
        case "delete_code":
            return ToolCallResult(
                CodeExecutionTools(agent: agent, modelContext: modelContext)
                    .deleteCode(arguments: arguments))

        // --- Cron ---
        case "schedule_cron":
            return ToolCallResult(
                CronTools(agent: agent, modelContext: modelContext)
                    .scheduleCron(arguments: arguments))
        case "unschedule_cron":
            return ToolCallResult(
                CronTools(agent: agent, modelContext: modelContext)
                    .unscheduleCron(arguments: arguments))
        case "list_cron":
            return ToolCallResult(
                CronTools(agent: agent, modelContext: modelContext)
                    .listCron())

        // --- Skills ---
        // create_skill / edit_skill / delete_skill / read_skill are removed in
        // favor of `fs.*` writes against the `/skills/<slug>/` mount. Auto-
        // reload (SkillService.reload) and validate_skill replace the
        // round-trip those tools provided.
        case "install_skill":
            return ToolCallResult(
                SkillTools(agent: agent, modelContext: modelContext)
                    .installSkill(arguments: arguments))
        case "uninstall_skill":
            return ToolCallResult(
                SkillTools(agent: agent, modelContext: modelContext)
                    .uninstallSkill(arguments: arguments))
        case "list_skills":
            return ToolCallResult(
                SkillTools(agent: agent, modelContext: modelContext)
                    .listSkills(arguments: arguments))
        case "validate_skill":
            return ToolCallResult(
                SkillTools(agent: agent, modelContext: modelContext)
                    .validateSkill(arguments: arguments))

        // --- Model ---
        case "set_model":
            return ToolCallResult(
                ModelTools(agent: agent, modelContext: modelContext)
                    .setModel(arguments: arguments))
        case "get_model":
            return ToolCallResult(
                ModelTools(agent: agent, modelContext: modelContext)
                    .getModel(arguments: arguments))
        case "list_models":
            return ToolCallResult(
                ModelTools(agent: agent, modelContext: modelContext)
                    .listModels(arguments: arguments))

        // --- Files ---
        case "file_list":
            return ToolCallResult(FileTools(agent: agent).listFiles(arguments: arguments))
        case "file_read":
            return ToolCallResult(FileTools(agent: agent).readFile(arguments: arguments))
        case "file_write":
            return ToolCallResult(FileTools(agent: agent).writeFile(arguments: arguments))
        case "file_delete":
            return ToolCallResult(FileTools(agent: agent).deleteFile(arguments: arguments))
        case "file_info":
            return ToolCallResult(FileTools(agent: agent).fileInfo(arguments: arguments))
        case "attach_media":
            return await FileTools(agent: agent).attachMedia(arguments: arguments)

        // --- Image Generation ---
        case "generate_image":
            let result = try await generateImage(arguments: arguments)
            try Task.checkCancellation()
            return result

        // --- Video Generation ---
        case "generate_video":
            let result = try await generateVideo(arguments: arguments)
            try Task.checkCancellation()
            return result

        // --- Browser ---
        case "browser_navigate":
            return try await runAsync { await self.browserTools.navigate(arguments: arguments) }
        case "browser_get_page_info":
            return try await runAsync { await self.browserTools.getPageInfo(arguments: arguments) }
        case "browser_click":
            return try await runAsync { await self.browserTools.click(arguments: arguments) }
        case "browser_input":
            return try await runAsync { await self.browserTools.input(arguments: arguments) }
        case "browser_select":
            return try await runAsync { await self.browserTools.select(arguments: arguments) }
        case "browser_extract":
            return try await runAsync { await self.browserTools.extract(arguments: arguments) }
        case "browser_execute_js":
            return try await runAsync { await self.browserTools.executeJS(arguments: arguments) }
        case "browser_wait":
            return try await runAsync { await self.browserTools.waitForElement(arguments: arguments) }
        case "browser_scroll":
            return try await runAsync { await self.browserTools.scroll(arguments: arguments) }

        // --- Apple Calendar ---
        case "calendar_list_calendars":
            return try await runAsync { await AppleCalendarTools().listCalendars(arguments: arguments) }
        case "calendar_create_event":
            return try await runAsync { await AppleCalendarTools().createEvent(arguments: arguments) }
        case "calendar_search_events":
            return try await runAsync { await AppleCalendarTools().searchEvents(arguments: arguments) }
        case "calendar_update_event":
            return try await runAsync { await AppleCalendarTools().updateEvent(arguments: arguments) }
        case "calendar_delete_event":
            return try await runAsync { await AppleCalendarTools().deleteEvent(arguments: arguments) }

        // --- Apple Reminders ---
        case "reminder_list":
            return try await runAsync { await AppleReminderTools().listReminders(arguments: arguments) }
        case "reminder_lists":
            return try await runAsync { await AppleReminderTools().listReminderLists(arguments: arguments) }
        case "reminder_create":
            return try await runAsync { await AppleReminderTools().createReminder(arguments: arguments) }
        case "reminder_complete":
            return try await runAsync { await AppleReminderTools().completeReminder(arguments: arguments) }
        case "reminder_delete":
            return try await runAsync { await AppleReminderTools().deleteReminder(arguments: arguments) }

        // --- Apple Contacts ---
        case "contacts_search":
            return try await runAsync { await AppleContactsTools().searchContacts(arguments: arguments) }
        case "contacts_get_detail":
            return try await runAsync { await AppleContactsTools().getContactDetail(arguments: arguments) }

        // --- Apple Clipboard ---
        case "clipboard_read":
            return try await runAsync { AppleClipboardTools().readClipboard(arguments: arguments) }
        case "clipboard_write":
            return try await runAsync { AppleClipboardTools().writeClipboard(arguments: arguments) }

        // --- Apple Notifications ---
        case "notification_schedule":
            return try await runAsync { await AppleNotificationTools().scheduleNotification(arguments: arguments) }
        case "notification_cancel":
            return try await runAsync { await AppleNotificationTools().cancelNotification(arguments: arguments) }
        case "notification_list":
            return try await runAsync { await AppleNotificationTools().listNotifications(arguments: arguments) }

        // --- Apple Location ---
        case "location_get_current":
            return try await runAsync { await AppleLocationTools().getCurrentLocation(arguments: arguments) }
        case "location_geocode":
            return try await runAsync { await AppleLocationTools().geocode(arguments: arguments) }
        case "location_reverse_geocode":
            return try await runAsync { await AppleLocationTools().reverseGeocode(arguments: arguments) }

        // --- Apple Map ---
        case "map_search_places":
            return try await runAsync { await AppleMapTools().searchPlaces(arguments: arguments) }
        case "map_get_directions":
            return try await runAsync { await AppleMapTools().getDirections(arguments: arguments) }

        // --- Apple Health (Read) ---
        // Long-tail reads (blood_pressure/glucose/oxygen, body_temperature) are reached
        // via the "Health Plus" built-in skill → `apple.health.*` bridge.
        case "health_read_steps":
            return try await runAsync { await AppleHealthTools().readSteps(arguments: arguments) }
        case "health_read_heart_rate":
            return try await runAsync { await AppleHealthTools().readHeartRate(arguments: arguments) }
        case "health_read_sleep":
            return try await runAsync { await AppleHealthTools().readSleep(arguments: arguments) }
        case "health_read_body_mass":
            return try await runAsync { await AppleHealthTools().readBodyMass(arguments: arguments) }
        // --- Apple Health (Write) ---
        // Long-tail writes (macronutrients, blood_*, body_fat/height/temperature,
        // heart_rate, workouts) are reached via the "Health Plus" skill.
        case "health_write_dietary_energy":
            return try await runAsync { await AppleHealthTools().writeDietaryEnergy(arguments: arguments) }
        case "health_write_body_mass":
            return try await runAsync { await AppleHealthTools().writeBodyMass(arguments: arguments) }
        case "health_write_dietary_water":
            return try await runAsync { await AppleHealthTools().writeDietaryWater(arguments: arguments) }

        default:
            // Dispatch skill custom tools (prefixed with "skill_")
            if name.hasPrefix("skill_") {
                return try await executeSkillTool(name: name, arguments: arguments)
            }
            return ToolCallResult("[Error] Unknown tool: \(name)")
        }
    }

    // MARK: - Skill Custom Tool Execution

    /// Execute a custom tool defined by an active skill.
    /// Finds the matching SkillToolDefinition and runs its JS implementation
    /// via the code execution sandbox, passing tool arguments and installation config.
    private func executeSkillTool(name: String, arguments: [String: Any]) async throws -> ToolCallResult {
        for installation in agent.activeSkills {
            guard let skill = installation.skill else { continue }
            let prefix = PromptBuilder.skillToolName(skillName: skill.name, toolName: "")
            guard name.hasPrefix(prefix) else { continue }

            let funcName = String(name.dropFirst(prefix.count))
            guard let toolDef = skill.customTools.first(where: { $0.name == funcName }) else { continue }

            // Phase 6: invoking a skill tool counts as an activation — the
            // skill's body joins the system prompt on the next turn so the
            // model has the methodology that wraps this tool call.
            activateSkillForSession(skillName: skill.name)

            // Merge tool arguments with installation config
            var jsArgs: [String: Any] = arguments
            if !installation.config.isEmpty {
                jsArgs["config"] = installation.config
            }

            let codeTools = CodeExecutionTools(agent: agent, modelContext: modelContext)
            let execArgs: [String: Any] = [
                "code": toolDef.implementation,
                "mode": "script",
                "args": jsArgs
            ]
            let result = try await codeTools.executeJavaScript(arguments: execArgs)
            return ToolCallResult(result)
        }
        return ToolCallResult("[Error] Skill tool '\(name)' not found or skill is not active")
    }

    /// Mark a skill as activated for the current session so progressive
    /// disclosure (Phase 6) expands its body into the system prompt on the
    /// next turn. No-op for cron / sub-agent flows that lack a session id.
    /// Internal (rather than `private`) so tests can exercise the helper
    /// without spinning up a full WKWebView JS execution.
    func activateSkillForSession(skillName: String) {
        guard let sessionId else { return }
        let slug = SkillPackage.derivedSlug(forName: skillName)
        var descriptor = FetchDescriptor<Session>(
            predicate: #Predicate { $0.id == sessionId }
        )
        descriptor.fetchLimit = 1
        guard let session = try? modelContext.fetch(descriptor).first else { return }
        if !session.activatedSkillSlugs.contains(slug) {
            session.activatedSkillSlugs.insert(slug)
            try? modelContext.save()
        }
    }

    // MARK: - Cancellation Helpers

    /// Wraps a non-throwing async tool. Checks cancellation after the operation completes.
    private func runAsync(_ work: () async -> String) async throws -> ToolCallResult {
        let text = await work()
        try Task.checkCancellation()
        return ToolCallResult(text)
    }

    /// Wraps a throwing async tool. CancellationError propagates naturally from the
    /// underlying operation; also re-checks cancellation after successful completion.
    private func runAsyncThrowing(_ work: () async throws -> String) async throws -> ToolCallResult {
        let text = try await work()
        try Task.checkCancellation()
        return ToolCallResult(text)
    }

    // MARK: - Image Generation

    private func generateImage(arguments: [String: Any]) async throws -> ToolCallResult {
        guard let prompt = arguments["prompt"] as? String, !prompt.isEmpty else {
            return ToolCallResult("[Error] Missing required parameter: prompt")
        }

        let router = ModelRouter(modelContext: modelContext)

        // Allow per-call provider/model override
        let provider: LLMProvider
        let effectiveModel: String
        if let overrideIdStr = arguments["provider_id"] as? String,
           let overrideId = UUID(uuidString: overrideIdStr) {
            guard let p = router.providerById(overrideId) else {
                return ToolCallResult("[Error] Provider not found with id: \(overrideIdStr)")
            }
            provider = p
            effectiveModel = (arguments["model_name"] as? String) ?? p.modelName
        } else {
            guard let imageProviderId = agent.imageProviderId else {
                return ToolCallResult("[Error] No image generation provider configured for this agent. Please configure one in Agent Settings → Model → Image Generation.")
            }
            guard let p = router.providerById(imageProviderId) else {
                return ToolCallResult("[Error] Image generation provider not found. It may have been deleted.")
            }
            provider = p
            effectiveModel = agent.imageModelNameOverride ?? p.modelName
        }

        let n = (arguments["n"] as? Int) ?? 1
        let size = arguments["size"] as? String
        let quality = arguments["quality"] as? String
        let imageURL = arguments["image_url"] as? String

        let agentId = AgentFileManager.shared.resolveAgentId(for: agent)
        let imageData: Data? = try await resolveInputImageData(from: imageURL)

        let service = ImageGenerationService(provider: provider, modelName: effectiveModel)
        let (images, revisedPrompt) = try await service.generate(
            prompt: prompt,
            n: min(max(n, 1), 4),
            size: size,
            quality: quality,
            imageData: imageData,
            agentId: agentId
        )

        var resultText = "Generated \(images.count) image\(images.count == 1 ? "" : "s") successfully."
        if let revised = revisedPrompt {
            resultText += "\nRevised prompt: \(revised)"
        }

        return ToolCallResult(resultText, imageAttachments: images)
    }

    // MARK: - Video Generation

    /// Video generation progress callback, set by ChatViewModel for UI updates.
    var videoProgressCallback: (@Sendable (VideoGenerationPhase) -> Void)?

    private func generateVideo(arguments: [String: Any]) async throws -> ToolCallResult {
        guard let prompt = arguments["prompt"] as? String, !prompt.isEmpty else {
            return ToolCallResult("[Error] Missing required parameter: prompt")
        }

        let duration = arguments["duration"] as? String
        let aspectRatio = arguments["aspect_ratio"] as? String
        let imageURL = arguments["image_url"] as? String
        let isI2V = imageURL != nil && !imageURL!.isEmpty

        let router = ModelRouter(modelContext: modelContext)

        // Allow per-call provider/model override
        let provider: LLMProvider
        let effectiveModel: String
        if let overrideIdStr = arguments["provider_id"] as? String,
           let overrideId = UUID(uuidString: overrideIdStr) {
            guard let p = router.providerById(overrideId) else {
                return ToolCallResult("[Error] Provider not found with id: \(overrideIdStr)")
            }
            provider = p
            effectiveModel = (arguments["model_name"] as? String) ?? p.modelName
        } else {
            // Resolve provider: use separate I2V provider if configured, else fall back to T2V provider
            let resolvedProviderId: UUID?
            let resolvedModelOverride: String?
            if isI2V, let i2vId = agent.i2vProviderId {
                resolvedProviderId = i2vId
                resolvedModelOverride = agent.i2vModelNameOverride
            } else {
                resolvedProviderId = agent.videoProviderId
                resolvedModelOverride = agent.videoModelNameOverride
            }

            guard let providerId = resolvedProviderId else {
                return ToolCallResult("[Error] No video generation provider configured for this agent. Please configure one in Agent Settings → Model → Video Generation.")
            }
            guard let p = router.providerById(providerId) else {
                return ToolCallResult("[Error] Video generation provider not found. It may have been deleted.")
            }
            provider = p
            effectiveModel = resolvedModelOverride ?? p.modelName
        }
        let agentId = AgentFileManager.shared.resolveAgentId(for: agent)

        let service = VideoGenerationService(provider: provider, modelName: effectiveModel)

        // Pre-resolve video provider for background continuation (avoid capturing @Model in @Sendable)
        let resolvedVideoProvider = VideoGenProvider.resolve(apiStyle: provider.apiStyle)
        let providerEndpoint = provider.endpoint
        let providerApiKey = provider.apiKey

        // Track the submit result so we can continue polling in the background if cancelled.
        let capturedSubmitResult = MutableBox<VideoGenerationService.SubmitResult?>(nil)
        let progressCallback = videoProgressCallback
        let wrappedProgress: @Sendable (VideoGenerationPhase) -> Void = { phase in
            progressCallback?(phase)
            if case .submitted(let taskId) = phase {
                capturedSubmitResult.value = VideoGenerationService.SubmitResult(
                    taskId: taskId,
                    videoProvider: resolvedVideoProvider,
                    endpoint: providerEndpoint,
                    apiKey: providerApiKey,
                    agentId: agentId
                )
            }
        }

        // Try the full generate flow with progress reporting.
        // On cancellation after submit, continue polling in the background.
        do {
            let video = try await service.generate(
                prompt: prompt,
                duration: duration,
                aspectRatio: aspectRatio,
                imageURL: imageURL,
                agentId: agentId,
                onProgress: wrappedProgress
            )

            let durationStr = String(format: "%.1fs", video.duration)
            let sizeStr = ByteCountFormatter.string(fromByteCount: video.fileSize, countStyle: .file)
            let resultText = "Generated video successfully (\(durationStr), \(sizeStr))."

            return ToolCallResult(resultText, videoAttachments: [video])
        } catch is CancellationError {
            // If we have a taskId from the submit phase, continue polling in background
            if let submitResult = capturedSubmitResult.value {
                Task.detached { [service] in
                    _ = try? await service.pollUntilComplete(
                        taskId: submitResult.taskId,
                        videoProvider: submitResult.videoProvider,
                        agentId: submitResult.agentId
                    )
                    // Video saved to agent files by downloadAndStore
                }
            }
            throw CancellationError()
        }
    }

    /// Thread-safe mutable box for capturing values from @Sendable closures.
    private final class MutableBox<T>: @unchecked Sendable {
        var value: T
        init(_ value: T) { self.value = value }
    }

    /// Resolve an optional `image_url` argument (either an `agentfile://` reference
    /// or a regular HTTP(S) URL) into raw image bytes. Returns nil when the
    /// argument is missing or empty.
    private func resolveInputImageData(from imageURL: String?) async throws -> Data? {
        guard let imageURL, !imageURL.isEmpty else { return nil }
        if imageURL.hasPrefix("agentfile://") {
            return AgentFileManager.shared.loadImageData(from: imageURL)
        }
        if let url = URL(string: imageURL) {
            let (data, _) = try await URLSession.shared.data(from: url)
            return data
        }
        return nil
    }

    // MARK: - Private

    private var subAgentTools: SubAgentTools {
        SubAgentTools(agent: agent, modelContext: modelContext, subAgentManager: subAgentManager, parentSessionId: sessionId)
    }

    private var browserTools: BrowserTools {
        BrowserTools(sessionId: sessionId ?? agent.id, agentName: agent.name)
    }

    private func parseArguments(_ json: String) -> [String: Any] {
        guard let data = json.data(using: .utf8),
              let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return [:]
        }
        return dict
    }
}
