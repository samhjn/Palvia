import SwiftUI

struct HighlightedTextEditor: UIViewRepresentable {
    @Binding var text: String
    let language: String

    static let codeFont = UIFont.monospacedSystemFont(ofSize: 14, weight: .regular)

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIView(context: Context) -> UITextView {
        let tv = UITextView()
        tv.delegate = context.coordinator
        tv.font = Self.codeFont
        tv.typingAttributes = [.font: Self.codeFont, .foregroundColor: UIColor.label]
        tv.backgroundColor = .clear
        tv.isScrollEnabled = false
        tv.autocapitalizationType = .none
        tv.autocorrectionType = .no
        tv.smartDashesType = .no
        tv.smartQuotesType = .no
        tv.smartInsertDeleteType = .no
        tv.textContainerInset = UIEdgeInsets(top: 8, left: 4, bottom: 8, right: 4)
        tv.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        tv.text = text
        context.coordinator.fullHighlight(tv)
        return tv
    }

    func updateUIView(_ tv: UITextView, context: Context) {
        guard !tv.isFirstResponder, tv.text != text else { return }
        tv.text = text
        context.coordinator.fullHighlight(tv)
    }

    func sizeThatFits(_ proposal: ProposedViewSize, uiView: UITextView, context: Context) -> CGSize? {
        let width = proposal.width ?? uiView.frame.width
        guard width > 0 else { return nil }
        let size = uiView.sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude))
        return CGSize(width: width, height: max(size.height, 120))
    }

    final class Coordinator: NSObject, UITextViewDelegate {
        var parent: HighlightedTextEditor

        init(_ parent: HighlightedTextEditor) { self.parent = parent }

        func textViewDidChange(_ textView: UITextView) {
            parent.text = textView.text
            colorOnly(textView)
        }

        func textViewDidChangeSelection(_ textView: UITextView) {
            textView.typingAttributes = [
                .font: HighlightedTextEditor.codeFont,
                .foregroundColor: UIColor.label
            ]
        }

        func fullHighlight(_ tv: UITextView) {
            let len = tv.textStorage.length
            guard len > 0 else { return }
            let fullRange = NSRange(location: 0, length: len)
            tv.textStorage.beginEditing()
            tv.textStorage.addAttribute(.font, value: HighlightedTextEditor.codeFont, range: fullRange)
            applyColors(tv.textStorage, code: tv.text ?? "", length: len)
            tv.textStorage.endEditing()
        }

        func colorOnly(_ tv: UITextView) {
            let len = tv.textStorage.length
            guard len > 0 else { return }
            tv.textStorage.beginEditing()
            applyColors(tv.textStorage, code: tv.text ?? "", length: len)
            tv.textStorage.endEditing()
        }

        private func applyColors(_ storage: NSTextStorage, code: String, length: Int) {
            storage.addAttribute(.foregroundColor, value: UIColor.label, range: NSRange(location: 0, length: length))
            let tokens = SyntaxHighlighter.tokenize(code: code, language: parent.language)
            var loc = 0
            for (tok, type) in tokens {
                let tLen = (tok as NSString).length
                guard tLen > 0 else { continue }
                if type != .plain {
                    storage.addAttribute(
                        .foregroundColor,
                        value: SyntaxHighlighter.uiColor(for: type),
                        range: NSRange(location: loc, length: tLen)
                    )
                }
                loc += tLen
            }
        }
    }
}
