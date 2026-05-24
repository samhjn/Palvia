import SwiftUI
import UIKit

// MARK: - Coordinator

@Observable
final class TextFilePreviewCoordinator {
    static let shared = TextFilePreviewCoordinator()

    private(set) var content: String?
    private(set) var filename: String = ""
    private(set) var isMarkdown: Bool = false
    private(set) var isPresented = false

    func show(content: String, filename: String) {
        UIApplication.shared.sendAction(
            #selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil
        )
        self.content = content
        self.filename = filename
        self.isMarkdown = Self.markdownExtensions.contains(
            (filename as NSString).pathExtension.lowercased()
        )
        withAnimation(.easeOut(duration: 0.25)) {
            isPresented = true
        }
    }

    func close(animated: Bool = true) {
        if animated {
            withAnimation(.easeOut(duration: 0.15)) {
                isPresented = false
            }
        } else {
            isPresented = false
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
            self?.content = nil
            self?.filename = ""
        }
    }

    /// Extensions treated as text files that can be previewed.
    static let textExtensions: Set<String> = [
        "txt", "md", "markdown", "log", "json", "xml", "csv", "yaml", "yml",
        "js", "py", "swift", "html", "css", "ts", "tsx", "jsx",
        "sh", "bash", "zsh", "rb", "go", "rs", "c", "cpp", "h", "hpp",
        "java", "kt", "toml", "ini", "cfg", "conf", "env", "gitignore",
        "dockerfile", "makefile", "sql", "graphql", "r", "lua", "pl",
    ]

    private static let markdownExtensions: Set<String> = ["md", "markdown"]
}

// MARK: - Root Overlay Modifier

struct TextFilePreviewRootModifier: ViewModifier {
    private var coordinator: TextFilePreviewCoordinator { .shared }

    func body(content: Content) -> some View {
        content.overlay {
            if coordinator.isPresented, let text = coordinator.content {
                TextFilePreviewOverlay(
                    content: text,
                    filename: coordinator.filename,
                    isMarkdown: coordinator.isMarkdown
                )
                .transition(.opacity)
            }
        }
    }
}

extension View {
    func textFilePreviewOverlay() -> some View {
        modifier(TextFilePreviewRootModifier())
    }
}

// MARK: - Overlay

private struct TextFilePreviewOverlay: View {
    let content: String
    let filename: String
    let isMarkdown: Bool

    @State private var toastMessage: String?

    var body: some View {
        ZStack {
            Color(.systemBackground)
                .ignoresSafeArea()

            VStack(spacing: 0) {
                header
                Divider()
                fileContent
            }

            if let message = toastMessage {
                VStack {
                    Spacer()
                    Text(message)
                        .font(.callout)
                        .foregroundStyle(.white)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 8)
                        .background(Capsule().fill(.black.opacity(0.7)))
                        .padding(.bottom, 48)
                }
                .transition(.opacity)
                .allowsHitTesting(false)
            }
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack {
            Button {
                TextFilePreviewCoordinator.shared.close()
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.title2)
                    .symbolRenderingMode(.palette)
                    .foregroundStyle(.secondary, Color(.tertiarySystemFill))
            }

            Spacer()

            VStack(spacing: 1) {
                Text(filename)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
                Text(formattedLineCount)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Button {
                UIPasteboard.general.string = content
                flashToast(L10n.Common.copied)
            } label: {
                Image(systemName: "doc.on.doc")
                    .font(.title3)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    private var formattedLineCount: String {
        let count = content.components(separatedBy: "\n").count
        return "\(count) line\(count == 1 ? "" : "s")"
    }

    // MARK: - Content

    @ViewBuilder
    private var fileContent: some View {
        if isMarkdown {
            ScrollView {
                MarkdownContentView(content)
                    .padding(16)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        } else {
            ScrollView([.horizontal, .vertical]) {
                Text(content)
                    .font(.system(size: 13, design: .monospaced))
                    .textSelection(.enabled)
                    .padding(16)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private func flashToast(_ message: String) {
        withAnimation { toastMessage = message }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            withAnimation { toastMessage = nil }
        }
    }
}
