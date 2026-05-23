import Foundation

/// Permission level for a tool category on a specific agent.
enum ToolPermissionLevel: String, Codable, CaseIterable {
    case readWrite = "rw"
    case readOnly = "r"
    case writeOnly = "w"
    case disabled = "-"

    var allowsRead: Bool { self == .readWrite || self == .readOnly }
    var allowsWrite: Bool { self == .readWrite || self == .writeOnly }

    var displayLabel: String {
        switch self {
        case .readWrite: return L10n.ApplePermissions.readWrite
        case .readOnly:  return L10n.ApplePermissions.readOnly
        case .writeOnly: return L10n.ApplePermissions.writeOnly
        case .disabled:  return L10n.ApplePermissions.disabled
        }
    }

    var iconName: String {
        switch self {
        case .readWrite: return "checkmark.circle.fill"
        case .readOnly:  return "eye.fill"
        case .writeOnly: return "pencil.circle.fill"
        case .disabled:  return "xmark.circle"
        }
    }

    var iconColor: String {
        switch self {
        case .readWrite: return "green"
        case .readOnly:  return "blue"
        case .writeOnly: return "orange"
        case .disabled:  return "gray"
        }
    }
}

/// Defines a tool permission category with associated read & write tool names.
enum ToolCategory: String, CaseIterable, Identifiable {
    // Apple Ecosystem
    case calendar
    case reminders
    case contacts
    case clipboard
    case notifications
    case location
    case map
    case health

    // Agent Capabilities
    case browser
    case codeExecution
    case subAgents
    case sessions
    case cron
    case skills
    case config
    case model
    case files
    case imageGeneration
    case videoGeneration

    var id: String { rawValue }

    var isAppleCategory: Bool {
        Self.appleCategories.contains(self)
    }

    var displayName: String {
        switch self {
        case .calendar:      return L10n.ApplePermissions.calendar
        case .reminders:     return L10n.ApplePermissions.reminders
        case .contacts:      return L10n.ApplePermissions.contacts
        case .clipboard:     return L10n.ApplePermissions.clipboard
        case .notifications: return L10n.ApplePermissions.notifications
        case .location:      return L10n.ApplePermissions.location
        case .map:           return L10n.ApplePermissions.map
        case .health:        return L10n.ApplePermissions.health
        case .browser:       return L10n.ToolPermissions.browser
        case .codeExecution: return L10n.ToolPermissions.codeExecution
        case .subAgents:     return L10n.ToolPermissions.subAgents
        case .sessions:      return L10n.ToolPermissions.sessions
        case .cron:          return L10n.ToolPermissions.cron
        case .skills:        return L10n.ToolPermissions.skills
        case .config:        return L10n.ToolPermissions.config
        case .model:         return L10n.ToolPermissions.model
        case .files:         return L10n.ToolPermissions.files
        case .imageGeneration: return L10n.ToolPermissions.imageGeneration
        case .videoGeneration: return L10n.ToolPermissions.videoGeneration
        }
    }

    var systemImage: String {
        switch self {
        case .calendar:      return "calendar"
        case .reminders:     return "checklist"
        case .contacts:      return "person.crop.circle"
        case .clipboard:     return "doc.on.clipboard"
        case .notifications: return "bell"
        case .location:      return "location"
        case .map:           return "map"
        case .health:        return "heart.text.square"
        case .browser:       return "safari"
        case .codeExecution: return "curlybraces"
        case .subAgents:     return "person.2.fill"
        case .sessions:      return "text.bubble.fill"
        case .cron:          return "clock.arrow.circlepath"
        case .skills:        return "book.pages"
        case .config:        return "slider.horizontal.3"
        case .model:         return "cpu"
        case .files:         return "folder"
        case .imageGeneration: return "paintbrush.pointed"
        case .videoGeneration: return "film"
        }
    }

    var hasWriteTools: Bool { !writeToolNames.isEmpty }

