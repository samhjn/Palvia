import Foundation

// swiftlint:disable type_body_length file_length

/// Centralized localization keys. All user-facing strings should be referenced
/// through this enum to guarantee compile-time safety and a single source of truth.
enum L10n {

    private static func tr(_ key: String) -> String {
        NSLocalizedString(key, comment: "")
    }

    private static func tr(_ key: String, _ args: CVarArg...) -> String {
        String(format: NSLocalizedString(key, comment: ""), arguments: args)
    }

    // MARK: - Migration

    enum Migration {
        static var alertTitle: String { tr("migration.alertTitle") }
        static var alertMessage: String { tr("migration.alertMessage") }
        static var resetAndRestart: String { tr("migration.resetAndRestart") }
        static var exitApp: String { tr("migration.exitApp") }
    }

    // MARK: - Launch Tasks

    enum Launch {
        static var cleaningUp: String { tr("launch.cleaningUp") }
        static var buildingIndex: String { tr("launch.buildingIndex") }
    }

    // MARK: - Tabs

    enum Tabs {
        static var sessions: String { tr("tabs.sessions") }
        static var agents: String { tr("tabs.agents") }
        static var browser: String { tr("tabs.browser") }
        static var skills: String { tr("tabs.skills") }
        static var settings: String { tr("tabs.settings") }
    }

    // MARK: - Common

    enum Common {
        static var save: String { tr("common.save") }
        static var cancel: String { tr("common.cancel") }
        static var delete: String { tr("common.delete") }
        static var create: String { tr("common.create") }
        static var edit: String { tr("common.edit") }
        static var add: String { tr("common.add") }
        static var done: String { tr("common.done") }
        static var copy: String { tr("common.copy") }
        static var copied: String { tr("common.copied") }
        static var dismiss: String { tr("common.dismiss") }
        static var enable: String { tr("common.enable") }
        static var disable: String { tr("common.disable") }
        static var defaultLabel: String { tr("common.default") }
        static var active: String { tr("common.active") }
        static var preview: String { tr("common.preview") }
        static var empty: String { tr("common.empty") }
        static var refresh: String { tr("common.refresh") }
        static var name: String { tr("common.name") }
        static var unknown: String { tr("common.unknown") }
        static var confirm: String { tr("common.confirm") }
        static var `import`: String { tr("common.import") }
    }

    // MARK: - Chat

    enum Chat {
        static var messagePlaceholder: String { tr("chat.messagePlaceholder") }
        static var cancelling: String { tr("chat.cancelling") }
        static func skillActivated(_ name: String) -> String {
            tr("chat.skillActivated", name)
        }
        static var thinking: String { tr("chat.thinking") }
        static var compressingContext: String { tr("chat.compressingContext") }
        static var renameSession: String { tr("chat.renameSession") }
        static var rename: String { tr("chat.rename") }
        static var compressContext: String { tr("chat.compressContext") }
        static var title: String { tr("chat.title") }
        static var openLink: String { tr("chat.openLink") }
        static var share: String { tr("chat.share") }
        static var loadingImage: String { tr("chat.loadingImage") }
        static var imageLoadFailed: String { tr("chat.imageLoadFailed") }
        static var newChat: String { tr("chat.newChat") }
        static var aborted: String { tr("chat.aborted") }
        static var toolCallAborted: String { tr("chat.toolCallAborted") }
        static var noAgent: String { tr("chat.noAgent") }
        static var noCompressModel: String { tr("chat.noCompressModel") }
        static func sessionBlocked(_ title: String) -> String { tr("chat.sessionBlocked", title) }
        static func compressionInfo(active: String, threshold: String, total: Int, compressed: Int) -> String {
            tr("chat.compressionInfo", active, threshold, total, compressed)
        }
        static func tokenUsage(active: String, threshold: String) -> String {
            tr("chat.tokenUsage", active, threshold)
        }
        static func messageStats(total: Int, compressed: Int) -> String {
            tr("chat.messageStats", total, compressed)
        }
        static func pendingCompression(_ count: Int) -> String {
            tr("chat.pendingCompression", count)
        }
        static func compressedBadge(_ count: Int) -> String {
            tr("chat.compressedBadge", count)
        }
        static var cancelStuckReason: String { tr("chat.cancelStuckReason") }
        static var forceStoppedContent: String { tr("chat.forceStoppedContent") }
        static var deleteSessionTitle: String { tr("chat.deleteSessionTitle") }
        static var deleteSessionMessage: String { tr("chat.deleteSessionMessage") }
        static var deleteAgentTitle: String { tr("chat.deleteAgentTitle") }
        static func deleteAgentMessage(_ name: String) -> String { tr("chat.deleteAgentMessage", name) }
        static var thinkingProcess: String { tr("chat.thinkingProcess") }
        static var addMedia: String { tr("chat.addMedia") }
        static var photosAndVideos: String { tr("chat.photosAndVideos") }
        static var camera: String { tr("chat.camera") }
        static var pasteFromClipboard: String { tr("chat.pasteFromClipboard") }
        static var chooseFile: String { tr("chat.chooseFile") }
        static var imagePlaceholder: String { tr("chat.imagePlaceholder") }
        static var saveImageToPhotos: String { tr("chat.saveImageToPhotos") }
        static var imageSaved: String { tr("chat.imageSaved") }
        static var copyImage: String { tr("chat.copyImage") }
        static var imageDeleted: String { tr("chat.imageDeleted") }
        static var videoDeleted: String { tr("chat.videoDeleted") }
        static func modalityStripped(_ count: Int, _ model: String) -> String { tr("chat.modalityStripped", count, model) }
        static func toolUseUnsupported(_ model: String) -> String { tr("chat.toolUseUnsupported", model) }
        static var exportSession: String { tr("chat.exportSession") }
        static var retry: String { tr("chat.retry") }
        static var retryHint: String { tr("chat.retryHint") }
        static var verbose: String { tr("chat.verbose") }
        static var silent: String { tr("chat.silent") }
        static var switchToSilent: String { tr("chat.switchToSilent") }
        static var switchToVerbose: String { tr("chat.switchToVerbose") }
        static func silentThinking(_ turn: Int) -> String { tr("chat.silentThinking", turn) }
        static func silentRunningTool(_ name: String) -> String { tr("chat.silentRunningTool", name) }
        static func displayModeScope(_ agentName: String) -> String { tr("chat.displayModeScope", agentName) }
        static var doubleTapToExpand: String { tr("chat.doubleTapToExpand") }
        static var cellDetail: String { tr("chat.cellDetail") }
        // Video generation progress
        static var videoSubmitting: String { tr("chat.videoSubmitting") }
        static var videoSubmitted: String { tr("chat.videoSubmitted") }
        static func videoGenerating(_ seconds: Int) -> String { tr("chat.videoGenerating", seconds) }
        static var videoDownloading: String { tr("chat.videoDownloading") }
        static var videoCompleted: String { tr("chat.videoCompleted") }
        static func videoFailed(_ reason: String) -> String { tr("chat.videoFailed", reason) }
    }

