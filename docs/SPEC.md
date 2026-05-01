# Madini Archive 仕様書

Version: 2026-04-28
Status: Active, macOS 先行 (iOS は追従)

## 1. 位置づけと目的

Madini Archive は **LLM チャットログの長期保管庫を browse するための macOS 向けローカルアプリ** である。エディタでも自動要約ツールでも評価エンジンでもなく、「溜まり続ける会話ログを、時間を経た後でも再読・探索・比較・再構成できる」ことを中心に据える。

主要なユーザー行動:

- 過去の会話を **見つける** (全文検索・タグ・ブックマーク・保存フィルタ)
- 会話を **読み直す** (リーダー表示、原文 LaTeX / 画像復元、外部原本へのリンク)
- 会話を **LLM に再投入する** (.md / .txt 書き出し、クリップボードコピー)
- インポート元 (ChatGPT / Claude / Gemini エクスポート ZIP 等) の **原本を失わない**
- 蓄積した archive を **集計で俯瞰する** (Dashboard モード)

この Swift 実装が現時点の **canonical** である。過去の Python プロトタイプは未公開で、スキーマ決定には影響しない (一方向インポートのみ互換)。

## 2. スコープと非スコープ

### やる

- 既存 DB からの読み取り中心のアーカイブブラウズ
- 5 種類の中ペイン表示モード (Table / Card / Viewer / Focus / Stats)
- FTS5 ベースのキーワード検索
- ブックマーク、タグ、保存フィルタ、Virtual Thread
- Raw Export Vault — プロバイダ ZIP を content-addressed blob として保全
- 会話書き出し (Markdown / LLM 向けプレーンテキスト / クリップボード)
- ドロップフォルダ監視による自動取り込み
- Dashboard による集計可視化 (日付ヒートマップ、時刻×曜日ヒートマップ、ソース・モデル円グラフ、月別棒グラフ)

### やらない (少なくとも現フェーズでは)

- 本格的な会話編集 (書き込みは基本的にタグ・ブックマーク・Saved View に限定)
- 自動要約・スコアリング・ランク付け
- iCloud 同期 (ローカル整合性が確立するまで)
- Spotlight 統合 (検索リポジトリが安定するまで)
- iOS の本格作り込み (レイアウトは存在するが、macOS を先に仕上げる)
- M.Wiki 連携 (別アプリとして開発中。Madini Archive 側からは将来 read-only 連携の予定)

## 3. アーキテクチャ

### 3.1 レイヤー分離

| レイヤー | 役割 | 保管先 |
|---|---|---|
| Raw | インポート原本とプロバナンス | `raw_sources` テーブル + Raw Export Vault (content-addressed blob) |
| Normalize | 共通形式に落とした会話 / メッセージ | `conversations`, `messages` |
| View | Saved Views, Recent Filters, Bookmarks, Virtual Thread 定義 | `saved_filters`, `bookmarks`, `bookmark_tags`, `bookmark_tag_links` |
| Cache | 検索インデックス・再生成可能なキャッシュ | `search_idx` (FTS5)、Stats 集計 (DB 保存しない、クエリ時生成) |
| UI | 選択状態・スクロール位置・パネル状態・テーマ | SwiftUI `@State` / `@Observable` / `NavigationPath` |

**原則:** Normalize と View と UI を混ぜない。View 層は「フィルタ定義」だけを持ち、結果本文をコピーしない。Stats 集計値は DB に永続化しない。

### 3.2 3-Pane レイアウト (macOS)

`NavigationSplitView` で 3 カラム。役割は厳密に分離:

