# 調査レポート: Python importer から Swift importer への完全移行

- **日付**: 2026-04-30
- **ブランチ**: `claude/investigate-importer-migration` (base: main `92bf6d9`)
- **スコープ**: 調査と作業量見積もりのみ（コード変更なし）
- **関連レポート**: `docs/investigations/rendering-framework-2026-04-30.md`（同日付、別ブランチに存在）

---

## 1. 背景

### 1.1 直接の動機

直近の調査（`rendering-framework-2026-04-30.md`）で、Python importer が Claude エクスポート JSON の `thinking` ブロックを flat text に結合してしまっており、これが view 層の不具合 Bug B（日本語応答の誤折りたたみ）の root cause となっていることが判明した。

raw export JSON では（実例の構造を保った合成サンプル）:

```json
"content": [
  { "type": "text", "text": " " },
  { "type": "thinking", "thinking": "[English thinking preamble — model reasoning before response]" },
  { "type": "text", "text": "[Japanese response body]" }
]
```

これが Python importer 後の `messages.content` では:

```text
[English thinking preamble][Japanese response body]
```

と結合され、構造的境界が消失している。

### 1.2 判断材料の必要性

選択肢:

- **延命**: Python importer に手を入れて thinking を保存する形に改修する
- **移行**: Python importer の延命をやめて Swift importer に完全移行する

オーナーの長期計画として「Python core 分離 → SwiftUI 移行」があると申告されているが、後述（§5.1）の通り**現行ドキュメントの方針はこれと逆向き**であるため、まず方針整理が必要。本レポートでは Swift 移行に必要な作業量を見積もりつつ、現行方針との不整合も明示する。

---

## 2. 現状の Swift importer の完成度

### 2.1 既存 Swift import 関連コード一覧

| ファイル | 行数 | 役割 | DB 書き込み |
|---------|------|------|-----------|
| `Sources/Services/JSONImporter.swift` | 156 | **Python importer を `Process` で shell-exec** | × (Python に委譲) |
| `Sources/Services/ImportCoordinator.swift` | 170 | vault → Python importer → project reconciler の orchestration | × (Python に委譲) |
| `Sources/Services/JSONImportFileResolver.swift` | 97 | importable JSON ファイルの検出（`.conversations-*.json`、Claude/ChatGPT/Gemini 判定） | × |
| `Sources/Services/JSONImportProjectReconciler.swift` | 360 | JSON からプロジェクトメタデータを抽出、`projects` テーブルに upsert | ○ (projects 系のみ) |
| `Sources/Services/ConversationTranscriptExtractor.swift` | 24 | provider router（Claude/ChatGPT に dispatch） | × |
| `Sources/Services/ClaudeTranscriptExtractor.swift` | 256 | **Claude JSON → ConversationTranscript** | × |
| `Sources/Services/ChatGPTTranscriptExtractor.swift` | 292 | **ChatGPT JSON → ConversationTranscript**（DAG walk） | × |
| `Sources/Services/ConversationTranscript.swift` | 70 | provider-neutral transcript 型定義 | × |
| `Sources/Services/RawExportProviderDetector.swift` | 164 | ファイル名/path から provider 判定 | × |
| `Sources/Services/RawExportVaultSupport.swift` | 86 | protocol 定義 + result type | × |
| `Sources/Database/GRDBRawExportVault.swift` | 1440 | **raw export blob 保管**（SHA-256、LZFSE 圧縮、FTS5 索引） | ○ (raw_export_* 系) |

**合計: 約 3115 行**（うち Swift importer "本体" は約 2665 行: 1440 + 360 + 292 + 256 + 170 + 156 + 97 + ...）

**テスト**:
- `Tests/MadiniArchiveTests/ConversationTranscriptExtractorTests.swift` (399 行) — Claude/ChatGPT extractor のテスト
- `Tests/MadiniArchiveTests/RawExportVaultTests.swift` (486 行) — vault ingest, dedup, blob compression, search のテスト

### 2.2 各 extractor の現状

#### ClaudeTranscriptExtractor（256 行）

**入力**: Claude `conversations.json` の単一 conversation オブジェクト

**現在の対応**:

| ブロック型 | 対応状況 |
|-----------|---------|
| `type: "text"` | ✓ → `.text(String)` |
| `type: "image"` | ✓ → `.image(AssetReference)` |
| `type: "tool_use"` | ✓ → `.toolUse(name, inputJSON)` |
| `type: "tool_result"` | ✓ → `.toolResult(String)`（埋め込み画像も処理） |
| `type: "artifact"` | ✓ → `.artifact(id, title, kind, content)` |
| `type: "thinking"` | ✗ **意図的に skip** (lines 116-120) |
| `type: "redacted_thinking"` | ✗ skip |
| `attachments[]`, `files[]` | ✓ → `.attachment(...)` |

**未対応**:
- DB 書き込み一切なし
- 重複検出なし
- ハッシュ計算なし
- raw_sources 挿入なし

#### ChatGPTTranscriptExtractor（292 行）

**入力**: ChatGPT `conversations-*.json` の conversation オブジェクト

