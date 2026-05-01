# Phase 1 関連ファイル索引

`thinking-preservation-2026-04-30.md` §3.1 のファイル特定結果を再掲し、各ファイルの現状と Phase 1 でどう変わる予定かを 1-2 行で要約。Phase 1 のスコープは Python core 側のスキーマ migration のみ。

実在性の確認: 2026-04-30 時点で `~/Madini_Dev/` 配下に対象ファイルが存在することを確認済み（`ls ~/Madini_Dev/` 実行結果より `archive_store.py`, `split_chatlog.py`, `madini_gui.py`, `viewer_builder.py`, `app_paths.py`, `app_metadata.py` を確認）。

---

## Python 側 — Phase 1 で改修するファイル

### `~/Madini_Dev/archive_store.py`（3,269 行）

DB スキーマ定義 + 全ストア操作（import + view 両方）。Phase 1 の改修対象はこのファイルのみ。

#### 改修箇所 (a) — `messages` CREATE TABLE 文（lines 37-51 周辺）

**現状**:
```python
cursor.execute(
    """
    CREATE TABLE IF NOT EXISTS messages (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        conv_id TEXT,
        role TEXT,
        content TEXT,
        msg_index INTEGER,
        FOREIGN KEY(conv_id) REFERENCES conversations(id)
    )
    """
)
```

**Phase 1 後**:
```python
cursor.execute(
    """
    CREATE TABLE IF NOT EXISTS messages (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        conv_id TEXT,
        role TEXT,
        content TEXT,
        content_json TEXT,
        msg_index INTEGER,
        FOREIGN KEY(conv_id) REFERENCES conversations(id)
    )
    """
)
```

新規 archive.db では CREATE 時点で `content_json` 列が含まれる。既存 DB は次の改修箇所 (b) の ALTER で追補。

#### 改修箇所 (b) — `_ensure_message_columns()` の新設

**現状**: 関数自体が存在しない。`_ensure_conversation_columns` という同種の関数が conversations テーブル用に存在する（lines 67 周辺）。

**Phase 1 後**:
```python
def _ensure_message_columns(cursor):
    """messages テーブルへの後方互換的な列追加。
    既存 archive.db に対しては ADD COLUMN、新規 DB では CREATE TABLE で
    既に含まれている前提（CREATE TABLE 側も更新する）。"""
    existing = {row["name"] for row in cursor.execute("PRAGMA table_info(messages)")}
    if "content_json" not in existing:
        try:
            cursor.execute("ALTER TABLE messages ADD COLUMN content_json TEXT")
        except sqlite3.OperationalError:
            pass
```

`_ensure_conversation_columns` の隣に配置。

#### 改修箇所 (c) — `init_db()` からの呼び出し追加

**現状**: `init_db()` は `_ensure_conversation_columns(cursor)` を呼んでいる（migration 機構の起動点）。

**Phase 1 後**: `_ensure_conversation_columns(cursor)` の直後に `_ensure_message_columns(cursor)` を追加。

#### Phase 1 では触らないもの（archive_store.py 内）

- `register_conversation()` (lines 316-377 周辺): messages INSERT への `content_json` 追加は Phase 2 で実施
- `update_conversation_metadata()`: 無変更
- `fetch_conversation_detail()` / `fetch_conversation_index()` / `fetch_all_conversations()`: 無変更（Python reader は引き続き `content` 列のみ参照）
- FTS5 (`search_idx`) の生成・populate ロジック: 無変更
- hash 計算: 無変更

---

## Python 側 — Phase 1 では改修しないが関連するファイル

### `~/Madini_Dev/split_chatlog.py`（655 行）

import orchestration + 各 provider parser。Phase 2 / 2b で改修するが、**Phase 1 では無変更**。

主な改修予定箇所（Phase 2 / 2b）:
- `parse_claude_export()` (lines 406-440): `_build_claude_message_blocks()` 新設で thinking 抽出
- `_build_claude_message_text()` (lines 374-403): 既存挙動維持（content 列用）
- `parse_chatgpt_export()` (lines 271-324): `_build_chatgpt_message_blocks()` 新設で thoughts / reasoning_recap 抽出

### `~/Madini_Dev/madini_gui.py`（885 行）

PyQt6 GUI。`fetch_conversation_detail()` 等を呼ぶだけで `content_json` は読まない。**Phase 1 では完全に無変更**。将来 thinking を Python GUI でも表示したい場合は別 Phase で扱う。

### `~/Madini_Dev/viewer_builder.py`（359 行）

HTML viewer 生成。Python GUI 内部で使われる。**Phase 1 では無変更**。

---

## Swift 側 — Phase 1 では原則変更なし

Swift reader は新スキーマ（`content_json`）を参照しない。Phase 1 は「列を追加するだけ」なので Swift 側コードへの影響はない。Phase 3 で forward-compat read（`Message.contentBlocks` 追加）を実装するまで `content_json` は populate されないし、読まれない。

念のため Phase 1 完了後に確認すべきこと:

- `swift build` が成功する（コード変更なしなので必ず成功）
- 既存 archive.db を Madini Archive で開いて表示が壊れていないこと（Swift 側の SELECT は `content` のみ読むため、新列追加で壊れる経路なし）

参考: Swift 側で関連する将来の改修箇所（Phase 3 以降のスコープ）:

- `Sources/Core/Repositories.swift` (line 149 周辺の Message struct): `contentBlocks: [MessageBlock]?` 追加 — Phase 3
- `Sources/Database/GRDBConversationRepository.swift` (line 88-90 周辺): SELECT に `content_json` を追加して JSONDecoder で parse — Phase 3
- `Sources/Views/Shared/MessageRenderProfile.swift`: `collapsesThinking: Bool` 追加 — Phase 4
- 新規 `Sources/Views/Shared/StructuredBlockGrouper.swift`: 構造ベースの折りたたみグルーピング — Phase 4
- `Sources/Views/Shared/MessageBubbleView.swift`: `renderItems` の構造ベース優先化 — Phase 4
- `Sources/Views/Shared/ForeignLanguageGrouping.swift`: deprecation — Phase 6（今夜の hotfix 群もここで除去）

---

## スキーマ — migration ファイルの追加場所

Madini Archive は SQLite + Python の組み合わせで、**専用の migration 管理ツール（Alembic 等）は使っていない**。スキーマ変更は `archive_store.py` 内で:

1. `CREATE TABLE IF NOT EXISTS` で新規 DB 用の最新形を定義
2. `_ensure_*_columns()` 関数で既存 DB への ALTER TABLE ADD COLUMN を実行
3. `init_db()` が両者を呼び出す

という慣行に従う。Phase 1 はこの慣行の範囲内で完結する。新しい migration ファイル / ディレクトリは作らない。

参考: Swift 側の GRDB は別途 `DatabaseMigrator` を使うが、これは view-layer table（bookmarks, saved_filters, projects 等）専用。`messages` / `conversations` などの core table の migration は Python 側で完結させる（`AGENTS.md` の "SQLite Schema Compatibility" 節参照）。

---

## まとめ

Phase 1 で実際に編集するファイルは **`~/Madini_Dev/archive_store.py` の 1 ファイルのみ**、追加行数は約 20 行。他のファイルは無変更。

Phase 2（Claude parser 改修）から `split_chatlog.py` も対象に入る。Phase 3 から Swift 側に影響が及ぶ。