- **左ペイン (サイドバー)** — 中ペインへの **操作** (検索、フィルタ、ソート、タグ・保存フィルタのクリック選択)。中ペインを絞る・並べ替えるコントロールはすべてここ。
- **中ペイン** — SQL DB の **表現** そのもの。以下の 5 つの表示モードのうち 1 つを取る:
  1. **Table** (`.table`) — 行 × 列の一覧
  2. **Card** (`.default`) — カード型サマリ一覧
  3. **Viewer** (`.viewer`) — 選択カードのプロンプト見出し一覧
  4. **Focus** (`.focus`) — 中ペイン非表示でリーダーに集中
  5. **Stats** (`.stats`) — Dashboard。フィルタスコープに沿った集計ビュー
- **右ペイン (リーダー)** — 選択中の会話を読む。原文リンク、タグ編集、書き出しはここ。

モード切替の segmented picker は「5 つのレイアウトつまみ」ではなく「中ペインの 5 状態」であり、`MiddlePaneMode` enum がそれを表す。

左右の drag-and-drop (左サイドバー ↔ 中ペイン) はタグ編集を兼ねる。

### 3.3 サイドバー構造

サイドバーは **User** と **Library** の 2 セクションに分ける。前者はユーザーが自分で作る / 自分で見たいものの入口、後者は取り込まれたファイルが持つ構造そのもの。

```
User
  Wikis              books.vertical          (M.Wiki 連携、現在 placeholder)
  Bookmarks          bookmark.fill           (User 注釈)
  Dashboard          chart.bar.xaxis         (中ペイン .stats モード)

Library
  archive.db         (HDD 風アイコン)         Archive Inspector を開く
  All Threads        (展開可能)               全会話の入口
    chatgpt          緑丸                    複数選択チェックボックス
    gemini           青丸                    複数選択チェックボックス
    claude           橙丸                    複数選択チェックボックス
    others           灰丸                    複数選択チェックボックス
```

ソース子項目は **複数選択チェックボックス UI**。チェック状態に応じて `source IN (…)` の集合フィルタが中ペインに伝搬する。`others` は `source NOT IN ('chatgpt', 'claude', 'gemini')` のスコープ (`markdown` は別途常時除外、Dashboard 含む)。

ソース行(chatgpt / gemini / claude / others)とモデル行(gpt-4o 等)のテキスト部分は **passive** で、クリックしても画面遷移しない。filter 操作はチェックボックスでのみ行う(行の頭の色丸アイコンが checkbox を兼ねる)— これによりチェックボックスを押そうとして誤って行のテキスト領域をクリックしても画面が切り替わらない。disclosure chevron のクリックは引き続き有効で、子モデル行の展開 / 折りたたみを切り替える。Stats モードを含むすべての中ペインモードで同じ挙動。

### 3.4 Repository パターン

UI / ViewModel は **protocol 経由でのみ DB にアクセスする**。GRDB 型は `Database/GRDB*.swift` と `Core/AppServices.swift` 以外に import されない。

| Protocol | 責務 | 実装 |
|---|---|---|
| `ConversationRepository` | ページング付き会話一覧、詳細取得、source × model facets | `GRDBConversationRepository` |
| `SearchRepository` | キーワード検索 (FTS5-first) | `GRDBSearchRepository` |
| `BookmarkRepository` | ブックマーク CRUD、タグ関係 | `GRDBBookmarkRepository` |
| `TagRepository` | タグの列挙・リネーム | `GRDBTagRepository` |
| `ProjectRepository` | Project 定義 | `GRDBProjectRepository` |
| `ProjectMembershipRepository` | 会話 ↔ Project の紐付け | `GRDBProjectMembershipRepository` |
| `ProjectSuggestionRepository` | Project 所属候補の永続化 | `GRDBProjectSuggestionRepository` |
| `RawExportVault` | Raw ZIP のスナップショット / blob 復元 | `GRDBRawExportVault` |
| `ViewService` | Saved View, Recent Filter, Virtual Thread 構築 | `GRDBViewService` |
| `StatsRepository` | Dashboard 用集計 (heatmap / distribution / monthly) | `GRDBStatsRepository` |

`AppServices` が唯一の dependency container で、`@EnvironmentObject` として注入される。

### 3.5 パッケージ構成

