import Foundation

final class PromptBuilder {

    /// Per-app setting toggling progressive disclosure of installed-skill
    /// bodies. When true (default) the skills section renders dormant skills
    /// as a one-line bullet (`name (/slug) — description`) and only expands a
    /// skill's full body once it's been activated for the session (via a
    /// `/<slug>` slash-command, a `skill_<slug>_*` tool call, or a
    /// `run_snippet skill:<name>:*` invocation). When false, every installed
    /// skill's full body joins the prompt every turn — the pre-Phase-6
    /// behavior.
    ///
    /// Read via `object(forKey:)` so the missing-default case can be
    /// distinguished from an explicit `false`.
    static let progressiveDisclosureKey = "iclaw.skill.progressive_disclosure"

    static var progressiveDisclosureEnabled: Bool {
        get {
            if let v = UserDefaults.standard.object(forKey: progressiveDisclosureKey) as? Bool {
                return v
            }
            return true
        }
        set { UserDefaults.standard.set(newValue, forKey: progressiveDisclosureKey) }
    }

    func buildSystemPrompt(
        for agent: Agent,
        isSubAgent: Bool = false,
        relatedSessions: [(id: UUID, title: String, updatedAt: Date)] = [],
        rootAgentId: UUID? = nil,
        activatedSkillSlugs: Set<String>? = nil
    ) -> String {
        var sections: [String] = []

        let effectiveRootId = rootAgentId ?? AgentFileManager.shared.resolveAgentId(for: agent)
        sections.append(buildCapabilitiesSection(for: agent, rootAgentId: effectiveRootId))

        sections.append(buildSoulSection(agent.soulMarkdown))

        if isSubAgent {
            sections.append(buildSubAgentHints())
        } else {
            sections.append(buildMemorySection(agent.memoryMarkdown))
            sections.append(buildUserSection(agent.userMarkdown))
        }

        let activeSkills = agent.activeSkills
        if !activeSkills.isEmpty {
            sections.append(buildInstalledSkillsSection(activeSkills, activatedSlugs: activatedSkillSlugs))
        }

        if !agent.customConfigs.isEmpty {
            sections.append(buildCustomConfigsIndex(agent))
        }

        if !relatedSessions.isEmpty {
            sections.append(buildRelatedSessionsSection(relatedSessions))
        }

        return sections.joined(separator: "\n\n---\n\n")
    }

    func buildSystemPromptWithCompressedContext(
        for agent: Agent,
        compressedContext: String?,
        isSubAgent: Bool = false,
        activatedSkillSlugs: Set<String>? = nil
    ) -> String {
        var prompt = buildSystemPrompt(
            for: agent,
            isSubAgent: isSubAgent,
            activatedSkillSlugs: activatedSkillSlugs
        )

        if let compressed = compressedContext, !compressed.isEmpty {
            prompt += "\n\n---\n\n"
            prompt += "## Conversation History Summary\n\n"
            prompt += "The following is a compressed summary of earlier messages in this conversation:\n\n"
            prompt += compressed
        }

        return prompt
    }

    func buildSubAgentInitPrompt(
        parentAgent: Agent,
        subAgentName: String,
        initialContext: String?
    ) -> String {
        var prompt = buildSystemPrompt(for: parentAgent, isSubAgent: true)

        if let context = initialContext, !context.isEmpty {
            prompt += "\n\n---\n\n"
            prompt += "## Context from Parent Agent\n\n"
            prompt += context
        }

        return prompt
    }

    // MARK: - Private sections

    private func isEnabled(_ category: ToolCategory, for agent: Agent) -> Bool {
        agent.permissionLevel(for: category) != .disabled
    }

