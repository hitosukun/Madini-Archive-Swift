# Madini Archive 仕様書

Version: 2026-04-25
Status: Active, macOS 先行 (iOS は追従)

## 1. 位置づけと目的

Madini Archive は **LLM チャットログの長期保管庫を browse するための macOS 向けローカルアプリ** である。エディタでも自動要約ツールでも評価エンジンでもなく、「溜まり続ける会話ログを、時間を経た後でも再読・探索・比較・再構成できる」ことを中心に据える。

主要なユーザー行動:

- 過去の会話を **見つける** (全文検索・タグ・ブックマーク・保存フィルタ)
- 会話を **読み直す** (リーダー表示、原文 LaTeX / 画像復元、外部原本へのリンク)
- 会話を **LLM に再投入する** (.md / .txt 書き出し、クリップボードコピー)
- インポート元 (ChatGPT / Claude / Gemini エクスポート ZIP 等) の **原本を失わない**

この Swift 実装が現時点の **canonical** である。過去の Python プロトタイプは未公開で、スキーマ決定には影響しない (一方向インポートのみ互換)。

## 2. スコープと非スコープ

### やる

- 既存 DB からの読み取り中心のアーカイブブラウズ
- 4 種類の中ペイン表示モード (Table / Card / Viewer / Hidden)
- FTS5 ベースのキーワード検索
- ブックマーク、タグ、保存フィルタ、Virtual Thread
- Raw Export Vault — プロバイダ ZIP を content-addressed blob として保全
- 会話書き出し (Markdown / LLM 向けプレーンテキスト / クリップボード)
- ドロップフォルダ監視による自動取り込み

### やらない (少なくとも現フェーズでは)

- 本格的な会話編集 (書き込みは基本的にタグ・ブックマーク・Saved View に限定)
- 自動要約・スコアリング・ランク付け
- iCloud 同期 (ローカル整合性が確立するまで)
- Spotlight 統合 (検索リポジトリが安定するまで)
- iOS の本格作り込み (レイアウトは存在するが、macOS を先に仕上げる)

## 3. アーキテクチャ

### 3.1 レイヤー分離

| レイヤー | 役割 | 保管先 |
|---|---|---|
| Raw | インポート原本とプロバナンス | `raw_sources` テーブル + Raw Export Vault (content-addressed blob) |
| Normalize | 共通形式に落とした会話 / メッセージ | `conversations`, `messages` |
| View | Saved Views, Recent Filters, Bookmarks, Virtual Thread 定義 | `saved_filters`, `bookmarks`, `bookmark_tags`, `bookmark_tag_links` |
| Cache | 検索インデックス・再生成可能なキャッシュ | `search_idx` (FTS5) |
| UI | 選択状態・スクロール位置・パネル状態・テーマ | SwiftUI `@State` / `@Observable` / `NavigationPath` |

**原則:** Normalize と View と UI を混ぜない。View 層は「フィルタ定義」だけを持ち、結果本文をコピーしない。

### 3.2 3-Pane レイアウト (macOS)

`NavigationSplitView` で 3 カラム。役割は厳密に分離:

- **左ペイン (サイドバー)** — 中ペインへの **操作** (検索、フィルタ、ソート、タグ・保存フィルタのクリック選択)。中ペインを絞る・並べ替えるコントロールはすべてここ。
- **中ペイン** — SQL DB の **表現** そのもの。以下の 4 つの表示モードのうち 1 つを取る:
  1. **Table** (`.table`) — 行 × 列の一覧
  2. **Card** (`.default`) — カード型サマリ一覧
  3. **Viewer** (`.viewer`) — 選択カードのプロンプト見出し一覧
  4. **Hidden** (`.hidden`) — 非表示 (リーダーに集中)
- **右ペイン (リーダー)** — 選択中の会話を読む。原文リンク、タグ編集、書き出しはここ。

モード切替の segmented picker は「4 つのレイアウトつまみ」ではなく「中ペインの 4 状態」であり、`MiddlePaneMode` enum がそれを表す。

左右の drag-and-drop (左サイドバー ↔ 中ペイン) はタグ編集を兼ねる。

### 3.3 Repository パターン

UI / ViewModel は **protocol 経由でのみ DB にアクセスする**。GRDB 型は `Database/GRDB*.swift` と `Core/AppServices.swift` 以外に import されない。

