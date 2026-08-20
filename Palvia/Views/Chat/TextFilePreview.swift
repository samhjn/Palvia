import SwiftUI
import UIKit

// MARK: - Coordinator

@Observable
final class TextFilePreviewCoordinator {
    static let shared = TextFilePreviewCoordinator()

    private(set) var content: String?
    private(set) var filename: String = ""
    private(set) var lineCount: Int = 0
    private(set) var isMarkdown: Bool = false
    private(set) var isPresented = false

    func show(content: String, filename: String, lineCount: Int? = nil) {
        UIApplication.shared.sendAction(
            #selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil
        )
        self.content = content
        self.filename = filename
        self.lineCount = lineCount ?? TextFilePreviewDocument.countLines(in: content)
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
            self?.lineCount = 0
        }
    }

    /// Extensions treated as text files that can be previewed.
    static let textExtensions: Set<String> = [
        "txt", "md", "markdown", "log", "json", "xml", "csv", "yaml", "yml",
        "js", "py", "swift", "html", "css", "ts", "tsx", "jsx",
        "sh", "bash", "zsh", "rb", "go", "rs", "c", "cpp", "h", "hpp",
        "java", "kt", "toml", "ini", "cfg", "conf", "env", "gitignore",
        "dockerfile", "makefile", "sql", "graphql", "r", "lua", "luau", "pl",
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
                    lineCount: coordinator.lineCount,
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
    let lineCount: Int
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
            .accessibilityIdentifier(AccessibilityID.TextFilePreview.closeButton)

            Spacer()

            VStack(spacing: 1) {
                Text(filename)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
                Text(formattedLineCount)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier(AccessibilityID.TextFilePreview.lineCount)
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
        "\(lineCount) line\(lineCount == 1 ? "" : "s")"
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
            PlainTextFileView(content: content)
        }
    }

    private func flashToast(_ message: String) {
        withAnimation { toastMessage = message }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            withAnimation { toastMessage = nil }
        }
    }
}

// MARK: - Large Plain-Text Rendering

/// A TextKit 2-backed viewer for source files and other large plain-text files.
///
/// A single SwiftUI `Text` inside a two-axis `ScrollView` eagerly lays out the
/// entire selectable string. Real source files with thousands of lines can
/// therefore monopolize the main thread long enough for the app to appear
/// frozen. `UITextView` owns its scrolling and TextKit 2 lays out the visible
/// viewport incrementally.
struct PlainTextFileView: UIViewRepresentable {
    let content: String

    static let codeFont = UIFont.monospacedSystemFont(ofSize: 13, weight: .regular)

    func makeUIView(context: Context) -> UITextView {
        Self.makeTextView(content: content)
    }

    func updateUIView(_ textView: UITextView, context: Context) {
        guard textView.text != content else { return }

        let oldOffset = textView.contentOffset
        let oldSelection = textView.selectedRange
        textView.text = content
        let newLength = (content as NSString).length
        let selectionLocation = min(oldSelection.location, newLength)
        textView.selectedRange = NSRange(
            location: selectionLocation,
            length: min(oldSelection.length, newLength - selectionLocation)
        )
        textView.setContentOffset(oldOffset, animated: false)
    }

    /// Kept internal so the regression test can verify the real UIKit viewer
    /// without needing to manufacture a `UIViewRepresentable.Context`.
    static func makeTextView(content: String) -> UITextView {
        let textView = UITextView(usingTextLayoutManager: true)
        textView.text = content
        textView.font = codeFont
        textView.textColor = .label
        textView.backgroundColor = .systemBackground
        textView.isEditable = false
        textView.isSelectable = true
        textView.isScrollEnabled = true
        textView.alwaysBounceVertical = true
        textView.showsVerticalScrollIndicator = true
        textView.textContainerInset = UIEdgeInsets(top: 16, left: 16, bottom: 16, right: 16)
        textView.textContainer.lineFragmentPadding = 0
        // Track the viewport width so TextKit can discard off-screen layout
        // fragments. Wrapping is also easier to navigate on a phone than a
        // second, nested horizontal scroll axis.
        textView.textContainer.widthTracksTextView = true

        textView.accessibilityIdentifier = AccessibilityID.TextFilePreview.content
        return textView
    }
}

// MARK: - Background File Loading

struct TextFilePreviewDocument: Sendable {
    let content: String
    let filename: String
    let lineCount: Int

    static func load(fileURL: URL, filename: String) async -> TextFilePreviewDocument? {
        await Task.detached(priority: .userInitiated) {
            guard let data = try? Data(contentsOf: fileURL, options: [.mappedIfSafe]),
                  let content = String(data: data, encoding: .utf8) else {
                return nil
            }
            return TextFilePreviewDocument(
                content: content,
                filename: filename,
                lineCount: countLines(in: content)
            )
        }.value
    }

    static func countLines(in content: String) -> Int {
        content.utf8.reduce(into: 1) { count, byte in
            if byte == 0x0A { count += 1 }
        }
    }
}
