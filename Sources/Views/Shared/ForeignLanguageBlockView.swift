import SwiftUI
import NaturalLanguage
#if canImport(Translation)
import Translation
#endif

/// Renders a contiguous run of foreign-language blocks as one
/// de-emphasized box with an expand toggle and an in-place translate
/// affordance. Tapping translate rewrites the block contents using
/// `TranslationSession` (macOS 14.4+/iOS 17.4+) — no popup. After
/// translation a "原文" toggle restores the source text.
struct ForeignLanguageBlockView<Content: View>: View {
    let language: NLLanguage
    let blocks: [ContentBlock]
    @ViewBuilder let content: ([ContentBlock]) -> Content

    @State private var expanded = false
    @State private var translatedBlocks: [ContentBlock]? = nil
    @State private var showingOriginal = false
    @State private var isTranslating = false

    private var displayBlocks: [ContentBlock] {
        if let translated = translatedBlocks, !showingOriginal {
            return translated
        }
        return blocks
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            header

            if expanded {
                VStack(alignment: .leading, spacing: 10) {
                    content(displayBlocks)
                }
                .padding(.top, 2)
            }
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.secondary.opacity(0.06))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(Color.secondary.opacity(0.18), lineWidth: 0.5)
        )
        .opacity(expanded ? 1.0 : 0.78)
        .animation(.easeInOut(duration: 0.18), value: expanded)
    }

    private var header: some View {
        HStack(spacing: 8) {
            Button {
                expanded.toggle()
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 10, weight: .semibold))
                        .rotationEffect(.degrees(expanded ? 90 : 0))
                    Image(systemName: "globe")
                        .font(.system(size: 11, weight: .medium))
                    Text(languageDisplayName)
                        .font(.caption)
                        .fontWeight(.medium)
                    if !expanded {
                        Text("·")
                            .foregroundStyle(.tertiary)
                        Text(collapsedLabelText)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }
                }
                .foregroundStyle(.secondary)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            Spacer(minLength: 8)

            #if canImport(Translation)
            if #available(macOS 15.0, iOS 18.0, *) {
                TranslationControl(
                    language: language,
                    blocks: blocks,
                    translatedBlocks: $translatedBlocks,
                    showingOriginal: $showingOriginal,
                    isTranslating: $isTranslating,
                    onTranslateRequested: { expanded = true }
                )
            }
            #endif
        }
    }

    private var languageDisplayName: String {
        let code = language.rawValue
        if let name = Locale.current.localizedString(forLanguageCode: code), !name.isEmpty {
            return name.capitalized
        }
        return code.uppercased()
    }

    private var previewSnippet: String {
        let combined = blocks
            .compactMap { ForeignLanguageGrouping.textContent(of: $0) }
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if combined.count <= 60 { return combined }
        let idx = combined.index(combined.startIndex, offsetBy: 60)
        return String(combined[..<idx]) + "…"
    }

    private var collapsedLabelText: String {
        trailingJapaneseSummary ?? previewSnippet
    }

    /// Claude-style English preambles often end with a short Japanese
    /// aside that works well as a collapsed summary ("いい質問…",
    /// "要するに…"). Prefer showing that tail when present so the
    /// folded header hints at the answer, not just the original English.
    private var trailingJapaneseSummary: String? {
        guard let lastText = blocks
            .compactMap({ ForeignLanguageGrouping.textContent(of: $0) })
            .reversed()
            .first(where: { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) else {
            return nil
        }

        let lastLine = lastText
            .split(whereSeparator: \.isNewline)
            .map(String.init)
            .reversed()
            .first(where: { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty })
            ?? lastText

        guard let firstJapaneseIndex = lastLine.firstIndex(where: Self.containsJapaneseCharacter(in:)),
              firstJapaneseIndex != lastLine.startIndex else {
            return nil
        }

        let candidate = String(lastLine[firstJapaneseIndex...])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard candidate.count >= 4 else { return nil }

        if candidate.count <= 48 {
            return candidate
        }
        let endIndex = candidate.index(candidate.startIndex, offsetBy: 48)
        return String(candidate[..<endIndex]).trimmingCharacters(in: .whitespacesAndNewlines) + "…"
    }

    private static func containsJapaneseCharacter(in character: Character) -> Bool {
        character.unicodeScalars.contains { scalar in
            switch scalar.value {
            case 0x3040...0x309F,    // Hiragana
                 0x30A0...0x30FF,    // Katakana
                 0x3400...0x4DBF,    // CJK Extension A
                 0x4E00...0x9FFF,    // CJK Unified Ideographs
                 0x3000...0x303F:    // CJK punctuation
                return true
            default:
                return false
            }
        }
    }
}

#if canImport(Translation)
@available(macOS 15.0, iOS 18.0, *)
private struct TranslationControl: View {
    let language: NLLanguage
    let blocks: [ContentBlock]
    @Binding var translatedBlocks: [ContentBlock]?
    @Binding var showingOriginal: Bool
    @Binding var isTranslating: Bool
    let onTranslateRequested: () -> Void

    @State private var configuration: TranslationSession.Configuration?

    var body: some View {
        Button {
            handleTap()
        } label: {
            label
        }
        .buttonStyle(.borderless)
        .disabled(isTranslating)
        .translationTask(configuration) { session in
            await runTranslation(session: session)
        }
    }

    @ViewBuilder
    private var label: some View {
        if isTranslating {
            HStack(spacing: 4) {
                ProgressView()
                    .controlSize(.small)
                Text("翻訳中…")
                    .font(.caption)
            }
            .foregroundStyle(.secondary)
        } else if translatedBlocks != nil {
            Label(showingOriginal ? "翻訳を表示" : "原文を表示",
                  systemImage: showingOriginal ? "character.bubble" : "arrow.uturn.backward")
                .font(.caption)
                .foregroundStyle(.secondary)
        } else {
            Label("翻訳", systemImage: "character.bubble")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func handleTap() {
        if translatedBlocks != nil {
            // Already translated — toggle original/translated view.
            showingOriginal.toggle()
            return
        }
        onTranslateRequested()
        isTranslating = true
        // Setting (or invalidating) the configuration is what fires
        // `.translationTask`. First tap creates one; future tap-after-
        // failure invalidates to retry the same session.
        if configuration == nil {
            configuration = TranslationSession.Configuration(
                source: Locale.Language(identifier: language.rawValue),
                target: nil
            )
        } else {
            configuration?.invalidate()
        }
    }

    private func runTranslation(session: TranslationSession) async {
        let textBlocks: [(index: Int, text: String)] = blocks.enumerated().compactMap { i, b in
            guard let t = ForeignLanguageGrouping.textContent(of: b) else { return nil }
            return (i, t)
        }
        var result = blocks
        do {
            for entry in textBlocks {
                let response = try await session.translate(entry.text)
                result[entry.index] = Self.replaceText(in: result[entry.index], with: response.targetText)
            }
            await MainActor.run {
                translatedBlocks = result
                showingOriginal = false
                isTranslating = false
            }
        } catch {
            await MainActor.run {
                isTranslating = false
            }
        }
    }

    private static func replaceText(in block: ContentBlock, with newText: String) -> ContentBlock {
        switch block {
        case .paragraph:
            return .paragraph(newText)
        case .heading(let level, _):
            return .heading(level: level, text: newText)
        case .listItem(let ordered, let depth, _, let marker):
            return .listItem(ordered: ordered, depth: depth, text: newText, marker: marker)
        case .blockquote:
            return .blockquote(newText)
        case .table, .code, .math, .horizontalRule:
            return block
        }
    }
}
#endif