**現在の対応**:

| `content_type` | 対応状況 |
|----------------|---------|
| `text` | ✓ → `parts[]` 結合 |
| `multimodal_text` | ✓ → text + image_asset_pointer + audio/video |
| `code` | ✓ → `.code(language, source)` |
| `execution_output` | ✓ → `.toolResult(text)` |
| `tether_browsing_display` | ✓ → `.toolResult(...)` |
| `tether_quote` | ✓ → `.toolResult(...)` |
| `system_error` | ✓ → `.toolResult("Error: ...")` |
| `user_editable_context` | ✓ skip |
| `model_editable_context` | ✓ skip |

**DAG walk**: `current_node` から parent ポインタで遡上、逆順で chronological 配列に。
（注: Python importer は **異なる戦略** を使う — 後述 §3.2）

**未対応**: DB 書き込み、dedup、ハッシュ、raw_sources 挿入

### 2.3 ConversationTranscriptBlock の表現力

現在定義されている case（`Sources/Services/ConversationTranscript.swift` lines 51-59）:

```swift
case text(String)
case code(language: String?, source: String)
case image(AssetReference)
case attachment(AssetReference, name: String?, sizeBytes: Int64?)
case toolUse(name: String, inputJSON: String)
case toolResult(String)
case artifact(identifier: String, title: String?, kind: String?, content: String)
case unsupported(summary: String)
```

**重要**: `.thinking` case は**存在しない**。前述の rendering-framework レポートで提案されている `.thinking(String)` を追加するためには、

1. enum に case 追加
2. `ClaudeTranscriptExtractor` の skip ロジックを emit に変更
3. 呼び出し側（`RawTranscriptReaderView` 等）の switch 拡充

が必要（Phase 2 相当の作業）。

各社構造化要素のカバレッジ:

| 構造化要素 | Claude | ChatGPT | Gemini |
|-----------|--------|---------|--------|
| 通常テキスト | ✓ | ✓ | ✗ extractor 自体なし |
| コードブロック | △ (markdown 経由) | ✓ | ✗ |
| ツール呼び出し | ✓ | ✓ (execution/tether) | ✗ |
| 画像 | ✓ | ✓ (asset_pointer) | ✗ |
| 添付ファイル | ✓ | △ | ✗ |
| Artifact / Canvas | ✓ | ✗ | ✗ |
| Thinking / reasoning | ✗ (skip) | ✗ | ✗ |
| Web grounding | ✗ | △ (tether 限定) | ✗ |

### 2.4 Swift 側の DB 書き込み権限の現状

| テーブル | Swift 書き込み | Python 書き込み |
|---------|---------------|----------------|
| `conversations` | ✗ | ✓ |
| `messages` | ✗ | ✓ |
| `raw_sources` | ✗ | ✓ |
| `search_idx` (FTS5) | ✗ | ✓ |
| `raw_export_snapshots` | ✓ | ✗ |
| `raw_export_blobs` | ✓ | ✗ |
| `raw_export_files` | ✓ | ✗ |
| `raw_export_search_idx` | ✓ | ✗ |
| `raw_export_asset_links` | ✓ | ✗ |
| `projects`, `project_memberships`, `project_suggestions` | ✓ | ✗ |
| `bookmarks`, `bookmark_tags`, `bookmark_tag_links` | ✓ | ✗ |
| `saved_filters` | ✓ | ✗ |
| `conversation_raw_refs` | ? (要確認、おそらく Python のみ) | ✓ |

**核心の事実**: Swift は `conversations` / `messages` テーブルに**一切書き込まない**。canonical conversation データの書き手は Python のみ。

### 2.5 Import UI エントリーポイント

**現状の唯一のエントリ**: drag-and-drop（`Sources/Views/macOS/MacOSRootView.swift` lines 214-328）

```
ユーザーがファイルをドラッグ
  ↓
.onDrop(of: [.fileURL]) { handleFileURLDrop() }
  ↓
ImportCoordinator.importDroppedURLs(urls, services:)
  ├── GRDBRawExportVault.ingest(urls:)            ← Swift 完結
  ├── JSONImporter.importFiles(urls:)             ← Python shell-exec
  └── JSONImportProjectReconciler.reconcileImportedFiles()  ← Swift 完結
```

**ない物**:
- File → Import メニュー
- onboarding wizard
- CLI/scriptable interface

### 2.6 ImportService protocol の状況

AGENTS.md (lines 68-75) の Repository Inventory 表に:

```
| ImportService | File parse + DB registration + raw source preservation | GRDBImportService |
```

と記載されているが、**実装は存在しない**。`grep "protocol.*ImportService" Sources/` は 0 件。

実態:
- `JSONImporter` enum (Python shell-exec wrapper)
- `ImportCoordinator` struct (orchestrator)
- `RawExportVault` protocol + `GRDBRawExportVault` 実装

つまり ImportService は **aspirational**（仕様文書上は存在するがコード未実装）。

---

## 3. Python importer の現状機能

### 3.1 規模

ロケーション: `~/Madini_Dev/`

