import SwiftUI

/// Displays a session row using only pre-computed `SessionRowData`.
/// Reading @Model properties directly (session.isActive, session.title, etc.)
/// would register SwiftData observation tracking, causing the List's
/// UICollectionView to receive conflicting batch updates when the auto-refresh
/// timer and ChatViewModel-driven model changes fire in the same render cycle.
struct SessionRowView: View {
    let rowData: SessionRowData

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                if rowData.isActive {
                    PulsingDot()
                }
                Text(rowData.title)
                    .font(.headline)
                    .lineLimit(1)
                Spacer()
                Text(rowData.updatedAt, style: .relative)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            HStack {
                if let agentName = rowData.agentName {
                    Label(agentName, systemImage: "cpu")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                if rowData.isActive {
                    Text(L10n.Common.active)
                        .font(.caption2)
                        .foregroundStyle(.white)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 1)
                        .background(Capsule().fill(.green))
                }

                if rowData.hasDraft && !rowData.isActive {
                    Text(L10n.Sessions.draft)
                        .font(.caption2)
                        .foregroundStyle(.orange)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 1)
                        .background(Capsule().fill(.orange.opacity(0.12)))
                }

                Spacer()

                Text(L10n.Sessions.messagesCount(rowData.messageCount))
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }

            if let content = rowData.previewContent {
                Text(content)
                    .font(.subheadline)
                    .foregroundStyle(rowData.isStreaming ? .primary : .secondary)
                    .lineLimit(2)
            }
        }
        .padding(.vertical, 4)
    }
}

private struct PulsingDot: View {
    @State private var isPulsing = false

    var body: some View {
        Circle()
            .fill(.green)
            .frame(width: 8, height: 8)
            .scaleEffect(isPulsing ? 1.3 : 1.0)
            .opacity(isPulsing ? 0.6 : 1.0)
            .animation(.easeInOut(duration: 0.8).repeatForever(autoreverses: true), value: isPulsing)
            .onAppear { isPulsing = true }
    }
}
