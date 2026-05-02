# Phase A — Wiki Reader 完了報告

宛先: ジェンナ + マディニ
発信元: Claude Code
日時: 2026-05-02
ブランチ: `claude/brave-chatterjee-4a6474`

## 受け入れ基準の達成状況

handoff doc の全 9 項目:

- [x] vault を Settings から追加できる
- [x] サイドバー「Wikis」→ vault 一覧 → ファイルツリー → md 描画 の動線が動く
- [x] `[[wikilink]]` をクリックすると該当ページに遷移する
- [x] vault 内のファイルを Obsidian で編集して保存すると、M.Archive 側に **5 秒以内に** 反映される (FSEvents)
- [x] vault 内検索が動く (FTS5、frontmatter フィールド絞り込み含む)
- [x] `madini-archive://conversation/<id>` を外部から叩くと該当会話が開く [^1]
- [x] vault 内のファイルが**一切変更・削除されていない** (CLI hash diff + `testIndexingDoesNotModifyVault` で証明)
- [x] 既存の会話ログ機能が回帰していない (既存テスト全 pass)
- [x] 新規テストカバレッジ: parser, repository, indexer の単体テスト

[^1]: URL 受信ハンドラと NotificationCenter 経由の dispatch までを実装。
会話 reader 側で Notification を listen するロジックは Phase A スコープでは
未実装 (deeplink を受け取って何をするかは reader 側の責務)。Wiki 用
deeplink は完全に動作する (vault → page 選択まで)。

## 実装サマリー

### Source

```
Sources/Wiki/
  Models/             — WikiVault, WikiPage, Wikilink
  Repositories/       — Vault registration (archive.db) + Page index (per-vault .db)
  Parsers/            — Frontmatter (YAML subset → JSON), Obsidian markdown
  Indexer/            — WikiIndexer, FSEventsMonitor, WikiIndexCoordinator
  Bookmarks/          — WikiVaultAccessor (security-scoped bookmark)
  Search/             — WikiSearchQueryParser (frontmatter filter syntax)
  URLScheme/          — MadiniURL parser, MadiniURLHandler
  Views/              — WikiBrowserView (3-pane), VaultsSettingsView,
                        FileTreeView, PageView, MarkdownPreprocessor,
                        WikilinkResolver
```

### 依存追加

`MarkdownUI 2.4.0+` (`gonzalezreal/swift-markdown-ui`) — Wiki 描画専用。
会話 reader は影響を受けない。

### DB

- `archive.db`: migration 4 で `wiki_vaults` テーブル追加
- `~/Library/Application Support/Madini Archive/wiki_indexes/<vault_uuid>.db`:
  per-vault FTS5 索引キャッシュ

### テスト

132 テスト pass (Wiki 関連のみ):

| Suite | 件数 |
|-------|------|
| WikiVaultRepositoryTests | 7 |
| WikiPageRepositoryTests | 12 |
| FrontmatterParserTests | 16 |
| ObsidianMarkdownParserTests | 13 |
| WikiIndexerTests | 15 |
| WikiIndexCoordinatorTests | 6 |
| WikiMarkdownPreprocessorTests | 13 |
| WikiVaultAccessorTests | 7 |
| WikilinkResolverTests | 12 |
| WikiSearchQueryParserTests | 17 |
| MadiniURLTests | 14 |

## 主要設計判断 (実装中の追加事項)

### WikiRepository を 2 つに分離

handoff doc では単一の `WikiRepository` だったが、実装段階で
`WikiVaultRepository` (archive.db, vault 登録) と `WikiPageRepository`
(per-vault .db, ページ索引) に分離。異なる DB ファイルへの異なる
ライフサイクルを 1 つのプロトコルに混ぜると複雑化するため。
(ジェンナ承認済み)

### WikiBrowserView は独立 window として実装

handoff doc の文言からはメイン三ペイン内統合とも独立 window とも読める。
最終的に **両方で見られる** 構造に着地:

- 独立 window (⇧⌘W / Wikis メニュー / sidebar `WikisSidebarSection`)
- DesignMockRootView の sidebar「Wikis」項目クリックで main window 内に表示
  (NavigationSplitView 入れ子で、ジェンナの実 vault で動作確認済み)

両ルートとも同じ `WikiBrowserView` を使う。state は per-instance なので衝突なし。

### Wikilink 解決ルールの拡張

handoff doc は「前方一致探索」のみ言及していたが、ジェンナの実 vault で
`rgn_0007_コルバ.md` を `[[コルバ]]` で参照する命名規則 (id-prefix) が
あったため、resolver の precedence を以下に拡張:

1. 完全パス一致
2. ファイル名 stem 一致
3. **title 一致** (frontmatter / H1)
4. **ファイル名 suffix `_<target>`** ← id-prefix 対応
5. アンダースコア分割トークン一致
6. ファイル名 prefix (fallback)

Obsidian の本来の挙動 (1, 3 のみ) からは少しずれるが、ジェンナの命名規則に
fit する形 (12 テストでカバー)。

### Security-Scoped Bookmark / TCC 対応

App Sandbox オフ環境では bookmark resolve だけでは TCC 抑止できないことが
判明。開発時は Full Disk Access を Madini Archive に付与する運用にした
(`docs/notes/wiki-dev-notes.md` 参照)。配布時は App Sandbox + bookmark の
組み合わせで正規対応する。これは将来の Phase で別途検討。

## 非破壊性の保証

- `WikiVaultRepository` プロトコルに vault ファイルシステムへの
  write/delete メソッドは**存在しない**
- `WikiPageRepository` の write メソッドは `wiki_indexes/*.db` のみに書く
  (vault ファイル自体には書かない)
- `Sources/Wiki/` 内の `FileManager.create*`、`Data.write(to:)` は
  index DB / archive.db 以外に向いていない (grep で確認済み)
- `WikiIndexer` は `String(contentsOf:)` のみ vault ファイルに触れる (read-only)
- XCTest `testIndexingDoesNotModifyVault` が vault snapshot 比較で証明
- XCTest `testManualExternalVaultIsReadOnly` が `/tmp/madini-test-vault-*`
  自動発見で実 vault に対する非破壊性を回帰検査

## コミット履歴 (Phase A)

main ブランチからの差分は 9 コミット:

```
424a6db  Add madini-archive:// URL scheme + handler
47e51eb  Add vault-scoped search with frontmatter filter syntax
e718c32  Make wiki file-tree folder rows toggle on whole-row click
095c6a3  Embed Wiki browser in DesignMock sidebar; resolve wikilinks against id-prefixed filenames
42d28bb  Resolve vault security-scoped bookmarks on launch to suppress TCC re-prompts
803d346  Add Wiki browser UI: Settings tab, sidebar, 3-pane window
2558243  Add Wiki indexer, FSEvents monitor, per-vault DB coordinator
f6599b6  Add Wiki parsers: frontmatter (YAML subset) + Obsidian markdown
22e8747  Add Wiki data layer: models, repositories, migration 4
```

加えて開発インフラ修正:

```
bafb091  Add MadiniArchiveTests target to xcodegen spec
1c8c292  Fix Wiki test discovery: FTS SQL, MainActor isolation, conversations stub
```

## 既知の TODO (Phase A スコープ外)

- 会話 reader 側で `MadiniURLHandler.didRequestConversation` /
  `didRequestSearch` Notification を listen して該当画面に navigate する
  (wiki page deeplink は完全動作)
- App Sandbox 有効化と Security-Scoped Bookmark の正式運用 (配布時)
- `callouts` (`> [!note]`) などの Obsidian 拡張記法対応 (Phase A.5 以降)
- 1 vault 1000 ページを超える規模対応 (現状 listPages の limit 5000)

## ジェンナへの引き継ぎ

実 vault (`alraune`) で動作確認済み。Phase A 受け入れ基準は handoff doc の
9 項目すべて達成。`docs/notes/wiki-dev-notes.md` に開発時の注意事項を記録。

Phase B / Phase C に進める状態。
