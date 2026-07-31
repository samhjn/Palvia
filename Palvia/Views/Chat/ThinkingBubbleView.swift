import SwiftUI

struct ThinkingBubbleView: View {
    let content: String
    let isStreaming: Bool

    /// Keep a long, fast reasoning stream from continuously changing the
    /// outer chat scroll view's content height. The newest part remains
    /// visible while streaming; after completion the full trace is available
    /// when the user expands the collapsed card.
    static let streamingContentMaxHeight: CGFloat = 280

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

                if isStreaming {
                    thinkingContent
                        // Measure the complete Markdown at its natural height,
                        // then show a bottom-aligned window onto the newest
                        // reasoning. Once the window reaches this height,
                        // further deltas no longer resize the outer chat list.
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxHeight: Self.streamingContentMaxHeight, alignment: .bottom)
                        .clipped()
                        // Streaming deltas may arrive inside an animated
                        // transaction started elsewhere in the chat. Never
                        // interpolate this rapidly changing subtree.
                        .transaction {
                            $0.animation = nil
                            $0.disablesAnimations = true
                        }
                } else {
                    thinkingContent
                }
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
            guard oldValue != newValue else { return }

            // Automatic expansion/collapse can remove hundreds of points from
            // the row. Animating that change while the parent keeps itself
            // bottom-anchored makes the two layouts fight and visibly bounce.
            var transaction = Transaction(animation: nil)
            transaction.disablesAnimations = true
            withTransaction(transaction) {
                isExpanded = newValue
            }
        }
    }

    private var thinkingContent: some View {
        MarkdownContentView(content, isUser: false)
            .font(.callout)
            .foregroundStyle(.secondary)
            .padding(10)
    }
}