```
Sources/
├── MadiniArchiveApp.swift      @main + メニューコマンド + Settings scene
├── Core/                        AppServices + Repository protocol
├── Database/                    GRDB 実装 (GRDB 型はここに閉じる)
├── Services/                    Import / Intake / Raw Export / クエリパーサ
├── ViewModels/                  @Observable な UI 状態 (StatsViewModel 含む)
├── Views/
│   ├── Shared/                  macOS / iOS 共通
│   ├── macOS/                   `NavigationSplitView` ベース (StatsView 含む)
│   └── iOS/                     `NavigationStack` ベース
├── Models/                      軽量 DTO (Drag payload 等)
├── Preferences/                 ユーザ設定 (IdentityPreferencesStore 等、機能ごとに分離)
├── Utilities/                   AppPaths 等の汎用ヘルパ
├── Fixtures/                    Preview 用サンプル
└── Resources/                   バンドルアセット (アバター画像)

App/
└── Support/
    ├── Info.plist               Xcode アプリターゲット用
    └── MadiniArchive.icns       アプリアイコン
```

## 4. データの置き場所

- 正規 DB: `~/Library/Application Support/Madini Archive/archive.db`
- Raw Export Vault: 同ディレクトリ配下 (詳細は `docs/specs/raw-export-vault.md`)
- ドロップフォルダ (取り込み監視対象): ユーザー設定で変更可。デフォルトは同ディレクトリ配下の `Drop/`
- 共有 tmp: `$TMPDIR/madini-share/` (書き出し用の中間ファイル。iOS の `ShareLink` 用のみ使用)

bundle id は `com.madini.archive`。Python プロトタイプの `archive.db` をそのまま読めるよう場所を共有する。

## 5. 主要機能の現状

### 5.1 Library 参照

- 会話一覧はすべてページング (`offset` + `limit`)。全件 SCAN を UI 経路で起こさない。
- 5 つの表示モード間の遷移は `⌘1` 〜 `⌘4` と `⌘→` / `⌘←` (ドリルイン / アウト) で統一。
- タグ / Project / 日付範囲によるフィルタはサイドバーに集約。

### 5.2 検索

- FTS5 の `search_idx` 仮想テーブルを一次経路とする。
- フィルタは `ArchiveSearchFilter` を共通の Filter 型として使用。

### 5.3 ブックマーク・タグ・Saved View

- ブックマークは会話 ID に紐づく注釈。本文はコピーしない。
- Saved View は「名前付きフィルタ定義」。結果本文は保存しない。
- Recent Filter は直近利用履歴 (bounded)。

### 5.4 Archive Inspector

- 旧「Vault Browser」ウィンドウは廃止され、サイドバーの `archive.db` エントリ配下にスナップショット一覧 / スナップショット内ファイル / ファイルプレビューが統合されている。
- 選択中スナップショットの削除は Archive メニューの「Delete Snapshot…」(⌘⌫) から。

### 5.5 Import / Intake

- `ImportService` が `.json` / `.md` の取り込みを担当。UI は URL リストを渡すだけ。
- 重複判定は `conversations.hash` (MD5 of `title + full_text`)。衝突時は本文は維持、メタデータ (`model`, `source_file`, `raw_source_id`, `source_created_at`) のみ更新。
- パーサ検出順: `mapping` 鍵 → ChatGPT / `chat_messages` → Claude / `time`+`title` → Gemini / `.md`→ Markdown。
- ドロップフォルダは `IntakeWatcher` が起動時から監視 (`.task` で root に紐付け)。

### 5.6 Raw Export Vault

- プロバイダ ZIP を SHA-256 addressed blob として格納し、LZFSE で可逆圧縮。
- スナップショット単位で不変 (immutable) で、原本バイトをハッシュ検証付きで復元可能。
- 会話正規化層とは独立。詳細は `docs/specs/raw-export-vault.md`。

### 5.7 会話書き出し