| ファイル | 行数 | 役割 |
|---------|------|------|
| `split_chatlog.py` | 655 | パーサー本体 + import orchestration |
| `archive_store.py` | 3,269 | DB schema + 全ストア操作（import + view 両方） |
| `madini_gui.py` | 885 | PyQt6 GUI（webview ホスト） |
| `viewer_builder.py` | 359 | HTML/JS viewer 生成 |
| `app_paths.py` | 46 | パス管理 |
| `app_metadata.py` | 8 | メタデータ |
| `Scripts/audit_math_rendering.py` | 153 | 数式レンダリング監査ツール |

**合計**: 約 5,375 行 / うち import-only ロジック ≈ 1,255 行（split_chatlog.py 全部 + archive_store.py 内 register_conversation/register_raw_source/hash 関連）

import 比率: **約 23%**（残り 77% は viewing, search, bookmark, virtual thread, GUI）

### 3.2 各 provider parser の実装

#### Claude (`parse_claude_export`, lines 406-440)

入力形式バリエーション:
- JSON 配列 of conversation objects
- `chat_messages[]` を持つ
- `content[]` 配列内に文字列と構造化要素が混在
- model 情報は `modelCode` / `modelName` / メッセージメタデータのいずれか

固有処理:
- **tool_use**: `_format_claude_tool_block()` (lines 349-371) で名前 + input サマリ抽出
- **thinking**: 文字列として扱われ、メッセージ本文に**結合される** ← **Bug B の root cause**
- **artifact**: 明示的にパースされず、content の一部として通過
- **tool_result**: blockquote として整形、成功時は冗長性回避のため drop
- **添付**: メタデータで参照のみ、別レコード化なし

#### ChatGPT (`parse_chatgpt_export`, lines 271-324)

DAG 平坦化戦略（**Swift と異なる**）:

```python
nodes = sorted(
    [n for n in conv["mapping"].values() if n.get("message")],
    key=lambda x: x["message"].get("create_time") or 0,
)
for node in nodes:
    # 平坦に追加
```

- **全ノードを `create_time` で sort して順次追加**
- `current_node` からの walk-up は**しない**
- 結果: 全ブランチ・全リトライがタイムスタンプ順に並ぶ "transcript-like view"

これに対し Swift の ChatGPTTranscriptExtractor は `current_node` から parent を辿る walk-up 戦略。**両者は同じ JSON から異なる結果を生成する**。

#### Gemini (`parse_gemini_export`, lines 443-489)

- 各 item に `time`（ISO 8601）と `title`、`safeHtmlItem[]` を持つ
- 会話 ID なし → `gemini_{date_key}` で日付ベース合成
- **HTML → Markdown 変換**: `gemini_html_to_md()` (lines 157-226) が table, heading, list, link, blockquote, math, HTML entity を処理
- `safeHtmlItem[]` の最初の要素のみ採用、残りは無視

#### Markdown (`parse_markdown_file`, lines 233-268)

- セクションヘッダーで role 判定
- キーワード: ai/assistant/gpt/claude/gemini/madini/user/オーナー/自分
- title: ファイル名 stem
- timestamp: ファイルの mtime/birth time

### 3.3 重複検出とハッシュ

```python
# archive_store.py:330-331
conv_hash = hashlib.md5(f"{title}{full_text}".encode("utf-8")).hexdigest()
```

- **入力**: `title` + 全メッセージの結合 text
- **アルゴリズム**: MD5
- **constraint**: `conversations.hash UNIQUE`

衝突時の挙動 (`register_conversation`, lines 316-376):
1. `INSERT` 試行
2. `IntegrityError` → 既存行に対して `update_conversation_metadata()` (lines 574-582)
3. 更新フィールド: model, source_file, raw_source_id, source_created_at, imported_at
4. **本文は上書きしない**（AGENTS.md "Preserve originals" 原則）

### 3.4 raw_sources テーブル書き込み

`register_raw_source()` (archive_store.py:379-458):

| フィールド | 値 |
|-----------|-----|
| source_hash | SHA256(file bytes) |
| source_format | "json" / "markdown" / "text" |
| source_path | absolute path |
| source_created_at | birth/mtime |
| imported_at | import 実行時刻 |
| mime_type | 拡張子から推定 |
| size_bytes | UTF-8 byte count |
| text_encoding | "utf-8" |
| raw_text | **ファイル内容そのまま verbatim** |
| raw_bytes_path | NULL（未使用） |

upsert: `source_hash` 衝突時は欠損フィールドのみ UPDATE。

### 3.5 ChatGPT DAG 平坦化 — Python vs Swift 差異

| 観点 | Python | Swift |
|------|--------|-------|
| 戦略 | timestamp sort で全 node 採用 | `current_node` から walk-up |
| ブランチ・retry | 含める（時系列順） | ユーザに最後に見えた chain のみ |
| 出力サイズ | 大きい場合あり | コンパクト |
| ユーザ体感への近さ | 低い（時系列で混在） | 高い（最終 chain） |

**Python から Swift へ完全移行する場合、この差異が既存 import 結果との互換性問題を生む**。Swift 戦略の方が "正しい" と思われるが、過去の archive で見えていた message が再 import で消える可能性。