    var readToolNames: [String] {
        switch self {
        case .calendar:
            return ["calendar_list_calendars", "calendar_search_events"]
        case .reminders:
            return ["reminder_list", "reminder_lists"]
        case .contacts:
            return ["contacts_search", "contacts_get_detail"]
        case .clipboard:
            return ["clipboard_read"]
        case .notifications:
            return ["notification_list"]
        case .location:
            return ["location_get_current", "location_geocode", "location_reverse_geocode"]
        case .map:
            return ["map_search_places", "map_get_directions"]
        case .health:
            // Long-tail reads (blood pressure/glucose/oxygen, body temperature) live in the
            // "Health Plus" built-in skill; bridgeReadActions still includes them so the
            // skill's JS wrappers route through the `health` permission gate.
            return [
                "health_read_steps", "health_read_heart_rate", "health_read_sleep",
                "health_read_body_mass",
            ]
        case .browser:
            return ["browser_get_page_info", "browser_extract"]
        case .codeExecution:
            return ["list_code", "load_code"]
        case .subAgents:
            return ["list_sub_agents", "collect_sub_agent_output"]
        case .sessions:
            return ["search_sessions", "recall_session"]
        case .cron:
            return ["list_cron"]
        case .skills:
            return ["list_skills", "validate_skill"]
        case .config:
            return ["read_config"]
        case .model:
            return ["get_model", "list_models"]
        case .files:
            return ["file_list", "file_read", "file_info", "attach_media"]
        case .imageGeneration:
            return []
        case .videoGeneration:
            return []
        }
    }

    var writeToolNames: [String] {
        switch self {
        case .calendar:
            return ["calendar_create_event", "calendar_update_event", "calendar_delete_event"]
        case .reminders:
            return ["reminder_create", "reminder_complete", "reminder_delete"]
        case .contacts:
            return []
        case .clipboard:
            return ["clipboard_write"]
        case .notifications:
            return ["notification_schedule", "notification_cancel"]
        case .location:
            return []
        case .map:
            return []
        case .health:
            // Long-tail writes (macronutrients, blood pressure/glucose/oxygen, body
            // fat/height/temperature, heart-rate writes, workouts) live in the "Health Plus"
            // built-in skill; bridgeWriteActions still includes them so the skill's JS
            // wrappers route through the `health` permission gate.
            return [
                "health_write_dietary_energy", "health_write_body_mass", "health_write_dietary_water",
            ]
        case .browser:
            return [
                "browser_navigate", "browser_click", "browser_input", "browser_select",
                "browser_execute_js", "browser_wait", "browser_scroll",
            ]
        case .codeExecution:
            return ["execute_javascript", "save_code", "run_snippet", "delete_code"]
        case .subAgents:
            return ["create_sub_agent", "message_sub_agent", "stop_sub_agent", "delete_sub_agent"]
        case .sessions:
            return []
        case .cron:
            return ["schedule_cron", "unschedule_cron"]
        case .skills:
            // Authoring (create/edit/delete) is via fs.* on the /skills/<slug>/
            // mount — no dedicated LLM tools. Only the binding ops remain.
            return ["install_skill", "uninstall_skill"]
        case .config:
            return ["write_config"]
        case .model:
            return ["set_model"]
        case .files:
            return ["file_write", "file_delete"]
        case .imageGeneration:
            return ["generate_image"]
        case .videoGeneration:
            return ["generate_video"]
        }
    }

    var allToolNames: [String] { readToolNames + writeToolNames }

    var availableLevels: [ToolPermissionLevel] {
        if writeToolNames.isEmpty {
            return [.readWrite, .disabled]
        }
        return ToolPermissionLevel.allCases
    }

    // MARK: - Bridge action names (used by JS apple.* API)

    var bridgeReadActions: [String] {
        switch self {
        case .calendar:      return ["calendar.listCalendars", "calendar.searchEvents"]
        case .reminders:     return ["reminders.list", "reminders.lists"]
        case .contacts:      return ["contacts.search", "contacts.getDetail"]
        case .clipboard:     return ["clipboard.read"]
        case .notifications: return ["notifications.list"]
        case .location:      return ["location.getCurrent", "location.geocode", "location.reverseGeocode"]
        case .map:           return ["maps.searchPlaces", "maps.getDirections"]
        case .health:
            return [
                "health.readSteps", "health.readHeartRate", "health.readSleep",
                "health.readBodyMass", "health.readBloodPressure", "health.readBloodGlucose",
                "health.readBloodOxygen", "health.readBodyTemperature",
            ]
        case .files:
            return [
                "files.list", "files.read", "files.readFile", "files.info", "files.stat",
                "files.exists", "files.close", "files.seek", "files.tell", "files.fstat",
            ]
        case .browser, .codeExecution, .subAgents, .sessions, .cron, .skills, .config, .model, .imageGeneration, .videoGeneration:
            return []
        }
    }

