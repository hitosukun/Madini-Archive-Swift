# フリーズ原因調査レポート

- **日付**: 2026-05-05
- **ブランチ**: `claude/practical-vaughan-97314f` (base: main `d3faf4b`)
- **スコープ**: 静的コード解析のみ（コード変更なし、スタックトレース未提供）

---

## 1. 症状の整理

### 報告された症状
通常使用中（長文会話の表示、検索クエリ実行、連続スクロール等）にフリーズ/ビーチボール現象が発生。

### 再現条件の推測（コード構造から）
- **長文会話を開いた瞬間**: 全メッセージの一括ロード + 初回パース（キャッシュ cold）
- **検索で2文字の日本語を入力**: LIKE fallback path がメッセージテーブル全件スキャン
- **会話内を高速スクロール中**: NSCache eviction 後の再パースが集中
- **Bookmarks表示中にフィルタ変更**: `listBookmarks()` の全件取得 + `LIKE c.id || ':%'` パターン

---

## 2. 疑わしい箇所の一覧

### カテゴリ 1: メインスレッドブロッキング

| # | ファイル:行 | 問題 | 証拠の強さ |
|---|-----------|------|-----------|
| 1-1 | `MessageBubbleView.swift:1016` | `ContentBlock.parse()` が `body` 評価中に同期実行。行ベースのステートマシンが 20,000文字（`maxRenderedMessageLength`）まで許容 | **High** |
| 1-2 | `MessageBubbleView.swift:1137-1164` | `contentBlocksExcludingThinking()`: thinking テキストの `range(of:)` 検索 + 正規表現 `\n{3,}` 置換 + 再パース。全て `body` 評価中の同期処理 | **High** |
| 1-3 | `MessageBubbleView.swift:2932-2956` | `InlineMarkdownCache.render()`: キャッシュ miss 時に `AttributedString(markdown:)` を同期実行。コメントに「surprisingly expensive — always builds a CommonMark tree even for pure text」と記載 | **High** |
| 1-4 | `MessageBubbleView.swift:1469-1517` | `renderInlineRich()`: インライン数式検出 + `InlineMathSplitter.split()` + 複数回の markdown parse + SwiftMath レンダリング。全て `body` 内同期 | **Medium** |
| 1-5 | `LineBreakHints.swift:88+` | `softWrap()`: 全段落/見出し/リスト/引用で呼ばれる O(n) の文字スキャン。`body` 評価パス内（`MessageBubbleView.swift:668,709,741,765`） | **Medium** |
| 1-6 | `SyntaxHighlighter.swift:43-100` | コードブロックのトークナイズ。32文字未満はキャッシュスキップ、毎回実行 | **Low** |

**メインスレッド保護の状態**: DB アクセスは `GRDBAsync.read()` で `DispatchQueue.global(qos: .userInitiated)` にオフロードされており適切。問題は**View body 内のテキスト処理**に集中している。

### カテゴリ 2: FTS5 検索クエリの効率

| # | ファイル:行 | 問題 | 証拠の強さ |
|---|-----------|------|-----------|
| 2-1 | `GRDBSearchRepository.swift:191-211` | LIKE fallback path: 2文字トークン（`編集`, `削除`等）で `EXISTS(SELECT 1 FROM messages m WHERE m.conv_id = c.id AND m.content LIKE ?)` がコンバセーション毎に走る。messages テーブルの全件スキャン | **High** |
| 2-2 | `SearchFilterSQL.swift:136-143` | Bookmark フィルタ: `b.target_id LIKE c.id || ':%'` — 文字列連結 + LIKE パターンでインデックス利用不可 | **High** |
| 2-3 | `SearchFilterSQL.swift:179-189` | Role フィルタ: `lower(COALESCE(m.role, ''))` で関数適用、インデックス無効化 | **Medium** |
| 2-4 | `GRDBSearchRepository.swift:276-294` | `headlinePromptSQL` / `firstMessageSnippetSQL`: 結果行ごとに相関サブクエリ実行 | **Medium** |
| 2-5 | `AppServices.swift:435-446` | FTS5 インデックス再構築: `GROUP_CONCAT(m.content, ' ')` で全メッセージ結合。10K+ conversations でのブートストラップ時間が不明 | **Medium** |