右ペイン・Viewer モードフローティング・Design Mock ツールバーの 3 箇所に共通の書き出しメニューを配置。ボタンのアイコンは従来通り `square.and.arrow.up`。

メニュー項目 (macOS):

1. **Markdown (.md) として書き出し…** — `NSSavePanel` をシートで開く。人が Notes / Mail に貼って読む用。役割見出しは `### **User**` 形式。
2. **プレーンテキスト (.txt) として書き出し… — LLM 向け** — `NSSavePanel` をシートで開く。`===== User =====` / `===== Assistant =====` 区切りのみで装飾なし。本文は verbatim (コードブロック / 表 / 数式ソース保持)。
3. **LLM プロンプトとしてコピー** — クリップボードに直書き (.txt と同じフォーマット)。ChatGPT / Claude のチャット欄に即貼り付け可能。

設計上の決定:

- **共有シート (`NSSharingServicePicker`) を使わない。** メニューから共有シートを出すと「メニューの中にメニュー」の入れ子になって混乱するため。AirDrop / Mail に送りたい場合は、書き出したファイルを Finder 側で共有するフローに任せる。
- iOS では `NSSavePanel` が無いので `ShareLink` ベースの従来フロー。

LLM 向けフォーマット例:

```
Title: Benchmarking sort algorithms
Source: ChatGPT | Model: gpt-5 | Date: 2026-01-15

===== User =====

Which sort algorithm is fastest for nearly-sorted arrays?

===== Assistant =====

For nearly-sorted arrays, **insertion sort** runs in O(n) time.

```python
def insertion_sort(a):
    ...
```
```

### 5.8 Dashboard (Stats モード)

中ペインの 5 番目のモード `.stats`。他のレイアウト(`.table` / `.default` / `.viewer`)とは性質が異なる**例外状態**として扱う(Phase 6)。検索バーとサイドバー選択を結合した `ArchiveSearchFilter` をスコープとして受け取り、その範囲で集計を可視化するという点では他モードと同じ計算経路を共有するが、入退場の規約は別建て。

**Phase 5 (γ) の UX**: Stats モードは中央ペインに 5 種類のチャートのコンパクトサマリを表示し、ユーザーが選択したチャートを右ペインに拡大表示する。サイドバーの複数選択チェックボックスや検索バー入力は中央と右ペインの両方に filter として反映される。Stats モードから会話一覧への遷移はサイドバー(All Threads / source 選択)経由のみ — チャート上のデータポイントクリックは表示の一部であって導線ではない(Phase 5 (β) でドリルダウンを実装したが、月別棒クリック → サイドバー操作のクラッシュおよびオーナーの意図と異なる UX 経路だったため、(γ) で削除済)。

**Phase 6 — `.stats` モードの位置づけ(入退場ルール)**:

`.stats` は他のレイアウトとは性質が異なる「例外状態」として扱う。

入場ルール:

- 他レイアウトから `.stats` への遷移時(⌘4 / サイドバー Dashboard クリック / View → Layout → Dashboard / レイアウトピッカー)、`composedQuery` を構成する **すべての filter を完全リセット** する:
  - 検索バーの `searchText` 全体(キーワード、DSL ディレクティブ全部)
  - `excludedSources` / `excludedModels`(サイドバーチェックボックス由来の `-source:` / `-model:` トークン)
  - `bookmarksOnly`(`.bookmarks` 経路から引きずる可能性のあるフラグ)
  - `tagName`、`sources`、`models` 等の `composedQuery` に流れる全 filter
- これにより Bookmarks の `bookmarksOnly` や source 排除が引きずられて Stats が異常な集計を実行する事故を構造的に防ぐ
- ユーザーは `.stats` モード内でサイドバーチェックボックスや検索バーを使って再度 narrow できる(filter チャネルは閉じていない、画面遷移チャネルだけが「リセット入場」)

退場ルール(Stats ロック):

