import SwiftUI

struct MarkdownEditorView: View {
    @Binding var content: String
    let title: String
    @State private var isEditing = false

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(title)
                    .font(.subheadline)
                    .fontWeight(.semibold)
                    .foregroundStyle(.secondary)
                Spacer()
                Button {
                    isEditing.toggle()
                } label: {
                    Label(
                        isEditing ? L10n.MarkdownEditor.preview : L10n.MarkdownEditor.edit,
                        systemImage: isEditing ? "eye" : "pencil"
                    )
                    .font(.subheadline)
                }
            }
            .padding(.horizontal)
            .padding(.vertical, 8)

            Divider()

            if isEditing {
                TextEditor(text: $content)
                    .font(.system(.body, design: .monospaced))
                    .scrollContentBackground(.hidden)
                    .padding(8)
            } else {
                ScrollView {
                    if content.isEmpty {
                        Text(L10n.Common.empty)
                            .font(.body)
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding()
                    } else {
                        MarkdownContentView(content)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding()
                    }
                }
            }
        }
    }
}