| Protocol | 責務 | 実装 |
|---|---|---|
| `ConversationRepository` | ページング付き会話一覧、詳細取得 | `GRDBConversationRepository` |
| `SearchRepository` | キーワード検索 (FTS5-first) | `GRDBSearchRepository` |
| `BookmarkRepository` | ブックマーク CRUD、タグ関係 | `GRDBBookmarkRepository` |
| `TagRepository` | タグの列挙・リネーム | `GRDBTagRepository` |
| `ProjectRepository` | Project 定義 | `GRDBProjectRepository` |
| `ProjectMembershipRepository` | 会話 ↔ Project の紐付け | `GRDBProjectMembershipRepository` |
| `ProjectSuggestionRepository` | Project 所属候補の永続化 | `GRDBProjectSuggestionRepository` |
| `RawExportVault` | Raw ZIP のスナップショット / blob 復元 | `GRDBRawExportVault` |
| `ViewService` | Saved View, Recent Filter, Virtual Thread 構築 | `GRDBViewService` |

`AppServices` が唯一の dependency container で、`@EnvironmentObject` として注入される。

### 3.4 パッケージ構成

```
Sources/
├── MadiniArchiveApp.swift      @main + メニューコマンド
├── Core/                        AppServices + Repository protocol
├── Database/                    GRDB 実装 (GRDB 型はここに閉じる)
├── Services/                    Import / Intake / Raw Export / クエリパーサ
├── ViewModels/                  @Observable な UI 状態
├── Views/
│   ├── Shared/                  macOS / iOS 共通
│   ├── macOS/                   `NavigationSplitView` ベース
│   └── iOS/                     `NavigationStack` ベース
├── Models/                      軽量 DTO (Drag payload 等)
├── Preferences/                 ユーザ設定 (アバター・差出人名 等)
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
- 4 つの表示モード間の遷移は `⌘1` / `⌘2` / `⌘3` と `⌘→` / `⌘←` (ドリルイン / アウト) で統一。
- タグ / Project / 日付範囲によるフィルタはサイドバーに集約。

### 5.2 検索

- FTS5 の `search_idx` 仮想テーブルを一次経路とする。
- クエリパーサは `SearchQueryParser` にあり、キーワード + フィルタ句の混合を解釈。

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

### 5.7 会話書き出し (このフェーズで追加)

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

## 6. キーボードナビゲーション

メインメニューからすべて確認可能。主な割り当て:

| ショートカット | 動作 |
|---|---|
| `⌘1` / `⌘2` / `⌘3` | Table / Default / Viewer レイアウトへ切替 |
| `⌘→` / `⌘←` | Thread list → Thread → Prompt の階層をドリル |
| `⌘↑` / `⌘↓` | Viewer モードで前後プロンプトへ (Viewer / state 3 以外では無効) |
| `⌘⇧↑` / `⌘⇧↓` | 現在フォーカスされているリストの先頭 / 末尾へジャンプ (Thread レベルと Prompt レベルを自動切替) |
| `⌘R` | Library 再読込 |
| `⌘⇧O` | ドロップフォルダを Finder で開く |
| `⌘⌫` | Archive Inspector 選択中スナップショット削除 (確認ダイアログ付き) |

`⌘↑` / `⌘↓` を Thread レベルの edge-jump に使わないのは意図的 — テキストフィールドのカーソル移動を壊さないため。

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
4. **Scale 10x / 100x 耐性** — ページング必須、全件 SCAN 禁止、重い処理は incremental / bounded。
5. **人間の判断を支援** — 自動スコア・自動要約を authoritative として押し付けない。
6. **DB スキーマは Swift 側が所有** — 破壊的変更は `DatabaseMigrator` に新規 migration を積む。Python 互換は一方向 import のみ。

## 9. 今後の方針 (Not Yet)

- 本格的な自動要約パイプライン
- AI 出力の自動評価・ランキング
- アーカイブ整合性より先にエディタ機能を広げない
- iCloud 同期
- Spotlight 統合
- 公開ビルド (Developer ID 署名 + notarization)

詳細サブ仕様は `docs/specs/` 配下を参照:

- `docs/specs/raw-export-vault.md` — Vault 層の詳細