    // MARK: - Token Analytics

    enum TokenStats {
        static var menuLabel: String { tr("tokenStats.menuLabel") }
        static var title: String { tr("tokenStats.title") }
        static var sectionBilled: String { tr("tokenStats.sectionBilled") }
        static var sectionComposition: String { tr("tokenStats.sectionComposition") }
        static var sectionContext: String { tr("tokenStats.sectionContext") }
        static var input: String { tr("tokenStats.input") }
        static var output: String { tr("tokenStats.output") }
        static var total: String { tr("tokenStats.total") }
        static var cacheRead: String { tr("tokenStats.cacheRead") }
        static var cacheWrite: String { tr("tokenStats.cacheWrite") }
        static var cacheHitRate: String { tr("tokenStats.cacheHitRate") }
        static var avgOutputPerTurn: String { tr("tokenStats.avgOutputPerTurn") }
        static func turnsWithUsage(_ count: Int) -> String { tr("tokenStats.turnsWithUsage", count) }
        static var roleSystem: String { tr("tokenStats.roleSystem") }
        static var roleUser: String { tr("tokenStats.roleUser") }
        static var roleAssistant: String { tr("tokenStats.roleAssistant") }
        static var roleTool: String { tr("tokenStats.roleTool") }
        static var estimatedTotal: String { tr("tokenStats.estimatedTotal") }
        static var activeContext: String { tr("tokenStats.activeContext") }
        static func messages(_ count: Int) -> String { tr("tokenStats.messages", count) }
        static var billedNote: String { tr("tokenStats.billedNote") }
        static var estimatedNote: String { tr("tokenStats.estimatedNote") }
        static var noUsage: String { tr("tokenStats.noUsage") }
    }

    // MARK: - Agents

    enum Agents {
        static var title: String { tr("agents.title") }
        static var newAgent: String { tr("agents.newAgent") }
        static var agentName: String { tr("agents.agentName") }
        static var createAgent: String { tr("agents.createAgent") }
        static var noAgents: String { tr("agents.noAgents") }
        static var createAgentDescription: String { tr("agents.createAgentDescription") }
        static var enterName: String { tr("agents.enterName") }
        static var renameAgent: String { tr("agents.renameAgent") }
    }

    // MARK: - Agent Detail

    // MARK: - Agent Files

    enum AgentFiles {
        static var title: String { tr("agentFiles.title") }
        static var empty: String { tr("agentFiles.empty") }
        static var emptyDescription: String { tr("agentFiles.emptyDescription") }
        static var deleteConfirmTitle: String { tr("agentFiles.deleteConfirmTitle") }
        static func deleteConfirmMessage(_ name: String) -> String { tr("agentFiles.deleteConfirmMessage", name) }
        static var imagePermissionDisabled: String { tr("agentFiles.imagePermissionDisabled") }
        static var newFolder: String { tr("agentFiles.newFolder") }
        static var folderName: String { tr("agentFiles.folderName") }
        static var invalidFolderName: String { tr("agentFiles.invalidFolderName") }
    }

    // MARK: - Agent Detail

    enum AgentDetail {
        static var config: String { tr("agentDetail.config") }
        static var modelConfig: String { tr("agentDetail.modelConfig") }
        static var skills: String { tr("agentDetail.skills") }
        static var cronJobs: String { tr("agentDetail.cronJobs") }
        static var customConfigs: String { tr("agentDetail.customConfigs") }
        static var subAgents: String { tr("agentDetail.subAgents") }
        static var codeSnippets: String { tr("agentDetail.codeSnippets") }
        static var newConfig: String { tr("agentDetail.newConfig") }
        static var keyPlaceholder: String { tr("agentDetail.keyPlaceholder") }
        static var noSubAgents: String { tr("agentDetail.noSubAgents") }
        static var subAgentsDescription: String { tr("agentDetail.subAgentsDescription") }
        static func sessionsCount(_ count: Int) -> String { tr("agentDetail.sessionsCount", count) }
        static func msgsCount(_ count: Int) -> String { tr("agentDetail.msgsCount", count) }
        static func subAgentsTitle(_ count: Int) -> String { tr("agentDetail.subAgentsTitle", count) }
        static var noCodeSnippets: String { tr("agentDetail.noCodeSnippets") }
        static var codeSnippetsDescription: String { tr("agentDetail.codeSnippetsDescription") }
        static var snippetInfo: String { tr("agentDetail.snippetInfo") }
        static var snippetName: String { tr("agentDetail.snippetName") }
        static var snippetLanguage: String { tr("agentDetail.snippetLanguage") }
        static var snippetCode: String { tr("agentDetail.snippetCode") }
        static var newSnippet: String { tr("agentDetail.newSnippet") }
        static var applePermissions: String { tr("agentDetail.applePermissions") }
        static var toolPermissions: String { tr("agentDetail.toolPermissions") }
    }

    // MARK: - Apple Permissions

    enum ApplePermissions {
        static var title: String { tr("applePermissions.title") }
        static var description: String { tr("applePermissions.description") }
        static var readWrite: String { tr("applePermissions.readWrite") }
        static var readOnly: String { tr("applePermissions.readOnly") }
        static var writeOnly: String { tr("applePermissions.writeOnly") }
        static var disabled: String { tr("applePermissions.disabled") }
        static var enableAll: String { tr("applePermissions.enableAll") }
        static var readOnlyAll: String { tr("applePermissions.readOnlyAll") }
        static var disableAll: String { tr("applePermissions.disableAll") }
        static var calendar: String { tr("applePermissions.calendar") }
        static var reminders: String { tr("applePermissions.reminders") }
        static var contacts: String { tr("applePermissions.contacts") }
        static var clipboard: String { tr("applePermissions.clipboard") }
        static var notifications: String { tr("applePermissions.notifications") }
        static var location: String { tr("applePermissions.location") }
        static var map: String { tr("applePermissions.map") }
        static var health: String { tr("applePermissions.health") }
        static func summaryReadWrite(_ count: Int) -> String { tr("applePermissions.summaryReadWrite", count) }
        static func summaryReadOnly(_ count: Int) -> String { tr("applePermissions.summaryReadOnly", count) }
        static func summaryWriteOnly(_ count: Int) -> String { tr("applePermissions.summaryWriteOnly", count) }
        static var summaryDisabled: String { tr("applePermissions.summaryDisabled") }
    }