    private func buildCapabilitiesSection(for agent: Agent, rootAgentId: UUID) -> String {
        var parts: [String] = [
            "## Your Capabilities\n\nYou are an AI agent with the following tools available:"
        ]

        // Config is always available
        parts.append("""
        ### Configuration Management
        - `read_config`: Read your configuration files (SOUL.md, MEMORY.md, USER.md, or custom configs)
        - `write_config`: Update your configuration files to persist knowledge and preferences
        """)

        if isEnabled(.codeExecution, for: agent) {
            parts.append(codeExecutionSection(for: agent))
        }

        if isEnabled(.subAgents, for: agent) {
            parts.append("""
            ### Sub-Agent Management
            Sub-agents are independent AI workers you create and communicate with via messages.

            **Standard workflow:**
            1. `create_sub_agent` → returns an `agent_id` (UUID string)
            2. `message_sub_agent` with that `agent_id` + your `message` → returns the sub-agent's response
            3. `collect_sub_agent_output` with the same `agent_id` → retrieves session content and cleans up

            **Parallel execution:** When you issue multiple `message_sub_agent` tool calls in the same response, they execute **concurrently**. This is the recommended pattern for fan-out tasks — create several sub-agents, then send messages to all of them in a single turn. Their LLM calls and tool loops run in parallel, significantly reducing total wait time.

            **Tools:**
            - `create_sub_agent`: Create a sub-agent. Returns its `agent_id`. Types: `temp` (default, auto-destroyed after collection) or `persistent` (long-lived).
            - `message_sub_agent`: Send a message to a sub-agent by `agent_id`. It runs autonomously (including tool calls) and returns a text response. Multiple calls in the same turn run in parallel.
            - `collect_sub_agent_output`: Retrieve session output. Mode `summary` (default) or `full`.
            - `list_sub_agents`: List all sub-agents with status and message counts.
            - `stop_sub_agent`: Force-stop a running sub-agent.
            - `delete_sub_agent`: Permanently delete a sub-agent.
            """)
        }

        if isEnabled(.sessions, for: agent) {
            parts.append("""
            ### Session Memory (RAG)
            You can search and recall context from past conversation sessions.

            - `search_sessions`: Search past sessions by keyword. Returns session IDs, titles, dates, and message counts. Use when the Related Sessions list is insufficient or when you need to find context beyond what was auto-injected.
            - `recall_session`: Retrieve context from a specific session by UUID — returns compressed history and recent messages.

            **When to use:** Related sessions (if any) are auto-injected in the "Related Sessions" section — you can recall those directly without searching. For longer conversations or new topics, use `search_sessions` to discover additional relevant history.
            """)
        }

        if isEnabled(.cron, for: agent) {
            parts.append("""
            ### Cron Job Scheduling
            - `schedule_cron`: Schedule a recurring job with a cron expression (e.g. `0 9 * * 1-5` for weekdays at 9am). Each trigger creates a new session and sends your job hint to the LLM automatically.
            - `unschedule_cron`: Disable or delete an existing cron job
            - `list_cron`: List all scheduled cron jobs with their status and run history
            - Supported presets: `@hourly`, `@daily`, `@weekly`, `@monthly`, `@yearly`
            """)
        }

        if isEnabled(.skills, for: agent) {
            parts.append("""
            ### Skills Management
            - `create_skill`: Create a reusable skill (methodology, instructions, or knowledge) in the skill library — can include `scripts` (JS code snippets) and `tools` (custom function-call tools) at creation time
            - `edit_skill`: Update an existing skill's metadata, scripts, or custom tools (cannot edit built-in skills; `scripts`/`tools` replace the whole array — call `read_skill` first to preserve existing entries)
            - `delete_skill`: Remove a skill from the library (cannot delete built-in skills)
            - `install_skill`: Install a library skill onto the current agent (adds to system prompt)
            - `uninstall_skill`: Remove a skill from the current agent
            - `list_skills`: Browse the skill library or view installed skills
            - `read_skill`: Read the full content of a skill
            """)
        }

        if isEnabled(.files, for: agent) {
            parts.append("""
            ### File Management
            Your file folder supports nested directories. All file tools take a relative `path` (e.g. `"notes.txt"` or `"docs/2026/readme.md"`). Absolute paths and `..` segments are rejected.
            - `file_list`: List direct children of a directory (`path` optional; empty = root). Directories are tagged `[dir]`.
            - `file_read`: Read a file. Default returns the first **1024 bytes** as UTF-8. Pass `size` to read more bytes, `offset` to page, `mode: "hex"` for a hexdump (address + ASCII sidebar) or `mode: "base64"` for binary.
            - `file_write`: Create or overwrite a file. Parent directories are created automatically. Use `encoding: "base64"` for binary data.
            - `file_delete`: Delete a file or directory (directories are removed recursively).
            - `file_info`: Get metadata (size, dates, `is_directory`, `is_image`).
            - `attach_media`: Attach a media file from your folder into the conversation so you can see and analyze it. Supports images (jpg, png, gif, webp, heic, bmp, tiff) and videos (mp4, mov, m4v, webm).
            - Files persist across sessions. Sub-agents share the parent agent's file folder.
            - Generated images are automatically saved here. Users can also upload files via the UI or iOS Files app.
            - For directory management, copy/move, or fine-grained POSIX I/O (seek, truncate, fd-based read/write), install the built-in **File Ops** skill which exposes `skill_file_ops_*` wrappers around the `fs` namespace.

            #### File References (`agentfile://` scheme)
            Your file folder ID: `\(rootAgentId.uuidString)`

            Reference files in markdown using the `agentfile://` URL scheme:
            - **Link to a file**: `[display text](agentfile://\(rootAgentId.uuidString)/filename)` — rendered as a clickable link in the UI
            - **Embed an image**: `![description](agentfile://\(rootAgentId.uuidString)/filename.jpg)` — rendered inline in the conversation

            When you output `![description](agentfile://...)` for an image file, the system will:
            1. Render the image inline in the UI for the user to see
            2. Automatically inject the image into subsequent LLM context so you (and sub-agents) can see it
            3. If the current model does not support vision, images will be stripped and the user will be notified

            Images you generate inline (base64 data URIs) are automatically saved to your file folder and converted to `agentfile://` references.
            """)
        }

        if isEnabled(.browser, for: agent) {
            parts.append("""
            ### Browser
            - `browser_navigate`: Navigate to a URL or search query
            - `browser_get_page_info`: Get current page title, URL, and interactive elements
            - `browser_click`: Click an element by selector or index
            - `browser_input`: Type text into an input field
            - `browser_select`: Select an option from a dropdown
            - `browser_extract`: Extract text content from the page
            - `browser_execute_js`: Execute JavaScript in the browser page context
            - `browser_wait`: Wait for an element to appear
            - `browser_scroll`: Scroll the page
            """)
        }

        if isEnabled(.model, for: agent) {
            parts.append("""
            ### Model Management
            - `set_model`: Configure your LLM model. Roles:
              - `primary`: Set the main model for this agent
              - `fallback`: Replace the entire fallback chain (array of model IDs)
              - `add_fallback`: Append a model to the fallback chain
              - `sub_agent`: Set the default model for sub-agents you create
            - `get_model`: View current model configuration (primary, fallbacks, sub-agent default)
            - `list_models`: List all available LLM providers and their model IDs
            - When creating sub-agents, you can specify `model_id` to override the default
            """)
        }

        // Apple ecosystem categories
        let appleCategories: [(ToolCategory, String)] = [
            (.calendar, "Calendar: `calendar_list_calendars`, `calendar_create_event`, `calendar_search_events`, `calendar_update_event`, `calendar_delete_event`"),
            (.reminders, "Reminders: `reminder_list`, `reminder_lists`, `reminder_create`, `reminder_complete`, `reminder_delete`"),
            (.contacts, "Contacts: `contacts_search`, `contacts_get_detail`"),
            (.clipboard, "Clipboard: `clipboard_read`, `clipboard_write`"),
            (.notifications, "Notifications: `notification_schedule`, `notification_cancel`, `notification_list`"),
            (.location, "Location: `location_get_current`, `location_geocode`, `location_reverse_geocode`"),
            (.map, "Maps: `map_search_places`, `map_get_directions`"),
            (.health, "Health: read steps/heart rate/sleep/body mass; write body mass, dietary energy, dietary water. For blood pressure/glucose/oxygen, body temperature/fat/height, heart-rate writes, macronutrient writes (carbs/protein/fat), and workouts, install the built-in **Health Plus** skill which exposes `skill_health_plus_*` wrappers around the `apple.health.*` namespace."),
        ]
        let enabledApple = appleCategories.filter { isEnabled($0.0, for: agent) }
        if !enabledApple.isEmpty {
            var section = "### Apple Ecosystem\n"
            for (_, desc) in enabledApple {
                section += "- \(desc)\n"
            }
            parts.append(section)
        }

        // Guidelines
        var guidelines: [String] = [
            "Update MEMORY.md with important facts and decisions you want to remember across sessions.",
            "If a model call fails, the system will automatically try fallback models in order.",
            "Always explain your reasoning before using tools.",
        ]
        if isEnabled(.codeExecution, for: agent) {
            guidelines.append("Use JavaScript execution when working with JSON-heavy data, web APIs, or when JS-specific features are needed.")
        }
        if isEnabled(.subAgents, for: agent) {
            guidelines.append("For sub-agents: always use the exact `agent_id` UUID string returned by `create_sub_agent`. When parallelizing work, batch multiple `message_sub_agent` calls in a single response for concurrent execution.")
        }
        if isEnabled(.cron, for: agent) {
            guidelines.append("Use cron jobs for recurring automated tasks like daily summaries, periodic checks, or scheduled reminders.")
        }
        if isEnabled(.skills, for: agent) {
            guidelines.append("Create and install skills to give yourself or other agents specialized capabilities.")
        }
        if isEnabled(.sessions, for: agent) {
            guidelines.append("When the user seems to reference past conversations or you need prior context, use `search_sessions` and `recall_session` to retrieve relevant history.")
        }
        let codeExecEnabled = isEnabled(.codeExecution, for: agent)
        let hasBridgeCategory = isEnabled(.files, for: agent)
            || ToolCategory.appleCategories.contains(where: { isEnabled($0, for: agent) })
        if codeExecEnabled && hasBridgeCategory {
            guidelines.append("Permission levels cover every route to a capability: function-call tools, the `apple.*` / `fs.*` JavaScript namespaces, and any installed skills that wrap those bridges. Setting a category to Read Only blocks its write bridge actions whether they are reached via a tool, `execute_javascript`, or a skill custom tool — do not try to route around a restriction.")
        } else if hasBridgeCategory {
            guidelines.append("Permission levels apply to both function-call tools and any installed skills that wrap the corresponding system bridges. Setting a category to Read Only blocks its write actions whether they are reached via a tool or a skill custom tool — do not try to route around a restriction.")
        }
        parts.append("### Important Guidelines\n" + guidelines.map { "- \($0)" }.joined(separator: "\n"))

        return parts.joined(separator: "\n\n")
    }

