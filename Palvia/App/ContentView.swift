import SwiftUI

struct ContentView: View {
    @State private var selectedTab: Tab = .sessions
    @AppStorage("hasSeenOnboarding") private var hasSeenOnboarding = false
    @State private var showOnboarding = false

    enum Tab: String {
        case sessions
        case agents
        case browser
        case skills
        case settings
    }

    var body: some View {
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
        .fullScreenCover(isPresented: $showOnboarding) {
            OnboardingView {
                hasSeenOnboarding = true
                showOnboarding = false
            }
        }
        .onAppear {
            // Show the first-launch landing once, but never during UI tests
            // (it would block every other UI test flow).
            if !hasSeenOnboarding && !PalviaModelContainer.isUITesting {
                showOnboarding = true
            }
        }
    }
}