    var bridgeWriteActions: [String] {
        switch self {
        case .calendar:      return ["calendar.createEvent", "calendar.updateEvent", "calendar.deleteEvent"]
        case .reminders:     return ["reminders.create", "reminders.complete", "reminders.delete"]
        case .contacts:      return []
        case .clipboard:     return ["clipboard.write"]
        case .notifications: return ["notifications.schedule", "notifications.cancel"]
        case .location:      return []
        case .map:           return []
        case .health:
            return [
                "health.writeDietaryEnergy", "health.writeBodyMass", "health.writeDietaryWater",
                "health.writeDietaryCarbohydrates", "health.writeDietaryProtein",
                "health.writeDietaryFat", "health.writeBloodPressure", "health.writeBodyFat",
                "health.writeHeight", "health.writeBloodGlucose", "health.writeBloodOxygen",
                "health.writeBodyTemperature", "health.writeHeartRate", "health.writeWorkout",
            ]
        case .files:
            return [
                "files.write", "files.writeFile", "files.appendFile", "files.delete",
                "files.mkdir", "files.cp", "files.mv", "files.truncate",
                "files.open", "files.fsync",
            ]
        case .browser, .codeExecution, .subAgents, .sessions, .cron, .skills, .config, .model, .imageGeneration, .videoGeneration:
            return []
        }
    }

    var allBridgeActions: [String] { bridgeReadActions + bridgeWriteActions }

    // MARK: - Static helpers

    static let appleCategories: [ToolCategory] = [
        .calendar, .reminders, .contacts, .clipboard, .notifications,
        .location, .map, .health,
    ]

    static let agentCategories: [ToolCategory] = [
        .browser, .codeExecution, .subAgents, .sessions, .cron, .skills, .config, .model, .files, .imageGeneration, .videoGeneration,
    ]

    /// Every function-call tool name across all categories.
    static let allRegisteredToolNames: Set<String> = {
        var names = Set<String>()
        for cat in ToolCategory.allCases {
            names.formUnion(cat.allToolNames)
        }
        return names
    }()

    /// Apple tool names only (backward compat).
    static let allAppleToolNames: Set<String> = {
        var names = Set<String>()
        for cat in appleCategories {
            names.formUnion(cat.allToolNames)
        }
        return names
    }()

    static func category(for toolName: String) -> ToolCategory? {
        for cat in ToolCategory.allCases {
            if cat.allToolNames.contains(toolName) { return cat }
        }
        return nil
    }

    static func isWriteTool(_ toolName: String) -> Bool {
        for cat in ToolCategory.allCases {
            if cat.writeToolNames.contains(toolName) { return true }
        }
        return false
    }

    static let allBridgeActionNames: Set<String> = {
        var names = Set<String>()
        for cat in ToolCategory.allCases {
            names.formUnion(cat.allBridgeActions)
        }
        return names
    }()

    static func category(forBridgeAction action: String) -> ToolCategory? {
        for cat in ToolCategory.allCases {
            if cat.allBridgeActions.contains(action) { return cat }
        }
        return nil
    }

    static func isBridgeWriteAction(_ action: String) -> Bool {
        for cat in ToolCategory.allCases {
            if cat.bridgeWriteActions.contains(action) { return true }
        }
        return false
    }

    static func blockedBridgeActions(for agent: Agent) -> Set<String> {
        var blocked = Set<String>()
        for cat in ToolCategory.allCases {
            let level = agent.permissionLevel(for: cat)
            if !level.allowsRead {
                blocked.formUnion(cat.bridgeReadActions)
            }
            if !level.allowsWrite {
                blocked.formUnion(cat.bridgeWriteActions)
            }
        }
        return blocked
    }
}