    // MARK: - Tool Permissions

    enum ToolPermissions {
        static var title: String { tr("toolPermissions.title") }
        static var description: String { tr("toolPermissions.description") }
        static var browser: String { tr("toolPermissions.browser") }
        static var codeExecution: String { tr("toolPermissions.codeExecution") }
        static var subAgents: String { tr("toolPermissions.subAgents") }
        static var sessions: String { tr("toolPermissions.sessions") }
        static var cron: String { tr("toolPermissions.cron") }
        static var skills: String { tr("toolPermissions.skills") }
        static var config: String { tr("toolPermissions.config") }
        static var model: String { tr("toolPermissions.model") }
        static var files: String { tr("toolPermissions.files") }
        static var imageGeneration: String { tr("toolPermissions.imageGeneration") }
        static var videoGeneration: String { tr("toolPermissions.videoGeneration") }
        static var appleSection: String { tr("toolPermissions.appleSection") }
        static var agentSection: String { tr("toolPermissions.agentSection") }
    }

    // MARK: - Permission Errors

    enum PermissionError {
        static var calendarDenied: String { tr("permError.calendarDenied") }
        static var calendarDeniedByUser: String { tr("permError.calendarDeniedByUser") }
        static var calendarWriteOnly: String { tr("permError.calendarWriteOnly") }
        static var calendarUnknown: String { tr("permError.calendarUnknown") }
        static var remindersDenied: String { tr("permError.remindersDenied") }
        static var remindersDeniedByUser: String { tr("permError.remindersDeniedByUser") }
        static var remindersUnknown: String { tr("permError.remindersUnknown") }
        static var contactsDenied: String { tr("permError.contactsDenied") }
        static var contactsDeniedByUser: String { tr("permError.contactsDeniedByUser") }
        static var contactsUnknown: String { tr("permError.contactsUnknown") }
        static var notificationDenied: String { tr("permError.notificationDenied") }
        static var notificationDeniedByUser: String { tr("permError.notificationDeniedByUser") }
        static var notificationUnknown: String { tr("permError.notificationUnknown") }
        static var locationDenied: String { tr("permError.locationDenied") }
        static var locationDeniedByUser: String { tr("permError.locationDeniedByUser") }
        static var locationUnknown: String { tr("permError.locationUnknown") }
        static var healthUnavailable: String { tr("permError.healthUnavailable") }
        static func healthFailed(_ error: String) -> String { tr("permError.healthFailed", error) }
        static func toolNotPermitted(_ toolName: String, _ categoryName: String) -> String { tr("permError.toolNotPermitted", toolName, categoryName) }
    }

    // MARK: - Model Config

    enum ModelConfig {
        static var title: String { tr("modelConfig.title") }
        static var globalDefault: String { tr("modelConfig.globalDefault") }
        static var primaryModel: String { tr("modelConfig.primaryModel") }
        static var primaryModelFooter: String { tr("modelConfig.primaryModelFooter") }
        static var noFallback: String { tr("modelConfig.noFallback") }
        static var addFallback: String { tr("modelConfig.addFallback") }
        static var fallbackChain: String { tr("modelConfig.fallbackChain") }
        static var fallbackFooter: String { tr("modelConfig.fallbackFooter") }
        static var inheritFromPrimary: String { tr("modelConfig.inheritFromPrimary") }
        static var subAgentModel: String { tr("modelConfig.subAgentModel") }
        static var subAgentDefault: String { tr("modelConfig.subAgentDefault") }
        static var subAgentFooter: String { tr("modelConfig.subAgentFooter") }
        static var compressionThreshold: String { tr("modelConfig.compressionThreshold") }
        static func defaultThreshold(_ value: Int) -> String { tr("modelConfig.defaultThreshold", value) }
        static var systemDefault: String { tr("modelConfig.systemDefault") }
        static var resetDefault: String { tr("modelConfig.resetDefault") }
        static var contextCompression: String { tr("modelConfig.contextCompression") }
        static var compressionFooter: String { tr("modelConfig.compressionFooter") }
        static func noToolUse(_ model: String) -> String { tr("modelConfig.noToolUse", model) }
        static var noModels: String { tr("modelConfig.noModels") }
        static var override: String { tr("modelConfig.override") }
        static var primary: String { tr("modelConfig.primary") }
        static var fallback: String { tr("modelConfig.fallback") }
        static var subAgent: String { tr("modelConfig.subAgent") }
        static var resolutionOrder: String { tr("modelConfig.resolutionOrder") }
        static var resolutionFooter: String { tr("modelConfig.resolutionFooter") }
        static var modelWhitelist: String { tr("modelConfig.modelWhitelist") }
        static var whitelistAllModels: String { tr("modelConfig.whitelistAllModels") }
        static var addToWhitelist: String { tr("modelConfig.addToWhitelist") }
        static var clearWhitelist: String { tr("modelConfig.clearWhitelist") }
        static var whitelistFooter: String { tr("modelConfig.whitelistFooter") }
        static func whitelistStaleWarning(_ count: Int) -> String { tr("modelConfig.whitelistStaleWarning", count) }
        static var whitelistMissingPrimary: String { tr("modelConfig.whitelistMissingPrimary") }
        static var whitelistMissingSubAgent: String { tr("modelConfig.whitelistMissingSubAgent") }
        static var thinkingLevel: String { tr("modelConfig.thinkingLevel") }
        static var thinkingLevelUseModelDefault: String { tr("modelConfig.thinkingLevelUseModelDefault") }
        static var thinkingLevelFooter: String { tr("modelConfig.thinkingLevelFooter") }
        static var imageProvider: String { tr("modelConfig.imageProvider") }
        static var imageProviderNone: String { tr("modelConfig.imageProviderNone") }
        static var imageGenerationHeader: String { tr("modelConfig.imageGenerationHeader") }
        static var imageProviderFooter: String { tr("modelConfig.imageProviderFooter") }
        static var videoProvider: String { tr("modelConfig.videoProvider") }
        static var videoProviderNone: String { tr("modelConfig.videoProviderNone") }
        static var videoGenerationHeader: String { tr("modelConfig.videoGenerationHeader") }
        static var videoProviderFooter: String { tr("modelConfig.videoProviderFooter") }
        static var i2vProvider: String { tr("modelConfig.i2vProvider") }
        static var i2vSameAsT2V: String { tr("modelConfig.i2vSameAsT2V") }
    }

