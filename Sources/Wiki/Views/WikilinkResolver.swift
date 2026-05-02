import Foundation

/// Resolves a `[[wikilink]]` target string to a concrete page path
/// inside a vault. Pure function so the matching rules can be tested
/// independent of view-model state.
///
/// Match precedence (first hit wins):
///   1. Exact relative-path match (`[[notes/sub/page]]`).
///   2. Filename match without `.md` extension.
///   3. Frontmatter title or H1-derived title match.
///   4. Filename suffix `_<target>` — covers id-prefixed naming
///      conventions like `rgn_0007_コルバ.md` linked as `[[コルバ]]`.
///   5. Filename contains `<target>` as one of its `_`-separated tokens.
///   6. Filename prefix match — Obsidian-style fallback.
///
/// All comparisons are case-insensitive.
enum WikilinkResolver {
    static func resolve(target: String, in pages: [WikiPage]) -> String? {
        let lowered = target
            .trimmingCharacters(in: .whitespaces)
            .lowercased()
        guard !lowered.isEmpty else { return nil }

        // 1. Exact path match (e.g. `notes/sub/page` or with `.md`).
        if let p = pages.first(where: {
            let lp = $0.path.lowercased()
            return lp == lowered || lp == "\(lowered).md"
        }) {
            return p.path
        }

        // 2. Filename match without extension.
        if let p = pages.first(where: { stem(of: $0.path).lowercased() == lowered }) {
            return p.path
        }

        // 3. Title match (frontmatter title or H1 cached during indexing).
        if let p = pages.first(where: {
            ($0.title?.trimmingCharacters(in: .whitespaces).lowercased() ?? "") == lowered
        }) {
            return p.path
        }

        // 4. Filename ends with `_<target>` — e.g. rgn_0007_コルバ.md
        //    matches [[コルバ]] in id-prefixed vaults. Constrained to a
        //    leading underscore so we don't accidentally match arbitrary
        //    substrings.
        if let p = pages.first(where: {
            stem(of: $0.path).lowercased().hasSuffix("_\(lowered)")
        }) {
            return p.path
        }

        // 5. Filename contains target as one of its underscore-separated
        //    tokens (full token match, not substring).
        if let p = pages.first(where: {
            let tokens = stem(of: $0.path)
                .lowercased()
                .split(separator: "_")
                .map(String.init)
            return tokens.contains(lowered)
        }) {
            return p.path
        }

        // 6. Filename prefix match — last-resort fallback for partial
        //    typing.
        if let p = pages.first(where: {
            stem(of: $0.path).lowercased().hasPrefix(lowered)
        }) {
            return p.path
        }

        return nil
    }

    private static func stem(of path: String) -> String {
        let filename = (path as NSString).lastPathComponent
        return (filename as NSString).deletingPathExtension
    }
}