- 中央チャート未選択時(`selectedStatsChart == nil`、右ペインがプレースホルダ)は、⌘1 / ⌘2 / ⌘3 やサイドバー項目クリックで他レイアウトへ通常通り遷移可能
- 中央チャート選択中(`selectedStatsChart != nil`、右ペインが詳細表示中)は、すべてのレイアウト遷移操作を **無視** する:
  - ⌘1 / ⌘2 / ⌘3 → 何も起きない
  - View → Layout メニューの Stats 以外 → 何も起きない
  - レイアウトピッカーの他セグメントクリック → 何も起きない
  - サイドバーの Wikis / Bookmarks / archive.db / All Threads / source / model 行クリック → 何も起きない
- サイドバーのチェックボックス操作(filter 反映)と検索バー入力は **ロック中も有効** — これらは `searchText` のみを書き換え、`selectedSidebarItemID` / `selectedLayoutMode` には触らないので構造的に画面遷移を起こさない
- 中央チャートを再クリックすると `selectedStatsChart = nil` になり、ロックが即時解除される(Phase 5 γ 既存挙動)

設計意図:

- `.stats` は「集計を見るための独立画面」であり、他レイアウトの会話一覧と同じ filter スコープを共有しない
- ユーザーが詳細チャートを見ている最中はその状態を保護する(意図しない離脱を防ぐ)
- ロック中の遷移ブロックは **binding setter で吸収** する(`.onChange` の巻き戻しではない)。Phase 5.1 で発生した「state 連鎖を `.onChange` で打ち消すと SwiftUI のバッチング内で再帰してクラッシュ」を構造的に避ける
- 視覚フィードバック(メニューのグレーアウト、トースト等)は出さない — Mac の慣習に準拠して「できない操作はそもそも反応しない」

**Phase 8 — Dashboard モード中のサイドバー filter 操作**:

- **チェックボックス操作**(All Threads 配下のソース行 / モデル行)は `.stats` 維持で集計に反映される。チェックボックスを切り替えると `searchText` の DSL(`-source:` / `-model:`)が更新され、`composedQuery` 経由で `statsViewModel.filter` に伝搬し、5 種チャートが narrowed で再描画される。**画面遷移は起きない**(`.stats` を離れない)
- **検索バーの DSL 直接入力**も同様に `.stats` 維持で集計に反映される(チェックボックス経路と同じ DSL 書き換えチャネルを通るため)
- **ナビゲーション項目クリック**(Wikis / Bookmarks / archive.db / All Threads / Dashboard 自身)は通常通り遷移し、その時点で `.stats` モードを離れる(これらは「画面遷移するための入口」)
- 視覚フィードバック:`.stats` モード中、All Threads 配下のソース行・モデル行のチェックボックス領域に **薄いアクセントカラーの背景**(`Color.accentColor.opacity(0.10)`)を敷く。「これらは Dashboard の集計を narrow するためのチェックボックス」というアフォーダンスを言語によらず示す。ナビゲーション項目には敷かない(意味が逆の操作なので)
- 実装上の重要点:`onToggleSource` / `onToggleModel` 内の「サイドバー選択を `.allThreads` にリセット」副作用は、`.stats` モード時には **発火しない**ように `selectedLayoutMode != .stats` でガードする。これにより `.onChange(of: selectedSidebarItemID)` の `.default` bump 経路が反応しない構造になる(state 書き換えそのものを発生させないので Phase 5.1 の「同一 frame 3 つ State 書き換え」教訓も自動的に満たす)

実装する集計 (Phase 2 で 5 種すべて実装済):

