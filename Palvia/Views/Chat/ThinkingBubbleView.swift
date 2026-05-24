import SwiftUI

struct ThinkingBubbleView: View {
    let content: String
    let isStreaming: Bool

    @State private var isExpanded = false
    @State private var hasBeenManuallyToggled = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                withAnimation(.easeInOut(duration: 0.2)) {
                    isExpanded.toggle()
                    hasBeenManuallyToggled = true
                }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "brain.head.profile")
                        .font(.caption)
                        .foregroundStyle(.purple.opacity(0.8))

                    Text(L10n.Chat.thinkingProcess)
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.secondary)

                    if isStreaming {
                        ProgressView()
                            .controlSize(.mini)
                    }

                    Spacer()

                    Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 10)
            .padding(.vertical, 8)

            if isExpanded {
                Divider()
                    .padding(.horizontal, 8)

                MarkdownContentView(content, isUser: false)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .padding(10)
            }
        }
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(Color.purple.opacity(0.06))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(Color.purple.opacity(0.15), lineWidth: 0.5)
        )
        .onAppear {
            if isStreaming && !hasBeenManuallyToggled {
                isExpanded = true
            }
        }
        .onChange(of: isStreaming) { oldValue, newValue in
            guard !hasBeenManuallyToggled else { return }
            if !oldValue && newValue {
                withAnimation { isExpanded = true }
            } else if oldValue && !newValue {
                withAnimation(.easeInOut(duration: 0.3)) {
                    isExpanded = false
                }
            }
        }
    }
}
