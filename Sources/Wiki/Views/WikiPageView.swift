import SwiftUI
import MarkdownUI

/// Renders a single wiki page on the right pane. MarkdownUI handles GFM;
/// the body is preprocessed first so Obsidian's `[[wikilink]]` and
/// `![[embed]]` shapes become standard markdown links/images.
///
/// Wikilink clicks come back through `OpenURLAction` with the custom
/// `wiki://` scheme, which we intercept and dispatch to the view model
/// for in-app navigation.
struct WikiPageView: View {
    let page: WikiPage
    let vault: WikiVault
    let viewModel: WikiBrowserViewModel

    private var rendered: String {
        WikiMarkdownPreprocessor.preprocess(
            page.body, vaultPath: vault.path
        )
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                if let title = page.title {
                    Text(title)
                        .font(.title.bold())
                        .padding(.bottom, 4)
                }
                Text(page.path)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Divider()
                Markdown(rendered)
                    .markdownTheme(.gitHub)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(24)
        }
        .environment(\.openURL, OpenURLAction { url in
            if url.scheme == WikiMarkdownPreprocessor.wikiURLScheme {
                let target = url.host ?? url.path
                let decoded = target.removingPercentEncoding ?? target
                Task { await viewModel.navigateToWikilink(target: decoded) }
                return .handled
            }
            return .systemAction
        })
    }
}

/// Empty state when a vault is selected but no page yet.
struct WikiPagePlaceholderView: View {
    let vault: WikiVault?

    var body: some View {
        ContentUnavailableView {
            Label(vault?.name ?? "Wiki", systemImage: "books.vertical")
        } description: {
            Text(vault == nil
                 ? "Choose a vault from the list."
                 : "Choose a page from the file tree.")
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