    // MARK: - Cron Jobs

    enum CronJobs {
        static var title: String { tr("cronJobs.title") }
        static var noCronJobs: String { tr("cronJobs.noCronJobs") }
        static var noCronJobsDescription: String { tr("cronJobs.noCronJobsDescription") }
        static var shortcutsTrigger: String { tr("cronJobs.shortcutsTrigger") }
        static var shortcutsDescription: String { tr("cronJobs.shortcutsDescription") }
        static func runsCount(_ count: Int) -> String { tr("cronJobs.runsCount", count) }
        static var nextPrefix: String { tr("cronJobs.nextPrefix") }
        static var jobInfo: String { tr("cronJobs.jobInfo") }
        static var schedule: String { tr("cronJobs.schedule") }
        static var description: String { tr("cronJobs.description") }
        static var enabled: String { tr("cronJobs.enabled") }
        static var jobHint: String { tr("cronJobs.jobHint") }
        static var statistics: String { tr("cronJobs.statistics") }
        static var totalRuns: String { tr("cronJobs.totalRuns") }
        static var lastRun: String { tr("cronJobs.lastRun") }
        static var ago: String { tr("cronJobs.ago") }
        static var nextRun: String { tr("cronJobs.nextRun") }
        static var created: String { tr("cronJobs.created") }
        static var triggerURL: String { tr("cronJobs.triggerURL") }
        static var viewShortcutsGuide: String { tr("cronJobs.viewShortcutsGuide") }
        static var shortcutsIntegration: String { tr("cronJobs.shortcutsIntegration") }
        static var shortcutsIntegrationFooter: String { tr("cronJobs.shortcutsIntegrationFooter") }
        static var lastSession: String { tr("cronJobs.lastSession") }
        static var editJob: String { tr("cronJobs.editJob") }
        static var newCronJob: String { tr("cronJobs.newCronJob") }
        static var basic: String { tr("cronJobs.basic") }
        static var jobName: String { tr("cronJobs.jobName") }
        static var cronExpression: String { tr("cronJobs.cronExpression") }
        static var nextFire: String { tr("cronJobs.nextFire") }
        static var cronFormat: String { tr("cronJobs.cronFormat") }
        static var quickPresets: String { tr("cronJobs.quickPresets") }
        static var everyHour: String { tr("cronJobs.everyHour") }
        static var daily9am: String { tr("cronJobs.daily9am") }
        static var weekdays9am: String { tr("cronJobs.weekdays9am") }
        static var weeklyMon: String { tr("cronJobs.weeklyMon") }
        static var every30min: String { tr("cronJobs.every30min") }
        static var monthly1st: String { tr("cronJobs.monthly1st") }
        static var jobHintFooter: String { tr("cronJobs.jobHintFooter") }
    }

    // MARK: - Shortcuts Guide

    enum Shortcuts {
        static var title: String { tr("shortcuts.title") }
        static var headerTitle: String { tr("shortcuts.headerTitle") }
        static var headerSubtitle: String { tr("shortcuts.headerSubtitle") }
        static var whyNeeded: String { tr("shortcuts.whyNeeded") }
        static var whyDescription: String { tr("shortcuts.whyDescription") }

        static var appIntentSection: String { tr("shortcuts.appIntentSection") }
        static var appIntentDescription: String { tr("shortcuts.appIntentDescription") }
        static var appIntentStep1Title: String { tr("shortcuts.appIntentStep1Title") }
        static var appIntentStep1Detail: String { tr("shortcuts.appIntentStep1Detail") }
        static var appIntentStep2Title: String { tr("shortcuts.appIntentStep2Title") }
        static var appIntentStep2Detail: String { tr("shortcuts.appIntentStep2Detail") }
        static var appIntentStep3Title: String { tr("shortcuts.appIntentStep3Title") }
        static var appIntentStep3Detail: String { tr("shortcuts.appIntentStep3Detail") }
        static var appIntentStep4Title: String { tr("shortcuts.appIntentStep4Title") }
        static var appIntentStep4Detail: String { tr("shortcuts.appIntentStep4Detail") }

        static var legacyFallbackSection: String { tr("shortcuts.legacyFallbackSection") }
        static var legacyFallbackDescription: String { tr("shortcuts.legacyFallbackDescription") }

        static var setupSteps: String { tr("shortcuts.setupSteps") }
        static var step1Title: String { tr("shortcuts.step1Title") }
        static var step1Detail: String { tr("shortcuts.step1Detail") }
        static var step2Title: String { tr("shortcuts.step2Title") }
        static var step2Detail: String { tr("shortcuts.step2Detail") }
        static var step3Title: String { tr("shortcuts.step3Title") }
        static var step3Detail: String { tr("shortcuts.step3Detail") }
        static var step4Title: String { tr("shortcuts.step4Title") }
        static var step4Detail: String { tr("shortcuts.step4Detail") }
        static var step5Title: String { tr("shortcuts.step5Title") }
        static var step5Detail: String { tr("shortcuts.step5Detail") }
        static var step6Title: String { tr("shortcuts.step6Title") }
        static var step6Detail: String { tr("shortcuts.step6Detail") }
        static var urlReference: String { tr("shortcuts.urlReference") }
        static var triggerSpecific: String { tr("shortcuts.triggerSpecific") }
        static var triggerSpecificDesc: String { tr("shortcuts.triggerSpecificDesc") }
        static var runAllDue: String { tr("shortcuts.runAllDue") }
        static var runAllDueDesc: String { tr("shortcuts.runAllDueDesc") }
        static var tips: String { tr("shortcuts.tips") }
        static var tip1: String { tr("shortcuts.tip1") }
        static var tip2: String { tr("shortcuts.tip2") }
        static var tip3: String { tr("shortcuts.tip3") }
        static var tip4: String { tr("shortcuts.tip4") }
    }

    // MARK: - Sessions

    enum Sessions {
        static var title: String { tr("sessions.title") }
        static var noSessions: String { tr("sessions.noSessions") }
        static var noSessionsDescription: String { tr("sessions.noSessionsDescription") }
        static var newSession: String { tr("sessions.newSession") }
        static var noAgents: String { tr("sessions.noAgents") }
        static var noAgentsDescription: String { tr("sessions.noAgentsDescription") }
        static func sessionsCount(_ count: Int) -> String { tr("sessions.sessionsCount", count) }
        static var selectAgent: String { tr("sessions.selectAgent") }
        static func messagesCount(_ count: Int) -> String { tr("sessions.messagesCount", count) }
        static var draft: String { tr("sessions.draft") }
        static var searchSessions: String { tr("sessions.searchSessions") }
        static var selectSession: String { tr("sessions.selectSession") }
        static var selectSessionDescription: String { tr("sessions.selectSessionDescription") }
    }

