import hashlib
import json
import sqlite3
from collections import defaultdict
from datetime import datetime
from pathlib import Path

from app_paths import DB_FILE, HISTORY_FILE, THEMES_JSON, USER_DATA_DIR, migrate_legacy_user_data_dir


def ensure_user_data_dir() -> None:
    migrate_legacy_user_data_dir()
    USER_DATA_DIR.mkdir(parents=True, exist_ok=True)


def init_db(db_file=DB_FILE):
    if Path(db_file) == DB_FILE:
        ensure_user_data_dir()
    else:
        Path(db_file).parent.mkdir(parents=True, exist_ok=True)
    conn = sqlite3.connect(db_file)
    cursor = conn.cursor()
    cursor.execute(
        """
        CREATE TABLE IF NOT EXISTS conversations (
            id TEXT PRIMARY KEY,
            source TEXT,
            model TEXT,
            source_file TEXT,
            title TEXT,
            date_str TEXT,
            prompt_count INTEGER,
            hash TEXT UNIQUE
        )
        """
    )
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
    cursor.execute(
        "CREATE INDEX IF NOT EXISTS idx_messages_conv_order ON messages(conv_id, msg_index)"
    )
    _ensure_conversation_columns(cursor)
    _ensure_message_columns(cursor)
    _ensure_raw_source_tables(cursor)
    _ensure_saved_filter_tables(cursor)
    _ensure_bookmark_tables(cursor)
    try:
        cursor.execute(
            """
            CREATE VIRTUAL TABLE IF NOT EXISTS search_idx
            USING fts5(conv_id, title, content, tokenize="unicode61")
            """
        )
    except sqlite3.OperationalError:
        pass
    conn.commit()
    return conn


def _ensure_conversation_columns(cursor):
    existing = {
        row[1]
        for row in cursor.execute("PRAGMA table_info(conversations)").fetchall()
    }
    if "model" not in existing:
        try:
            cursor.execute("ALTER TABLE conversations ADD COLUMN model TEXT")
        except sqlite3.OperationalError:
            pass
    if "source_file" not in existing:
        try:
            cursor.execute("ALTER TABLE conversations ADD COLUMN source_file TEXT")
        except sqlite3.OperationalError:
            pass
    if "raw_source_id" not in existing:
        try:
            cursor.execute("ALTER TABLE conversations ADD COLUMN raw_source_id INTEGER")
        except sqlite3.OperationalError:
            pass
    if "source_created_at" not in existing:
        try:
            cursor.execute("ALTER TABLE conversations ADD COLUMN source_created_at TEXT")
        except sqlite3.OperationalError:
            pass
    if "imported_at" not in existing:
        try:
            cursor.execute("ALTER TABLE conversations ADD COLUMN imported_at TEXT")
        except sqlite3.OperationalError:
            pass
    if "imported_at" in {
        row[1]
        for row in cursor.execute("PRAGMA table_info(conversations)").fetchall()
    }:
        try:
            cursor.execute(
                """
                UPDATE conversations
                SET imported_at = COALESCE(imported_at, date_str)
                WHERE imported_at IS NULL OR TRIM(imported_at) = ''
                """
            )
        except sqlite3.OperationalError:
            pass
    try:
        cursor.execute(
            """
            CREATE INDEX IF NOT EXISTS idx_conversations_raw_source_id
            ON conversations(raw_source_id)
            """
        )
    except sqlite3.OperationalError:
        pass


def _ensure_message_columns(cursor):
    """Backward-compatible column additions for the messages table.

    Phase 1 of the thinking-preservation plan introduces a
    `content_json` TEXT column alongside the existing flat `content`
    column. The new column will (in Phase 2 / 2b) carry a structured
    block list — Claude `thinking` blocks, ChatGPT `thoughts` /
    `reasoning_recap`, etc. — so the Swift reader can render
    monologue-vs-response folds from explicit structure instead of
    the language-detection heuristic that powered the temporary
    hotfixes.

    Phase 1 only adds the column. Existing rows stay at NULL until
    backfilled (Phase 5) or rewritten by a fresh import (Phase 2 /
    2b). The flat `content` column is intentionally untouched so:

    - The PyQt6 viewer keeps reading prose from `content` exactly as
      before.
    - The Swift reader keeps working until Phase 3 wires up the
      `content_json` SELECT.
    - The `conversations.hash` MD5 — computed from
      `title + "\n".join(m["text"])` over the flat content path —
      stays stable, so re-imports continue to dedupe correctly.

    Mirrors the pattern in `_ensure_conversation_columns` so the
    migration cost is the same on every `init_db()` call after the
    first.
    """
    existing = {
        row[1]
        for row in cursor.execute("PRAGMA table_info(messages)").fetchall()
    }
    if "content_json" not in existing:
        try:
            cursor.execute("ALTER TABLE messages ADD COLUMN content_json TEXT")
        except sqlite3.OperationalError:
            pass


def _ensure_raw_source_tables(cursor):
    cursor.execute(
        """
        CREATE TABLE IF NOT EXISTS raw_sources (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            source_hash TEXT NOT NULL UNIQUE,
            source_format TEXT NOT NULL,
            source_path TEXT,
            source_created_at TEXT,
            imported_at TEXT NOT NULL,
            mime_type TEXT,
            size_bytes INTEGER,
            text_encoding TEXT,
            raw_text TEXT,
            raw_bytes_path TEXT
        )
        """
    )
    cursor.execute(
        """
        CREATE INDEX IF NOT EXISTS idx_raw_sources_format_imported
        ON raw_sources(source_format, imported_at DESC, id DESC)
        """
    )


def _ensure_saved_filter_tables(cursor):
    cursor.execute(
        """
        CREATE TABLE IF NOT EXISTS saved_filters (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            kind TEXT NOT NULL,
            target_type TEXT NOT NULL,
            filter_hash TEXT NOT NULL,
            label TEXT NOT NULL,
            filter_json TEXT NOT NULL,
            created_at TEXT NOT NULL,
            last_used_at TEXT NOT NULL
        )
        """
    )
    cursor.execute(
        """
        CREATE UNIQUE INDEX IF NOT EXISTS idx_saved_filters_lookup
        ON saved_filters(kind, target_type, filter_hash)
        """
    )
    cursor.execute(
        """
        CREATE INDEX IF NOT EXISTS idx_saved_filters_recent
        ON saved_filters(kind, target_type, last_used_at DESC, created_at DESC)
        """
    )


def _ensure_bookmark_tables(cursor):
    cursor.execute(
        """
        CREATE TABLE IF NOT EXISTS bookmarks (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            target_type TEXT NOT NULL,
            target_id TEXT NOT NULL,
            payload_json TEXT,
            created_at TEXT NOT NULL,
            updated_at TEXT NOT NULL
        )
        """
    )
    cursor.execute(
        """
        CREATE UNIQUE INDEX IF NOT EXISTS idx_bookmarks_target
        ON bookmarks(target_type, target_id)
        """
    )
    cursor.execute(
        """
        CREATE INDEX IF NOT EXISTS idx_bookmarks_recent
        ON bookmarks(target_type, updated_at DESC, created_at DESC)
        """
    )
    cursor.execute(
        """
        CREATE TABLE IF NOT EXISTS bookmark_tags (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            name TEXT NOT NULL UNIQUE COLLATE NOCASE,
            system_key TEXT,
            is_system INTEGER NOT NULL DEFAULT 0,
            created_at TEXT NOT NULL,
            updated_at TEXT NOT NULL
        )
        """
    )
    existing_columns = {
        row[1]
        for row in cursor.execute("PRAGMA table_info(bookmark_tags)").fetchall()
    }
    if "system_key" not in existing_columns:
        try:
            cursor.execute("ALTER TABLE bookmark_tags ADD COLUMN system_key TEXT")
        except sqlite3.OperationalError:
            pass
    if "is_system" not in existing_columns:
        try:
            cursor.execute("ALTER TABLE bookmark_tags ADD COLUMN is_system INTEGER NOT NULL DEFAULT 0")
        except sqlite3.OperationalError:
            pass
    cursor.execute(
        """
        CREATE TABLE IF NOT EXISTS bookmark_tag_links (
            bookmark_id INTEGER NOT NULL,
            tag_id INTEGER NOT NULL,
            created_at TEXT NOT NULL,
            PRIMARY KEY (bookmark_id, tag_id),
            FOREIGN KEY(bookmark_id) REFERENCES bookmarks(id),
            FOREIGN KEY(tag_id) REFERENCES bookmark_tags(id)
        )
        """
    )
    cursor.execute(
        """
        CREATE INDEX IF NOT EXISTS idx_bookmark_tag_links_tag
        ON bookmark_tag_links(tag_id, bookmark_id)
        """
    )
    cursor.execute(
        """
        CREATE INDEX IF NOT EXISTS idx_bookmark_tag_links_bookmark
        ON bookmark_tag_links(bookmark_id, tag_id)
        """
    )
    cursor.execute(
        """
        CREATE UNIQUE INDEX IF NOT EXISTS idx_bookmark_tags_system_key
        ON bookmark_tags(system_key)
        WHERE system_key IS NOT NULL
        """
    )


def _get_conversation_columns(cursor):
    return {
        row[1]
        for row in cursor.execute("PRAGMA table_info(conversations)").fetchall()
    }


def _table_exists(cursor, table_name):
    row = cursor.execute(
        """
        SELECT 1
        FROM sqlite_master
        WHERE type = 'table' AND name = ?
        """,
        (table_name,),
    ).fetchone()
    return row is not None


def _current_timestamp():
    return datetime.now().strftime("%Y-%m-%d %H:%M:%S")


def _conversation_select_fragment(cursor, table_alias="conversations"):
    columns = _get_conversation_columns(cursor)
    model_expr = (
        f"{table_alias}.model AS model"
        if "model" in columns
        else "NULL AS model"
    )
    source_file_expr = (
        f"{table_alias}.source_file AS source_file"
        if "source_file" in columns
        else "NULL AS source_file"
    )
    return model_expr, source_file_expr, columns


def _conversation_primary_time_expr(columns, table_alias="conversations"):
    # Backend source of truth for Madini's primary time precedence.
    # Keep viewer-side getConversationPrimaryTimeInfo aligned with this order.
    candidates = []
    if "source_created_at" in columns:
        candidates.append(f"NULLIF(TRIM({table_alias}.source_created_at), '')")
    if "imported_at" in columns:
        candidates.append(f"NULLIF(TRIM({table_alias}.imported_at), '')")
    candidates.append(f"NULLIF(TRIM({table_alias}.date_str), '')")
    return "COALESCE(" + ", ".join(candidates) + ")"


def _joined_message_text(messages, role):
    return "\n\n".join(m["text"] for m in messages if m["role"] == role)


def register_conversation(
    cursor,
    conv_id,
    source,
    title,
    messages,
    model=None,
    source_file=None,
    raw_source_id=None,
    source_created_at=None,
    imported_at=None,
):
    full_text = "\n".join(m["text"] for m in messages)
    prompts_text = _joined_message_text(messages, "user")
    conv_hash = hashlib.md5(f"{title}{full_text}".encode("utf-8")).hexdigest()
    imported_timestamp = imported_at or datetime.now().strftime("%Y-%m-%d %H:%M:%S")

    try:
        cursor.execute(
            """
            INSERT INTO conversations (
                id, source, model, source_file, raw_source_id, source_created_at, imported_at,
                title, date_str, prompt_count, hash
            )
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            """,
            (
                conv_id,
                source,
                model,
                source_file,
                raw_source_id,
                source_created_at,
                imported_timestamp,
                title,
                imported_timestamp,
                sum(1 for m in messages if m["role"] == "user"),
                conv_hash,
            ),
        )
        for index, message in enumerate(messages):
            blocks = message.get("blocks")
            # Phase 2 / 2b: serialize the structured block list (Claude
            # thinking + text + tool_use, ChatGPT o3 thinking + text)
            # into the new content_json column. Falls back to NULL when
            # the parser didn't produce blocks — markdown imports,
            # ChatGPT messages without reasoning, Claude messages whose
            # `content[]` carries no thinking / tool blocks. The flat
            # `content` column stays as the canonical user-facing prose
            # (hash-stable) regardless.
            blocks_json = (
                json.dumps(blocks, ensure_ascii=False) if blocks else None
            )
            cursor.execute(
                """
                INSERT INTO messages (conv_id, role, content, content_json, msg_index)
                VALUES (?, ?, ?, ?, ?)
                """,
                (conv_id, message["role"], message["text"], blocks_json, index),
            )
        try:
            cursor.execute(
                "INSERT INTO search_idx (conv_id, title, content) VALUES (?, ?, ?)",
                (conv_id, title, full_text or prompts_text),
            )
        except sqlite3.OperationalError:
            pass
        return True
    except sqlite3.IntegrityError:
        return False
    except sqlite3.DatabaseError as exc:
        print(f"⚠️ DB error: {exc}")
        return False


