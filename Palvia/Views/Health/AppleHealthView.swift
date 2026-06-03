import SwiftUI
import HealthKit
import Observation

/// A dedicated, discoverable Apple Health screen.
///
/// This screen exists so the HealthKit integration is obvious and demonstrable
/// without using the AI chat: the user (or an App Store reviewer) can grant
/// HealthKit access directly, read their latest data, and log new entries.
/// It reuses the exact same code paths the AI agent uses (`AppleHealthTools`
/// and `ApplePermissionManager`) — no chat or tool-execution flow is involved.
struct AppleHealthView: View {
    @State private var model: HealthDashboardViewModel?

    // Write-demo input fields.
    @State private var waterText: String = ""
    @State private var bodyMassText: String = ""

    var body: some View {
        Group {
            if let model {
                List {
                    introSection
                    connectionSection(model)
                    readSection(model)
                    writeSection(model)
                    dataTypesSection
                }
                .listStyle(.insetGrouped)
            } else {
                ProgressView()
            }
        }
        .navigationTitle(L10n.AppleHealth.title)
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            if model == nil { model = HealthDashboardViewModel() }
        }
    }

    // MARK: - Sections

    private var introSection: some View {
        Section {
            HStack(spacing: 12) {
                Image(systemName: "heart.fill")
                    .font(.largeTitle)
                    .foregroundStyle(.pink)
                Text(L10n.AppleHealth.intro)
                    .font(.subheadline)
            }
            Text(L10n.AppleHealth.privacyNote)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func connectionSection(_ model: HealthDashboardViewModel) -> some View {
        Section {
            Label(
                model.isAvailable ? L10n.AppleHealth.available : L10n.AppleHealth.unavailable,
                systemImage: model.isAvailable ? "checkmark.seal.fill" : "exclamationmark.triangle.fill"
            )
            .foregroundStyle(model.isAvailable ? .green : .orange)
            .font(.subheadline)

            Button {
                Task { await model.connect() }
            } label: {
                HStack {
                    if model.isConnecting {
                        ProgressView()
                        Text(L10n.AppleHealth.connecting)
                    } else {
                        Image(systemName: "heart.text.square")
                        Text(L10n.AppleHealth.connectButton)
                    }
                }
            }
            .disabled(!model.isAvailable || model.isConnecting)
            .accessibilityIdentifier(AccessibilityID.AppleHealth.connectButton)

            if let result = model.connectResult {
                Text(result)
                    .font(.caption)
                    .foregroundStyle(model.connected ? .green : .red)
            }
        } header: {
            Text(L10n.AppleHealth.connectionHeader)
        } footer: {
            Text(L10n.AppleHealth.connectFooter)
        }
    }

    private func readSection(_ model: HealthDashboardViewModel) -> some View {
        Section {
            Button {
                Task { await model.refreshReads() }
            } label: {
                HStack {
                    if model.isReading {
                        ProgressView()
                    } else {
                        Image(systemName: "arrow.clockwise")
                    }
                    Text(L10n.AppleHealth.readRefresh)
                }
            }
            .disabled(model.isReading)
            .accessibilityIdentifier(AccessibilityID.AppleHealth.readRefreshButton)

            if model.stepsSummary == nil, model.heartRateSummary == nil, model.bodyMassSummary == nil {
                Text(L10n.AppleHealth.readEmpty)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                readResultRow(title: L10n.AppleHealth.readSteps, text: model.stepsSummary)
                readResultRow(title: L10n.AppleHealth.readHeartRate, text: model.heartRateSummary)
                readResultRow(title: L10n.AppleHealth.readBodyMass, text: model.bodyMassSummary)
            }
        } header: {
            Text(L10n.AppleHealth.readHeader)
        }
    }

    @ViewBuilder
    private func readResultRow(title: String, text: String?) -> some View {
        if let text {
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.headline)
                Text(text)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
            .padding(.vertical, 2)
        }
    }

    private func writeSection(_ model: HealthDashboardViewModel) -> some View {
        Section {
            HStack {
                Text(L10n.AppleHealth.writeWaterLabel)
                TextField(L10n.AppleHealth.writeWaterPlaceholder, text: $waterText)
                    .keyboardType(.decimalPad)
                    .multilineTextAlignment(.trailing)
                Button(L10n.AppleHealth.writeWaterButton) {
                    Task {
                        await model.logWater(waterText)
                        waterText = ""
                    }
                }
                .disabled(Double(waterText) == nil || model.isWriting)
                .accessibilityIdentifier(AccessibilityID.AppleHealth.writeWaterButton)
            }

            HStack {
                Text(L10n.AppleHealth.writeBodyMassLabel)
                TextField(L10n.AppleHealth.writeBodyMassPlaceholder, text: $bodyMassText)
                    .keyboardType(.decimalPad)
                    .multilineTextAlignment(.trailing)
                Button(L10n.AppleHealth.writeBodyMassButton) {
                    Task {
                        await model.logBodyMass(bodyMassText)
                        bodyMassText = ""
                    }
                }
                .disabled(Double(bodyMassText) == nil || model.isWriting)
                .accessibilityIdentifier(AccessibilityID.AppleHealth.writeBodyMassButton)
            }

            if let result = model.writeResult {
                Text(result)
                    .font(.caption)
                    .foregroundStyle(model.writeSucceeded ? .green : .red)
            }
        } header: {
            Text(L10n.AppleHealth.writeHeader)
        }
    }

    private var dataTypesSection: some View {
        Section {
            Text(L10n.AppleHealth.dataTypesRead)
                .font(.caption)
            Text(L10n.AppleHealth.dataTypesWrite)
                .font(.caption)
        } header: {
            Text(L10n.AppleHealth.dataTypesHeader)
        } footer: {
            Text(L10n.AppleHealth.dataTypesFooter)
        }
    }
}

