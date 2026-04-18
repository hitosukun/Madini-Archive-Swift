import SwiftUI

struct SearchResultRowView: View {
    let result: SearchResult
    var onToggleBookmark: (() -> Void)? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(result.displayTitle)
                .font(.headline)
                .lineLimit(2)

            HStack(spacing: 8) {
                BookmarkToggleButton(
                    isBookmarked: result.isBookmarked,
                    action: onToggleBookmark
                )

                // Model preferred, source fallback — same rule as
                // `ConversationRowView`. Model pill inherits the service's
                // brand color so an explicit `source` next to it would be
                // redundant.
                if let model = result.model {
                    Text(model)
                        .font(.caption)
                        .foregroundStyle(SourceAppearance.color(forModel: model))
                        .lineLimit(1)
                } else if let source = result.source {
                    SourceText(source: source)
                }

                Spacer()

                if let primaryTime = result.primaryTime {
                    Text(String(primaryTime.prefix(10)))
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .monospacedDigit()
                }
            }

            Text(cleanedSnippet)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .lineLimit(3)
        }
        .padding(.vertical, 4)
    }

    private var cleanedSnippet: String {
        result.snippet
            .replacingOccurrences(of: "[", with: "")
            .replacingOccurrences(of: "]", with: "")
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