def register_raw_source(
    cursor,
    source_hash,
    source_format,
    source_path=None,
    source_created_at=None,
    imported_at=None,
    mime_type=None,
    size_bytes=None,
    text_encoding=None,
    raw_text=None,
    raw_bytes_path=None,
):
    imported_timestamp = imported_at or _current_timestamp()
    existing = cursor.execute(
        """
        SELECT id, source_path, source_created_at, mime_type, size_bytes, text_encoding, raw_text, raw_bytes_path
        FROM raw_sources
        WHERE source_hash = ?
        """,
        (source_hash,),
    ).fetchone()
    if existing:
        updates = []
        params = []
        if source_path and not existing[1]:
            updates.append("source_path = ?")
            params.append(source_path)
        if source_created_at and not existing[2]:
            updates.append("source_created_at = ?")
            params.append(source_created_at)
        if mime_type and not existing[3]:
            updates.append("mime_type = ?")
            params.append(mime_type)
        if size_bytes is not None and existing[4] is None:
            updates.append("size_bytes = ?")
            params.append(size_bytes)
        if text_encoding and not existing[5]:
            updates.append("text_encoding = ?")
            params.append(text_encoding)
        if raw_text and not existing[6]:
            updates.append("raw_text = ?")
            params.append(raw_text)
        if raw_bytes_path and not existing[7]:
            updates.append("raw_bytes_path = ?")
            params.append(raw_bytes_path)
        if updates:
            params.append(existing[0])
            cursor.execute(
                f"""
                UPDATE raw_sources
                SET {", ".join(updates)}
                WHERE id = ?
                """,
                params,
            )
        return existing[0]

    cursor.execute(
        """
        INSERT INTO raw_sources (
            source_hash, source_format, source_path, source_created_at, imported_at,
            mime_type, size_bytes, text_encoding, raw_text, raw_bytes_path
        )
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        """,
        (
            source_hash,
            source_format,
            source_path,
            source_created_at,
            imported_timestamp,
            mime_type,
            size_bytes,
            text_encoding,
            raw_text,
            raw_bytes_path,
        ),
    )
    return cursor.lastrowid


def update_conversation_metadata(
    cursor,
    conv_id,
    model=None,
    source_file=None,
    raw_source_id=None,
    source_created_at=None,
    imported_at=None,
):
    updates = []
    params = []
    columns = _get_conversation_columns(cursor)
    if model is not None:
        updates.append("model = ?")
        params.append(model)
    if source_file is not None:
        updates.append("source_file = ?")
        params.append(source_file)
    if "raw_source_id" in columns and raw_source_id is not None:
        updates.append("raw_source_id = ?")
        params.append(raw_source_id)
    if "source_created_at" in columns and source_created_at is not None:
        updates.append("source_created_at = ?")
        params.append(source_created_at)
    if "imported_at" in columns and imported_at is not None:
        updates.append("imported_at = ?")
        params.append(imported_at)
    if not updates:
        return 0
    params.append(conv_id)
    cursor.execute(
        f"""
        UPDATE conversations
        SET {", ".join(updates)}
        WHERE id = ?
        """,
        params,
    )
    return cursor.rowcount


def fetch_all_conversations(db_file=DB_FILE):
    if not db_file.exists():
        return []

    conn = sqlite3.connect(f"file:{db_file}?mode=ro", uri=True)
    conn.row_factory = sqlite3.Row
    cursor = conn.cursor()
    model_expr, source_file_expr, _columns = _conversation_select_fragment(cursor, "conversations")
    starred_prompt_counts = _fetch_starred_prompt_counts(cursor)

    conv_rows = cursor.execute(
        f"""
        SELECT id, source, title, date_str, prompt_count
             , {model_expr}, {source_file_expr}
        FROM conversations
        ORDER BY date_str DESC
        """
    ).fetchall()

    grouped_messages = defaultdict(list)
    for row in cursor.execute(
        """
        SELECT conv_id, role, content, msg_index
        FROM messages
        ORDER BY conv_id, msg_index
        """
    ).fetchall():
        grouped_messages[row["conv_id"]].append(
            {"role": row["role"], "text": row["content"]}
        )

    conversations = []
    for row in conv_rows:
        messages = grouped_messages.get(row["id"], [])
        conversations.append(
            {
                "id": row["id"],
                "source": row["source"],
                "title": row["title"],
                "date": row["date_str"],
                "model": row["model"],
                "sourceFile": row["source_file"],
                "bookmarked": starred_prompt_counts.get(row["id"], 0) > 0,
                "starredPromptCount": starred_prompt_counts.get(row["id"], 0),
                "messages": messages,
                "promptCount": row["prompt_count"],
                "prompts_text": _joined_message_text(messages, "user"),
                "answers_text": "\n\n".join(
                    m["text"] for m in messages if m["role"] != "user"
                ),
            }
        )

    conn.close()
    return conversations


def fetch_conversation_index(
    db_file=DB_FILE,
    prompt_search_limit=1200,
    answer_search_limit=1200,
    preview_limit=5,
    preview_chars=24,
):
    if not db_file.exists():
        return []

    conn = sqlite3.connect(f"file:{db_file}?mode=ro", uri=True)
    conn.row_factory = sqlite3.Row
    cursor = conn.cursor()
    model_expr, source_file_expr, _columns = _conversation_select_fragment(cursor, "conversations")
    source_created_at_expr = (
        "conversations.source_created_at AS source_created_at"
        if "source_created_at" in _columns
        else "NULL AS source_created_at"
    )
    imported_at_expr = (
        "conversations.imported_at AS imported_at"
        if "imported_at" in _columns
        else "NULL AS imported_at"
    )
    starred_prompt_counts = _fetch_starred_prompt_counts(cursor)

    conv_rows = cursor.execute(
        f"""
        SELECT id, source, title, date_str, prompt_count
             , {model_expr}, {source_file_expr}
             , {source_created_at_expr}, {imported_at_expr}
        FROM conversations
        ORDER BY date_str DESC
        """
    ).fetchall()

    by_conv = {
        row["id"]: {
            "id": row["id"],
            "source": row["source"],
            "title": row["title"],
            "date": row["date_str"],
            "model": row["model"],
            "sourceFile": row["source_file"],
            "source_created_at": row["source_created_at"],
            "imported_at": row["imported_at"],
            "bookmarked": starred_prompt_counts.get(row["id"], 0) > 0,
            "starredPromptCount": starred_prompt_counts.get(row["id"], 0),
            "promptCount": row["prompt_count"],
            "promptPreviews": [],
            "prompts_text": "",
            "answers_text": "",
        }
        for row in conv_rows
    }

    for row in cursor.execute(
        """
        SELECT conv_id, role, content, msg_index
        FROM messages
        ORDER BY conv_id, msg_index
        """
    ).fetchall():
        conv = by_conv.get(row["conv_id"])
        if not conv:
            continue

        content = row["content"] or ""
        if row["role"] == "user":
            if len(conv["promptPreviews"]) < preview_limit:
                conv["promptPreviews"].append(
                    {
                        "messageIndex": row["msg_index"],
                        "preview": content.splitlines()[0][:preview_chars],
                    }
                )
            remaining = prompt_search_limit - len(conv["prompts_text"])
            if remaining > 0:
                if conv["prompts_text"]:
                    conv["prompts_text"] += "\n\n"
                    remaining -= 2
                conv["prompts_text"] += content[: max(0, remaining)]
        else:
            remaining = answer_search_limit - len(conv["answers_text"])
            if remaining > 0:
                if conv["answers_text"]:
                    conv["answers_text"] += "\n\n"
                    remaining -= 2
                conv["answers_text"] += content[: max(0, remaining)]

    conn.close()
    return [by_conv[row["id"]] for row in conv_rows]


def fetch_conversation_detail(conv_id, db_file=DB_FILE):
    # Lightweight conversation payload for normal viewing. Keep this cheap and avoid
    # inlining raw source content here; raw/provenance inspection belongs to
    # fetch_conversation_raw_source().
    if not db_file.exists():
        return None

    conn = sqlite3.connect(f"file:{db_file}?mode=ro", uri=True)
    conn.row_factory = sqlite3.Row
    cursor = conn.cursor()
    model_expr, source_file_expr, _columns = _conversation_select_fragment(cursor, "conversations")
    raw_source_id_expr = (
        "conversations.raw_source_id AS raw_source_id"
        if "raw_source_id" in _columns
        else "NULL AS raw_source_id"
    )
    source_created_at_expr = (
        "conversations.source_created_at AS source_created_at"
        if "source_created_at" in _columns
        else "NULL AS source_created_at"
    )
    imported_at_expr = (
        "conversations.imported_at AS imported_at"
        if "imported_at" in _columns
        else "NULL AS imported_at"
    )
    source_format_expr = "NULL AS source_format"
    join_clause = ""
    if "raw_source_id" in _columns and _table_exists(cursor, "raw_sources"):
        source_format_expr = "raw_sources.source_format AS source_format"
        join_clause = "LEFT JOIN raw_sources ON raw_sources.id = conversations.raw_source_id"
    starred_prompt_counts = _fetch_starred_prompt_counts(cursor)

    row = cursor.execute(
        f"""
        SELECT
              conversations.id AS id
            , conversations.source AS source
            , conversations.title AS title
            , conversations.date_str AS date_str
            , conversations.prompt_count AS prompt_count
             , {model_expr}, {source_file_expr}
             , {raw_source_id_expr}, {source_created_at_expr}, {imported_at_expr}, {source_format_expr}
        FROM conversations
        {join_clause}
        WHERE conversations.id = ?
        """,
        (conv_id,),
    ).fetchone()
    if not row:
        conn.close()
        return None

    messages = [
        {"role": msg["role"], "text": msg["content"]}
        for msg in cursor.execute(
            """
            SELECT role, content, msg_index
            FROM messages
            WHERE conv_id = ?
            ORDER BY msg_index
            """,
            (conv_id,),
        ).fetchall()
    ]

    conn.close()
    return {
        "id": row["id"],
        "source": row["source"],
        "title": row["title"],
        "date": row["date_str"],
        "model": row["model"],
        "sourceFile": row["source_file"],
        "raw_source_id": row["raw_source_id"],
        "source_created_at": row["source_created_at"],
        "imported_at": row["imported_at"],
        "source_format": row["source_format"],
        "bookmarked": starred_prompt_counts.get(row["id"], 0) > 0,
        "starredPromptCount": starred_prompt_counts.get(row["id"], 0),
        "promptCount": row["prompt_count"],
        "messages": messages,
        "prompts_text": _joined_message_text(messages, "user"),
        "answers_text": "\n\n".join(m["text"] for m in messages if m["role"] != "user"),
    }


