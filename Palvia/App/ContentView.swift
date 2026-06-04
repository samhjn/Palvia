import SwiftUI

struct ContentView: View {
    @State private var selectedTab: Tab = .sessions
    @AppStorage("hasSeenOnboarding") private var hasSeenOnboarding = false

    enum Tab: String {
        case sessions
        case agents
        case browser
        case skills
        case settings
    }

    /// Show the first-launch landing once, but never during UI tests
    /// (it would block every other UI test flow).
    private var showOnboarding: Bool {
        !hasSeenOnboarding && !PalviaModelContainer.isUITesting
    }

    var body: some View {
        // The onboarding is shown as the app root rather than as a modal
        // (.fullScreenCover). Presenting it as a modal breaks HealthKit
        // authorization: the system presents the Health consent sheet from the
        // window's root view controller, which conflicts with an already
        // presented cover, so the request never completes ("times out").
        if showOnboarding {
            OnboardingView { hasSeenOnboarding = true }
        } else {
            mainTabView
        }
    }

    private var mainTabView: some View {
        TabView(selection: $selectedTab) {
            SessionListView()
                .tabItem {
                    Label(L10n.Tabs.sessions, systemImage: "bubble.left.and.bubble.right")
                }
                .tag(Tab.sessions)
                .accessibilityIdentifier(AccessibilityID.Tabs.sessions)

            AgentListView()
                .tabItem {
                    Label(L10n.Tabs.agents, systemImage: "cpu")
                }
                .tag(Tab.agents)
                .accessibilityIdentifier(AccessibilityID.Tabs.agents)

            BrowserView()
                .tabItem {
                    Label(L10n.Tabs.browser, systemImage: "globe")
                }
                .tag(Tab.browser)
                .accessibilityIdentifier(AccessibilityID.Tabs.browser)

            SkillLibraryView()
                .tabItem {
                    Label(L10n.Tabs.skills, systemImage: "sparkles")
                }
                .tag(Tab.skills)
                .accessibilityIdentifier(AccessibilityID.Tabs.skills)

            SettingsView()
                .tabItem {
                    Label(L10n.Tabs.settings, systemImage: "gearshape")
                }
                .tag(Tab.settings)
                .accessibilityIdentifier(AccessibilityID.Tabs.settings)
        }
        .imagePreviewOverlay()
        .textFilePreviewOverlay()
        .onReceive(NotificationCenter.default.publisher(for: BrowserService.switchToBrowserTabNotification)) { _ in
            selectedTab = .browser
        }
    }
}
