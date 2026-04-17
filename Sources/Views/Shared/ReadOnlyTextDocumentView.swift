import SwiftUI

struct ReadOnlyTextDocumentView: View {
    let text: String

    var body: some View {
        PlatformReadOnlyTextView(text: text)
            .background(PlatformDocumentColors.background)
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .stroke(PlatformDocumentColors.border, lineWidth: 1)
            )
    }
}

#if os(macOS)
private struct PlatformReadOnlyTextView: NSViewRepresentable {
    let text: String

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder

        let textView = NSTextView()
        textView.isEditable = false
        textView.isSelectable = true
        textView.drawsBackground = false
        textView.isRichText = false
        textView.importsGraphics = false
        textView.usesFindBar = true
        textView.allowsUndo = false
        textView.font = .monospacedSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
        textView.textContainerInset = NSSize(width: 16, height: 16)
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.lineFragmentPadding = 0
        textView.string = text

        scrollView.documentView = textView
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = scrollView.documentView as? NSTextView else {
            return
        }

        if textView.string != text {
            textView.string = text
        }
    }
}

private enum PlatformDocumentColors {
    static let background = Color(nsColor: .textBackgroundColor)
    static let border = Color.gray.opacity(0.18)
}
#else
private struct PlatformReadOnlyTextView: UIViewRepresentable {
    let text: String

    func makeUIView(context: Context) -> UITextView {
        let textView = UITextView()
        textView.isEditable = false
        textView.isSelectable = true
        textView.backgroundColor = .secondarySystemBackground
        textView.font = .monospacedSystemFont(ofSize: UIFont.systemFontSize, weight: .regular)
        textView.textContainerInset = UIEdgeInsets(top: 16, left: 16, bottom: 16, right: 16)
        textView.text = text
        return textView
    }

    func updateUIView(_ textView: UITextView, context: Context) {
        if textView.text != text {
            textView.text = text
        }
    }
}

private enum PlatformDocumentColors {
    static let background = Color(uiColor: .secondarySystemBackground)
    static let border = Color.gray.opacity(0.18)
}
#endif