    // MARK: - Settings

    enum Settings {
        static var title: String { tr("settings.title") }
        static var llmProviders: String { tr("settings.llmProviders") }
        static var imageProviders: String { tr("settings.imageProviders") }
        static var videoProviders: String { tr("settings.videoProviders") }
        static var addProvider: String { tr("settings.addProvider") }
        static var deleteProviderTitle: String { tr("settings.deleteProviderTitle") }
        static var deleteProviderMessage: String { tr("settings.deleteProviderMessage") }
        static func deleteProviderAffectedMessage(_ names: String) -> String { tr("settings.deleteProviderAffectedMessage", names) }
        static var about: String { tr("settings.about") }
        static var version: String { tr("settings.version") }
        static var build: String { tr("settings.build") }
        static var aboutDescription: String { tr("settings.aboutDescription") }
        static var sourceCode: String { tr("settings.sourceCode") }
        static var license: String { tr("settings.license") }
        static var backgroundExecution: String { tr("settings.backgroundExecution") }
        static var backgroundKeepAlive: String { tr("settings.backgroundKeepAlive") }
        static var backgroundKeepAliveFooter: String { tr("settings.backgroundKeepAliveFooter") }
        static var skills: String { tr("settings.skills") }
        static var progressiveSkillDisclosure: String { tr("settings.progressiveSkillDisclosure") }
        static var progressiveSkillDisclosureFooter: String { tr("settings.progressiveSkillDisclosureFooter") }
    }

    // MARK: - Live Activity

    enum LiveActivity {
        static var running: String { tr("liveActivity.running") }
        static var done: String { tr("liveActivity.done") }
        static var error: String { tr("liveActivity.error") }
        static func agentsRunning(_ count: Int) -> String { tr("liveActivity.agentsRunning", count) }
    }

    // MARK: - LLM Provider

    enum Provider {
        static var editProvider: String { tr("provider.editProvider") }
        static var addProvider: String { tr("provider.addProvider") }
        static var addModel: String { tr("provider.addModel") }
        static var modelNamePlaceholder: String { tr("provider.modelNamePlaceholder") }
        static var provider: String { tr("provider.provider") }
        static var endpoint: String { tr("provider.endpoint") }
        static var authentication: String { tr("provider.authentication") }
        static var apiKey: String { tr("provider.apiKey") }
        static var defaultModel: String { tr("provider.defaultModel") }
        static var defaultModelFooter: String { tr("provider.defaultModelFooter") }
        static var noModelsEnabled: String { tr("provider.noModelsEnabled") }
        static var setDefault: String { tr("provider.setDefault") }
        static var manuallyAddModel: String { tr("provider.manuallyAddModel") }
        static var enabledModels: String { tr("provider.enabledModels") }
        static var enabledModelsFooter: String { tr("provider.enabledModelsFooter") }
        static var fetchFromAPI: String { tr("provider.fetchFromAPI") }
        static func availableToEnable(_ count: Int) -> String { tr("provider.availableToEnable", count) }
        static func allModelsEnabled(_ count: Int) -> String { tr("provider.allModelsEnabled", count) }
        static var enableAll: String { tr("provider.enableAll") }
        static var remoteModels: String { tr("provider.remoteModels") }
        static var remoteModelsFooter: String { tr("provider.remoteModelsFooter") }
        static func maxTokens(_ value: Int) -> String { tr("provider.maxTokens", value) }
        static func thinkingBudget(_ value: Int) -> String { tr("provider.thinkingBudget", value) }
        static var thinkingBudgetFooter: String { tr("provider.thinkingBudgetFooter") }
        static var parameters: String { tr("provider.parameters") }
        static var supportsVision: String { tr("provider.supportsVision") }
        static var supportsVideoInput: String { tr("provider.supportsVideoInput") }
        static var supportsVisionFooter: String { tr("provider.supportsVisionFooter") }
        static var supportsToolUse: String { tr("provider.supportsToolUse") }
        static var supportsToolUseFooter: String { tr("provider.supportsToolUseFooter") }
        static var supportsImageGeneration: String { tr("provider.supportsImageGeneration") }
        static var supportsImageGenerationFooter: String { tr("provider.supportsImageGenerationFooter") }
        static var supportsVideoGeneration: String { tr("provider.supportsVideoGeneration") }
        static var supportsReasoning: String { tr("provider.supportsReasoning") }
        static var supportsReasoningFooter: String { tr("provider.supportsReasoningFooter") }
        static var thinkingLevel: String { tr("provider.thinkingLevel") }
        static var thinkingLevelFooter: String { tr("provider.thinkingLevelFooter") }
        /// Suffix shown next to the `Extra High` row on the Anthropic dialect.
        static var thinkingLevelXHighSuffix: String { tr("provider.thinkingLevelXHighSuffix") }
        /// Suffix shown next to the `Max` row on the Anthropic dialect.
        static var thinkingLevelMaxSuffix: String { tr("provider.thinkingLevelMaxSuffix") }
        /// Suffix shown next to the `Extra High` row on the OpenAI dialect.
        static var thinkingLevelXHighSuffixOpenAI: String { tr("provider.thinkingLevelXHighSuffixOpenAI") }
        /// Suffix shown next to the `Max` row on the OpenAI dialect.
        static var thinkingLevelMaxSuffixOpenAI: String { tr("provider.thinkingLevelMaxSuffixOpenAI") }
        static var perModelMaxTokens: String { tr("provider.perModelMaxTokens") }
        static func temperature(_ value: Double) -> String { tr("provider.temperature", value) }
        static var perModelTemperature: String { tr("provider.perModelTemperature") }
        static var parametersFooter: String { tr("provider.parametersFooter") }
        static var providerType: String { tr("provider.providerType") }
        static var providerTypeLLM: String { tr("provider.providerType.llm") }
        static var providerTypeImage: String { tr("provider.providerType.image") }
        static var providerTypeVideo: String { tr("provider.providerType.video") }
        static var providerTypeFooter: String { tr("provider.providerTypeFooter") }
        static var apiStyle: String { tr("provider.apiStyle") }
        static var apiStyleFooter: String { tr("provider.apiStyleFooter") }
        static var apiStyleOpenAI: String { tr("provider.apiStyle.openAI") }
        static var apiStyleOpenAIResponses: String { tr("provider.apiStyle.openAIResponses") }
        static var apiStyleAnthropic: String { tr("provider.apiStyle.anthropic") }
        static var apiStyleGoogleVeo: String { tr("provider.apiStyle.googleVeo") }
        static var apiStyleDashScope: String { tr("provider.apiStyle.dashScope") }
        static var apiStyleKling: String { tr("provider.apiStyle.kling") }
        static var apiStyleSeedance: String { tr("provider.apiStyle.seedance") }
        static var testConnection: String { tr("provider.testConnection") }
        static func testConnectionSuccess(_ count: Int) -> String { tr("provider.testConnectionSuccess", count) }
        static var testConnectionOK: String { tr("provider.testConnectionOK") }
        static var modelCapabilities: String { tr("provider.modelCapabilities") }
        static var presets: String { tr("provider.presets") }
        // MARK: Models.dev catalog
        static var modelsDevBrowse: String { tr("provider.modelsDev.browse") }
        static var modelsDevSectionFooter: String { tr("provider.modelsDev.sectionFooter") }
        static var modelsDevTitle: String { tr("provider.modelsDev.title") }
        static var modelsDevLoading: String { tr("provider.modelsDev.loading") }
        static var modelsDevFailed: String { tr("provider.modelsDev.failed") }
        static var modelsDevSearch: String { tr("provider.modelsDev.search") }
        static var modelsDevSearchModels: String { tr("provider.modelsDev.searchModels") }
        static var modelsDevModels: String { tr("provider.modelsDev.models") }
        static func modelsDevModelCount(_ count: Int) -> String { tr("provider.modelsDev.modelCount", count) }
        static var modelsDevSelectAll: String { tr("provider.modelsDev.selectAll") }
        static var modelsDevDeselectAll: String { tr("provider.modelsDev.deselectAll") }
        static var modelsDevNoEndpoint: String { tr("provider.modelsDev.noEndpoint") }
        static var modelsDevImportFooter: String { tr("provider.modelsDev.importFooter") }
        static var imageGenModeNone: String { tr("provider.imageGenMode.none") }
        static var imageGenModeChatInline: String { tr("provider.imageGenMode.chatInline") }
        static var imageGenModeDedicatedAPI: String { tr("provider.imageGenMode.dedicatedAPI") }
        static var imageGenModeDashScope: String { tr("provider.imageGenMode.dashScope") }
    }

