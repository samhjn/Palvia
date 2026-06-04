import SwiftUI
import SwiftData

/// First-launch landing flow.
///
/// Serves two goals at once:
///  1. Makes the HealthKit integration immediately visible (and connectable)
///     so it is obvious to a user / App Store reviewer without using the chat.
///  2. Bootstraps initial setup (default LLM provider + a starter agent), since
///     the app ships with an empty data store.
///
/// Every step is skippable so the user is never blocked. Reuses existing flows:
/// `ApplePermissionManager`, `LLMProviderEditView` + `SettingsViewModel`, and
/// `AgentViewModel.createAgent`.
struct OnboardingView: View {
    @Environment(\.modelContext) private var modelContext

    /// Called when the user finishes or skips the whole flow.
    let onFinish: () -> Void

    @AppStorage("defaultAgentId") private var defaultAgentId: String = ""

    @State private var step = 0
    private let lastStep = 2

    // Step 1 — Health
    @State private var isConnectingHealth = false
    @State private var healthResult: String?
    @State private var healthConnected = false

    // Step 2 — Provider
    @State private var settingsVM: SettingsViewModel?
    @State private var showProviderSheet = false

    // Step 3 — Agent
    @State private var agentName = L10n.Onboarding.agentNameDefault
    @State private var createdAgentName: String?

    var body: some View {
        VStack(spacing: 0) {
            header

            TabView(selection: $step) {
                healthStep.tag(0)
                providerStep.tag(1)
                agentStep.tag(2)
            }
            .tabViewStyle(.page(indexDisplayMode: .always))
            .animation(.easeInOut, value: step)

            bottomBar
        }
        .onAppear {
            if settingsVM == nil {
                settingsVM = SettingsViewModel(modelContext: modelContext)
            }
        }
    }

    // MARK: - Header

    private var header: some View {
        VStack(spacing: 4) {
            Text(L10n.Onboarding.welcomeTitle)
                .font(.largeTitle).bold()
            Text(L10n.Onboarding.welcomeSubtitle)
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .padding(.top, 40)
        .padding(.horizontal)
        .multilineTextAlignment(.center)
    }

    // MARK: - Steps

    private var healthStep: some View {
        stepScaffold(icon: "heart.fill", iconColor: .pink,
                     title: L10n.Onboarding.healthStepTitle,
                     body: L10n.Onboarding.healthStepBody) {
            Button {
                connectHealth()
            } label: {
                HStack {
                    if isConnectingHealth {
                        ProgressView()
                        Text(L10n.AppleHealth.connecting)
                    } else {
                        Image(systemName: "heart.text.square")
                        Text(L10n.AppleHealth.connectButton)
                    }
                }
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .disabled(isConnectingHealth)
            .accessibilityIdentifier(AccessibilityID.Onboarding.connectHealthButton)

            if let healthResult {
                Text(healthResult)
                    .font(.caption)
                    .foregroundStyle(healthConnected ? .green : .red)
                    .multilineTextAlignment(.center)
            }

            NavigationLink {
                AppleHealthView()
            } label: {
                Text(L10n.Onboarding.healthLearnMore)
            }
        }
    }

    private var providerStep: some View {
        stepScaffold(icon: "cpu", iconColor: .teal,
                     title: L10n.Onboarding.providerStepTitle,
                     body: L10n.Onboarding.providerStepBody) {
            Button {
                showProviderSheet = true
            } label: {
                HStack {
                    Image(systemName: "plus.circle")
                    Text(L10n.Onboarding.configureProvider)
                }
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .accessibilityIdentifier(AccessibilityID.Onboarding.configureProviderButton)

            if let summary = defaultProviderSummary {
                Label(L10n.Onboarding.providerConfigured(summary), systemImage: "checkmark.circle.fill")
                    .font(.caption)
                    .foregroundStyle(.green)
                    .multilineTextAlignment(.center)
            }
        }
        .sheet(isPresented: $showProviderSheet, onDismiss: { settingsVM?.fetchProviders() }) {
            if let vm = settingsVM {
                LLMProviderEditView(viewModel: vm)
            }
        }
    }

    private var agentStep: some View {
        stepScaffold(icon: "person.crop.circle.badge.plus", iconColor: .orange,
                     title: L10n.Onboarding.agentStepTitle,
                     body: L10n.Onboarding.agentStepBody) {
            TextField(L10n.Onboarding.agentNamePlaceholder, text: $agentName)
                .textFieldStyle(.roundedBorder)

            Button {
                createAgent()
            } label: {
                HStack {
                    Image(systemName: "sparkles")
                    Text(L10n.Onboarding.createAgent)
                }
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .disabled(agentName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            .accessibilityIdentifier(AccessibilityID.Onboarding.createAgentButton)

            if let createdAgentName {
                Label(L10n.Onboarding.agentCreated(createdAgentName), systemImage: "checkmark.circle.fill")
                    .font(.caption)
                    .foregroundStyle(.green)
            }
        }
    }

    // MARK: - Step scaffold

    @ViewBuilder
    private func stepScaffold<Content: View>(
        icon: String,
        iconColor: Color,
        title: String,
        body: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 20) {
                    Image(systemName: icon)
                        .font(.system(size: 56))
                        .foregroundStyle(iconColor)
                        .padding(.top, 24)
                    Text(title)
                        .font(.title2).bold()
                    Text(body)
                        .font(.body)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                    content()
                }
                .padding(.horizontal, 28)
                .padding(.bottom, 24)
            }
        }
    }

    // MARK: - Bottom bar

    private var bottomBar: some View {
        HStack {
            if step > 0 {
                Button(L10n.Onboarding.back) { withAnimation { step -= 1 } }
            }
            Spacer()
            if step < lastStep {
                Button(L10n.Onboarding.skip) { withAnimation { step += 1 } }
                    .accessibilityIdentifier(AccessibilityID.Onboarding.skipButton)
                Button(L10n.Onboarding.next) { withAnimation { step += 1 } }
                    .buttonStyle(.borderedProminent)
                    .accessibilityIdentifier(AccessibilityID.Onboarding.nextButton)
            } else {
                Button(L10n.Onboarding.getStarted, action: onFinish)
                    .buttonStyle(.borderedProminent)
                    .accessibilityIdentifier(AccessibilityID.Onboarding.getStartedButton)
            }
        }
        .padding()
    }

    // MARK: - Helpers

    private var defaultProviderSummary: String? {
        guard let vm = settingsVM,
              let id = vm.defaultProviderId,
              let row = vm.providerRowCache[id] else { return nil }
        return "\(row.name) · \(row.modelName)"
    }

    private func connectHealth() {
        guard !isConnectingHealth else { return }
        isConnectingHealth = true
        healthResult = nil
        Task {
            let error = await ApplePermissionManager.shared.ensureHealthAccess()
            isConnectingHealth = false
            healthConnected = (error == nil)
            healthResult = error ?? L10n.AppleHealth.connected
        }
    }

    private func createAgent() {
        let trimmed = agentName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let agent = AgentViewModel(modelContext: modelContext).createAgent(name: trimmed)
        defaultAgentId = agent.id.uuidString
        createdAgentName = agent.name
    }
}
