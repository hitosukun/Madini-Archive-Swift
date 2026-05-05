#!/usr/bin/env python3
# TEMPORARY — Phase 2 measurement only. Delete after the report is final.
# Reads archive.db read-only. Does not mutate any table.

import sqlite3
import sys
import os
import statistics
from pathlib import Path

DB_PATH = Path.home() / "Library" / "Application Support" / "Madini Archive" / "archive.db"

def main():
    if not DB_PATH.exists():
        print(f"archive.db not found at: {DB_PATH}", file=sys.stderr)
        sys.exit(1)

    # Open read-only via URI to avoid any chance of mutating.
    uri = f"file:{DB_PATH}?mode=ro"
    conn = sqlite3.connect(uri, uri=True)
    conn.row_factory = sqlite3.Row
    cur = conn.cursor()

    print("=" * 72)
    print(f"archive.db = {DB_PATH}")
    size_mb = os.path.getsize(DB_PATH) / (1024 * 1024)
    print(f"file size  = {size_mb:.1f} MB")
    print("=" * 72)

    # ---- Per-conversation message counts ----
    cur.execute("""
        SELECT conv_id, COUNT(*) AS msg_count
        FROM messages
        GROUP BY conv_id
    """)
    counts = [r["msg_count"] for r in cur.fetchall()]
    counts.sort()

    total_conversations = len(counts)
    total_messages = sum(counts)

    def pct(p):
        if not counts:
            return 0
        k = (len(counts) - 1) * p / 100.0
        f = int(k)
        c = min(f + 1, len(counts) - 1)
        if f == c:
            return counts[f]
        return counts[f] + (counts[c] - counts[f]) * (k - f)

    print("\n## Per-conversation message count distribution")
    print(f"  total conversations    : {total_conversations:,}")
    print(f"  total messages         : {total_messages:,}")
    if counts:
        print(f"  min                    : {min(counts):,}")
        print(f"  median (p50)           : {pct(50):,.1f}")
        print(f"  mean                   : {statistics.mean(counts):,.2f}")
        print(f"  p75                    : {pct(75):,.1f}")
        print(f"  p90                    : {pct(90):,.1f}")
        print(f"  p95                    : {pct(95):,.1f}")
        print(f"  p99                    : {pct(99):,.1f}")
        print(f"  max                    : {max(counts):,}")

    # ---- Top-10 conversations by message count ----
    cur.execute("""
        SELECT conv_id, COUNT(*) AS msg_count, SUM(length(content)) AS total_chars
        FROM messages
        GROUP BY conv_id
        ORDER BY msg_count DESC
        LIMIT 10
    """)
    print("\n## Top-10 conversations by message count")
    print(f"  {'conv_id':<40s} {'msgs':>8s} {'total_chars':>14s}")
    for r in cur.fetchall():
        cid = (r["conv_id"] or "")[:38]
        tc = r["total_chars"] or 0
        print(f"  {cid:<40s} {r['msg_count']:>8,d} {tc:>14,d}")

    # ---- Top-10 longest single messages ----
    cur.execute("""
        SELECT conv_id, msg_index, length(content) AS char_count
        FROM messages
        ORDER BY char_count DESC
        LIMIT 10
    """)
    print("\n## Top-10 longest individual messages")
    print(f"  {'conv_id':<40s} {'idx':>5s} {'chars':>12s}")
    for r in cur.fetchall():
        cid = (r["conv_id"] or "")[:38]
        print(f"  {cid:<40s} {r['msg_index']:>5d} {r['char_count']:>12,d}")

    # ---- Char-count distribution per message ----
    cur.execute("SELECT length(content) FROM messages")
    char_counts = [row[0] or 0 for row in cur.fetchall()]
    char_counts.sort()

    def pct_chars(p):
        if not char_counts:
            return 0
        k = (len(char_counts) - 1) * p / 100.0
        f = int(k)
        c = min(f + 1, len(char_counts) - 1)
        if f == c:
            return char_counts[f]
        return char_counts[f] + (char_counts[c] - char_counts[f]) * (k - f)

    print("\n## Per-message character-count distribution")
    if char_counts:
        print(f"  min                    : {min(char_counts):,}")
        print(f"  median (p50)           : {pct_chars(50):,.1f}")
        print(f"  mean                   : {statistics.mean(char_counts):,.2f}")
        print(f"  p90                    : {pct_chars(90):,.1f}")
        print(f"  p95                    : {pct_chars(95):,.1f}")
        print(f"  p99                    : {pct_chars(99):,.1f}")
        print(f"  max                    : {max(char_counts):,}")
        # Counts crossing render-cap thresholds
        over_12k = sum(1 for c in char_counts if c > 12_000)
        over_20k = sum(1 for c in char_counts if c > 20_000)
        print(f"  > 12,000 chars (block cap)  : {over_12k:,}")
        print(f"  > 20,000 chars (msg cap)    : {over_20k:,}")

    # ---- Conversations with very many messages (window-decision input) ----
    print("\n## Conversations exceeding key thresholds")
    print(f"  > 100  messages : {sum(1 for c in counts if c > 100):,}")
    print(f"  > 300  messages : {sum(1 for c in counts if c > 300):,}")
    print(f"  > 500  messages : {sum(1 for c in counts if c > 500):,}")
    print(f"  > 1000 messages : {sum(1 for c in counts if c > 1000):,}")

    conn.close()

if __name__ == "__main__":
    main()
