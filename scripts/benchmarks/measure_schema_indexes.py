#!/usr/bin/env python3
# TEMPORARY — Phase 2 measurement only. Delete after the report is final.
# Reads archive.db read-only. Inspects schema and query plans.

import sqlite3
import sys
from pathlib import Path

DB_PATH = Path.home() / "Library" / "Application Support" / "Madini Archive" / "archive.db"

def section(title):
    print()
    print("=" * 72)
    print(title)
    print("=" * 72)

def dump_indexes(cur, table):
    section(f"Indexes on {table}")
    cur.execute(
        "SELECT name, sql FROM sqlite_master "
        "WHERE type = 'index' AND tbl_name = ? ORDER BY name",
        (table,),
    )
    rows = cur.fetchall()
    if not rows:
        print(f"  (no explicit indexes — only the implicit rowid)")
    for r in rows:
        sql = (r["sql"] or "<auto>").strip()
        print(f"  {r['name']}")
        print(f"    sql: {sql}")
        # Auto-indexes have NULL sql; pull info via index_info
        cur.execute(f"PRAGMA index_info({r['name']!r})")
        cols = cur.fetchall()
        if cols:
            colnames = [c["name"] for c in cols]
            print(f"    columns: {colnames}")

def dump_table_schema(cur, table):
    cur.execute(
        "SELECT sql FROM sqlite_master WHERE type = 'table' AND name = ?",
        (table,),
    )
    row = cur.fetchone()
    if not row:
        print(f"  (table {table} not found)")
        return
    sql = (row["sql"] or "").strip()
    print(f"  CREATE TABLE statement:")
    for line in sql.splitlines():
        print(f"    {line}")

def query_plan(cur, label, sql, params=()):
    print(f"\n  -- {label} --")
    print(f"  SQL: {sql.strip()}")
    cur.execute("EXPLAIN QUERY PLAN " + sql, params)
    for row in cur.fetchall():
        # Row schema: id, parent, notused, detail
        print(f"    {row['detail']}")

def main():
    if not DB_PATH.exists():
        print(f"archive.db not found at: {DB_PATH}", file=sys.stderr)
        sys.exit(1)

    uri = f"file:{DB_PATH}?mode=ro"
    conn = sqlite3.connect(uri, uri=True)
    conn.row_factory = sqlite3.Row
    cur = conn.cursor()

    section("messages table schema")
    dump_table_schema(cur, "messages")
    dump_indexes(cur, "messages")

    section("conversations table schema")
    dump_table_schema(cur, "conversations")
    dump_indexes(cur, "conversations")

    section("bookmarks table schema")
    dump_table_schema(cur, "bookmarks")
    dump_indexes(cur, "bookmarks")

    section("search_idx (FTS5) schema")
    dump_table_schema(cur, "search_idx")
    cur.execute(
        "SELECT name, sql FROM sqlite_master WHERE name LIKE 'search_idx%' ORDER BY name"
    )
    for r in cur.fetchall():
        print(f"  {r['name']:30s} sql={(r['sql'] or '<auto>')[:60]}")

    # ---- Query plans for the LIKE-fallback search path ----
    section("Query plans — LIKE fallback path")
    query_plan(
        cur,
        "EXISTS-on-messages with content LIKE",
        """
        SELECT c.id, c.title FROM conversations c
        WHERE EXISTS (
            SELECT 1 FROM messages m
            WHERE m.conv_id = c.id AND m.content LIKE ?
        )
        LIMIT 50
        """,
        ("%編集%",),
    )

    query_plan(
        cur,
        "fetchDetail-equivalent (messages WHERE conv_id ORDER BY msg_index)",
        """
        SELECT id, role, content, content_json FROM messages
        WHERE conv_id = ?
        ORDER BY msg_index
        """,
        ("dummy-id",),
    )

    query_plan(
        cur,
        "Bookmark filter (b.target_id LIKE c.id || ':%')",
        """
        SELECT c.id FROM conversations c
        WHERE EXISTS (
            SELECT 1 FROM bookmarks b WHERE b.target_id LIKE c.id || ':%'
        )
        LIMIT 50
        """,
    )

    query_plan(
        cur,
        "Role filter (lower(COALESCE(m.role, '')))",
        """
        SELECT c.id FROM conversations c
        WHERE EXISTS (
            SELECT 1 FROM messages m
            WHERE m.conv_id = c.id AND lower(COALESCE(m.role, '')) = ?
        )
        LIMIT 50
        """,
        ("user",),
    )

    section("Row counts")
    for tbl in ("conversations", "messages", "bookmarks"):
        try:
            cur.execute(f"SELECT COUNT(*) AS n FROM {tbl}")
            row = cur.fetchone()
            print(f"  {tbl:20s} {row['n']:>12,d}")
        except sqlite3.OperationalError as e:
            print(f"  {tbl:20s} (error: {e})")

    conn.close()

if __name__ == "__main__":
    main()