def fetch_conversation_raw_source(conv_id, db_file=DB_FILE, preview_chars=12000):
    # Developer-facing raw/provenance entry point. This is intentionally separate
    # from fetch_conversation_detail() so raw text stays out of the normal detail path.
    if not db_file.exists():
        return None

    conn = sqlite3.connect(f"file:{db_file}?mode=ro", uri=True)
    conn.row_factory = sqlite3.Row
    cursor = conn.cursor()
    columns = _get_conversation_columns(cursor)
    if "raw_source_id" not in columns:
        conn.close()
        return None

    row = cursor.execute(
        """
        SELECT
            c.id AS conv_id,
            c.raw_source_id,
            c.source_file,
            c.source_created_at AS conversation_source_created_at,
            c.imported_at AS conversation_imported_at,
            r.source_hash,
            r.source_format,
            r.source_path,
            r.source_created_at,
            r.imported_at,
            r.mime_type,
            r.size_bytes,
            r.text_encoding,
            CASE
                WHEN r.raw_text IS NULL THEN 0
                ELSE LENGTH(r.raw_text)
            END AS raw_text_length,
            SUBSTR(COALESCE(r.raw_text, ''), 1, ?) AS raw_text_preview,
            r.raw_bytes_path
        FROM conversations c
        LEFT JOIN raw_sources r ON r.id = c.raw_source_id
        WHERE c.id = ?
        """,
        (max(0, int(preview_chars or 0)), conv_id),
    ).fetchone()
    conn.close()
    if not row:
        return None

    if row["raw_source_id"] is None:
        return {
            "convId": row["conv_id"],
            "rawSourceId": None,
            "sourceFile": row["source_file"],
            "sourceCreatedAt": row["conversation_source_created_at"],
            "importedAt": row["conversation_imported_at"],
            "rawTextPreview": "",
            "rawTextLength": 0,
            "rawTextTruncated": False,
            "available": False,
        }

    raw_text_length = int(row["raw_text_length"] or 0)
    raw_text_preview = row["raw_text_preview"] or ""
    return {
        "convId": row["conv_id"],
        "rawSourceId": row["raw_source_id"],
        "sourceHash": row["source_hash"],
        "sourceFormat": row["source_format"],
        "sourcePath": row["source_path"],
        "sourceCreatedAt": row["source_created_at"] or row["conversation_source_created_at"],
        "importedAt": row["imported_at"] or row["conversation_imported_at"],
        "mimeType": row["mime_type"],
        "sizeBytes": row["size_bytes"],
        "textEncoding": row["text_encoding"],
        "rawTextPreview": raw_text_preview,
        "rawTextLength": raw_text_length,
        "rawTextTruncated": raw_text_length > len(raw_text_preview),
        "rawBytesPath": row["raw_bytes_path"],
        "sourceFile": row["source_file"],
        "available": True,
    }


def fetch_conversation_raw_text(conv_id, db_file=DB_FILE):
    if not db_file.exists():
        return None

    conn = sqlite3.connect(f"file:{db_file}?mode=ro", uri=True)
    conn.row_factory = sqlite3.Row
    cursor = conn.cursor()
    columns = _get_conversation_columns(cursor)
    if "raw_source_id" not in columns:
        conn.close()
        return None

    row = cursor.execute(
        """
        SELECT
            c.id AS conv_id,
            c.raw_source_id,
            r.raw_text
        FROM conversations c
        LEFT JOIN raw_sources r ON r.id = c.raw_source_id
        WHERE c.id = ?
        """,
        (conv_id,),
    ).fetchone()
    conn.close()
    if not row:
        return None

    if row["raw_source_id"] is None:
        return {
            "convId": row["conv_id"],
            "available": False,
            "rawText": "",
        }

    raw_text = row["raw_text"] or ""
    return {
        "convId": row["conv_id"],
        "available": True,
        "rawText": raw_text,
        "rawTextLength": len(raw_text),
    }


def _group_turns(message_rows):
    turns = []
    current_turn = None

    for row in message_rows:
        role = row["role"]
        content = row["content"] or ""
        msg_index = row["msg_index"]

        if role == "user":
            if current_turn and (current_turn["prompt"] or current_turn["answers"]):
                turns.append(current_turn)
            current_turn = {"messageIndex": msg_index, "prompt": content, "answers": []}
            continue

        if current_turn is None:
            current_turn = {"messageIndex": msg_index, "prompt": "", "answers": []}
        current_turn["answers"].append(content)

    if current_turn and (current_turn["prompt"] or current_turn["answers"]):
        turns.append(current_turn)

    return turns


def _normalize_search_words(words):
    return [word.strip().lower() for word in words if word and word.strip()]


def normalize_keyword_search_spec(search_spec):
    search_spec = search_spec or {}
    return {
        "query": str(search_spec.get("query") or "").strip(),
        "words": _normalize_search_words(search_spec.get("words") or []),
        "includeTitle": bool(search_spec.get("includeTitle", True)),
        "includePrompt": bool(search_spec.get("includePrompt", True)),
        "includeAnswer": bool(search_spec.get("includeAnswer", True)),
    }


def _build_all_words_like_clause(columns, normalized_words):
    if not columns or not normalized_words:
        return "", []

    clauses = []
    params = []
    for word in normalized_words:
        token = f"%{word}%"
        subclauses = [f"LOWER(COALESCE({column}, '')) LIKE ?" for column in columns]
        clauses.append("(" + " OR ".join(subclauses) + ")")
        params.extend([token] * len(columns))

    return " AND ".join(clauses), params


def _build_contains_clause(column, value):
    normalized = (value or "").strip().lower()
    if not normalized:
        return "", []
    return f"LOWER(COALESCE({column}, '')) LIKE ?", [f"%{normalized}%"]


def _make_keyword_search_result(title_matched=False):
    return {
        "matched": True,
        "hits": 0,
        "matchedMessageIndexes": [],
        "titleMatched": bool(title_matched),
    }


def _build_keyword_turn_columns(include_prompt, include_answer):
    turn_columns = []
    if include_prompt:
        turn_columns.append("prompt")
    if include_answer:
        turn_columns.append("answer")
    return turn_columns


def _search_conversation_title_matches(cursor, normalized_words):
    title_clause, title_params = _build_all_words_like_clause(["title"], normalized_words)
    if not title_clause:
        return []
    return cursor.execute(
        f"""
        SELECT id
        FROM conversations
        WHERE {title_clause}
        """,
        title_params,
    ).fetchall()


def _search_conversation_turn_matches(cursor, normalized_words, include_prompt, include_answer):
    turn_columns = _build_keyword_turn_columns(include_prompt, include_answer)
    if not turn_columns:
        return []

    turn_clause, turn_params = _build_all_words_like_clause(turn_columns, normalized_words)
    if not turn_clause:
        return []

    return cursor.execute(
        f"""
        WITH ordered_messages AS (
            SELECT
                conv_id,
                role,
                content,
                msg_index,
                SUM(CASE WHEN role = 'user' THEN 1 ELSE 0 END) OVER (
                    PARTITION BY conv_id
                    ORDER BY msg_index
                    ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW
                ) AS turn_no
            FROM messages
        ),
        turns AS (
            SELECT
                conv_id,
                MIN(CASE WHEN role = 'user' THEN msg_index END) AS message_index,
                MAX(CASE WHEN role = 'user' THEN content END) AS prompt,
                GROUP_CONCAT(
                    CASE WHEN role != 'user' THEN content END,
                    char(10) || char(10)
                ) AS answer
            FROM ordered_messages
            GROUP BY conv_id, turn_no
        )
        SELECT conv_id, message_index
        FROM turns
        WHERE message_index IS NOT NULL
          AND {turn_clause}
        ORDER BY conv_id, message_index
        """,
        turn_params,
    ).fetchall()


def fetch_filter_options(db_file=DB_FILE):
    if not db_file.exists():
        return {"services": [], "models": [], "modelsByService": {}, "sourceFiles": []}

    conn = sqlite3.connect(f"file:{db_file}?mode=ro", uri=True)
    conn.row_factory = sqlite3.Row
    cursor = conn.cursor()
    columns = _get_conversation_columns(cursor)

    def fetch_values(column):
        if column not in columns:
            return []
        return [
            row[0]
            for row in cursor.execute(
                f"""
                SELECT DISTINCT {column}
                FROM conversations
                WHERE {column} IS NOT NULL AND TRIM({column}) != ''
                ORDER BY {column} COLLATE NOCASE
                """
            ).fetchall()
        ]

    options = {
        "services": fetch_values("source"),
        "models": fetch_values("model"),
        "sourceFiles": fetch_values("source_file"),
    }
    if "source" in columns and "model" in columns:
        models_by_service = {}
        for row in cursor.execute(
            """
            SELECT DISTINCT source, model
            FROM conversations
            WHERE source IS NOT NULL
              AND TRIM(source) != ''
              AND model IS NOT NULL
              AND TRIM(model) != ''
            ORDER BY source COLLATE NOCASE, model COLLATE NOCASE
            """
        ).fetchall():
            service = row["source"]
            model = row["model"]
            models_by_service.setdefault(service, []).append(model)
        options["modelsByService"] = models_by_service
    else:
        options["modelsByService"] = {}
    conn.close()
    return options


def _normalize_filter_values(value):
    if value is None:
        return []
    if isinstance(value, (list, tuple, set)):
        values = value
    else:
        values = [value]
    normalized = []
    for item in values:
        text = str(item or "").strip()
        if text and text not in normalized:
            normalized.append(text)
    return normalized


def _normalize_bookmarked_filter(value):
    normalized = str(value or "").strip().lower()
    if normalized in {
        "bookmarked",
        "only",
        "true",
        "1",
        "yes",
        "starred",
        "starred-prompt",
        "has-starred-prompt",
    }:
        return "bookmarked"
    if normalized in {
        "not-bookmarked",
        "not_bookmarked",
        "exclude",
        "false",
        "0",
        "no",
        "not-starred",
        "without-starred-prompt",
    }:
        return "not-bookmarked"
    return "all"


def _normalize_virtual_thread_filters(filters):
    filters = filters or {}
    normalized = {}

    services = _normalize_filter_values(filters.get("service"))
    models = _normalize_filter_values(filters.get("model"))
    roles = _normalize_filter_values(filters.get("role"))
    bookmark_tags = _normalize_filter_values(filters.get("bookmarkTags"))
    bookmark_tag_groups = _normalize_bookmark_tag_groups(filters.get("bookmarkTagGroups"))
    date_from = str(filters.get("dateFrom") or "").strip()
    date_to = str(filters.get("dateTo") or "").strip()
    title_contains = str(filters.get("titleContains") or "").strip()
    prompt_contains = str(filters.get("promptContains") or "").strip()
    response_contains = str(filters.get("responseContains") or "").strip()
    source_file = str(filters.get("sourceFile") or "").strip()
    sort_mode = str(filters.get("sortMode") or "date-asc").strip() or "date-asc"
    bookmarked = _normalize_bookmarked_filter(filters.get("bookmarked"))

    if services:
        normalized["service"] = services
    if models:
        normalized["model"] = models
    if roles:
        normalized["role"] = roles
    if bookmark_tags:
        normalized["bookmarkTags"] = bookmark_tags
    if bookmark_tag_groups:
        normalized["bookmarkTagGroups"] = bookmark_tag_groups
    if date_from:
        normalized["dateFrom"] = date_from
    if date_to:
        normalized["dateTo"] = date_to
    if title_contains:
        normalized["titleContains"] = title_contains
    if prompt_contains:
        normalized["promptContains"] = prompt_contains
    if response_contains:
        normalized["responseContains"] = response_contains
    if source_file:
        normalized["sourceFile"] = source_file
    if bookmarked != "all":
        normalized["bookmarked"] = bookmarked
    normalized["sortMode"] = sort_mode
    return normalized


def _has_meaningful_virtual_thread_filters(filters):
    filters = _normalize_virtual_thread_filters(filters)
    return any(
        [
            filters.get("service"),
            filters.get("model"),
            filters.get("role"),
            filters.get("bookmarkTags"),
            filters.get("bookmarkTagGroups"),
            filters.get("dateFrom"),
            filters.get("dateTo"),
            filters.get("titleContains"),
            filters.get("promptContains"),
            filters.get("responseContains"),
            filters.get("sourceFile"),
            filters.get("bookmarked"),
        ]
    )


def _build_filter_history_label(filters):
    filters = _normalize_virtual_thread_filters(filters)
    parts = []

    services = filters.get("service") or []
    models = filters.get("model") or []
    roles = filters.get("role") or []
    bookmark_tags = filters.get("bookmarkTags") or []
    bookmark_tag_groups = _normalize_bookmark_tag_groups(filters.get("bookmarkTagGroups"))
    if services:
        parts.append(f"service={'+'.join(services)}")
    if models:
        parts.append(f"model={'+'.join(models)}")
    if filters.get("dateFrom") or filters.get("dateTo"):
        parts.append(f"{filters.get('dateFrom') or '...'}–{filters.get('dateTo') or '...'}")
    if filters.get("titleContains"):
        parts.append(f"title={filters['titleContains']}")
    if filters.get("promptContains"):
        parts.append(f"prompt={filters['promptContains']}")
    if filters.get("responseContains"):
        parts.append(f"response={filters['responseContains']}")
    if roles:
        parts.append(f"role={'+'.join(roles)}")
    if bookmark_tags:
        parts.append(f"tags={'|'.join(bookmark_tags)}")
    if bookmark_tag_groups:
        parts.extend([f"tags=({'&'.join(group)})" for group in bookmark_tag_groups])
    if filters.get("sourceFile"):
        parts.append(f"file={filters['sourceFile']}")
    if filters.get("bookmarked") == "bookmarked":
        parts.append("has starred prompt")
    elif filters.get("bookmarked") == "not-bookmarked":
        parts.append("without starred prompt")

    if not parts:
        return "All conversations"
    if len(parts) > 4:
        return ", ".join(parts[:4]) + f" +{len(parts) - 4}"
    return ", ".join(parts)