    // MARK: - Skills

    enum Skills {
        static var title: String { tr("skills.title") }
        static var noSkills: String { tr("skills.noSkills") }
        static var noSkillsDescription: String { tr("skills.noSkillsDescription") }
        static var createSkill: String { tr("skills.createSkill") }
        static var importSkill: String { tr("skills.importSkill") }
        static var importContinue: String { tr("skills.importContinue") }
        static var importReplace: String { tr("skills.importReplace") }
        static var importSecurityTitle: String { tr("skills.importSecurityTitle") }
        static var importSecurityBody: String { tr("skills.importSecurityBody") }
        static var importFailedTitle: String { tr("skills.importFailedTitle") }
        static var importNotADirectory: String { tr("skills.importNotADirectory") }
        static var importWarningsTitle: String { tr("skills.importWarningsTitle") }
        static var importCollisionTitle: String { tr("skills.importCollisionTitle") }
        static func importCollisionBody(_ name: String) -> String { tr("skills.importCollisionBody", name) }
        static func importCollisionFooter(_ name: String) -> String { tr("skills.importCollisionFooter", name) }
        static func importBuiltInRefused(_ name: String) -> String { tr("skills.importBuiltInRefused", name) }
        static func importValidationFailed(_ count: Int) -> String { tr("skills.importValidationFailed", count) }
        static func importValidationWarnings(_ count: Int) -> String { tr("skills.importValidationWarnings", count) }
        static var importedTitle: String { tr("skills.importedTitle") }
        static func importedBody(_ name: String) -> String { tr("skills.importedBody", name) }
        static var revealInFiles: String { tr("skills.revealInFiles") }
        static var showInFiles: String { tr("skills.showInFiles") }
        static var shareSkill: String { tr("skills.shareSkill") }
        static var validationErrorsTitle: String { tr("skills.validationErrorsTitle") }
        static var validationWarningsTitle: String { tr("skills.validationWarningsTitle") }
        static var parameterOptional: String { tr("skills.parameterOptional") }
        static var editScriptTitle: String { tr("skills.editScriptTitle") }
        static var editToolTitle: String { tr("skills.editToolTitle") }
        static var customSkills: String { tr("skills.customSkills") }
        static var builtInSkills: String { tr("skills.builtInSkills") }
        static var builtIn: String { tr("skills.builtIn") }
        static var searchSkills: String { tr("skills.searchSkills") }
        static var deleteSkill: String { tr("skills.deleteSkill") }
        static func deleteSkillMessage(_ name: String) -> String { tr("skills.deleteSkillMessage", name) }
        static var content: String { tr("skills.content") }
        static var noAgents: String { tr("skills.noAgents") }
        static var noAgentsDescription: String { tr("skills.noAgentsDescription") }
        static func install(_ name: String) -> String { tr("skills.install", name) }
        static func skillsActive(_ count: Int) -> String { tr("skills.skillsActive", count) }
        static var agents: String { tr("skills.agents") }
        static var editSkill: String { tr("skills.editSkill") }
        static var newSkill: String { tr("skills.newSkill") }
        static var info: String { tr("skills.info") }
        static var skillName: String { tr("skills.skillName") }
        static var summary: String { tr("skills.summary") }
        static var tags: String { tr("skills.tags") }
        static var contentMarkdown: String { tr("skills.contentMarkdown") }
        static var contentFooter: String { tr("skills.contentFooter") }
        static var noSkillsInstalled: String { tr("skills.noSkillsInstalled") }
        static var installDescription: String { tr("skills.installDescription") }
        static var browseLibrary: String { tr("skills.browseLibrary") }
        static var uninstall: String { tr("skills.uninstall") }
        static var skillLibrary: String { tr("skills.skillLibrary") }
        static func activeInstalled(active: Int, installed: Int) -> String {
            tr("skills.activeInstalled", active, installed)
        }
        // Scripts & Tools
        static func scriptsCount(_ count: Int) -> String { tr("skills.scriptsCount", count) }
        static func customToolsCount(_ count: Int) -> String { tr("skills.customToolsCount", count) }
        static var parameters: String { tr("skills.parameters") }
        static var addScript: String { tr("skills.addScript") }
        static var addTool: String { tr("skills.addTool") }
        static var addParameter: String { tr("skills.addParameter") }
        static var scripts: String { tr("skills.scripts") }
        static var customTools: String { tr("skills.customTools") }
        static var scriptsFooter: String { tr("skills.scriptsFooter") }
        static var customToolsFooter: String { tr("skills.customToolsFooter") }
        static var scriptName: String { tr("skills.scriptName") }
        static var descriptionOptional: String { tr("skills.descriptionOptional") }
        static var jsCode: String { tr("skills.jsCode") }
        static var toolName: String { tr("skills.toolName") }
        static var toolInfo: String { tr("skills.toolInfo") }
        static var description: String { tr("skills.description") }
        static var jsImplementation: String { tr("skills.jsImplementation") }
        static var jsImplementationFooter: String { tr("skills.jsImplementationFooter") }
        static var configure: String { tr("skills.configure") }
        static var skillConfiguration: String { tr("skills.skillConfiguration") }
        static var required: String { tr("skills.required") }
    }