### 3.6 添付・画像処理

- `raw_bytes_path` フィールドはあるが**常に NULL**
- inline base64 画像: 抽出・別保存しない
- ファイル参照: 追跡しない
- アプローチ: raw_text を verbatim 保管、本文は全てテキスト化

これに対し Swift 側の RawExportVault は blob を SHA-256 で content-addressed 保管し、LZFSE 圧縮、メタデータ DB 化、FTS5 索引まで完備。**Swift の vault 設計は Python の raw_sources を大幅に超えた設計**。

### 3.7 エラーハンドリング

```python
# split_chatlog.py:516-602
for path in paths:
    cursor.execute("SAVEPOINT import_file")
    try:
        conversations = parse_input_file(path, raw_text=...)
    except Exception:
        cursor.execute("ROLLBACK TO SAVEPOINT import_file")
        continue
    # ...
    cursor.execute("RELEASE SAVEPOINT import_file")
conn.commit()
```

- ファイル単位で SAVEPOINT
- 不正 JSON → そのファイルだけ rollback、次に進む
- 部分 import OK
- ロギング: ステータス bar への日本語メッセージ（構造化ロギングなし）

### 3.8 import 以外の責務

`archive_store.py` (3,269 行) のうち import 関連は ~600 行のみ。残りは:

| 領域 | 関数例 |
|------|-------|
| 検索 | `search_conversations_for_spec()` |
| 表示 | `fetch_conversation_index()`, `fetch_conversation_detail()`, `fetch_conversation_raw_*()` |
| Virtual threads | `build_virtual_thread()`, `build_virtual_thread_preview()` |
| Bookmarks | `set_bookmark()`, `fetch_bookmark_states()`, タグ管理 |
| Saved filters | `save_recent_filter()`, `save_saved_view()` |
| Metadata 計算 | `prompt_count` (INSERT 時)、`primary_time` (read 時 expression) |

**重要**: Swift 側は既にこれら view 機能を独自実装済み（`GRDBSearchRepository` 等）。Swift importer 完成時に Python の view 機能はもはや不要。**Python importer 廃止＝ Python 全廃止に等しい**。

### 3.9 GUI 統合

`madini_gui.py` (885 行):
- drag-drop イベント → `Worker(QThread)` → `split_chatlog.main()` 呼び出し
- import 後に webview リフレッシュ
- WebChannel bridge `ViewerBridge` で 40+ Python 関数を JavaScript に exposed
- import 以外: 主に webview ホスト

**call site**: `split_chatlog.main()` は GUI Worker から1箇所で呼ばれるのみ。Swift 側からは `JSONImporter` で 1箇所。**呼び出し点は計2箇所**。

---

## 4. archive.db スキーマの移行影響

### 4.1 現状スキーマ（Python 所有テーブル）

`conversations`:
- id (TEXT PK), source, title, model, prompt_count, source_file, source_created_at, imported_at, date_str, hash (UNIQUE)

`messages`:
- conv_id (TEXT, FK), msg_index (INTEGER), id (INTEGER), role, content (TEXT)
- **content は plain TEXT のみ**。JSON 列なし。構造化データ保管不可。

`raw_sources`:
- source_hash (PK), source_format, source_path, raw_text (verbatim), 他

`search_idx` (FTS5):
- conv_id UNINDEXED, title, content
- tokenize="unicode61"

### 4.2 thinking / tool_use / artifact 等を保持するスキーマ変更案

#### 案 1: messages.content_json 列追加

```sql
ALTER TABLE messages ADD COLUMN content_json TEXT;  -- JSON serialized blocks
```

**メリット**:
- 既存 `content` 列を残せるため後方互換
- 単一行 SELECT で構造化データ取得可能
- Python が NULL のままでも既存 view は動く

**デメリット**:
- JSON クエリは SQLite の JSON1 拡張に依存
- FTS5 索引は別途構築必要（content_json から抽出 → search_idx 投入）
- Python と Swift の両方で読み書きする場合、JSON schema が "defacto schema" となり管理コスト

#### 案 2: 別テーブル messages_blocks 新設

```sql
CREATE TABLE messages_blocks (
    conv_id TEXT, msg_index INT, block_index INT,
    block_type TEXT, block_data TEXT,  -- JSON
    PRIMARY KEY (conv_id, msg_index, block_index)
);
```

**メリット**:
- 正規化された構造、各ブロック単位でクエリ可能
- block_type 単位の集計や検索が容易（"このユーザーの thinking 出現率" 等）
- 大きい artifact 等を分離保管可能

**デメリット**:
- JOIN が必要、view 層クエリの修正範囲大
- 行数が爆発（メッセージあたり 1〜10 ブロック）→ FTS5 索引の構築方針再考必要
- 既存の `messages.content` との二重管理（または content を消す → 後方互換破壊）

#### 案 3: スキーマ変更なし、raw vault に頼る

view 層で必要な時に raw_export blob を読み出してパースする。

**メリット**:
- スキーマ無変更、AGENTS.md の compatibility 制約を完全に守れる
- 既に `RawTranscriptReaderView` がこの方式で動作
- vault dedup により記憶容量効率良い

