import SwiftUI

private struct LaunchTaskOverlayModifier: ViewModifier {
    let manager: LaunchTaskManager

    @State private var visible = false

    func body(content: Content) -> some View {
        content.overlay(alignment: .top) {
            if visible, case .running(let description, let progress) = manager.phase {
                HStack(spacing: 8) {
                    ProgressView()
                        .controlSize(.small)
                    Text(description)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    if let progress {
                        Text("\(Int(progress * 100))%")
                            .font(.caption)
                            .monospacedDigit()
                            .foregroundStyle(.tertiary)
                    }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background(.ultraThinMaterial, in: Capsule())
                .padding(.top, 6)
                .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .animation(.easeInOut(duration: 0.3), value: visible)
        .onChange(of: manager.phase) { _, newPhase in
            switch newPhase {
            case .running:
                visible = true
            case .done:
                Task { @MainActor in
                    try? await Task.sleep(for: .milliseconds(600))
                    visible = false
                }
            case .idle:
                visible = false
            }
        }
    }
}

extension View {
    func launchTaskOverlay(manager: LaunchTaskManager) -> some View {
        modifier(LaunchTaskOverlayModifier(manager: manager))
    }
}
