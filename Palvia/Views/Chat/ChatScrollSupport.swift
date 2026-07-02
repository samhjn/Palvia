import SwiftUI
import UIKit

// MARK: - Scroll Geometry

/// Pure scroll geometry shared by the chat scroll pipeline
/// (`ScrollViewOffsetObserver.Coordinator`, `ChatScrollState` and the
/// SwiftUI handlers in `ChatContentView`). Extracted so the bottom-anchoring
/// math is unit-testable without a live scroll view.
enum ChatScrollGeometry {
    /// Residual distance below which the view counts as settled at the bottom.
    static let bottomTolerance: CGFloat = 2
    /// Near-bottom threshold while the user's finger is on the scroll view.
    /// Also the threshold that flips `userDidScrollAway` on user gestures.
    static let userScrollThreshold: CGFloat = 50
    /// Wider near-bottom threshold used for programmatic movement and
    /// deceleration, so rendering-induced shifts don't flap the state.
    static let idleThreshold: CGFloat = 200

    /// Highest legal contentOffset.y; anything beyond shows blank space
    /// below the content.
    static func maxOffsetY(contentHeight: CGFloat,
                           boundsHeight: CGFloat,
                           adjustedTopInset: CGFloat,
                           adjustedBottomInset: CGFloat) -> CGFloat {
        max(-adjustedTopInset, contentHeight + adjustedBottomInset - boundsHeight)
    }

    /// Signed distance from the current offset to the bottom of the content.
    /// Negative means over-scrolled past the end: blank space is visible and
    /// no user content remains below the viewport.
    static func distanceToBottom(contentHeight: CGFloat,
                                 boundsHeight: CGFloat,
                                 adjustedTopInset: CGFloat,
                                 adjustedBottomInset: CGFloat,
                                 offsetY: CGFloat) -> CGFloat {
        maxOffsetY(contentHeight: contentHeight,
                   boundsHeight: boundsHeight,
                   adjustedTopInset: adjustedTopInset,
                   adjustedBottomInset: adjustedBottomInset) - offsetY
    }

    /// Near-bottom decision with interaction-dependent thresholds.
    static func isNearBottom(distance: CGFloat, isUserScrolling: Bool) -> Bool {
        distance <= (isUserScrolling ? userScrollThreshold : idleThreshold)
    }

    static func maxOffsetY(_ sv: UIScrollView) -> CGFloat {
        maxOffsetY(contentHeight: sv.contentSize.height,
                   boundsHeight: sv.bounds.height,
                   adjustedTopInset: sv.adjustedContentInset.top,
                   adjustedBottomInset: sv.adjustedContentInset.bottom)
    }

    static func distanceToBottom(_ sv: UIScrollView) -> CGFloat {
        maxOffsetY(sv) - sv.contentOffset.y
    }

    /// True while the scroll view is moving because of the user (finger down
    /// or momentum from a flick).
    static func isUserDriven(_ sv: UIScrollView) -> Bool {
        sv.isTracking || sv.isDragging || sv.isDecelerating
    }
}

// MARK: - Message Filtering

/// The single source of truth for which messages are visible in each display
/// mode. `ChatContentView.filteredMessages()` and the tests both call this,
/// so the view and the test suite can never drift apart.
/// Mirrored by `MessageBubbleView.shouldHideInSilentMode`.
enum ChatMessageFilter {
    /// Silent mode hides tool results and content-less assistant messages
    /// whose only payload is tool calls. Verbose mode shows everything.
    static func visibleMessages(_ messages: [Message], isVerbose: Bool) -> [Message] {
        guard !isVerbose else { return messages }
        return messages.filter { isVisibleInSilentMode($0) }
    }

    static func isVisibleInSilentMode(_ msg: Message) -> Bool {
        if msg.role == .tool { return false }
        if msg.role == .assistant,
           let data = msg.toolCallsData,
           data.count > 2,
           (msg.content ?? "").isEmpty {
            return false
        }
        return true
    }

    /// Resolve `target` to the nearest message that survives filtering:
    /// the target itself if visible, else the closest visible predecessor,
    /// else the first / last displayed message. Returns nil only when
    /// nothing is displayed at all.
    static func nearestVisibleId(to target: UUID, all: [Message], displayed: [Message]) -> UUID? {
        if displayed.contains(where: { $0.id == target }) { return target }
        guard let idx = all.firstIndex(where: { $0.id == target }) else { return displayed.last?.id }
        let visibleIds = Set(displayed.map(\.id))
        for i in stride(from: idx, through: 0, by: -1) {
            if visibleIds.contains(all[i].id) { return all[i].id }
        }
        return displayed.first?.id
    }
}