def _build_saved_filter_hash(kind, label, filter_json):
    if kind == "saved_view":
        seed = f"{str(label or '').strip()}\n{filter_json}"
    else:
        seed = filter_json
    return hashlib.md5(seed.encode("utf-8")).hexdigest()


def _normalize_bookmark_tag_groups(value):
    groups = []
    seen = set()
    if not isinstance(value, (list, tuple)):
        return groups
    for raw_group in value:
        normalized_group = _normalize_filter_values(raw_group)
        if len(normalized_group) < 2:
            continue
        key = tuple(normalized_group)
        if key in seen:
            continue
        seen.add(key)
        groups.append(normalized_group)
    return groups


def _combine_bookmark_tag_filter_groups(bookmark_tags, bookmark_tag_groups):
    combined = []
    seen = set()
    for tag in _normalize_filter_values(bookmark_tags):
        key = (tag,)
        if key in seen:
            continue
        seen.add(key)
        combined.append([tag])
    for group in _normalize_bookmark_tag_groups(bookmark_tag_groups):
        key = tuple(group)
        if key in seen:
            continue
        seen.add(key)
        combined.append(group)
    return combined


def _rename_tag_references_in_filters(filters, previous_name, next_name):
    if not isinstance(filters, dict):
        return filters, False

    old_name = str(previous_name or "").strip()
    new_name = str(next_name or "").strip()
    if not old_name or not new_name or old_name == new_name:
        return filters, False

    next_filters = dict(filters)
    changed = False

    bookmark_tags = [
        new_name if str(tag_name or "").strip() == old_name else str(tag_name or "").strip()
        for tag_name in _normalize_filter_values(next_filters.get("bookmarkTags"))
    ]
    bookmark_tags = list(dict.fromkeys([tag_name for tag_name in bookmark_tags if tag_name]))
    if bookmark_tags != _normalize_filter_values(next_filters.get("bookmarkTags")):
        changed = True
    if bookmark_tags:
        next_filters["bookmarkTags"] = bookmark_tags
    else:
        next_filters.pop("bookmarkTags", None)

    bookmark_tag_groups = []
    original_groups = _normalize_bookmark_tag_groups(next_filters.get("bookmarkTagGroups"))
    for group in original_groups:
        renamed_group = [
            new_name if str(tag_name or "").strip() == old_name else str(tag_name or "").strip()
            for tag_name in group
        ]
        normalized_group = _normalize_filter_values(renamed_group)
        if len(normalized_group) >= 2:
            bookmark_tag_groups.append(normalized_group)
    bookmark_tag_groups = _normalize_bookmark_tag_groups(bookmark_tag_groups)
    if bookmark_tag_groups != original_groups:
        changed = True
    if bookmark_tag_groups:
        next_filters["bookmarkTagGroups"] = bookmark_tag_groups
    else:
        next_filters.pop("bookmarkTagGroups", None)

    return next_filters, changed


def _migrate_saved_filter_tag_references(cursor, previous_name, next_name):
    if not _table_exists(cursor, "saved_filters"):
        return 0

    rows = cursor.execute(
        """
        SELECT id, kind, label, filter_json
        FROM saved_filters
        """
    ).fetchall()

    updated_count = 0
    for row in rows:
        try:
            filters = json.loads(row["filter_json"]) if row["filter_json"] else {}
        except (TypeError, json.JSONDecodeError):
            continue

        next_filters, changed = _rename_tag_references_in_filters(
            filters,
            previous_name,
            next_name,
        )
        if not changed:
            continue

        normalized_filters = _normalize_virtual_thread_filters(next_filters)
        filter_json = json.dumps(
            normalized_filters,
            ensure_ascii=False,
            sort_keys=True,
        )
        label = row["label"]
        if row["kind"] == "recent":
            label = _build_filter_history_label(normalized_filters)
        filter_hash = _build_saved_filter_hash(row["kind"], label, filter_json)

        cursor.execute(
            """
            UPDATE saved_filters
            SET label = ?, filter_json = ?, filter_hash = ?
            WHERE id = ?
            """,
            (label, filter_json, filter_hash, row["id"]),
        )
        updated_count += 1

    return updated_count


def _decode_filter_history_row(row):
    try:
        filters = json.loads(row["filter_json"]) if row["filter_json"] else {}
    except (TypeError, json.JSONDecodeError):
        filters = {}
    return {
        "id": row["id"],
        "kind": row["kind"],
        "targetType": row["target_type"],
        "name": row["label"],
        "label": row["label"],
        "filters": filters,
        "createdAt": row["created_at"],
        "updatedAt": row["last_used_at"],
        "lastUsedAt": row["last_used_at"],
    }


def list_starred_filters(
    target_type="virtual_thread",
    limit=100,
    db_file=DB_FILE,
):
    return list_saved_views(
        target_type=target_type,
        limit=limit,
        db_file=db_file,
    )


def save_starred_filter(
    name,
    filters,
    target_type="virtual_thread",
    starred_filter_id=None,
    db_file=DB_FILE,
):
    return save_saved_view(
        name,
        filters,
        target_type=target_type,
        saved_view_id=starred_filter_id,
        db_file=db_file,
    )


def delete_starred_filter(
    starred_filter_id,
    target_type="virtual_thread",
    db_file=DB_FILE,
):
    return delete_saved_view(
        starred_filter_id,
        target_type=target_type,
        db_file=db_file,
    )


def list_saved_filters(
    kind="recent",
    target_type="virtual_thread",
    limit=10,
    db_file=DB_FILE,
):
    if not db_file.exists():
        return []

    conn = sqlite3.connect(f"file:{db_file}?mode=ro", uri=True)
    conn.row_factory = sqlite3.Row
    cursor = conn.cursor()
    if not _table_exists(cursor, "saved_filters"):
        conn.close()
        return []

    rows = cursor.execute(
        """
        SELECT id, kind, target_type, label, filter_json, created_at, last_used_at
        FROM saved_filters
        WHERE kind = ?
          AND target_type = ?
        ORDER BY last_used_at DESC, created_at DESC, id DESC
        LIMIT ?
        """,
        (kind, target_type, max(1, int(limit or 10))),
    ).fetchall()
    conn.close()
    return [_decode_filter_history_row(row) for row in rows]


def save_recent_filter(
    filters,
    kind="recent",
    target_type="virtual_thread",
    limit=10,
    db_file=DB_FILE,
):
    normalized_filters = _normalize_virtual_thread_filters(filters)
    if not _has_meaningful_virtual_thread_filters(normalized_filters):
        return None

    ensure_user_data_dir()
    conn = init_db(db_file)
    conn.row_factory = sqlite3.Row
    cursor = conn.cursor()

    filter_json = json.dumps(
        normalized_filters,
        ensure_ascii=False,
        sort_keys=True,
    )
    label = _build_filter_history_label(normalized_filters)
    filter_hash = _build_saved_filter_hash(kind, label, filter_json)
    timestamp = _current_timestamp()

    existing = cursor.execute(
        """
        SELECT id, created_at
        FROM saved_filters
        WHERE kind = ?
          AND target_type = ?
          AND filter_hash = ?
        """,
        (kind, target_type, filter_hash),
    ).fetchone()

    if existing:
        cursor.execute(
            """
            UPDATE saved_filters
            SET label = ?, filter_json = ?, last_used_at = ?
            WHERE id = ?
            """,
            (label, filter_json, timestamp, existing["id"]),
        )
        row_id = existing["id"]
        created_at = existing["created_at"]
    else:
        cursor.execute(
            """
            INSERT INTO saved_filters (
                kind, target_type, filter_hash, label, filter_json, created_at, last_used_at
            )
            VALUES (?, ?, ?, ?, ?, ?, ?)
            """,
            (
                kind,
                target_type,
                filter_hash,
                label,
                filter_json,
                timestamp,
                timestamp,
            ),
        )
        row_id = cursor.lastrowid
        created_at = timestamp

    rows = cursor.execute(
        """
        SELECT id
        FROM saved_filters
        WHERE kind = ?
          AND target_type = ?
        ORDER BY last_used_at DESC, created_at DESC, id DESC
        """,
        (kind, target_type),
    ).fetchall()
    overflow_ids = [row["id"] for row in rows[max(1, int(limit or 10)) :]]
    if overflow_ids:
        cursor.executemany(
            "DELETE FROM saved_filters WHERE id = ?",
            [(saved_filter_id,) for saved_filter_id in overflow_ids],
        )

    conn.commit()
    conn.close()
    return {
        "id": row_id,
        "kind": kind,
        "targetType": target_type,
        "name": label,
        "label": label,
        "filters": normalized_filters,
        "createdAt": created_at,
        "updatedAt": timestamp,
        "lastUsedAt": timestamp,
    }


def list_saved_views(
    target_type="virtual_thread",
    limit=100,
    db_file=DB_FILE,
):
    return list_saved_filters(
        kind="saved_view",
        target_type=target_type,
        limit=limit,
        db_file=db_file,
    )


def save_saved_view(
    name,
    filters,
    target_type="virtual_thread",
    saved_view_id=None,
    db_file=DB_FILE,
):
    normalized_name = str(name or "").strip()
    normalized_filters = _normalize_virtual_thread_filters(filters)
    if not normalized_name or not _has_meaningful_virtual_thread_filters(normalized_filters):
        return None

    ensure_user_data_dir()
    conn = init_db(db_file)
    conn.row_factory = sqlite3.Row
    cursor = conn.cursor()

    filter_json = json.dumps(
        normalized_filters,
        ensure_ascii=False,
        sort_keys=True,
    )
    filter_hash = _build_saved_filter_hash("saved_view", normalized_name, filter_json)
    timestamp = _current_timestamp()

    existing = None
    if saved_view_id is not None:
        existing = cursor.execute(
            """
            SELECT id, created_at
            FROM saved_filters
            WHERE id = ?
              AND kind = 'saved_view'
              AND target_type = ?
            """,
            (saved_view_id, target_type),
        ).fetchone()
    if existing is None:
        existing = cursor.execute(
            """
            SELECT id, created_at
            FROM saved_filters
            WHERE kind = 'saved_view'
              AND target_type = ?
              AND label = ?
            ORDER BY id DESC
            LIMIT 1
            """,
            (target_type, normalized_name),
        ).fetchone()

    if existing:
        cursor.execute(
            """
            UPDATE saved_filters
            SET filter_hash = ?, label = ?, filter_json = ?, last_used_at = ?
            WHERE id = ?
            """,
            (
                filter_hash,
                normalized_name,
                filter_json,
                timestamp,
                existing["id"],
            ),
        )
        row_id = existing["id"]
        created_at = existing["created_at"]
    else:
        cursor.execute(
            """
            INSERT INTO saved_filters (
                kind, target_type, filter_hash, label, filter_json, created_at, last_used_at
            )
            VALUES (?, ?, ?, ?, ?, ?, ?)
            """,
            (
                "saved_view",
                target_type,
                filter_hash,
                normalized_name,
                filter_json,
                timestamp,
                timestamp,
            ),
        )
        row_id = cursor.lastrowid
        created_at = timestamp

    conn.commit()
    conn.close()
    return {
        "id": row_id,
        "kind": "saved_view",
        "targetType": target_type,
        "name": normalized_name,
        "label": normalized_name,
        "filters": normalized_filters,
        "createdAt": created_at,
        "updatedAt": timestamp,
        "lastUsedAt": timestamp,
    }


def delete_saved_view(
    saved_view_id,
    target_type="virtual_thread",
    db_file=DB_FILE,
):
    try:
        normalized_id = int(saved_view_id)
    except (TypeError, ValueError):
        return {"deleted": False}

    ensure_user_data_dir()
    conn = init_db(db_file)
    cursor = conn.cursor()
    cursor.execute(
        """
        DELETE FROM saved_filters
        WHERE id = ?
          AND kind = 'saved_view'
          AND target_type = ?
        """,
        (normalized_id, target_type),
    )
    deleted = cursor.rowcount > 0
    conn.commit()
    conn.close()
    return {
        "id": normalized_id,
        "targetType": target_type,
        "deleted": deleted,
    }