**ページネーション**: FTS path / LIKE path ともに `LIMIT ? OFFSET ?` は適切に設定されている。問題は LIKE fallback 内部の相関サブクエリコスト。

### カテゴリ 3: レンダリング層のコスト

| # | ファイル:行 | 問題 | 証拠の強さ |
|---|-----------|------|-----------|
| 3-1 | `GRDBConversationRepository.swift:77-86` | `fetchDetail()` が会話の全メッセージを LIMIT なしで一括ロード。1000+ messages の会話で全 `content` + `content_json` がメモリに | **High** |
| 3-2 | `ConversationDetailView.swift:385-500` | `LazyVStack` + `ForEach(Array(detail.messages.enumerated()))`: `Array()` で全メッセージを即座に具象化。LazyVStack はレンダリングを遅延するがビュー階層の構築は即座 | **High** |
| 3-3 | `ConversationDetailView.swift:433-444` | 全ユーザーメッセージに `GeometryReader` でスクロール位置を `PreferenceKey` 経由で publish。スクロール毎にフレーム計算が全可視メッセージで走る | **Medium** |
| 3-4 | `MessageBubbleView.swift:524` | `ForEach(Array(renderItems.enumerated()), id: \.offset)`: `id: \.offset` はインデックスベースのため、リスト先頭の挿入で全アイテム再生成の可能性 | **Low** |

### カテゴリ 4: GRDB `ValueObservation` の暴発

**調査結果: 該当なし。** コードベース全体で GRDB の `ValueObservation` は一切使用されていない。代わりに `@Observable` ViewModel + debounced `Task` + `.task(id:)` の手動更新パターンを採用。この設計自体は問題ないが、反面「DB変更→自動UI更新」がないため、手動 reload が遅延する場合がある（フリーズとは無関係）。

### カテゴリ 5: ページネーション義務違反

| # | ファイル:行 | 問題 | 証拠の強さ |
|---|-----------|------|-----------|
| 5-1 | `GRDBConversationRepository.swift:77-86` | `fetchDetail()` 内のメッセージ取得: `SELECT ... FROM messages WHERE conv_id = ? ORDER BY msg_index` — LIMIT なし | **High** |
| 5-2 | `GRDBBookmarkRepository.swift:104-145` | `listBookmarks()`: `SELECT ... FROM bookmarks b LEFT JOIN conversations c ...` — LIMIT なし。全ブックマーク一括取得 | **High** |
| 5-3 | `GRDBBookmarkRepository.swift:64-70` | `fetchBookmarkStates()`: `SELECT ... FROM bookmarks` — 全行取得して Dict 化。呼び出し元の `targets` パラメータでフィルタしていない | **High** |
| 5-4 | `GRDBConversationRepository.swift:150-235` | `fetchSources()`, `fetchModels()`, `fetchSourceFileFacets()`: GROUP BY 集約で LIMIT なし（ただしカーディナリティが低いため実害は小） | **Low** |

### カテゴリ 6: メモリ累積パターン

| # | ファイル:行 | 問題 | 証拠の強さ |
|---|-----------|------|-----------|
| 6-1 | `MessageBubbleView.swift:1021-1025` | `blocksCache: NSCache` countLimit=500。LRU eviction のみ、メモリ圧力時に一括 purge → 再パースの突発的 CPU スパイク | **Medium** |
| 6-2 | `MessageBubbleView.swift:1167-1171` | `renderItemsCache: NSCache` countLimit=500。同上 | **Medium** |
| 6-3 | `MessageBubbleView.swift:2920-2926` | `InlineMarkdownCache` countLimit=2048。`AttributedString` はサイズが大きい（1段落あたり数KB〜数十KB）。2048エントリで数十MB に達する可能性 | **Medium** |
| 6-4 | `LibraryViewModel.swift:74,863-897` | `conversationTags: [String: [TagEntry]]`: ページネーション forward 時に無限蓄積。`loadAllConversations()` で全件ロード可能 | **Medium** |
| 6-5 | `MessageBubbleView.swift:1720-1722` | `InlineMathImageCache` countLimit=512。NSImage/UIImage を保持。1画像あたり数十KB〜数百KB | **Low** |

