import SwiftUI
import HealthKit

/// A simple, discoverable Apple Health authorization screen.
///
/// Its only job is to make the HealthKit integration obvious and to let the
/// user (or an App Store reviewer) grant access directly — without using the
/// AI chat. Reuses the same `ApplePermissionManager` path the agent uses.
struct AppleHealthView: View {
    private let isAvailable = HKHealthStore.isHealthDataAvailable()

    @State private var isConnecting = false
    @State private var connected = false
    @State private var connectResult: String?

    var body: some View {
        List {
            introSection
            connectionSection
            dataTypesSection
        }
        .listStyle(.insetGrouped)
        .navigationTitle(L10n.AppleHealth.title)
        .navigationBarTitleDisplayMode(.inline)
    }

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

    private var connectionSection: some View {
        Section {
            Label(
                isAvailable ? L10n.AppleHealth.available : L10n.AppleHealth.unavailable,
                systemImage: isAvailable ? "checkmark.seal.fill" : "exclamationmark.triangle.fill"
            )
            .foregroundStyle(isAvailable ? .green : .orange)
            .font(.subheadline)

            Button {
                connect()
            } label: {
                HStack {
                    if isConnecting {
                        ProgressView()
                        Text(L10n.AppleHealth.connecting)
                    } else {
                        Image(systemName: "heart.text.square")
                        Text(L10n.AppleHealth.connectButton)
                    }
                }
            }
            .disabled(!isAvailable || isConnecting)
            .accessibilityIdentifier(AccessibilityID.AppleHealth.connectButton)

            if let connectResult {
                Text(connectResult)
                    .font(.caption)
                    .foregroundStyle(connected ? .green : .red)
            }
        } header: {
            Text(L10n.AppleHealth.connectionHeader)
        } footer: {
            Text(L10n.AppleHealth.connectFooter)
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

    private func connect() {
        guard !isConnecting else { return }
        isConnecting = true
        connectResult = nil
        Task {
            let error = await ApplePermissionManager.shared.ensureHealthAccess()
            isConnecting = false
            connected = (error == nil)
            connectResult = error ?? L10n.AppleHealth.connected
        }
    }
}
