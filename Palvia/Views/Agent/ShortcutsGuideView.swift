import SwiftUI

/// Guide view explaining how to set up Apple Shortcuts to trigger cron jobs reliably.
struct ShortcutsGuideView: View {
    let cronJob: CronJob?

    @Environment(\.dismiss) private var dismiss

    private var triggerURL: String {
        if let job = cronJob {
            return "iclaw://cron/trigger/\(job.id.uuidString)"
        }
        return "iclaw://cron/trigger/{JOB_ID}"
    }

    private var runAllURL: String {
        "iclaw://cron/run-due"
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    headerSection
                    whySection
                    appIntentSection
                    legacyFallbackHeader
                    setupSteps
                    urlReferenceSection
                    tipsSection
                }
                .padding()
            }
            .navigationTitle(L10n.Shortcuts.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(L10n.Common.done) { dismiss() }
                }
            }
        }
    }

    // MARK: - Sections

    private var headerSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 12) {
                Image(systemName: "shortcuts")
                    .font(.largeTitle)
                    .foregroundStyle(.blue)
                VStack(alignment: .leading) {
                    Text(L10n.Shortcuts.headerTitle)
                        .font(.headline)
                    Text(L10n.Shortcuts.headerSubtitle)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private var whySection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(L10n.Shortcuts.whyNeeded, systemImage: "questionmark.circle")
                .font(.headline)

            Text(L10n.Shortcuts.whyDescription)
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .padding()
        .background(RoundedRectangle(cornerRadius: 12).fill(Color(.systemGray6)))
    }

    private var appIntentSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            Label(L10n.Shortcuts.appIntentSection, systemImage: "lock.open.rotation")
                .font(.headline)
                .foregroundStyle(.green)

            Text(L10n.Shortcuts.appIntentDescription)
                .font(.subheadline)
                .foregroundStyle(.secondary)

            StepView(number: 1,
                     title: L10n.Shortcuts.appIntentStep1Title,
                     detail: L10n.Shortcuts.appIntentStep1Detail)
            StepView(number: 2,
                     title: L10n.Shortcuts.appIntentStep2Title,
                     detail: L10n.Shortcuts.appIntentStep2Detail)
            StepView(number: 3,
                     title: L10n.Shortcuts.appIntentStep3Title,
                     detail: L10n.Shortcuts.appIntentStep3Detail)
            StepView(number: 4,
                     title: L10n.Shortcuts.appIntentStep4Title,
                     detail: L10n.Shortcuts.appIntentStep4Detail)
        }
        .padding()
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(Color.green.opacity(0.08))
        )
    }

    private var legacyFallbackHeader: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(L10n.Shortcuts.legacyFallbackSection, systemImage: "exclamationmark.triangle")
                .font(.headline)
                .foregroundStyle(.orange)

            Text(L10n.Shortcuts.legacyFallbackDescription)
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .padding()
        .background(RoundedRectangle(cornerRadius: 12).fill(Color(.systemGray6)))
    }

    @ViewBuilder
    private var setupSteps: some View {
        VStack(alignment: .leading, spacing: 16) {
            Label(L10n.Shortcuts.setupSteps, systemImage: "list.number")
                .font(.headline)

            StepView(number: 1, title: L10n.Shortcuts.step1Title, detail: L10n.Shortcuts.step1Detail)

            StepView(number: 2, title: L10n.Shortcuts.step2Title, detail: L10n.Shortcuts.step2Detail)

            StepView(number: 3, title: L10n.Shortcuts.step3Title, detail: L10n.Shortcuts.step3Detail)

            StepView(number: 4, title: L10n.Shortcuts.step4Title, detail: L10n.Shortcuts.step4Detail)

            HStack {
                Text(triggerURL)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.blue)
                    .textSelection(.enabled)
                Spacer()
                Button {
                    UIPasteboard.general.string = triggerURL
                } label: {
                    Label(L10n.Common.copy, systemImage: "doc.on.doc")
                        .font(.caption)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
            .padding()
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color(.systemGray6))
            )

            StepView(number: 5, title: L10n.Shortcuts.step5Title, detail: L10n.Shortcuts.step5Detail)

            StepView(number: 6, title: L10n.Shortcuts.step6Title, detail: L10n.Shortcuts.step6Detail)
        }
    }

    private var urlReferenceSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(L10n.Shortcuts.urlReference, systemImage: "link")
                .font(.headline)

            VStack(alignment: .leading, spacing: 12) {
                URLRefRow(
                    label: L10n.Shortcuts.triggerSpecific,
                    url: triggerURL,
                    description: L10n.Shortcuts.triggerSpecificDesc
                )

                URLRefRow(
                    label: L10n.Shortcuts.runAllDue,
                    url: runAllURL,
                    description: L10n.Shortcuts.runAllDueDesc
                )
            }
        }
        .padding()
        .background(RoundedRectangle(cornerRadius: 12).fill(Color(.systemGray6)))
    }

    private var tipsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(L10n.Shortcuts.tips, systemImage: "lightbulb")
                .font(.headline)

            VStack(alignment: .leading, spacing: 6) {
                tipRow(L10n.Shortcuts.tip1)
                tipRow(L10n.Shortcuts.tip2)
                tipRow(L10n.Shortcuts.tip3)
                tipRow(L10n.Shortcuts.tip4)
            }
        }
    }

    private func tipRow(_ text: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text("•")
                .foregroundStyle(.secondary)
            Text(text)
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
    }
}

// MARK: - Helper Views

private struct StepView: View {
    let number: Int
    let title: String
    let detail: String

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Text("\(number)")
                .font(.caption)
                .fontWeight(.bold)
                .foregroundStyle(.white)
                .frame(width: 24, height: 24)
                .background(Circle().fill(Color.accentColor))

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.subheadline)
                    .fontWeight(.semibold)
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

private struct URLRefRow: View {
    let label: String
    let url: String
    let description: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label)
                .font(.subheadline)
                .fontWeight(.medium)
            HStack {
                Text(url)
                    .font(.system(.caption2, design: .monospaced))
                    .foregroundStyle(.blue)
                    .textSelection(.enabled)
                Spacer()
                Button {
                    UIPasteboard.general.string = url
                } label: {
                    Image(systemName: "doc.on.doc")
                        .font(.caption2)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
            }
            Text(description)
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
    }
}
