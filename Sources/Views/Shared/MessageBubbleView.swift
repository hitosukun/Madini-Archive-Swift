import SwiftUI

struct MessageBubbleView: View {
    enum DisplayMode {
        case rendered
        case plain
    }

    private enum Layout {
        static let avatarSize: CGFloat = 34
        static let avatarColumnWidth: CGFloat = 42
        static let maxRenderedMessageLength = 12_000
        static let maxRenderedTextBlockLength = 8_000
    }

    let message: Message
    let displayMode: DisplayMode
    let identityContext: MessageIdentityContext?
    @Environment(IdentityPreferencesStore.self) private var identityPreferences

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            if message.isUser {
                messageColumn

                IdentityAvatarView(
                    presentation: identityPresentation,
                    size: Layout.avatarSize
                )
                .frame(width: Layout.avatarColumnWidth, alignment: .topTrailing)
            } else {
                IdentityAvatarView(
                    presentation: identityPresentation,
                    size: Layout.avatarSize
                )
                .frame(width: Layout.avatarColumnWidth, alignment: .topLeading)

                messageColumn
            }
        }
    }

    private var messageColumn: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                if message.isUser {
                    Spacer()
                }

                Text(identityPresentation.displayName)
                    .font(.caption)
                    .fontWeight(.semibold)
                    .foregroundStyle(identityPresentation.accentColor)

                if !message.isUser {
                    Spacer()
                }
            }

            VStack(alignment: .leading, spacing: 8) {
                if displayMode == .plain {
                    Text(verbatim: message.content)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    ForEach(Array(contentBlocks.enumerated()), id: \.offset) { _, block in
                        switch block {
                        case .text(let text):
                            if canRenderMarkdown(text) {
                                Text(renderMarkdown(text))
                                    .textSelection(.enabled)
                            } else {
                                Text(verbatim: text)
                                    .textSelection(.enabled)
                            }
                        case .code(let language, let code):
                            CodeBlockView(language: language, code: code)
                        }
                    }
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(bubbleBackground)
            .clipShape(RoundedRectangle(cornerRadius: 8))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var identityPresentation: MessageIdentityPresentation {
        identityPreferences.presentation(for: message.role, context: identityContext)
    }

    private var bubbleBackground: Color {
        message.isUser ? Color.accentColor.opacity(0.08) : PlatformColors.controlBackground
    }

    private var contentBlocks: [ContentBlock] {
        guard canRenderMessage else {
            return [.text(message.content)]
        }
        return ContentBlock.parse(message.content)
    }

    private var canRenderMessage: Bool {
        message.content.count <= Layout.maxRenderedMessageLength
    }

    private func renderMarkdown(_ text: String) -> AttributedString {
        let options = AttributedString.MarkdownParsingOptions(
            interpretedSyntax: .inlineOnlyPreservingWhitespace
        )
        return (try? AttributedString(markdown: text, options: options)) ?? AttributedString(text)
    }

    private func canRenderMarkdown(_ text: String) -> Bool {
        text.count <= Layout.maxRenderedTextBlockLength
    }
}

enum ContentBlock {
    case text(String)
    case code(language: String?, code: String)

    static func parse(_ content: String) -> [ContentBlock] {
        var blocks: [ContentBlock] = []
        var currentTextLines: [String] = []
        var currentCodeLines: [String] = []
        var currentLanguage: String?
        var inCodeBlock = false

        for line in content.components(separatedBy: "\n") {
            if !inCodeBlock && line.hasPrefix("```") {
                if !currentTextLines.isEmpty {
                    let text = currentTextLines.joined(separator: "\n")
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    if !text.isEmpty {
                        blocks.append(.text(text))
                    }
                    currentTextLines.removeAll()
                }

                let language = String(line.dropFirst(3)).trimmingCharacters(in: .whitespaces)
                currentLanguage = language.isEmpty ? nil : language
                inCodeBlock = true
                continue
            }

            if inCodeBlock && line.hasPrefix("```") {
                blocks.append(.code(language: currentLanguage, code: currentCodeLines.joined(separator: "\n")))
                currentCodeLines.removeAll()
                currentLanguage = nil
                inCodeBlock = false
                continue
            }

            if inCodeBlock {
                currentCodeLines.append(line)
            } else {
                currentTextLines.append(line)
            }
        }

        if inCodeBlock {
            blocks.append(.code(language: currentLanguage, code: currentCodeLines.joined(separator: "\n")))
        } else {
            let text = currentTextLines.joined(separator: "\n")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty {
                blocks.append(.text(text))
            }
        }

        return blocks
    }
}

private struct CodeBlockView: View {
    let language: String?
    let code: String

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let language, !language.isEmpty {
                Text(language)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 10)
                    .padding(.top, 6)
                    .padding(.bottom, 2)
            }

            ScrollView(.horizontal, showsIndicators: true) {
                Text(code)
                    .font(.system(.callout, design: .monospaced))
                    .textSelection(.enabled)
                    .padding(10)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(PlatformColors.textBackground.opacity(0.5))
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .stroke(Color.gray.opacity(0.2), lineWidth: 1)
        )
    }
}

private enum PlatformColors {
    #if os(macOS)
    static let controlBackground = Color(nsColor: .controlBackgroundColor)
    static let textBackground = Color(nsColor: .textBackgroundColor)
    #else
    static let controlBackground = Color(uiColor: .secondarySystemBackground)
    static let textBackground = Color(uiColor: .systemBackground)
    #endif
}