// MARK: - View Model

@Observable
@MainActor
final class HealthDashboardViewModel {
    let isAvailable: Bool = HKHealthStore.isHealthDataAvailable()

    var isConnecting = false
    var connected = false
    var connectResult: String?

    var isReading = false
    var stepsSummary: String?
    var heartRateSummary: String?
    var bodyMassSummary: String?

    var isWriting = false
    var writeSucceeded = false
    var writeResult: String?

    private let tools = AppleHealthTools()

    func connect() async {
        guard !isConnecting else { return }
        isConnecting = true
        connectResult = nil
        defer { isConnecting = false }

        if let error = await ApplePermissionManager.shared.ensureHealthAccess() {
            connected = false
            connectResult = error
        } else {
            connected = true
            connectResult = L10n.AppleHealth.connected
        }
    }

    func refreshReads() async {
        guard !isReading else { return }
        isReading = true
        defer { isReading = false }

        let tools = self.tools
        async let steps = tools.readSteps(arguments: [:])
        async let heart = tools.readHeartRate(arguments: [:])
        async let mass = tools.readBodyMass(arguments: [:])
        stepsSummary = await steps
        heartRateSummary = await heart
        bodyMassSummary = await mass
    }

    func logWater(_ text: String) async {
        guard let ml = Double(text) else { return }
        await runWrite { await self.tools.writeDietaryWater(arguments: ["ml": ml]) }
    }

    func logBodyMass(_ text: String) async {
        guard let kg = Double(text) else { return }
        await runWrite { await self.tools.writeBodyMass(arguments: ["value": kg, "unit": "kg"]) }
    }

    private func runWrite(_ operation: () async -> String) async {
        guard !isWriting else { return }
        isWriting = true
        writeResult = nil
        defer { isWriting = false }

        let result = await operation()
        // Tool methods prefix failures with "[Error]".
        writeSucceeded = !result.hasPrefix("[Error]")
        writeResult = result
    }
}