**デメリット**:
- vault が無い古い conversation には適用不可（fallback 必要）
- 都度パースのオーバーヘッド
- スキーマレベルでは構造化データを"持っていない"状態が続く

### 4.3 トレードオフまとめ

| 観点 | 案 1 (content_json) | 案 2 (messages_blocks) | 案 3 (raw vault のみ) |
|------|---------------------|------------------------|---------------------|
| Python 互換 | ◎ (旧 content そのまま) | △ (新規列の意味付け要協議) | ◎ (無変更) |
| Query 性能 | ○ (1行 fetch + JSON parse) | △ (JOIN 必要) | × (blob 読み込み + parse) |
| FTS5 検索 | △ (別途 index 必要) | △ (同左) | ○ (raw_export_search_idx 既存) |
| 既存 view 層改修 | 中 | 大 | 小 |
| 構造化集計の容易さ | ○ | ◎ | × |
| Swift 移行との整合 | ○ | ◎ | △ (vault が既存資産で連続性高い) |

**推奨**: 案 1（messages.content_json 追加）か案 3（vault のみ）。案 2 は移行規模が大きく、Python 互換維持コストも高い。

### 4.4 既存データの扱い

#### 案 A: 既存 archive.db を保持し、新形式で再 import

手順:
1. 既存 raw_export blob から re-extract（Swift importer で）
2. 同じ MD5 hash → 既存 conversation row との衝突 → metadata UPDATE のみ
3. content_json (案 1 の場合) を populate
4. messages.content は更新しない（"原本保全"）

**整合性課題**:
- raw vault に存在しない conversation（古い import）は新形式に上げられない
- bookmarks の target_id は conversation_id なので影響なし
- saved_filters の filter_json も影響なし
- 検索 index は再構築可能（rebuildable cache 扱い）

#### 案 B: 既存データを消して全 re-import

手順:
1. archive.db を削除
2. raw vault から全 re-import

**問題**:
- raw vault に無い古い conversation は失われる
- bookmarks の target_id が dangling になる
- オーナーの import 履歴メタデータも失われる

→ **採用不可**。

#### 案 C: 並行運用、徐々にマイグレート

- Python と Swift が両方動く状態を維持
- 新規 import は Swift で content_json 込み
- 既存 conversation は読み出し時に lazy upgrade（vault がある場合）

**問題**:
- 状態管理が複雑
- "片方だけ更新された" 不整合が発生しうる

→ **不採用**（複雑性が上回る）。

**推奨**: 案 A（保持 + 上書き不可で metadata のみ更新）。

---

## 5. SwiftUI 移行計画との整合

### 5.1 オーナーの長期計画と現行ドキュメントの**重大な乖離**

オーナー申告の長期計画: 「Python core 分離 → SwiftUI 移行」

**ところが現行ドキュメントは正反対の立場を取っている**:

`README.md` line 3:
> 既存の Python 版 Madini Archive が canonical な実装であり、この SwiftUI 版はその上に載るフロントエンドとして設計されている。

`README.md` line 12 (やらないこと):
> Python core の機能の完全な再現

`AGENTS.md` line 8:
> It shares the same SQLite schema and data directory as the Python version and must remain compatible with it.

`AGENTS.md` line 32:
> The SQLite schema must remain compatible with the Python version. Do not rename tables or columns without a migration path that both versions can consume.

`Sources/Services/JSONImporter.swift` lines 21-31（**特に重要**）:
> "The Swift app itself is read-only against `archive.db`. All write-side conversation parsing — Claude's array-per-file format, ChatGPT's nested `mapping`, Gemini's `messages` layout, source-file registration, the 20+ GRDB tables the schema spans — lives in a ~3000-line Python stack under `~/Madini_Dev`. **Re-porting that logic to Swift just to support drag-and-drop would duplicate a living codebase** (the Python side gets regular updates as export formats change) **and immediately drift**. Shelling out keeps both sides in sync: whatever the Python importer accepts today, drag-and-drop accepts today."

**つまり現行コードベースは「Python は canonical で残す、Swift は frontend として載る」という設計を**明示的に**選んでいる**。Swift importer に完全移行するということは、

- README.md の改訂
- AGENTS.md の section "SQLite Schema Compatibility" 改訂
- JSONImporter.swift の設計コメント全否定

を伴う**方針転換**になる。

これは技術的判断の前に、オーナーと方針整合の確認が必要な事項。

### 5.2 importer の位置付け（仕様文書の見方）

AGENTS.md の repository inventory（line 75）:

| Protocol | Responsibility | Implementation |
|---------|----------------|----------------|
| ImportService | File parse + DB registration + raw source preservation | GRDBImportService |

これは **aspirational**（実装未存在）。AGENTS.md の line 91-92 にも:

> Import logic lives in `ImportService` and parser files under `Import/`, not in UI code.
> The UI collects file URLs and passes them to `ImportService.importFiles()`. Nothing else.