    private func codeExecutionSection(for agent: Agent) -> String {
        var section = """
        ### Code Execution
        - `execute_javascript`: Execute JavaScript in a sandboxed WKWebView runtime with two modes:
          - `repl` mode: Evaluate an expression and return its JSON-serialized result
          - `script` mode: Run a script and capture console output
          - Full ES6+ syntax: arrow functions, destructuring, template literals, classes, Promises, Map/Set, Symbol, generators, spread/rest, for...of, and more
          - Built-in: `JSON`, `Math`, `Date`, `RegExp`, `Map`, `Set`, `Array` methods, `String` methods — all native JavaScript APIs
          - Console: `console.log()`, `console.warn()`, `console.error()`, `console.table()`, `console.dir()` — output is captured
          - Network: `fetch(url, options)` — synchronous bridge returning `{ok, status, text, json()}`. Supports GET/POST/PUT/DELETE with headers and body
          - Polyfills: `TextEncoder`/`TextDecoder`, `atob`/`btoa`, `setTimeout` (executes immediately)
          - Timeout: default 60s, pass `timeout` parameter (1-300s) per call, or set persistent default via `write_config` with key `javascript_timeout`
        """

        if isEnabled(.files, for: agent) {
            section += """

              - File system (Node-aligned `fs.*`, all Promise-returning; persistent agent storage):
                - Whole-file: `fs.list`, `fs.readFile(path, {mode})`, `fs.writeFile(path, content, {encoding})`, `fs.appendFile`, `fs.delete`/`fs.unlink`, `fs.stat(path)`, `fs.exists(path)`, `fs.mkdir(path)`, `fs.cp(src, dest, {recursive})`, `fs.mv(src, dest)`/`fs.rename`, `fs.truncate(pathOrFd, len)`
                - POSIX fd: `fs.open(path, flags)` → fd, `fs.close(fd)`, `fs.read(fd, length, position?)`, `fs.write(fd, content, position?, encoding?)`, `fs.seek(fd, offset, whence)`, `fs.tell(fd)`, `fs.fstat(fd)`, `fs.fsync(fd)`
                - Open flags: 'r','r+','w','w+','a','a+'. Seek whence: 'start','current','end'. fd's auto-close when this execution ends.
                - Legacy: `fs.read(path)` / `fs.write(path, content)` still accepted (arg-type dispatch delegates to readFile/writeFile).
            """
        }

        let enabledApple = ToolCategory.appleCategories.filter { isEnabled($0, for: agent) }
        if !enabledApple.isEmpty {
            let namespaces = enabledApple.map { "apple.\($0.rawValue).*" }.joined(separator: ", ")
            section += """

              - Apple ecosystem: \(namespaces) — all return Promises, use `await` in script mode (e.g. `let events = await apple.calendar.searchEvents({})`)
            """
        }

        section += """

          - Inter-snippet calling (from inside any running JS snippet):
            - `await snippets.invoke(name, args?, opts?)` — call another saved snippet and get its return value.
              The callee body is wrapped in an async IIFE, so it may use a top-level `return value;` to return a result.
              `args` becomes the callee's `args` object; `opts.stdin` (string) becomes the callee's `stdin` global.
              By default the callee's stdout/stderr are appended to the caller's output; pass `opts.capture = true` to
              receive a structured `{result, stdout, stderr}` instead (useful for piping).
            - `await snippets.pipe([name1, name2, ...], args?)` — run snippets in sequence, feeding stage N's stdout
              as stage N+1's stdin. Returns the final stage's `{result, stdout, stderr}`.
            - `await snippets.list()` — returns `[{name, language}, ...]` for all callable snippets (including `skill:*:*`).
            - Recursion (self or mutual) is allowed; enforced limits are depth ≤ 16 and a shared wall-clock budget inherited from the root call's JS timeout.
          - Ideal for: JSON manipulation, string processing, DOM-less web API prototyping, algorithm implementation, data transformation
        - `save_code`: Save a code snippet for later reuse
        - `load_code`: Load a previously saved code snippet
        - `list_code`: List all saved code snippets
        - `run_snippet`: Execute a saved code snippet by name — loads and runs it directly without needing to `load_code` + `execute_javascript` separately. Supports optional `mode` and `timeout` overrides.
        - `delete_code`: Delete a saved code snippet by name
        """

        return section
    }