---

## 3. 証拠の強さ格付け

### High（コードから確実に問題と判断）

1. **3-1 + 5-1: 会話メッセージの無制限一括ロード** — 1000+ messages の会話で全 `content` カラム（1メッセージ最大20,000文字）がメモリに載る。これだけで数十MBに達する可能性がある。
2. **1-1 + 1-2 + 1-3: body 内の同期テキスト処理チェーン** — NSCache miss 時に `ContentBlock.parse()` → `contentBlocksExcludingThinking()` → `renderInlineMarkdown()` → `AttributedString(markdown:)` が連鎖。1メッセージの初回描画で数十ms〜数百ms のメインスレッドブロックが発生する。
3. **2-1: 2文字検索の LIKE fallback** — 日本語の頻出2文字語彙（`編集`, `削除`, `追加`, `変更`）で `messages` テーブル全件スキャンが発生。アーカイブ成長に伴い線形に悪化。
4. **5-2 + 5-3: ブックマーク全件取得** — `listBookmarks()` が `LibraryViewModel.reloadNow()` から毎回呼ばれ（`bookmarkCountTask`として）、全件を in-memory 化している。

### Medium（状況により問題化）

5. **3-2: LazyVStack の実態** — ビュー hierarchy 構築は即座。100messages = 100 MessageBubbleView + modifiers が同時に存在。ただし `.equatable()` でbody再評価は短絡。
6. **2-2: Bookmark LIKE パターン** — `bookmarkedOnly` フィルタ使用時のみ。頻繁に使う場合にコスト大。
7. **6-3: InlineMarkdownCache のメモリフットプリント** — 2048 AttributedString は数十MB 占有の可能性。メモリ圧力時の eviction で突発的再パース。
8. **1-5: LineBreakHints.softWrap()** — 1段落あたりは低コストだが、長大会話（50+ paragraphs per message × 100 messages）のスクロール中に累積。

### Low（現時点では問題を確認できず）

9. **1-6: SyntaxHighlighter** — キャッシュ有効、短いコードブロックのみ miss。
10. **3-4: ForEach id: \.offset** — renderItems は message 内の block リストであり、先頭挿入は実質発生しない。

---

## 4. 計測すべき項目

### Instruments / Time Profiler

| 優先度 | 操作 | 注目すべきシンボル |
|--------|------|-------------------|
| P0 | 500+ messages の会話を開く | `GRDBConversationRepository.fetchDetail` → total elapsed, `ContentBlock.parse` per-message, `AttributedString.init(markdown:)` |
| P0 | 開いた直後に高速スクロール（上→下→上） | `MessageBubbleView.body.getter`, `InlineMarkdownCache.render`, `LineBreakHints.softWrap` |
| P0 | 検索バーに `編集` と入力 | `GRDBSearchRepository.searchViaLike` → total, SQLite `LIKE` per-conversation cost |
| P1 | Bookmarks サイドバーを表示 | `GRDBBookmarkRepository.listBookmarks` → row count × elapsed |
| P1 | 数式を多く含む会話を開く | `InlineMathImageCache.rendered`, `MathImage.asImage`, `InlineMathSplitter.split` |
| P2 | フィルタを `bookmarkedOnly=true` にして検索 | `SearchFilterSQL.makeWhereClause` → bookmark EXISTS subquery cost |

### Memory Graph Debugger

