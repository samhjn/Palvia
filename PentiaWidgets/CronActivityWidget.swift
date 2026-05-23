import ActivityKit
import SwiftUI
import WidgetKit

/// Widget extension that renders the background-task Live Activity on the
/// Lock Screen and Dynamic Island.
@main
struct CronActivityWidgetBundle: WidgetBundle {
    var body: some Widget {
        CronActivityWidget()
    }
}

struct CronActivityWidget: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: CronActivityAttributes.self) { context in
            // Lock Screen / banner presentation
            lockScreenView(context: context)
        } dynamicIsland: { context in
            DynamicIsland {
                // Expanded regions
                DynamicIslandExpandedRegion(.leading) {
                    Image(systemName: leadingIcon(context: context))
                        .font(.title2)
                        .foregroundStyle(leadingColor(context: context))
                }
                DynamicIslandExpandedRegion(.trailing) {
                    if context.state.activeAgentCount > 0 {
                        Text("\(context.state.activeAgentCount)")
                            .font(.title2.bold())
                            .foregroundStyle(.blue)
                    }
                }
                DynamicIslandExpandedRegion(.center) {
                    if !context.state.sessionName.isEmpty {
                        Text(context.state.sessionName)
                            .font(.headline)
                            .lineLimit(1)
                    }
                }
                DynamicIslandExpandedRegion(.bottom) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(context.state.statusText)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                        if !context.state.statusBrief.isEmpty {
                            briefRow(state: context.state)
                        }
                    }
                }
            } compactLeading: {
                Image(systemName: leadingIcon(context: context))
                    .foregroundStyle(leadingColor(context: context))
            } compactTrailing: {
                if context.state.isCompleted || context.state.isError {
                    Image(systemName: context.state.isError ? "xmark.circle.fill" : "checkmark.circle.fill")
                        .foregroundStyle(context.state.isError ? .red : .green)
                } else if !context.state.statusBriefIcon.isEmpty {
                    Image(systemName: context.state.statusBriefIcon)
                        .foregroundStyle(.blue)
                } else {
                    Text("\(context.state.activeAgentCount)")
                        .font(.caption.bold())
                        .foregroundStyle(.blue)
                }
            } minimal: {
                Image(systemName: minimalIcon(context: context))
                    .foregroundStyle(leadingColor(context: context))
            }
        }
    }

    // MARK: - Helpers

    private func leadingIcon(context: ActivityViewContext<CronActivityAttributes>) -> String {
        if context.state.isError {
            return "xmark.circle.fill"
        } else if context.state.isCompleted {
            return "checkmark.circle.fill"
        } else {
            return "bolt.fill"
        }
    }

    /// Minimal presentation uses the brief icon when available so the user can
    /// glance what the agent is doing; falls back to the generic bolt otherwise.
    private func minimalIcon(context: ActivityViewContext<CronActivityAttributes>) -> String {
        if context.state.isError { return "xmark.circle.fill" }
        if context.state.isCompleted { return "checkmark.circle.fill" }
        if !context.state.statusBriefIcon.isEmpty { return context.state.statusBriefIcon }
        return "bolt.fill"
    }

    private func leadingColor(context: ActivityViewContext<CronActivityAttributes>) -> Color {
        if context.state.isError {
            return .red
        } else if context.state.isCompleted {
            return .green
        } else {
            return .blue
        }
    }

    @ViewBuilder
    private func briefRow(state: CronActivityAttributes.ContentState) -> some View {
        HStack(spacing: 6) {
            if !state.statusBriefIcon.isEmpty {
                Image(systemName: state.statusBriefIcon)
                    .font(.caption2)
                    .foregroundStyle(.blue)
            }
            Text(state.statusBrief)
                .font(.caption2)
                .foregroundStyle(.primary)
                .lineLimit(1)
        }
    }

    // MARK: - Lock Screen

    @ViewBuilder
    private func lockScreenView(context: ActivityViewContext<CronActivityAttributes>) -> some View {
        HStack(spacing: 12) {
            Image(systemName: leadingIcon(context: context))
                .font(.title2)
                .foregroundStyle(leadingColor(context: context))

            VStack(alignment: .leading, spacing: 2) {
                if !context.state.sessionName.isEmpty {
                    Text(context.state.sessionName)
                        .font(.headline)
                        .lineLimit(1)
                }
                Text(context.state.statusText)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                if !context.state.statusBrief.isEmpty {
                    briefRow(state: context.state)
                }
            }

            Spacer()

            if context.state.activeAgentCount > 0 {
                Text("\(context.state.activeAgentCount)")
                    .font(.title2.bold())
                    .foregroundStyle(.blue)
            }
        }
        .padding()
    }
}