1. **日付別ヒートマップ** — `primary_time` を `'localtime'` で日付化。プロンプト数 (role='user') を集計、過去 365 日上限。中央ペインは過去 90 日のコンパクト表示、右ペインで全 365 日
2. **時刻 × 曜日ヒートマップ** — 7 行 × 24 列。1 つの会話の全プロンプトはその会話の代表時刻のセルに集計される (messages にメッセージ単位の時刻カラムが無い制約)
3. **ソース別棒グラフ** — `conversations.source` で GROUP BY、ブランドカラー (`SourceAppearance`) 流用
4. **モデル別棒グラフ** — `conversations.model` で GROUP BY、空欄は `"Unknown"` に集約。中央ペインは上位 10 件、右ペインは全件
5. **月別棒グラフ** — `strftime('%Y-%m', primary_time, 'localtime')` で GROUP BY、会話数 / プロンプト数の 2 系列を Picker で切替、過去 24 ヶ月上限

実装の入口:

- Repository: `StatsRepository` (`Sources/Core/Repositories.swift`) + `GRDBStatsRepository` (`Sources/Database/GRDBStatsRepository.swift`)
- ViewModel: `StatsViewModel` (`@Observable`、`Sources/ViewModels/StatsViewModel.swift`)
- View: `StatsContentPane`(中央コンパクト)+ `StatsDetailPane`(右ペイン詳細、Phase 5 で追加)— 共に `Sources/Views/macOS/StatsContentPane.swift`
- WHERE 組み立ては `SearchFilterSQL.makeWhereClause` を経由(会話一覧 / 検索 / Stats 完全共通)

設計上の決定:

- **集計値は DB に保存しない**。フィルタが変わるたびにクエリで再生成する純粋な派生ビュー
- **markdown source は常時除外**。Dashboard は「LLM 会話ログの集計ビュー」として意味づける
- **集計の母集合は user prompt を持つ会話に限定**(Phase 7)。`messages` に `role='user'` の行が 1 件以上ある会話のみを 5 種チャートすべてで集計対象とする。`sourceBreakdown` / `modelBreakdown` / `monthlyBreakdown` には `EXISTS (SELECT 1 FROM messages mm WHERE mm.conv_id = c.id AND mm.role = 'user')` を WHERE に追加し、`dailyHeatmap` / `hourWeekdayHeatmap` は元から `m.role='user'` で JOIN しているため同じ母集合を共有する。`conversations` 側の正規データには触らず、純粋に集計時の母集合定義として除外する。**根拠**: assistant のみ(user prompt 不在)の会話レコードが混入していた場合、月別チャートのプロンプト数系列に `prompt_count = 0` のバーが現れ、macOS Tahoe 26.4.1 の SwiftUI Charts framework が `Charts: Falling back to a fixed dimension size for a mark.` を出して layout 再帰クラッシュ(trace trap)に陥る現象を実機で確認した。意味的にも「user prompt が無い」会話を「会話」として集計するのは不適切なので、構造的にも防御的にも正しい絞り込み
- **グラフは Apple Swift Charts のみ使用**、外部依存なし
- **タイムゾーンは常に `'localtime'`**。"青いタイル問題" (UTC ベースで深夜のメッセージが翌日のセルに流れる) の再発を構造的に防ぐ
- **日付範囲フィルタが効いた時は Phase 0.5 の expression index を経由する**(EXPLAIN QUERY PLAN で確認済 — `idx_conversations_primary_time_expr`)。フィルタ無しの全件 GROUP BY は SCAN になるが、これは GROUP BY の本質的な制約で許容

## 6. キーボードナビゲーション

メインメニューからすべて確認可能。主な割り当て:

| ショートカット | 動作 |
|---|---|
| `⌘1` / `⌘2` / `⌘3` / `⌘4` | Table / Card / Viewer / Stats レイアウトへ切替 |
| `⌘→` / `⌘←` | Thread list → Thread → Prompt の階層をドリル |
| `⌘↑` / `⌘↓` | Viewer モードで前後プロンプトへ (Viewer / state 3 以外では無効) |
| `⌘⇧↑` / `⌘⇧↓` | 現在フォーカスされているリストの先頭 / 末尾へジャンプ (Thread レベルと Prompt レベルを自動切替) |
| `⌘R` | Library 再読込 |
| `⌘⇧O` | ドロップフォルダを Finder で開く |
| `⌘⌫` | Archive Inspector 選択中スナップショット削除 (確認ダイアログ付き) |
| `⌘,` | Settings ウィンドウ |