| 操作 | 注目ポイント |
|------|-------------|
| 長大会話を5つ連続で切り替え | `InlineMarkdownCache` の実メモリ占有量、`NSCache` purge 後の再パースタイミング |
| `loadAllConversations()` 実行後 | `conversations` Array + `conversationTags` Dict の合計メモリ |
| 数式多用会話を開く | `InlineMathImageCache` に保持される NSImage の合計サイズ |

---

## 5. 要追加調査

1. **`ContentBlock.parse()` の実測コスト**: 静的解析では O(n) の行ステートマシンだが、UTF-8 → Character 変換のオーバーヘッドが不明。20,000文字の日本語テキストでの実計測が必要。

2. **NSCache eviction のタイミング**: メモリ圧力時に 500/2048 エントリが一括 purge されるか段階的かで、フリーズの「突発性」が説明できる可能性がある。

3. **`messages` テーブルのインデックス構成**: `conv_id` + `msg_index` の複合インデックスが存在するか未確認。LIKE fallback の性能に直結。Schema migration history の確認が必要。

4. **`ConversationDetail.messages` の実サイズ分布**: archive.db 内の最大メッセージ数を持つ会話の特定。100messages × 20,000文字 = 理論上 2MB のテキストがメモリ常駐。

5. **`LazyVStack` の実際の materialize 動作**: SwiftUI 内部の実装による。`ForEach(Array(...))` が全ビューを事前に構築するか、スクロール近傍のみ構築するかは version 依存の可能性。macOS 14 / 15 での差異をプロファイラで確認が必要。

6. **`PromptTopYPreferenceKey` の preference 集約コスト**: 全ユーザーメッセージの GeometryReader が preference dict をスクロール毎に emit する。SwiftUI が毎フレーム dict merge を走らせている可能性（`onPreferenceChange` の呼ばれる頻度の確認）。

7. **FTS5 trigram インデックスの再構築頻度**: `AppServices.swift:435-446` での bootstrap が app launch 時のみか、import 後にも走るか確認が必要。

---

## 6. 次フェーズへの引き継ぎ事項

### 設計判断が必要な修正

1. **メッセージのウィンドウ化/仮想化**
   - `fetchDetail()` を paginated に変更するか、全件取得のまま view 側で仮想化するか
   - 全件取得 → NSCache warm は「会話切り替え時に1回だけ重い」を受容する設計
   - 仮想化 → スクロール中の追加フェッチで UX が変わる（ProgressView 差し込み）
   - 判断基準: archive.db 内の最大メッセージ数（100以下なら全件取得で十分、500+ なら仮想化必須）

2. **テキスト処理の非同期化**
   - `ContentBlock.parse()` + `renderItems` 計算を `Task` にオフロードする場合、キャッシュ miss 時に ProgressView を見せるか否か
   - 非同期化すると `.equatable()` の short-circuit が効かなくなる可能性（state 変更で body 再評価）
   - 代替案: キャッシュを永続化して cold start をなくす（LRU disk cache）

3. **LIKE fallback の改善方針**
   - 案A: `messages(conv_id, content)` のインデックス追加（LIKE `%...%` ではインデックス使えないが、EXISTS の conv_id 部分は改善）
   - 案B: FTS5 tokenizer を `unicode61` に変更（2文字トークンを扱える）— AGENTS.md に tokenizer 変更のプロトコル記載あり、index rebuild + progress UI 必須
   - 案C: content の先頭 N 文字を conversations テーブルに denormalize して JOIN 回避

4. **Bookmark クエリの正規化**
   - `target_id LIKE c.id || ':%'` パターンを廃止するか
   - 案: `bookmarks` テーブルに `conversation_id` カラムを追加する migration
   - Phase 4 で prompt-level bookmark に移行した際の設計判断の延長

5. **NSCache の制御戦略**
   - `totalCostLimit` による byte-aware eviction の導入を検討
   - memory warning 通知での proactive purge（macOS では `DidReceiveMemoryWarningNotification` 相当がないため、`ProcessInfo.processInfo.thermalState` またはカスタム監視が必要）