def _normalize_bookmark_target_spec(target_type, target_id, payload=None):
    normalized_target_type = str(target_type or "").strip()
    normalized_target_id = str(target_id or "").strip()
    payload_dict = payload if isinstance(payload, dict) else {}
    return normalized_target_type, normalized_target_id, payload_dict


def _build_bookmark_state_response(target_type, target_id, payload=None, bookmarked=False, updated_at=None):
    normalized_target_type, normalized_target_id, payload_dict = (
        _normalize_bookmark_target_spec(target_type, target_id, payload)
    )
    return {
        "targetType": normalized_target_type,
        "targetId": normalized_target_id,
        "payload": payload_dict,
        "bookmarked": bool(bookmarked),
        "updatedAt": updated_at,
    }


BOOKMARK_LABEL_KIND_BOOKMARK = "bookmark"
BOOKMARK_LABEL_KIND_TAG = "tag"


def _normalize_bookmark_target_specs(target_specs):
    normalized_specs = []
    for spec in target_specs or []:
        if not isinstance(spec, dict):
            continue
        normalized_target_type, normalized_target_id, payload_dict = (
            _normalize_bookmark_target_spec(
                spec.get("targetType"),
                spec.get("targetId"),
                spec.get("payload"),
            )
        )
        if not normalized_target_type or not normalized_target_id:
            continue
        normalized_specs.append(
            {
                "targetType": normalized_target_type,
                "targetId": normalized_target_id,
                "payload": payload_dict,
            }
        )
    return normalized_specs


def _bookmark_row_has_any_tags(cursor, bookmark_id):
    row = cursor.execute(
        """
        SELECT 1
        FROM bookmark_tag_links
        WHERE bookmark_id = ?
        LIMIT 1
        """,
        (bookmark_id,),
    ).fetchone()
    return bool(row)


def _resolve_runtime_bookmark_state(cursor, target_type, target_id, payload=None):
    normalized_target_type, normalized_target_id, payload_dict = (
        _normalize_bookmark_target_spec(target_type, target_id, payload)
    )
    row = cursor.execute(
        """
        SELECT id, payload_json, updated_at
        FROM bookmarks
        WHERE target_type = ?
          AND target_id = ?
        """,
        (normalized_target_type, normalized_target_id),
    ).fetchone()
    if not row:
        return _build_bookmark_state_response(
            normalized_target_type,
            normalized_target_id,
            payload=payload_dict,
            bookmarked=False,
        )
    try:
        stored_payload = json.loads(row["payload_json"]) if row["payload_json"] else {}
    except (TypeError, ValueError, json.JSONDecodeError):
        stored_payload = {}
    has_tags = _bookmark_row_has_any_tags(cursor, row["id"])
    is_active = True
    if normalized_target_type == "prompt":
        is_active = has_tags
    return _build_bookmark_state_response(
        normalized_target_type,
        normalized_target_id,
        payload=stored_payload or payload_dict,
        bookmarked=is_active,
        updated_at=row["updated_at"],
    )


def _set_primary_bookmark_membership(cursor, target_specs, assigned, timestamp):
    normalized_specs = _normalize_bookmark_target_specs(target_specs)
    if not normalized_specs:
        return {"labelKind": BOOKMARK_LABEL_KIND_BOOKMARK, "assigned": bool(assigned), "affected": 0}

    affected = 0
    if assigned:
        for spec in normalized_specs:
            cursor.execute(
                """
                INSERT INTO bookmarks (
                    target_type, target_id, payload_json, created_at, updated_at
                )
                VALUES (?, ?, ?, ?, ?)
                ON CONFLICT(target_type, target_id)
                DO UPDATE SET
                    payload_json = excluded.payload_json,
                    updated_at = excluded.updated_at
                """,
                (
                    spec["targetType"],
                    spec["targetId"],
                    json.dumps(spec["payload"], ensure_ascii=False, sort_keys=True),
                    timestamp,
                    timestamp,
                ),
            )
            affected += 1
    else:
        for spec in normalized_specs:
            row = cursor.execute(
                """
                SELECT id
                FROM bookmarks
                WHERE target_type = ?
                  AND target_id = ?
                """,
                (spec["targetType"], spec["targetId"]),
            ).fetchone()
            if row and spec["targetType"] == "prompt" and _bookmark_row_has_any_tags(cursor, row["id"]):
                continue
            if row:
                cursor.execute(
                    """
                    DELETE FROM bookmark_tag_links
                    WHERE bookmark_id = ?
                    """,
                    (row["id"],),
                )
            cursor.execute(
                """
                DELETE FROM bookmarks
                WHERE target_type = ?
                  AND target_id = ?
                """,
                (spec["targetType"], spec["targetId"]),
            )
            affected += cursor.rowcount

    return {
        "labelKind": BOOKMARK_LABEL_KIND_BOOKMARK,
        "assigned": bool(assigned),
        "affected": affected,
        "updatedAt": timestamp,
    }


def _fetch_bookmark_label_row(cursor, label_id):
    if label_id is None or str(label_id).strip() == "":
        return None
    try:
        normalized_label_id = int(label_id)
    except (TypeError, ValueError):
        return None
    return cursor.execute(
        """
        SELECT id, name, system_key, is_system, created_at, updated_at
        FROM bookmark_tags
        WHERE id = ?
        """,
        (normalized_label_id,),
    ).fetchone()


def _set_tag_bookmark_membership(cursor, label_id, target_specs, assigned, timestamp):
    tag_row = _fetch_bookmark_label_row(cursor, label_id)
    if not tag_row:
        return {"labelKind": BOOKMARK_LABEL_KIND_TAG, "labelId": None, "assigned": bool(assigned), "affected": 0}

    bookmark_rows = _resolve_bookmark_rows_for_targets(cursor, target_specs)
    if not bookmark_rows:
        return {
            "labelKind": BOOKMARK_LABEL_KIND_TAG,
            "labelId": tag_row["id"],
            "labelName": tag_row["name"],
            "assigned": bool(assigned),
            "affected": 0,
        }

    affected = 0
    if assigned:
        for row in bookmark_rows:
            cursor.execute(
                """
                INSERT OR IGNORE INTO bookmark_tag_links (bookmark_id, tag_id, created_at)
                VALUES (?, ?, ?)
                """,
                (row["id"], tag_row["id"], timestamp),
            )
            if cursor.rowcount > 0:
                affected += 1
    else:
        for row in bookmark_rows:
            cursor.execute(
                """
                DELETE FROM bookmark_tag_links
                WHERE bookmark_id = ?
                  AND tag_id = ?
                """,
                (row["id"], tag_row["id"]),
            )
            affected += cursor.rowcount
            if row["target_type"] == "prompt" and not _bookmark_row_has_any_tags(cursor, row["id"]):
                cursor.execute(
                    """
                    DELETE FROM bookmarks
                    WHERE id = ?
                    """,
                    (row["id"],),
                )

    cursor.execute(
        """
        UPDATE bookmark_tags
        SET updated_at = ?
        WHERE id = ?
        """,
        (timestamp, tag_row["id"]),
    )
    return {
        "labelKind": BOOKMARK_LABEL_KIND_TAG,
        "labelId": tag_row["id"],
        "labelName": tag_row["name"],
        "assigned": bool(assigned),
        "affected": affected,
        "updatedAt": timestamp,
    }


def set_bookmark_label_membership(label_kind, target_specs, assigned, label_id=None, db_file=DB_FILE):
    normalized_label_kind = str(label_kind or "").strip().lower()
    if normalized_label_kind not in {BOOKMARK_LABEL_KIND_BOOKMARK, BOOKMARK_LABEL_KIND_TAG}:
        return {"labelKind": normalized_label_kind or None, "assigned": bool(assigned), "affected": 0}

    ensure_user_data_dir()
    conn = init_db(db_file)
    conn.row_factory = sqlite3.Row
    cursor = conn.cursor()
    timestamp = _current_timestamp()

    if normalized_label_kind == BOOKMARK_LABEL_KIND_BOOKMARK:
        result = _set_primary_bookmark_membership(cursor, target_specs, assigned, timestamp)
    else:
        result = _set_tag_bookmark_membership(cursor, label_id, target_specs, assigned, timestamp)

    conn.commit()
    conn.close()
    return result


def set_bookmark(target_type, target_id, bookmarked, payload=None, db_file=DB_FILE):
    # Thread bookmarks are the only active UI today, but the DB boundary stays
    # generic so prompt/answer/saved-view targets can reuse the same write path.
    normalized_target_type, normalized_target_id, payload_dict = (
        _normalize_bookmark_target_spec(target_type, target_id, payload)
    )
    if not normalized_target_type or not normalized_target_id:
        return {"bookmarked": False}
    result = set_bookmark_label_membership(
        BOOKMARK_LABEL_KIND_BOOKMARK,
        [
            {
                "targetType": normalized_target_type,
                "targetId": normalized_target_id,
                "payload": payload_dict,
            }
        ],
        bookmarked,
        db_file=db_file,
    )
    conn = sqlite3.connect(f"file:{db_file}?mode=ro", uri=True)
    conn.row_factory = sqlite3.Row
    cursor = conn.cursor()
    final_state = _resolve_runtime_bookmark_state(
        cursor,
        normalized_target_type,
        normalized_target_id,
        payload=payload_dict,
    )
    conn.close()
    if final_state.get("updatedAt") is None:
        final_state["updatedAt"] = result.get("updatedAt")
    return final_state


def fetch_bookmark_states(target_specs, db_file=DB_FILE):
    # Generic read boundary for currently visible bookmark targets. Broader bookmark
    # listing/filtering still expands target type by target type on top of this.
    normalized_specs = _normalize_bookmark_target_specs(target_specs)
    if not normalized_specs:
        return []
    if not db_file.exists():
        return [
            _build_bookmark_state_response(
                spec["targetType"],
                spec["targetId"],
                payload=spec["payload"],
                bookmarked=False,
            )
            for spec in normalized_specs
        ]

    conn = sqlite3.connect(f"file:{db_file}?mode=ro", uri=True)
    conn.row_factory = sqlite3.Row
    cursor = conn.cursor()
    if not _table_exists(cursor, "bookmarks"):
        conn.close()
        return [
            _build_bookmark_state_response(
                spec["targetType"],
                spec["targetId"],
                payload=spec["payload"],
                bookmarked=False,
            )
            for spec in normalized_specs
        ]

    states = []
    for spec in normalized_specs:
        states.append(
            _resolve_runtime_bookmark_state(
                cursor,
                spec["targetType"],
                spec["targetId"],
                payload=spec["payload"],
            )
        )
    conn.close()
    return states


def _build_bookmark_list_entry(row):
    payload = {}
    raw_payload = row["payload_json"]
    if raw_payload:
        try:
            payload = json.loads(raw_payload)
        except (TypeError, ValueError, json.JSONDecodeError):
            payload = {}

    label = (
        payload.get("title")
        or payload.get("name")
        or payload.get("threadTitle")
        or payload.get("virtualThreadTitle")
        or payload.get("filterLabel")
        or row["target_id"]
    )

    return {
        "bookmarkId": row["id"],
        "targetType": row["target_type"],
        "targetId": row["target_id"],
        "payload": payload,
        "bookmarked": True,
        "createdAt": row["created_at"],
        "updatedAt": row["updated_at"],
        "label": label,
        "tags": row["tags"] if isinstance(row["tags"], list) else [],
    }


def _split_prompt_bookmark_target_id(target_id):
    conv_id, separator, message_index_text = str(target_id or "").rpartition(":")
    if not separator or not conv_id:
        return "", None
    try:
        message_index = int(message_index_text)
    except (TypeError, ValueError):
        return "", None
    if message_index < 0:
        return "", None
    return conv_id, message_index