`⌘↑` / `⌘↓` を Thread レベルの edge-jump に使わないのは意図的 — テキストフィールドのカーソル移動を壊さないため。

`.focus` モードへの入出力は **`ViewerModeSwipeGesture`(横スワイプ)経由のみ**。キーボードショートカットは未割当(意図的)。トラックパッドの 2 本指横スワイプで `.table → .default → .viewer → .focus` の cascade を 1 ステップずつ進む / 戻る。テキストフィールドのカーソル移動と干渉しない設計を保つため、`.focus` 専用のキー割り当ては今後も追加しない方針。`.stats` は cascade 外で、`⌘4` / サイドバー Dashboard / ピッカーでのみ出入りする(swipe では遷移しない)。

## 7. ビルドとリリース

### 7.1 SPM (日常開発・テスト)

```sh
swift build
swift test
open .build/debug/MadiniArchive
```

Xcode で `Package.swift` を開けば SwiftUI Preview も有効。

### 7.2 配布用 `.app` (xcodegen)

`project.yml` が single source of truth。`.xcodeproj/` は git 管理外。

```sh
xcodegen generate
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  xcodebuild -project "Madini Archive.xcodeproj" \
             -scheme "Madini Archive" \
             -configuration Release \
             -derivedDataPath build/derived build

cp -R build/derived/Build/Products/Release/"Madini Archive.app" /Applications/
```

ad-hoc 署名 (`codesign -`) で `/Applications/` から起動可能。Gatekeeper / notarization はまだ通していない (個人利用段階のため)。

SPM と xcodegen は **同じ `Sources/` を共有** する。依存バージョン (`GRDB.swift` 7.0+, `SwiftMath` 1.7+) は `Package.swift` と `project.yml` の両方に書く必要があり、片方を更新したら必ず両方を揃える。`Bundle.module` 参照は `SPM_BUILD` define で分岐し、Xcode ビルドでは `BundledResources` シム経由で `Bundle.main` にフォールバックする。

### 7.3 動作要件

- macOS 14 Sonoma+
- Xcode 15+ (Swift 5.9+)
- ローカルファイルシステム (DB・Vault・ドロップフォルダすべてローカル)

## 8. 設計原則 (短縮版)

1. **原本保全を優先** — Normalize は派生層。Raw は常に復元可能。
2. **標準フォーマット優先** — SQL / JSON / Markdown / HTML。内部 only フォーマット禁止。
3. **Local-first** — iCloud 同期はローカル整合性が固まるまで入れない。
4. **Scale 10x / 100x 耐性** — ページング必須、全件 SCAN 禁止、重い処理は incremental / bounded。集計は GROUP BY + index 前提。
5. **人間の判断を支援** — 自動スコア・自動要約を authoritative として押し付けない。
6. **DB スキーマは Swift 側が所有** — 破壊的変更は `DatabaseMigrator` に新規 migration を積む。Python 互換は一方向 import のみ。
7. **派生ビューは派生のまま** — Saved View, Recent Filter, Virtual Thread, Stats 集計はすべてフィルタ定義 / クエリで再現可能であり、結果本文を保存しない。

## 9. 今後の方針 (Not Yet)

- 本格的な自動要約パイプライン
- AI 出力の自動評価・ランキング
- アーカイブ整合性より先にエディタ機能を広げない
- iCloud 同期
- Spotlight 統合
- 公開ビルド (Developer ID 署名 + notarization)
- M.Wiki 連携 (別アプリで開発中。Madini Archive 側からは将来 read-only 連携)

詳細サブ仕様は `docs/specs/` 配下を参照:

- `docs/specs/raw-export-vault.md` — Vault 層の詳細
