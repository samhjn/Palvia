import SwiftUI

struct CodeBlockView: View {
    let code: String
    let language: String

    @State private var copied = false
    @State private var highlighted: AttributedString?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                Text(language.uppercased())
                    .font(.system(size: 10, weight: .semibold, design: .monospaced))
                    .foregroundStyle(.tertiary)
                Spacer()
                Button {
                    UIPasteboard.general.string = code
                    withAnimation(.easeInOut(duration: 0.15)) { copied = true }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.8) {
                        withAnimation(.easeInOut(duration: 0.15)) { copied = false }
                    }
                } label: {
                    Image(systemName: copied ? "checkmark" : "doc.on.doc")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(copied ? Color.green : Color(.tertiaryLabel))
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 12)
            .padding(.top, 8)
            .padding(.bottom, 2)

            ScrollView(.horizontal, showsIndicators: false) {
                Group {
                    if let highlighted {
                        Text(highlighted)
                    } else {
                        Text(code)
                    }
                }
                .font(.system(size: 13, design: .monospaced))
                .textSelection(.enabled)
                .padding(.horizontal, 12)
                .padding(.bottom, 10)
            }
        }
        .background(Color(.secondarySystemFill))
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .task(id: code + language) {
            let src = code
            let lang = language
            let result = await Task.detached(priority: .userInitiated) {
                SyntaxHighlighter.highlight(code: src, language: lang)
            }.value
            highlighted = result
        }
    }
}