    private func buildSoulSection(_ soul: String) -> String {
        """
        ## Soul (Identity & Personality)

        \(soul)
        """
    }

    private func buildMemorySection(_ memory: String) -> String {
        """
        ## Memory (Persistent Knowledge)

        \(memory)
        """
    }

    private func buildUserSection(_ user: String) -> String {
        """
        ## User Profile

        \(user)
        """
    }

    private func buildSubAgentHints() -> String {
        """
        ## Sub-Agent Notice

        You are operating as a sub-agent. Your SOUL configuration has been inherited from your parent agent.

        - You can read your parent's MEMORY.md using `read_config` with key "MEMORY.md" for additional context.
        - Focus on the specific task assigned to you.
        - Return clear, structured results to your parent agent.
        """
    }

    private func buildInstalledSkillsSection(
        _ activeSkills: [InstalledSkill],
        activatedSlugs: Set<String>?
    ) -> String {
        // Progressive disclosure applies only when (a) the global setting is
        // on AND (b) the caller threaded a non-nil activated set. Cron and
        // sub-agent flows pass nil to keep the legacy "render every body
        // every turn" behavior — they have no chat session to derive an
        // activation set from.
        let useProgressive = Self.progressiveDisclosureEnabled && activatedSlugs != nil
        let activated = activatedSlugs ?? []

        var dormant: [InstalledSkill] = []
        var expanded: [InstalledSkill] = []
        for installation in activeSkills {
            guard let skill = installation.skill else { continue }
            let slug = SkillPackage.derivedSlug(forName: skill.name)
            if useProgressive && !activated.contains(slug) {
                dormant.append(installation)
            } else {
                expanded.append(installation)
            }
        }

        var parts: [String] = []

        if !dormant.isEmpty {
            var section = """
            ## Installed Skills (dormant)

            Each skill below ships methodology that is not yet loaded into your context. Activate one (so its full body joins the prompt) by typing `/<slug>` from the user, calling one of its `skill_<slug>_*` custom tools, or running its scripts via `run_snippet skill:<name>:*`. Each skill's `skill_<slug>_*` tool definitions remain callable even while dormant — only the prose body is hidden.
            """
            for installation in dormant {
                guard let skill = installation.skill else { continue }
                let slug = SkillPackage.derivedSlug(forName: skill.name)
                section += "\n\n- **\(skill.effectiveDisplayName)** (`/\(slug)`) — \(skill.summary)"
            }
            parts.append(section)
        }

        if !expanded.isEmpty {
            let header: String
            if dormant.isEmpty {
                header = "## Installed Skills\n\nThe following skills are active and provide specialized instructions:"
            } else {
                header = "## Active Skills\n\nThe following installed skills have been activated for this session — follow their methodology:"
            }
            var section = header
            for installation in expanded {
                guard let skill = installation.skill else { continue }
                section += "\n\n### Skill: \(skill.effectiveDisplayName)\n\(skill.content)"

                // List available scripts. The snippet ID embedded in backticks
                // must stay in sync with the CodeSnippet name registered in
                // `SkillService.installSkill` — which uses the English `name` —
                // so `run_snippet` can resolve it. Do NOT swap in `effectiveDisplayName`.
                if !skill.scripts.isEmpty {
                    section += "\n\n**Available scripts** (use `run_snippet` to execute):"
                    for script in skill.scripts {
                        let desc = script.description ?? script.name
                        section += "\n- `skill:\(skill.name):\(script.name)` — \(desc)"
                    }
                }
                if !skill.customTools.isEmpty {
                    section += "\n\n**Custom tools** provided by this skill:"
                    for tool in skill.customTools {
                        let toolName = Self.skillToolName(skillName: skill.name, toolName: tool.name)
                        let params = tool.parameters.map { "\($0.name): \($0.type)" }.joined(separator: ", ")
                        section += "\n- `\(toolName)(\(params))` — \(tool.description)"
                    }
                }
            }
            parts.append(section)
        }

        return parts.joined(separator: "\n\n")
    }

    /// Generate the canonical tool name for a skill custom tool.
    static func skillToolName(skillName: String, toolName: String) -> String {
        let sanitized = skillName.lowercased().replacingOccurrences(of: " ", with: "_")
        return "skill_\(sanitized)_\(toolName)"
    }

    private func buildRelatedSessionsSection(_ sessions: [(id: UUID, title: String, updatedAt: Date)]) -> String {
        let dateFormatter = DateFormatter()
        dateFormatter.dateStyle = .medium
        dateFormatter.timeStyle = .short

        var lines: [String] = [
            "## Related Sessions",
            "",
            "The following past sessions may contain relevant context. Use `recall_session` with the session ID to retrieve details.",
            ""
        ]

        for session in sessions {
            lines.append("- **\(session.title)** — `\(session.id.uuidString)` (updated \(dateFormatter.string(from: session.updatedAt)))")
        }

        return lines.joined(separator: "\n")
    }

    private func buildCustomConfigsIndex(_ agent: Agent) -> String {
        let keys = agent.customConfigs.map { "- `\($0.key)`" }.joined(separator: "\n")
        return """
        ## Additional Configs Available

        You have the following custom configuration files. Use `read_config` to access them:

        \(keys)
        """
    }
}