とあるが、実コードでは `JSONImporter.importFiles()` という enum static method が Python を shell-exec しているのみ。**つまり AGENTS.md は将来的に Swift importer を作る前提で書かれている**が、JSONImporter.swift のコメントは**それを否定している**。

ドキュメント間で内部矛盾がある。これも方針整合の論点。

### 5.3 移行戦略 3 案

#### 戦略 A: Swift importer を main 上で完成させ、Python を read-only な参照実装として凍結

- 以後の import は全て Swift
- 既存 archive.db は触らない
- 既存データの thinking 結合問題は raw transcript path で凌ぐ
- Python は仕様参照用（リグレッションテストの ground truth として使う）

**メリット**:
- 過去データに非破壊
- Python の新形式追従義務から解放
- 移行規模は中程度

**デメリット**:
- 既存 conversations の thinking blocks は消えたまま（vault 経由でしか見えない）
- ChatGPT DAG 平坦化が Python と Swift で異なるため、新旧 import 結果の体感差

#### 戦略 B: Swift importer を完成させ、既存 archive.db を再生成

- 過去の全 raw_export snapshot から Swift importer で re-import
- thinking 結合問題が遡って解消
- Python は完全廃止

**メリット**:
- 過去データも構造化される
- Bug B が完全に解消
- 設計の一貫性最高

**デメリット**:
- raw vault に無い conversation は失われる（重大）
- bookmarks/saved_filters の target_id 整合性確保の追加実装必要
- 移行規模が最大、リスクも最大
- ChatGPT 平坦化戦略変更に伴う見え方の変化

#### 戦略 C: Swift importer の作業を SwiftUI 移行 Phase に組み込む

- 今は Python のまま延命
- thinking ブロックを保存するために Python に最小限の改修（例: thinking を `<thinking>...</thinking>` でマークアップして結合）
- Swift importer は SwiftUI 移行 Phase（将来）で実装
- オーナーの長期計画と直接整合

**メリット**:
- 直近のバグ修正コストが最小
- SwiftUI 移行 Phase の規模が予測しやすい
- 現行ドキュメントの方針と矛盾しない（重要）

**デメリット**:
- Python 改修と Swift 改修の両方が必要（短期＋長期）
- SwiftUI 移行 Phase の本格化までは Python 依存が続く

### 5.4 戦略比較表

| 観点 | 戦略 A | 戦略 B | 戦略 C |
|------|--------|--------|--------|
| 既存データ保護 | ◎ | ✗ | ◎ |
| 過去 thinking の救出 | ✗ (vault のみ) | ◎ | △ (Python 改修次第) |
| 直近のバグ修正コスト | 大 | 特大 | 小 |
| 長期コスト | 中 | 小 | 中 |
| 現行ドキュメントとの整合 | △ (要 README/AGENTS 改訂) | ✗ (大幅改訂) | ◎ |
| オーナー申告の長期計画との整合 | ◎ | ◎ | ◎ |
| Python 並行維持の負担 | 不要 | 不要 | 必要 |
| ChatGPT DAG 戦略変更の影響 | 中 | 大 | 小 (Python のまま) |
| AGENTS.md "core 分離" 方針 | △ | △ | ◎ |
| SwiftUI iOS 展開時の容易さ | ◎ | ◎ | △ |

---

## 6. 作業量見積もり

### 6.1 戦略 A（Swift importer 完成、Python 凍結）

#### Phase 構成

**Phase A-1: ImportService protocol 確立** (小)
- `Sources/Core/Repositories.swift` に protocol 追加
- 既存 `JSONImporter` を `LegacyPythonImportService` にリネームして残す
- `AppServices` に DI を追加

**Phase A-2: ConversationTranscript → DB normalize 層実装** (大)
- 新規ファイル `Sources/Database/GRDBImportService.swift`（約 800-1000 行）
  - conversations テーブルへの insert
  - messages テーブルへの insert（`content` flat text として書く）
  - hash 計算（MD5 of title+content）→ conversations.hash
  - 重複検出 → metadata 更新パス
  - raw_sources insert（既存スキーマと整合する形）
  - SAVEPOINT パターンの再現
- `ConversationTranscriptBlock` → flat text への変換ロジック
- 既存の `ImportCoordinator` を再配線

**Phase A-3: .thinking ブロック対応** (小〜中)
- `ConversationTranscriptBlock.thinking(String)` case 追加
- `ClaudeTranscriptExtractor` の skip → emit に変更
- `RawTranscriptReaderView` で thinking を collapsed 表示
- 既存 messages.content への落とし方は2案:
  - (a) thinking を捨てる（現行 Python 互換）
  - (b) `messages.content_json` 列追加して保存（スキーマ拡張）
- 案 (b) なら追加ファイル 1〜2 + migration 1 件

**Phase A-4: Gemini extractor 実装** (中)
- 新規 `Sources/Services/GeminiTranscriptExtractor.swift`（約 200-300 行）
- HTML → Markdown 変換（NSAttributedString or 自前 parser、約 100-150 行）
- 日付ベース合成 ID