    // MARK: - Cron Parser

    enum CronDesc {
        static var invalidExpression: String { tr("cron.invalidExpression") }
        static var everyMinute: String { tr("cron.everyMinute") }
        static func atMinute(_ m: Int) -> String { tr("cron.atMinute", m) }
        static func atMinutes(_ s: String) -> String { tr("cron.atMinutes", s) }
        static var ofEveryHour: String { tr("cron.ofEveryHour") }
        static func ofHour(_ h: Int) -> String { tr("cron.ofHour", h) }
        static func ofHours(_ s: String) -> String { tr("cron.ofHours", s) }
        static func onDays(_ s: String) -> String { tr("cron.onDays", s) }
        static func inMonths(_ s: String) -> String { tr("cron.inMonths", s) }
        static func onWeekdays(_ s: String) -> String { tr("cron.onWeekdays", s) }
        static var weekdayNames: [String] {
            [tr("cron.sun"), tr("cron.mon"), tr("cron.tue"), tr("cron.wed"),
             tr("cron.thu"), tr("cron.fri"), tr("cron.sat")]
        }
    }

    // MARK: - Cron Executor

    enum CronExec {
        static var completed: String { tr("cronExec.completed") }
        static func completedBody(_ name: String) -> String { tr("cronExec.completedBody", name) }
        static var noProvider: String { tr("cronExec.noProvider") }
    }

    // MARK: - Chat Errors

    enum ChatError {
        static var noProvider: String { tr("chatError.noProvider") }
        static var noAgent: String { tr("chatError.noAgent") }
        static var whitelistBlocked: String { tr("chatError.whitelistBlocked") }
    }

    // MARK: - Browser

    enum Browser {
        static var title: String { tr("browser.title") }
        static var urlPlaceholder: String { tr("browser.urlPlaceholder") }
        static func agentControlling(_ name: String) -> String { tr("browser.agentControlling", name) }
        static var takeOver: String { tr("browser.takeOver") }
        static var takeOverTitle: String { tr("browser.takeOverTitle") }
        static func takeOverMessage(_ name: String) -> String { tr("browser.takeOverMessage", name) }
        static var closePage: String { tr("browser.closePage") }
        static var closePageTitle: String { tr("browser.closePageTitle") }
        static var closePageMessage: String { tr("browser.closePageMessage") }
    }

    // MARK: - Markdown Editor

    enum MarkdownEditor {
        static var preview: String { tr("markdownEditor.preview") }
        static var edit: String { tr("markdownEditor.edit") }
    }

    // MARK: - Tool Card Display Names