def _fetch_bookmark_tag_map(cursor, bookmark_ids):
    normalized_ids = [
        int(bookmark_id)
        for bookmark_id in (bookmark_ids or [])
        if isinstance(bookmark_id, int) or str(bookmark_id).isdigit()
    ]
    if not normalized_ids or not _table_exists(cursor, "bookmark_tags") or not _table_exists(cursor, "bookmark_tag_links"):
        return {}
    placeholders = ", ".join("?" for _ in normalized_ids)
    rows = cursor.execute(
        f"""
        SELECT l.bookmark_id, t.id AS tag_id, t.name AS tag_name
             , t.system_key AS system_key
             , t.is_system AS is_system
        FROM bookmark_tag_links l
        JOIN bookmark_tags t ON t.id = l.tag_id
        WHERE l.bookmark_id IN ({placeholders})
        ORDER BY LOWER(t.name) ASC, t.id ASC
        """,
        normalized_ids,
    ).fetchall()
    tag_map = defaultdict(list)
    for row in rows:
        if row["is_system"]:
            continue
        tag_map[row["bookmark_id"]].append(
            {
                "id": row["tag_id"],
                "name": row["tag_name"],
                "systemKey": row["system_key"],
                "isSystem": bool(row["is_system"]),
            }
        )
    return tag_map


def list_bookmarks(db_file=DB_FILE):
    ensure_user_data_dir()
    if not db_file.exists():
        return []

    conn = sqlite3.connect(f"file:{db_file}?mode=ro", uri=True)
    conn.row_factory = sqlite3.Row
    cursor = conn.cursor()

    if not _table_exists(cursor, "bookmarks"):
        conn.close()
        return []

    rows = cursor.execute(
        """
        SELECT id, target_type, target_id, payload_json, created_at, updated_at
        FROM bookmarks
        ORDER BY updated_at DESC, created_at DESC, target_type ASC, target_id ASC
        """
    ).fetchall()
    tag_map = _fetch_bookmark_tag_map(cursor, [row["id"] for row in rows])
    conn.close()
    return [
        _build_bookmark_list_entry(
            {
                **dict(row),
                "tags": tag_map.get(row["id"], []),
            }
        )
        for row in rows
    ]


def list_starred_prompts(limit=500, db_file=DB_FILE):
    ensure_user_data_dir()
    if not db_file.exists():
        return []

    conn = sqlite3.connect(f"file:{db_file}?mode=ro", uri=True)
    conn.row_factory = sqlite3.Row
    cursor = conn.cursor()

    if (
        not _table_exists(cursor, "bookmarks")
        or not _table_exists(cursor, "bookmark_tag_links")
    ):
        conn.close()
        return []

    rows = cursor.execute(
        """
        SELECT id, target_type, target_id, payload_json, created_at, updated_at
        FROM bookmarks
        WHERE target_type = 'prompt'
          AND EXISTS (
              SELECT 1
              FROM bookmark_tag_links l
              WHERE l.bookmark_id = bookmarks.id
          )
        ORDER BY updated_at DESC, created_at DESC, target_id DESC
        LIMIT ?
        """,
        (max(1, int(limit or 500)),),
    ).fetchall()
    tag_map = _fetch_bookmark_tag_map(cursor, [row["id"] for row in rows])

    conversation_ids = []
    parsed_rows = []
    for row in rows:
        conv_id, message_index = _split_prompt_bookmark_target_id(row["target_id"])
        if not conv_id or message_index is None:
            continue
        payload = {}
        raw_payload = row["payload_json"]
        if raw_payload:
            try:
                payload = json.loads(raw_payload)
            except (TypeError, ValueError, json.JSONDecodeError):
                payload = {}
        parsed_rows.append((row, conv_id, message_index, payload))
        if conv_id not in conversation_ids:
            conversation_ids.append(conv_id)

    conversation_meta = {}
    if conversation_ids:
        placeholders = ", ".join("?" for _ in conversation_ids)
        for row in cursor.execute(
            f"""
            SELECT id, title, source, model, date_str, source_file
            FROM conversations
            WHERE id IN ({placeholders})
            """,
            conversation_ids,
        ).fetchall():
            conversation_meta[row["id"]] = {
                "threadTitle": row["title"] or "Untitled",
                "source": row["source"] or "",
                "model": row["model"] or "",
                "date": row["date_str"] or "",
                "sourceFile": row["source_file"] or "",
            }

    conn.close()

    entries = []
    for row, conv_id, message_index, payload in parsed_rows:
        meta = conversation_meta.get(conv_id, {})
        title = payload.get("title") or f"Prompt {message_index + 1}"
        entries.append(
            {
                "targetType": "prompt",
                "bookmarkId": row["id"],
                "targetId": row["target_id"],
                "parentConversationId": conv_id,
                "messageIndex": message_index,
                "label": title,
                "title": title,
                "threadTitle": meta.get("threadTitle") or payload.get("threadTitle") or "Untitled",
                "source": meta.get("source", ""),
                "model": meta.get("model", ""),
                "date": meta.get("date", ""),
                "sourceFile": meta.get("sourceFile", ""),
                "payload": payload,
                "bookmarked": True,
                "createdAt": row["created_at"],
                "updatedAt": row["updated_at"],
                "tags": tag_map.get(row["id"], []),
            }
        )
    return entries


def create_bookmark_label(name, db_file=DB_FILE):
    normalized_name = str(name or "").strip()
    if not normalized_name:
        return None

    ensure_user_data_dir()
    conn = init_db(db_file)
    conn.row_factory = sqlite3.Row
    cursor = conn.cursor()
    timestamp = _current_timestamp()
    cursor.execute(
        """
        INSERT INTO bookmark_tags (name, created_at, updated_at)
        VALUES (?, ?, ?)
        ON CONFLICT(name)
        DO UPDATE SET updated_at = bookmark_tags.updated_at
        """,
        (normalized_name, timestamp, timestamp),
    )
    row = cursor.execute(
        """
        SELECT id, name, system_key, is_system, created_at, updated_at
        FROM bookmark_tags
        WHERE name = ?
        """,
        (normalized_name,),
    ).fetchone()
    conn.commit()
    conn.close()
    if not row:
        return None
    return {
        "id": row["id"],
        "name": row["name"],
        "systemKey": row["system_key"],
        "isSystem": bool(row["is_system"]),
        "createdAt": row["created_at"],
        "updatedAt": row["updated_at"],
        "bookmarkCount": 0,
    }


def create_bookmark_tag(name, db_file=DB_FILE):
    return create_bookmark_label(name, db_file=db_file)


def rename_bookmark_label(label_id, name, db_file=DB_FILE):
    if label_id is None or str(label_id).strip() == "":
        return {"renamed": 0, "error": "missing_id"}
    normalized_name = str(name or "").strip()
    if not normalized_name:
        return {"renamed": 0, "error": "missing_name"}

    ensure_user_data_dir()
    if not db_file.exists():
        return {"renamed": 0, "error": "missing_db"}

    conn = init_db(db_file)
    conn.row_factory = sqlite3.Row
    cursor = conn.cursor()
    label_row = cursor.execute(
        """
        SELECT id, name, system_key, is_system, created_at, updated_at
        FROM bookmark_tags
        WHERE id = ?
          AND COALESCE(is_system, 0) = 0
        """,
        (int(label_id),),
    ).fetchone()
    if not label_row:
        conn.close()
        return {"renamed": 0, "error": "not_found"}

    duplicate_row = cursor.execute(
        """
        SELECT id
        FROM bookmark_tags
        WHERE LOWER(name) = LOWER(?)
          AND id != ?
        LIMIT 1
        """,
        (normalized_name, label_row["id"]),
    ).fetchone()
    if duplicate_row:
        conn.close()
        return {"renamed": 0, "error": "duplicate"}

    timestamp = _current_timestamp()
    cursor.execute(
        """
        UPDATE bookmark_tags
        SET name = ?, updated_at = ?
        WHERE id = ?
        """,
        (normalized_name, timestamp, label_row["id"]),
    )
    migrated_filter_count = _migrate_saved_filter_tag_references(
        cursor,
        label_row["name"],
        normalized_name,
    )
    row = cursor.execute(
        """
        SELECT
            t.id,
            t.name,
            t.system_key,
            t.is_system,
            t.created_at,
            t.updated_at,
            COUNT(l.bookmark_id) AS bookmark_count
        FROM bookmark_tags t
        LEFT JOIN bookmark_tag_links l ON l.tag_id = t.id
        WHERE t.id = ?
        GROUP BY t.id, t.name, t.system_key, t.is_system, t.created_at, t.updated_at
        """,
        (label_row["id"],),
    ).fetchone()
    conn.commit()
    conn.close()
    if not row:
        return {"renamed": 0, "error": "not_found"}
    return {
        "id": row["id"],
        "name": row["name"],
        "systemKey": row["system_key"],
        "isSystem": bool(row["is_system"]),
        "createdAt": row["created_at"],
        "updatedAt": row["updated_at"],
        "bookmarkCount": row["bookmark_count"] or 0,
        "migratedFilterCount": migrated_filter_count,
        "renamed": 1,
    }


def rename_bookmark_tag(tag_id, name, db_file=DB_FILE):
    return rename_bookmark_label(tag_id, name, db_file=db_file)


def list_bookmark_labels(db_file=DB_FILE, include_system=False):
    ensure_user_data_dir()
    if not db_file.exists():
        return []

    conn = sqlite3.connect(f"file:{db_file}?mode=ro", uri=True)
    conn.row_factory = sqlite3.Row
    cursor = conn.cursor()
    if not _table_exists(cursor, "bookmark_tags"):
        conn.close()
        return []

    rows = cursor.execute(
        """
        SELECT
            t.id,
            t.name,
            t.system_key,
            t.is_system,
            t.created_at,
            t.updated_at,
            COUNT(l.bookmark_id) AS bookmark_count
        FROM bookmark_tags t
        LEFT JOIN bookmark_tag_links l ON l.tag_id = t.id
        GROUP BY t.id, t.name, t.system_key, t.is_system, t.created_at, t.updated_at
        ORDER BY t.is_system ASC, LOWER(t.name) ASC, t.id ASC
        """
    ).fetchall()
    conn.close()
    tags = [
        {
            "id": row["id"],
            "name": row["name"],
            "systemKey": row["system_key"],
            "isSystem": bool(row["is_system"]),
            "createdAt": row["created_at"],
            "updatedAt": row["updated_at"],
            "bookmarkCount": row["bookmark_count"] or 0,
        }
        for row in rows
    ]
    if include_system:
        return tags
    return [tag for tag in tags if not tag["isSystem"]]


def list_bookmark_tags(db_file=DB_FILE, include_system=False):
    return list_bookmark_labels(db_file=db_file, include_system=include_system)


def _resolve_bookmark_rows_for_targets(cursor, target_specs):
    normalized_specs = _normalize_bookmark_target_specs(target_specs)

    resolved_rows = []
    for spec in normalized_specs:
        row = cursor.execute(
            """
            SELECT id, target_type, target_id
            FROM bookmarks
            WHERE target_type = ?
              AND target_id = ?
            """,
            (spec["targetType"], spec["targetId"]),
        ).fetchone()
        if row:
            resolved_rows.append(row)
    return resolved_rows


def set_bookmark_tag_membership(tag_id, target_specs, assigned, db_file=DB_FILE):
    result = set_bookmark_label_membership(
        BOOKMARK_LABEL_KIND_TAG,
        target_specs,
        assigned,
        label_id=tag_id,
        db_file=db_file,
    )
    return {
        "tagId": result.get("labelId"),
        "tagName": result.get("labelName"),
        "assigned": bool(assigned),
        "affected": result.get("affected", 0),
    }


def delete_bookmark_label(label_id, db_file=DB_FILE):
    if label_id is None or str(label_id).strip() == "":
        return {"deleted": 0}

    ensure_user_data_dir()
    if not db_file.exists():
        return {"deleted": 0}

    conn = init_db(db_file)
    conn.row_factory = sqlite3.Row
    cursor = conn.cursor()
    label_row = cursor.execute(
        """
        SELECT id
        FROM bookmark_tags
        WHERE id = ?
          AND COALESCE(is_system, 0) = 0
        """,
        (int(label_id),),
    ).fetchone()
    if not label_row:
        conn.close()
        return {"deleted": 0}

    cursor.execute(
        """
        DELETE FROM bookmark_tag_links
        WHERE tag_id = ?
        """,
        (label_row["id"],),
    )
    cursor.execute(
        """
        DELETE FROM bookmark_tags
        WHERE id = ?
        """,
        (label_row["id"],),
    )
    deleted = cursor.rowcount
    conn.commit()
    conn.close()
    return {"deleted": deleted}


def delete_bookmark_tag(tag_id, db_file=DB_FILE):
    return delete_bookmark_label(tag_id, db_file=db_file)


def delete_bookmarks(target_specs, db_file=DB_FILE):
    result = set_bookmark_label_membership(
        BOOKMARK_LABEL_KIND_BOOKMARK,
        target_specs,
        False,
        db_file=db_file,
    )
    return {"deleted": result.get("affected", 0)}




