import Foundation

enum AccessibilityID {
    enum Tabs {
        static let sessions = "tab.sessions"
        static let agents = "tab.agents"
        static let browser = "tab.browser"
        static let skills = "tab.skills"
        static let settings = "tab.settings"
    }

    enum SessionList {
        static let newSessionButton = "sessionList.newSession"
        static let sessionRow = "sessionList.row"
        static let emptyState = "sessionList.empty"
        static let emptyNewSessionButton = "sessionList.emptyNewSession"
    }

    enum NewSessionSheet {
        static let cancelButton = "newSessionSheet.cancel"
        static let agentRow = "newSessionSheet.agentRow"
    }

    enum Chat {
        static let messageList = "chat.messageList"
        static let inputField = "chat.inputField"
        static let sendButton = "chat.send"
        static let stopButton = "chat.stop"
        static let menuButton = "chat.menu"
        static let messageBubble = "chat.bubble"
        static let scrollToBottom = "chat.scrollToBottom"
    }

    enum AgentList {
        static let createButton = "agentList.create"
        static let agentRow = "agentList.row"
        static let emptyState = "agentList.empty"
        static let emptyCreateButton = "agentList.emptyCreate"
    }

    enum Browser {
        static let addressBar = "browser.addressBar"
        static let backButton = "browser.back"
        static let forwardButton = "browser.forward"
    }

    enum SkillLibrary {
        static let createButton = "skillLibrary.create"
        static let skillRow = "skillLibrary.row"
        static let emptyState = "skillLibrary.empty"
    }

    enum Settings {
        static let addProviderButton = "settings.addProvider"
        static let providerRow = "settings.providerRow"
        static let aboutRow = "settings.about"
        static let backgroundToggle = "settings.backgroundToggle"
        static let skillDisclosureToggle = "settings.skillDisclosure"
    }
}