    enum ToolCard {
        static var javascript: String { tr("toolCard.javascript") }
        static var readConfig: String { tr("toolCard.readConfig") }
        static var writeConfig: String { tr("toolCard.writeConfig") }
        static var saveCode: String { tr("toolCard.saveCode") }
        static var loadCode: String { tr("toolCard.loadCode") }
        static var listCode: String { tr("toolCard.listCode") }
        static var createAgent: String { tr("toolCard.createAgent") }
        static var messageAgent: String { tr("toolCard.messageAgent") }
        static var collectOutput: String { tr("toolCard.collectOutput") }
        static var listAgents: String { tr("toolCard.listAgents") }
        static var stopAgent: String { tr("toolCard.stopAgent") }
        static var deleteAgent: String { tr("toolCard.deleteAgent") }
        static var scheduleJob: String { tr("toolCard.scheduleJob") }
        static var removeJob: String { tr("toolCard.removeJob") }
        static var listJobs: String { tr("toolCard.listJobs") }
        static var createSkill: String { tr("toolCard.createSkill") }
        static var deleteSkill: String { tr("toolCard.deleteSkill") }
        static var installSkill: String { tr("toolCard.installSkill") }
        static var uninstallSkill: String { tr("toolCard.uninstallSkill") }
        static var listSkills: String { tr("toolCard.listSkills") }
        static var readSkill: String { tr("toolCard.readSkill") }
        static var setModel: String { tr("toolCard.setModel") }
        static var getModel: String { tr("toolCard.getModel") }
        static var listModels: String { tr("toolCard.listModels") }
        static var fileList: String { tr("toolCard.fileList") }
        static var fileRead: String { tr("toolCard.fileRead") }
        static var fileWrite: String { tr("toolCard.fileWrite") }
        static var fileDelete: String { tr("toolCard.fileDelete") }
        static var fileInfo: String { tr("toolCard.fileInfo") }
        static var attachMedia: String { tr("toolCard.attachMedia") }
        static var browse: String { tr("toolCard.browse") }
        static var pageInfo: String { tr("toolCard.pageInfo") }
        static var click: String { tr("toolCard.click") }
        static var input: String { tr("toolCard.input") }
        static var select: String { tr("toolCard.select") }
        static var extract: String { tr("toolCard.extract") }
        static var browserJS: String { tr("toolCard.browserJS") }
        static var waitElement: String { tr("toolCard.waitElement") }
        static var scroll: String { tr("toolCard.scroll") }
        static var screenshot: String { tr("toolCard.screenshot") }
        static var runSnippet: String { tr("toolCard.runSnippet") }
        static var deleteCode: String { tr("toolCard.deleteCode") }
        static var calendarListCalendars: String { tr("toolCard.calendarListCalendars") }
        static var calendarCreateEvent: String { tr("toolCard.calendarCreateEvent") }
        static var calendarSearchEvents: String { tr("toolCard.calendarSearchEvents") }
        static var calendarUpdateEvent: String { tr("toolCard.calendarUpdateEvent") }
        static var calendarDeleteEvent: String { tr("toolCard.calendarDeleteEvent") }
        static var reminderLists: String { tr("toolCard.reminderLists") }
        static var reminderList: String { tr("toolCard.reminderList") }
        static var reminderCreate: String { tr("toolCard.reminderCreate") }
        static var reminderComplete: String { tr("toolCard.reminderComplete") }
        static var reminderDelete: String { tr("toolCard.reminderDelete") }
        static var contactsSearch: String { tr("toolCard.contactsSearch") }
        static var contactsGetDetail: String { tr("toolCard.contactsGetDetail") }
        static var clipboardRead: String { tr("toolCard.clipboardRead") }
        static var clipboardWrite: String { tr("toolCard.clipboardWrite") }
        static var notificationSchedule: String { tr("toolCard.notificationSchedule") }
        static var notificationCancel: String { tr("toolCard.notificationCancel") }
        static var notificationList: String { tr("toolCard.notificationList") }
        static var locationGetCurrent: String { tr("toolCard.locationGetCurrent") }
        static var locationGeocode: String { tr("toolCard.locationGeocode") }
        static var locationReverseGeocode: String { tr("toolCard.locationReverseGeocode") }
        static var mapSearchPlaces: String { tr("toolCard.mapSearchPlaces") }
        static var mapGetDirections: String { tr("toolCard.mapGetDirections") }
        static var healthReadSteps: String { tr("toolCard.healthReadSteps") }
        static var healthReadHeartRate: String { tr("toolCard.healthReadHeartRate") }
        static var healthReadSleep: String { tr("toolCard.healthReadSleep") }
        static var healthReadBodyMass: String { tr("toolCard.healthReadBodyMass") }
        static var healthReadBloodPressure: String { tr("toolCard.healthReadBloodPressure") }
        static var healthReadBloodGlucose: String { tr("toolCard.healthReadBloodGlucose") }
        static var healthReadBloodOxygen: String { tr("toolCard.healthReadBloodOxygen") }
        static var healthReadBodyTemperature: String { tr("toolCard.healthReadBodyTemperature") }
        static var healthWriteDietaryEnergy: String { tr("toolCard.healthWriteDietaryEnergy") }
        static var healthWriteBodyMass: String { tr("toolCard.healthWriteBodyMass") }
        static var healthWriteDietaryWater: String { tr("toolCard.healthWriteDietaryWater") }
        static var healthWriteDietaryCarbohydrates: String { tr("toolCard.healthWriteDietaryCarbohydrates") }
        static var healthWriteDietaryProtein: String { tr("toolCard.healthWriteDietaryProtein") }
        static var healthWriteDietaryFat: String { tr("toolCard.healthWriteDietaryFat") }
        static var healthWriteBloodPressure: String { tr("toolCard.healthWriteBloodPressure") }
        static var healthWriteBodyFat: String { tr("toolCard.healthWriteBodyFat") }
        static var healthWriteHeight: String { tr("toolCard.healthWriteHeight") }
        static var healthWriteBloodGlucose: String { tr("toolCard.healthWriteBloodGlucose") }
        static var healthWriteBloodOxygen: String { tr("toolCard.healthWriteBloodOxygen") }
        static var healthWriteBodyTemperature: String { tr("toolCard.healthWriteBodyTemperature") }
        static var healthWriteHeartRate: String { tr("toolCard.healthWriteHeartRate") }
        static var healthWriteWorkout: String { tr("toolCard.healthWriteWorkout") }
        static var searchSessions: String { tr("toolCard.searchSessions") }
        static var recallSession: String { tr("toolCard.recallSession") }
        static var generateImage: String { tr("toolCard.generateImage") }
        static var generateVideo: String { tr("toolCard.generateVideo") }
        static var skillScope: String { tr("toolCard.skillScope") }
    }

    // MARK: - Tool Result

    enum ToolResult {
        static var stdout: String { tr("toolResult.stdout") }
        static var stderr: String { tr("toolResult.stderr") }
    }

    // MARK: - Apple Health (dedicated feature screen)

    enum AppleHealth {
        static var title: String { tr("appleHealth.title") }
        static var intro: String { tr("appleHealth.intro") }
        static var privacyNote: String { tr("appleHealth.privacyNote") }

        static var available: String { tr("appleHealth.available") }
        static var unavailable: String { tr("appleHealth.unavailable") }
        static var connectionHeader: String { tr("appleHealth.connectionHeader") }
        static var connectButton: String { tr("appleHealth.connectButton") }
        static var connecting: String { tr("appleHealth.connecting") }
        static var connected: String { tr("appleHealth.connected") }
        static var connectFooter: String { tr("appleHealth.connectFooter") }

        static var dataTypesHeader: String { tr("appleHealth.dataTypesHeader") }
        static var dataTypesRead: String { tr("appleHealth.dataTypesRead") }
        static var dataTypesWrite: String { tr("appleHealth.dataTypesWrite") }
        static var dataTypesFooter: String { tr("appleHealth.dataTypesFooter") }
    }

    // MARK: - Onboarding (first-launch landing)

    enum Onboarding {
        static var welcomeTitle: String { tr("onboarding.welcomeTitle") }
        static var welcomeSubtitle: String { tr("onboarding.welcomeSubtitle") }

        static var healthStepTitle: String { tr("onboarding.healthStepTitle") }
        static var healthStepBody: String { tr("onboarding.healthStepBody") }
        static var healthLearnMore: String { tr("onboarding.healthLearnMore") }

        static var providerStepTitle: String { tr("onboarding.providerStepTitle") }
        static var providerStepBody: String { tr("onboarding.providerStepBody") }
        static var configureProvider: String { tr("onboarding.configureProvider") }
        static func providerConfigured(_ name: String) -> String { tr("onboarding.providerConfigured", name) }

        static var agentStepTitle: String { tr("onboarding.agentStepTitle") }
        static var agentStepBody: String { tr("onboarding.agentStepBody") }
        static var agentNamePlaceholder: String { tr("onboarding.agentNamePlaceholder") }
        static var agentNameDefault: String { tr("onboarding.agentNameDefault") }
        static var createAgent: String { tr("onboarding.createAgent") }
        static func agentCreated(_ name: String) -> String { tr("onboarding.agentCreated", name) }

        static var skip: String { tr("onboarding.skip") }
        static var next: String { tr("onboarding.next") }
        static var back: String { tr("onboarding.back") }
        static var getStarted: String { tr("onboarding.getStarted") }
    }

    // MARK: - Export

    enum Export {
        static var roleUser: String { tr("export.roleUser") }
        static var roleAssistant: String { tr("export.roleAssistant") }
        static var roleTool: String { tr("export.roleTool") }
        static var toolCall: String { tr("export.toolCall") }
    }
}

// swiftlint:enable type_body_length file_length