**Phase A-5: Markdown extractor 実装** (小)
- 新規 `Sources/Services/MarkdownTranscriptExtractor.swift`（約 100-150 行）
- セクションヘッダーから role 判定
- 既存パターンキーワード（ai/assistant/gpt/claude/gemini/madini/user/オーナー/自分）

**Phase A-6: ChatGPT DAG 戦略の選択** (小だが重要)
- Swift の walk-up 戦略を維持するか、Python の timestamp-sort 戦略に合わせるか
- ドキュメント化必要

**Phase A-7: search_idx (FTS5) の Swift 側書き込み** (中)
- 既存 GRDBSearchRepository は読み込みのみ
- 新規: import 時に search_idx を更新するコード（既存 trigger があるか要確認）
- 約 100-200 行

**Phase A-8: テスト** (中)
- 既存 Python importer の出力を ground truth とする回帰テスト
- 同じ入力で Python と Swift を走らせて diff を取るテストツール
- 約 500-1000 行

**Phase A-9: UI** (小)
- File → Import メニュー追加（drag-drop は既存）
- progress reporting の改善（Python の stderr 経由ではなく Swift native）

#### 工数感

| シナリオ | 規模 |
|---------|------|
| 楽観 | 中 (1週間) |
| 標準 | **大 (2-3週間)** |
| 悲観 | 特大 (1〜2 ヶ月) |

主要リスク:
- 既存 import 結果との微妙な差異（hash が変わる → conversation が重複と認識されない）
- ChatGPT DAG 戦略変更の影響範囲
- Gemini HTML→Markdown の細かい挙動

### 6.2 戦略 B（Swift importer 完成 + 既存 DB 再生成）

戦略 A の全 Phase + 以下:

**Phase B-1: re-import infrastructure** (大)
- 既存 raw_export snapshot を全走査して順次 import
- 進捗 UI、cancel 対応
- 約 300-500 行

**Phase B-2: bookmarks / saved_filters 整合性確保** (中〜大)
- conversation_id が変わらないことを保証する仕組み
- target_id の "rebase" ロジック（ChatGPT DAG 戦略変更で msg_index がずれた場合）
- 約 300-500 行 + テスト

**Phase B-3: 失われるデータの扱い** (中)
- vault に無い conversation の救済策
- 完全な metadata だけ残す UI

#### 工数感

| シナリオ | 規模 |
|---------|------|
| 楽観 | 大 (3週間) |
| 標準 | **特大 (5-6週間)** |
| 悲観 | 特大 (2 ヶ月超) |

### 6.3 戦略 C（Python 改修 + 将来 Swift）

#### 短期 Phase (Python 改修)

**Phase C-1: Python に thinking 保存追加** (小)
- `split_chatlog.py` の `parse_claude_export` 内で thinking ブロックを `<thinking>...</thinking>` のマーカーで囲んで concat
- もしくは新規列 `messages.content_json` を Python 側で populate
- 約 50-100 行

**Phase C-2: rendering-framework レポートの PreambleDetector** (小〜中)
- マーカーを認識して folding する
- 既に rendering-framework レポートで設計済み

#### 長期 Phase（SwiftUI 移行本格化時）

戦略 A と同等の作業を、SwiftUI 移行のスケジュールに組み込む。

#### 工数感

| 範囲 | 規模 |
|------|------|
| 短期のみ | **小〜中 (数日〜1週間)** |
| 長期含む | 戦略 A と同等 |

### 6.4 リスク評価

| リスク | 戦略 A | 戦略 B | 戦略 C |
|------|--------|--------|--------|
| 既存データ破損 | 低 (新規 import のみ) | **特大** (再生成) | なし (Python 改修のみ) |
| 既存検索/bookmarks への副作用 | 中 | 大 | 低 |
| Rollback 容易性 | 中 (Python に戻せる) | 低 (DB 再生成後は戻せない) | 高 (Python 改修だけ revert すれば良い) |
| 新形式 export への追従義務発生 | 大 (Swift 側で追従) | 大 | 小 (Python が引き続き対応) |
| ChatGPT DAG 戦略変更の影響 | 新規 import に限定 | 全 conversation | なし |
| AGENTS.md / README.md の方針改訂 | 必要 | 必要 | 不要 |

### 6.5 Bug B 解決タイミングの比較

| 戦略 | 新規 import の Bug B | 既存 conversation の Bug B |
|------|---------------------|---------------------------|
| A | Phase A-3 完了時 (.thinking emit) | 解消されない（vault 経由で raw 読みは可能） |
| B | Phase A-3 完了時 | Phase B-1 完了時 (再 import) |
| C 短期のみ | Phase C-1 + C-2 完了時 | Phase C-1 完了 + 既存に対し Python 再 import (vault があれば可能) |
| C 長期込 | A と同じ | B と同じ |

**暫定対応**: いずれの戦略でも、解決前は **raw transcript path** (`RawTranscriptReaderView`) で正しい thinking 表示が可能。view 層の default を raw transcript 優先に切り替えるのは即時可能（rendering-framework レポート参照）。

---

## 7. 推奨戦略とその根拠

### 7.1 推奨: 戦略 C（Python 改修 + 将来 Swift）

理由:

1. **現行ドキュメントとの整合**: README.md / AGENTS.md は明示的に「Python が canonical、Swift は frontend」と書かれている。戦略 A/B はこれを覆す方針転換であり、オーナーと**まず方針確認すべき**。
2. **直近のバグ修正コストが最小**: Bug B は Python 側の数十行の改修と Swift 側の rendering-framework Phase 1 で解決可能。
3. **戻せる**: Python 改修なら revert 一発で元に戻せる。
4. **Swift importer は寿命の長い投資**: 戦略 A/B は数週間の集中開発を要する。短期不具合修正の手段としてはオーバーキル。
5. **SwiftUI iOS 展開や Python 廃止が本当に長期計画にあるなら、戦略 C の長期 Phase でやればよい**。今やる必然性が薄い。

### 7.2 戦略 C の具体的アクション

**直近 (1-2日)**:
1. Python `split_chatlog.py` の `parse_claude_export` 内で thinking を区切りマーカー (例: `\n\n<thinking>\n...\n</thinking>\n\n`) で保存
2. rendering-framework レポートの Phase 1（PreambleDetector）でマーカー認識ベースの折りたたみを実装
3. 既存 conversation の救済: vault 経由で再 import すれば過去データも修正可能

**中期 (rendering-framework Phase 2 と同期)**:
4. ConversationTranscriptBlock に `.thinking` case 追加
5. `ClaudeTranscriptExtractor` の skip → emit に変更
6. `RawTranscriptReaderView` で thinking 表示

**長期（SwiftUI 移行本格化時）**:
7. 戦略 A の Phase A-1〜A-9 を実施
8. README.md / AGENTS.md を更新

### 7.3 戦略 C を採用しない場合の選択肢

オーナーが「**もう Python は廃止したい**」と判断した場合は、戦略 A が次点。理由:

- 戦略 B の "DB 再生成" は不可逆性が高すぎる
- 戦略 A は新規 import から切り替え、過去データは raw vault 経由でアクセスする構成が現実的

戦略 A 採用時の最重要決定:
- ChatGPT DAG 平坦化戦略を Python 互換にするか、Swift current_node walk-up 維持か
- 既存ドキュメント（README/AGENTS）の方針改訂をどこまでやるか

---

## 8. オーナーと相談すべき判断ポイント

### 8.1 方針整合（最優先）

「Python core 分離 → SwiftUI 移行」という長期計画と、現行ドキュメント（README.md / AGENTS.md / JSONImporter.swift コメント）の「Python は canonical で残す」立場の**どちらが正**か。

具体的な選択肢:
- (a) 長期計画が正、ドキュメントは古い → README/AGENTS/JSONImporter コメントを更新する
- (b) ドキュメントが正、長期計画は変わった → 戦略 C を採用、Python を残す
- (c) 並行する両立計画 → 戦略 C 短期のみ + 長期で戦略 A

### 8.2 戦略の選択

戦略 A / B / C のどれを採用するか。本レポートは戦略 C を推奨するが、オーナーの判断材料を再確認:

- 戦略 A: 1-2 ヶ月の集中作業、AGENTS/README 改訂、Python 廃止
- 戦略 B: 戦略 A + 既存データ再生成（高リスク、推奨しない）
- 戦略 C: 数日の Python 改修、長期は別 Phase

### 8.3 スキーマ変更の有無

`messages.content_json` 列を追加するか否か。

- 追加する: 構造化データを canonical に持てる、ただし Python と Swift の二重対応コスト
- 追加しない（vault 経由のみ）: スキーマ無変更、ただし文脈表示は raw vault 必須

### 8.4 ChatGPT DAG 戦略

戦略 A 採用時、Swift の walk-up 戦略を維持するか、Python の timestamp sort に合わせるか。

- 維持: ユーザに最後に見えた chain で再現性が高い、ただし既存 import との差異が出る
- 合わせる: 過去データと一致、ただし Swift の方が "正しい" 設計と思われる

### 8.5 既存 conversation の thinking 救済範囲

- raw vault に存在する conversation は救える
- vault に無い古い conversation はどうするか
  - そのまま放置
  - "thinking 不明" のラベルで明示
  - 古いデータは UI 上で別扱い

### 8.6 暫定対応の優先度

戦略決定までの間、view 層で raw transcript path を優先表示するか:

- する: ユーザ体感の即時改善、ただし vault 整合性のあるデータに限定
- しない: 戦略決定まで現状維持、Bug B は残る

### 8.7 Python 廃止のスコープ

戦略 A 採用時、Python 完全廃止か部分残存か:

- 完全廃止: madini_gui.py / viewer_builder.py 含めて全廃、Swift だけになる
- import のみ廃止: archive_store.py の import 部のみ消し、ただし Python GUI は残す（並行運用）
- リファレンス保管: コードは残すが run しない（仕様の ground truth として）

### 8.8 テストインフラ

戦略 A 採用時、Python importer 出力を ground truth とした回帰テストを書くか。書くなら:

- 楽観: テスト 1000 行
- 悲観: テスト 3000 行 + Python 環境セットアップ自動化

これが工数見積もりを大きく左右する。