def _fetch_bookmarked_target_ids(cursor, target_type):
    if not _table_exists(cursor, "bookmarks"):
        return set()
    return {
        row["target_id"]
        for row in cursor.execute(
            """
            SELECT target_id
            FROM bookmarks
            WHERE target_type = ?
            """,
            (str(target_type or "").strip(),),
        ).fetchall()
    }


def _fetch_bookmarked_thread_ids(cursor):
    # Current read paths still consume thread bookmarks only. Keep this narrow while
    # bookmark target types expand on the target-spec/write boundary first.
    return _fetch_bookmarked_target_ids(cursor, "thread")


def _fetch_starred_prompt_counts(cursor):
    if (
        not _table_exists(cursor, "bookmarks")
        or not _table_exists(cursor, "bookmark_tag_links")
    ):
        return {}
    counts = defaultdict(int)
    for row in cursor.execute(
        """
        SELECT DISTINCT b.id, b.target_id
        FROM bookmarks b
        JOIN bookmark_tag_links l ON l.bookmark_id = b.id
        WHERE b.target_type = 'prompt'
        """
    ).fetchall():
        conv_id, message_index = _split_prompt_bookmark_target_id(row["target_id"])
        if conv_id and message_index is not None:
            counts[conv_id] += 1
    return dict(counts)


def _build_virtual_thread_title(filters):
    filters = _normalize_virtual_thread_filters(filters)
    parts = []
    services = _normalize_filter_values(filters.get("service"))
    models = _normalize_filter_values(filters.get("model"))
    date_from = (filters.get("dateFrom") or "").strip()
    date_to = (filters.get("dateTo") or "").strip()
    title_contains = (filters.get("titleContains") or "").strip()
    prompt_contains = (filters.get("promptContains") or "").strip()
    response_contains = (filters.get("responseContains") or "").strip()
    roles = _normalize_filter_values(filters.get("role"))
    source_file = (filters.get("sourceFile") or "").strip()
    bookmarked = _normalize_bookmarked_filter(filters.get("bookmarked"))
    bookmark_tag_groups = _normalize_bookmark_tag_groups(filters.get("bookmarkTagGroups"))

    if services:
        parts.append(f"service={'+'.join(services)}")
    if models:
        parts.append(f"model={'+'.join(models)}")
    bookmark_tags = _normalize_filter_values(filters.get("bookmarkTags"))
    if date_from or date_to:
        parts.append(f"{date_from or '...'}–{date_to or '...'}")
    if title_contains:
        parts.append(f"title={title_contains}")
    if prompt_contains:
        parts.append(f"prompt={prompt_contains}")
    if response_contains:
        parts.append(f"response={response_contains}")
    if roles:
        parts.append(f"role={'+'.join(roles)}")
    if bookmark_tags:
        parts.append(f"tags={'|'.join(bookmark_tags)}")
    if bookmark_tag_groups:
        parts.extend([f"tags=({'&'.join(group)})" for group in bookmark_tag_groups])
    if source_file:
        parts.append(f"file={source_file}")
    if bookmarked == "bookmarked":
        parts.append("has starred prompt")
    elif bookmarked == "not-bookmarked":
        parts.append("without starred prompt")

    if not parts:
        return "Filter Preview"
    return "Filter Preview: " + ", ".join(parts)


def _build_bookmark_tag_exists_clause(
    target_id_expr,
    bookmark_tags,
    bookmark_tag_groups=None,
    has_bookmark_tag_tables=True,
):
    normalized_groups = _combine_bookmark_tag_filter_groups(bookmark_tags, bookmark_tag_groups)
    if not normalized_groups:
        return "", []
    if not has_bookmark_tag_tables:
        return "1=0", []
    clauses = []
    params = []
    for group in normalized_groups:
        placeholders = ", ".join("?" for _ in group)
        clauses.append(
            f"""
            EXISTS (
                SELECT 1
                FROM bookmarks b
                JOIN bookmark_tag_links l ON l.bookmark_id = b.id
                JOIN bookmark_tags t ON t.id = l.tag_id
                WHERE b.target_type = 'prompt'
                  AND b.target_id = {target_id_expr}
                  AND LOWER(COALESCE(t.name, '')) IN ({placeholders})
                GROUP BY b.id
                HAVING COUNT(DISTINCT LOWER(COALESCE(t.name, ''))) = ?
            )
            """
        )
        params.extend([tag.lower() for tag in group])
        params.append(len(group))
    return "(" + " OR ".join(clauses) + ")", params


def _build_conversation_bookmark_tag_exists_clause(
    conversation_id_expr,
    bookmark_tags,
    bookmark_tag_groups=None,
    has_bookmark_tag_tables=True,
):
    normalized_groups = _combine_bookmark_tag_filter_groups(bookmark_tags, bookmark_tag_groups)
    if not normalized_groups:
        return "", []
    if not has_bookmark_tag_tables:
        return "1=0", []
    clauses = []
    params = []
    for group in normalized_groups:
        placeholders = ", ".join("?" for _ in group)
        clauses.append(
            f"""
            EXISTS (
                SELECT 1
                FROM bookmarks b
                JOIN bookmark_tag_links l ON l.bookmark_id = b.id
                JOIN bookmark_tags t ON t.id = l.tag_id
                WHERE b.target_type = 'prompt'
                  AND substr(b.target_id, 1, length({conversation_id_expr}) + 1) = {conversation_id_expr} || ':'
                  AND LOWER(COALESCE(t.name, '')) IN ({placeholders})
                GROUP BY b.id
                HAVING COUNT(DISTINCT LOWER(COALESCE(t.name, ''))) = ?
            )
            """
        )
        params.extend([tag.lower() for tag in group])
        params.append(len(group))
    return "(" + " OR ".join(clauses) + ")", params


def _build_virtual_thread_where(
    filters,
    has_bookmarks_table=True,
    has_bookmark_tag_tables=True,
    primary_time_field="primary_time",
):
    clauses = []
    params = []
    used_optional_columns = set()

    filters = _normalize_virtual_thread_filters(filters)
    services = _normalize_filter_values(filters.get("service"))
    models = _normalize_filter_values(filters.get("model"))
    source_file = (filters.get("sourceFile") or "").strip()
    roles = _normalize_filter_values(filters.get("role"))
    bookmark_tags = _normalize_filter_values(filters.get("bookmarkTags"))
    bookmark_tag_groups = _normalize_bookmark_tag_groups(filters.get("bookmarkTagGroups"))
    date_from = (filters.get("dateFrom") or "").strip()
    date_to = (filters.get("dateTo") or "").strip()
    title_contains = (filters.get("titleContains") or "").strip()
    prompt_contains = (filters.get("promptContains") or "").strip()
    response_contains = (filters.get("responseContains") or "").strip()
    bookmarked = _normalize_bookmarked_filter(filters.get("bookmarked"))

    if services:
        clauses.append(
            "COALESCE(source, '') IN ({})".format(", ".join("?" for _ in services))
        )
        params.extend(services)

    if models:
        used_optional_columns.add("model")
        clauses.append(
            "LOWER(COALESCE(model, '')) IN ({})".format(", ".join("?" for _ in models))
        )
        params.extend([model.lower() for model in models])

    if source_file:
        used_optional_columns.add("source_file")
        clause, clause_params = _build_contains_clause("source_file", source_file)
        clauses.append(clause)
        params.extend(clause_params)

    if date_from:
        clauses.append(f"substr(COALESCE({primary_time_field}, ''), 1, 10) >= ?")
        params.append(date_from)
    if date_to:
        clauses.append(f"substr(COALESCE({primary_time_field}, ''), 1, 10) <= ?")
        params.append(date_to)

    if title_contains:
        clause, clause_params = _build_contains_clause("title", title_contains)
        clauses.append(clause)
        params.extend(clause_params)

    if prompt_contains:
        clause, clause_params = _build_contains_clause("prompt", prompt_contains)
        clauses.append(clause)
        params.extend(clause_params)

    if response_contains:
        clause, clause_params = _build_contains_clause("response", response_contains)
        clauses.append(clause)
        params.extend(clause_params)

    role_set = {role.lower() for role in roles}
    if role_set == {"user"}:
        clauses.append("COALESCE(prompt, '') != ''")
    elif role_set == {"assistant"}:
        clauses.append("COALESCE(response, '') != ''")
    elif role_set and role_set.isdisjoint({"user", "assistant"}):
        clauses.append("1=0")

    if bookmarked == "bookmarked":
        if has_bookmarks_table:
            clauses.append(
                """
                EXISTS (
                    SELECT 1
                    FROM bookmarks b
                    WHERE b.target_type = 'prompt'
                      AND substr(b.target_id, 1, length(conv_id) + 1) = conv_id || ':'
                )
                """
            )
        else:
            clauses.append("1=0")
    elif bookmarked == "not-bookmarked" and has_bookmarks_table:
        clauses.append(
            """
            NOT EXISTS (
                SELECT 1
                FROM bookmarks b
                WHERE b.target_type = 'prompt'
                  AND substr(b.target_id, 1, length(conv_id) + 1) = conv_id || ':'
            )
            """
        )

    if bookmark_tags or bookmark_tag_groups:
        clause, clause_params = _build_bookmark_tag_exists_clause(
            "conv_id || ':' || CAST(message_index AS TEXT)",
            bookmark_tags,
            bookmark_tag_groups,
            has_bookmark_tag_tables=has_bookmarks_table and has_bookmark_tag_tables,
        )
        clauses.append(clause)
        params.extend(clause_params)

    where_sql = " AND ".join(clauses) if clauses else "1=1"
    return where_sql, params, used_optional_columns


def _build_virtual_thread_conversation_where(
    filters,
    has_bookmarks_table=True,
    has_bookmark_tag_tables=True,
    table_alias="c",
    primary_time_expr="",
):
    clauses = []
    params = []
    used_optional_columns = set()

    filters = _normalize_virtual_thread_filters(filters)
    services = _normalize_filter_values(filters.get("service"))
    models = _normalize_filter_values(filters.get("model"))
    source_file = (filters.get("sourceFile") or "").strip()
    bookmark_tags = _normalize_filter_values(filters.get("bookmarkTags"))
    bookmark_tag_groups = _normalize_bookmark_tag_groups(filters.get("bookmarkTagGroups"))
    date_from = (filters.get("dateFrom") or "").strip()
    date_to = (filters.get("dateTo") or "").strip()
    title_contains = (filters.get("titleContains") or "").strip()
    bookmarked = _normalize_bookmarked_filter(filters.get("bookmarked"))

    if services:
        clauses.append(
            "COALESCE({alias}.source, '') IN ({values})".format(
                alias=table_alias,
                values=", ".join("?" for _ in services),
            )
        )
        params.extend(services)

    if models:
        used_optional_columns.add("model")
        clauses.append(
            "LOWER(COALESCE({alias}.model, '')) IN ({values})".format(
                alias=table_alias,
                values=", ".join("?" for _ in models),
            )
        )
        params.extend([model.lower() for model in models])

    if source_file:
        used_optional_columns.add("source_file")
        clause, clause_params = _build_contains_clause(f"{table_alias}.source_file", source_file)
        clauses.append(clause)
        params.extend(clause_params)

    if primary_time_expr:
        if date_from:
            clauses.append(f"substr(COALESCE({primary_time_expr}, ''), 1, 10) >= ?")
            params.append(date_from)
        if date_to:
            clauses.append(f"substr(COALESCE({primary_time_expr}, ''), 1, 10) <= ?")
            params.append(date_to)

    if title_contains:
        clause, clause_params = _build_contains_clause(f"{table_alias}.title", title_contains)
        clauses.append(clause)
        params.extend(clause_params)

    if bookmarked == "bookmarked":
        if has_bookmarks_table:
            clauses.append(
                f"""
                EXISTS (
                    SELECT 1
                    FROM bookmarks b
                    WHERE b.target_type = 'prompt'
                      AND substr(b.target_id, 1, length({table_alias}.id) + 1) = {table_alias}.id || ':'
                )
                """
            )
        else:
            clauses.append("1=0")
    elif bookmarked == "not-bookmarked" and has_bookmarks_table:
        clauses.append(
            f"""
            NOT EXISTS (
                SELECT 1
                FROM bookmarks b
                WHERE b.target_type = 'prompt'
                  AND substr(b.target_id, 1, length({table_alias}.id) + 1) = {table_alias}.id || ':'
            )
            """
        )

    if bookmark_tags or bookmark_tag_groups:
        clause, clause_params = _build_conversation_bookmark_tag_exists_clause(
            f"{table_alias}.id",
            bookmark_tags,
            bookmark_tag_groups,
            has_bookmark_tag_tables=has_bookmarks_table and has_bookmark_tag_tables,
        )
        clauses.append(clause)
        params.extend(clause_params)

    where_sql = " AND ".join(clauses) if clauses else "1=1"
    return where_sql, params, used_optional_columns


