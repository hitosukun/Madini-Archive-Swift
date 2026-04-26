import SwiftUI

/// Library-wide search keyword the toolbar field is currently
/// narrowing on. Surfaced through the environment so list views
/// (table titles, card titles, prompt outline snippets) and the
/// reader can paint a visual hit-confirmation on matched
/// substrings without each having to reach back into
/// `DesignMockRootView` for the parsed query.
///
/// Empty string = no highlight (the common default; SwiftUI views
/// reading this guard on `isEmpty` and skip the AttributedString
/// build path so renders stay cheap).
private struct LibraryHighlightQueryKey: EnvironmentKey {
    static let defaultValue: String = ""
}

extension EnvironmentValues {
    /// Free-text portion of the toolbar search (DSL directives like
    /// `source:` / `-model:` already stripped). Subviews compare a
    /// row's title or snippet against this and apply a yellow wash
    /// to matched substrings.
    var libraryHighlightQuery: String {
        get { self[LibraryHighlightQueryKey.self] }
        set { self[LibraryHighlightQueryKey.self] = newValue }
    }
}

/// Plain-text view that paints `libraryHighlightQuery` matches with a
/// yellow wash and falls through to a regular `Text` when the query is
/// empty. Used by every row surface that wants the visual hit-
/// confirmation (table title cells, card titles, prompt outline
/// snippets) so the highlight policy lives in one place.
struct HighlightedText: View {
    let source: String
    var color: Color = Color.yellow.opacity(0.45)
    @Environment(\.libraryHighlightQuery) private var query

    var body: some View {
        if query.isEmpty {
            Text(source)
        } else {
            Text(LibraryHighlight.attributed(source, query: query, color: color))
        }
    }
}

enum LibraryHighlight {
    /// Build an `AttributedString` that paints `query` matches with
    /// a yellow background. Case-insensitive scan, every match
    /// painted (not just the first), and short-circuits to the
    /// plain text when the query is empty so the cheap path stays
    /// cheap. Used by list rows + prompt outline rows for the
    /// "you typed this" hit confirmation.
    static func attributed(
        _ source: String,
        query: String,
        color: Color = Color.yellow.opacity(0.45)
    ) -> AttributedString {
        var attributed = AttributedString(source)
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return attributed }
        var search = source.startIndex..<source.endIndex
        while search.lowerBound < source.endIndex,
              let r = source.range(of: trimmed, options: .caseInsensitive, range: search) {
            // Map String indices to AttributedString indices via the
            // character-distance pair. AttributedString is grapheme-
            // backed and shares character semantics with String, so
            // the offsets line up 1:1.
            let lowerOffset = source.distance(from: source.startIndex, to: r.lowerBound)
            let upperOffset = source.distance(from: source.startIndex, to: r.upperBound)
            let aLower = attributed.index(attributed.startIndex, offsetByCharacters: lowerOffset)
            let aUpper = attributed.index(attributed.startIndex, offsetByCharacters: upperOffset)
            attributed[aLower..<aUpper].backgroundColor = color
            // Step past the match to find subsequent occurrences.
            // A degenerate empty range (shouldn't happen because
            // `trimmed.isEmpty` is guarded above) would loop forever
            // without this advance.
            search = r.upperBound..<source.endIndex
        }
        return attributed
    }
}