def build_virtual_thread_preview(filters, db_file=DB_FILE):
    filters = _normalize_virtual_thread_filters(filters)
    if not db_file.exists():
        return {
            "title": _build_virtual_thread_title(filters),
            "itemCount": 0,
            "filters": filters,
            "conversationIds": [],
        }

    conn = sqlite3.connect(f"file:{db_file}?mode=ro", uri=True)
    conn.row_factory = sqlite3.Row
    cursor = conn.cursor()
    has_bookmarks_table = _table_exists(cursor, "bookmarks")
    has_bookmark_tag_tables = (
        has_bookmarks_table
        and _table_exists(cursor, "bookmark_tags")
        and _table_exists(cursor, "bookmark_tag_links")
    )

    _model_expr, _source_file_expr, columns = _conversation_select_fragment(cursor, "c")
    primary_time_expr = _conversation_primary_time_expr(columns, "c")
    conversation_where_sql, params, used_optional_columns = _build_virtual_thread_conversation_where(
        filters,
        has_bookmarks_table=has_bookmarks_table,
        has_bookmark_tag_tables=has_bookmark_tag_tables,
        table_alias="c",
        primary_time_expr=primary_time_expr,
    )
    if any(column not in columns for column in used_optional_columns):
        conn.close()
        return {
            "title": _build_virtual_thread_title(filters),
            "itemCount": 0,
            "filters": filters,
            "conversationIds": [],
        }

    prompt_contains = (filters.get("promptContains") or "").strip()
    response_contains = (filters.get("responseContains") or "").strip()
    roles = _normalize_filter_values(filters.get("role"))
    role_set = {role.lower() for role in roles}

    if role_set and role_set.isdisjoint({"user", "assistant"}):
        conn.close()
        return {
            "title": _build_virtual_thread_title(filters),
            "itemCount": 0,
            "filters": filters,
            "conversationIds": [],
        }

    turn_clauses = [conversation_where_sql] if conversation_where_sql else []
    turn_params = list(params)

    if prompt_contains:
        clause, clause_params = _build_contains_clause("p.content", prompt_contains)
        turn_clauses.append(clause)
        turn_params.extend(clause_params)

    next_user_index_sql = (
        "COALESCE((SELECT MIN(mu.msg_index) "
        "FROM messages mu "
        "WHERE mu.conv_id = p.conv_id "
        "AND mu.role = 'user' "
        "AND mu.msg_index > p.msg_index), 2147483647)"
    )

    if role_set == {"assistant"}:
        turn_clauses.append(
            f"""
            EXISTS (
                SELECT 1
                FROM messages a
                WHERE a.conv_id = p.conv_id
                  AND a.role != 'user'
                  AND a.msg_index > p.msg_index
                  AND a.msg_index < {next_user_index_sql}
            )
            """
        )

    if response_contains:
        turn_clauses.append(
            f"""
            EXISTS (
                SELECT 1
                FROM messages a
                WHERE a.conv_id = p.conv_id
                  AND a.role != 'user'
                  AND a.msg_index > p.msg_index
                  AND a.msg_index < {next_user_index_sql}
                  AND LOWER(COALESCE(a.content, '')) LIKE ?
            )
            """
        )
        turn_params.append(f"%{response_contains.lower()}%")

    bookmark_tags = _normalize_filter_values(filters.get("bookmarkTags"))
    if bookmark_tags:
        clause, clause_params = _build_bookmark_tag_exists_clause(
            "p.conv_id || ':' || CAST(p.msg_index AS TEXT)",
            bookmark_tags,
            has_bookmark_tag_tables=has_bookmark_tag_tables,
        )
        turn_clauses.append(clause)
        turn_params.extend(clause_params)

    rows = cursor.execute(
        f"""
        SELECT
            p.conv_id AS conv_id,
            COUNT(*) AS item_count
        FROM conversations c
        JOIN messages p
          ON c.id = p.conv_id
         AND p.role = 'user'
        WHERE {" AND ".join(turn_clauses) if turn_clauses else "1=1"}
        GROUP BY p.conv_id
        """,
        turn_params,
    ).fetchall()
    conn.close()

    return {
        "title": _build_virtual_thread_title(filters),
        "itemCount": sum(int(row["item_count"] or 0) for row in rows),
        "filters": filters,
        "conversationIds": [row["conv_id"] for row in rows if row["conv_id"]],
    }


def build_virtual_thread(filters, db_file=DB_FILE):
    filters = _normalize_virtual_thread_filters(filters)
    if not db_file.exists():
        return {
            "title": _build_virtual_thread_title(filters),
            "itemCount": 0,
            "sortMode": filters.get("sortMode") or "date-asc",
            "filters": filters,
            "groups": [],
            "items": [],
        }

    sort_mode = filters.get("sortMode") or "date-asc"
    sort_direction = "DESC" if sort_mode == "date-desc" else "ASC"

    conn = sqlite3.connect(f"file:{db_file}?mode=ro", uri=True)
    conn.row_factory = sqlite3.Row
    cursor = conn.cursor()
    has_bookmarks_table = _table_exists(cursor, "bookmarks")
    has_bookmark_tag_tables = (
        has_bookmarks_table
        and _table_exists(cursor, "bookmark_tags")
        and _table_exists(cursor, "bookmark_tag_links")
    )
    model_expr, source_file_expr, columns = _conversation_select_fragment(cursor, "c")
    source_created_at_expr = (
        "c.source_created_at AS source_created_at"
        if "source_created_at" in columns
        else "NULL AS source_created_at"
    )
    imported_at_expr = (
        "c.imported_at AS imported_at"
        if "imported_at" in columns
        else "NULL AS imported_at"
    )
    primary_time_expr = _conversation_primary_time_expr(columns, "c")
    starred_prompt_counts = _fetch_starred_prompt_counts(cursor)
    where_sql, params, used_optional_columns = _build_virtual_thread_where(
        filters,
        has_bookmarks_table=has_bookmarks_table,
        has_bookmark_tag_tables=has_bookmark_tag_tables,
    )
    if any(column not in columns for column in used_optional_columns):
        conn.close()
        return {
            "title": _build_virtual_thread_title(filters),
            "itemCount": 0,
            "sortMode": sort_mode,
            "filters": filters,
            "groups": [],
            "items": [],
        }

    rows = cursor.execute(
        f"""
        WITH ordered_messages AS (
            SELECT
                conv_id,
                role,
                content,
                msg_index,
                SUM(CASE WHEN role = 'user' THEN 1 ELSE 0 END) OVER (
                    PARTITION BY conv_id
                    ORDER BY msg_index
                    ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW
                ) AS turn_no
            FROM messages
        ),
        turns AS (
            SELECT
                c.id AS conv_id,
                c.source,
                {model_expr},
                {source_file_expr},
                {source_created_at_expr},
                {imported_at_expr},
                c.title,
                c.date_str,
                {primary_time_expr} AS primary_time,
                MIN(CASE WHEN m.role = 'user' THEN m.msg_index END) AS message_index,
                MAX(CASE WHEN m.role = 'user' THEN m.content END) AS prompt,
                GROUP_CONCAT(
                    CASE WHEN m.role != 'user' THEN m.content END,
                    char(10) || char(10)
                ) AS response
            FROM conversations c
            JOIN ordered_messages m ON c.id = m.conv_id
            GROUP BY c.id, m.turn_no
        )
        SELECT *
        FROM turns
        WHERE message_index IS NOT NULL
          AND {where_sql}
        ORDER BY COALESCE(primary_time, '') {sort_direction}, message_index {sort_direction}
        """,
        params,
    ).fetchall()
    conn.close()

    items = []
    groups_by_conv = defaultdict(list)
    for index, row in enumerate(rows):
        prompt = row["prompt"] or ""
        response = row["response"] or ""
        if prompt and response:
            role_label = "mixed"
            body = f"[Prompt]\n{prompt}\n\n[Response]\n{response}"
        elif prompt:
            role_label = "user"
            body = prompt
        else:
            role_label = "assistant"
            body = response

        item = {
            "id": f"{row['conv_id']}:{row['message_index']}",
            "order": index,
            "convId": row["conv_id"],
            "messageIndex": row["message_index"],
            "date": row["date_str"],
            "primary_time": row["primary_time"],
            "source_created_at": row["source_created_at"],
            "imported_at": row["imported_at"],
            "service": row["source"] or "",
            "model": row["model"] or "",
            "sourceFile": row["source_file"] or "",
            "threadTitle": row["title"] or "Untitled",
            "role": role_label,
            "body": body,
            "prompt": prompt,
            "response": response,
            "bookmarked": starred_prompt_counts.get(row["conv_id"], 0) > 0,
            "starredPromptCount": starred_prompt_counts.get(row["conv_id"], 0),
        }
        items.append(item)
        groups_by_conv[row["conv_id"]].append(item)

    groups = []
    for conv_id, group_items in groups_by_conv.items():
        first = group_items[0]
        groups.append(
            {
                "convId": conv_id,
                "threadTitle": first["threadTitle"],
                "service": first["service"],
                "date": first["date"],
                "primary_time": first["primary_time"],
                "itemCount": len(group_items),
                "bookmarked": starred_prompt_counts.get(conv_id, 0) > 0,
                "starredPromptCount": starred_prompt_counts.get(conv_id, 0),
                "items": group_items,
            }
        )

    return {
        "title": _build_virtual_thread_title(filters),
        "itemCount": len(items),
        "sortMode": sort_mode,
        "filters": filters,
        "groups": groups,
        "items": items,
    }


def search_conversations(words, include_title=True, include_prompt=True, include_answer=True, db_file=DB_FILE):
    # Legacy keyword-search path. This still relies on LIKE-based matching over
    # normalized conversation/turn data until search_idx/FTS becomes the main path.
    normalized_words = _normalize_search_words(words)
    if not normalized_words or not db_file.exists():
        return {}

    conn = sqlite3.connect(f"file:{db_file}?mode=ro", uri=True)
    conn.row_factory = sqlite3.Row
    cursor = conn.cursor()

    results = {}
    if include_title:
        for row in _search_conversation_title_matches(cursor, normalized_words):
            results[row["id"]] = _make_keyword_search_result(title_matched=True)

    for row in _search_conversation_turn_matches(
        cursor,
        normalized_words,
        include_prompt=include_prompt,
        include_answer=include_answer,
    ):
        entry = results.setdefault(
            row["conv_id"],
            _make_keyword_search_result(title_matched=False),
        )
        entry["hits"] += 1
        entry["matchedMessageIndexes"].append(row["message_index"])

    conn.close()
    return results


def search_conversations_for_spec(search_spec, db_file=DB_FILE):
    # Stable backend boundary for keyword search requests coming from the viewer/bridge.
    # The low-level LIKE implementation can change later without changing the bridge shape.
    normalized = normalize_keyword_search_spec(search_spec)
    return search_conversations(
        normalized.get("words", []),
        include_title=normalized.get("includeTitle", True),
        include_prompt=normalized.get("includePrompt", True),
        include_answer=normalized.get("includeAnswer", True),
        db_file=db_file,
    )


def load_history():
    if HISTORY_FILE.exists():
        try:
            return json.loads(HISTORY_FILE.read_text(encoding="utf-8"))
        except (OSError, json.JSONDecodeError):
            pass
    return []


def save_history(files):
    ensure_user_data_dir()
    history = load_history()
    for file_path in reversed(files):
        if file_path in history:
            history.remove(file_path)
        history.insert(0, file_path)
    HISTORY_FILE.write_text(
        json.dumps(history[:50], ensure_ascii=False, indent=2), encoding="utf-8"
    )


def load_themes():
    if THEMES_JSON.exists():
        try:
            return json.loads(THEMES_JSON.read_text(encoding="utf-8"))
        except (OSError, json.JSONDecodeError):
            pass
    return {}
