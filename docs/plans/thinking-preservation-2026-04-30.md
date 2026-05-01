# 設計レポート: thinking ブロック保存対応

- **日付**: 2026-04-30
- **ブランチ**: `claude/plan-thinking-preservation` (base: main `92bf6d9`)
- **スコープ**: 設計レポートのみ（コード変更なし）
- **関連レポート**:
  - `docs/investigations/rendering-framework-2026-04-30.md`（Swift 側 / レンダリング設計）
  - `docs/investigations/importer-migration-2026-04-30.md`（Python 側 / importer 移行検討）

---

## ✅ 実施結果サマリー（2026-05-01 追記）

本計画は **Phase 0〜6 全て完了**。実機（`/Applications/Madini Archive.app`）に反映済み。

### Phase 別の到達状況

| Phase | 内容 | 状態 | 主要 commit |
|-------|------|------|-------------|
| 0 | vault/phase-c-importer-audit を main にマージ | ✅ | Swift `5b6c0f0` |
| 1 | Python: `messages.content_json` 列追加 + `_ensure_message_columns()` | ✅ | Madini_Dev `3db2a79` |
| 2 | Python: Claude parser に thinking 抽出 (`_build_claude_message_blocks`) | ✅ | Madini_Dev `1ac010f`（2b と同一 commit） |
| 2b | Python: ChatGPT o3 系 `thoughts` / `reasoning_recap` 抽出 | ✅ | Madini_Dev `1ac010f` |
| 3 | Swift: `MessageBlock` enum + `Message.contentBlocks` + GRDB 読み込み | ✅ | Swift `3e9f67b` |
| 4 | Swift: `MessageRenderProfile.collapsesThinking` + `StructuredBlockGrouper` + `ThinkingGroupView` | ✅ | Swift `e6d124d` |
| 4 hotfix | flat content からの thinking dedup（substring 削除） | ✅ | Swift `70778b9` |
| 5 | `Scripts/backfill_content_json.py`（raw_sources + vault 2 パス） | ✅ | Madini_Dev `62ff8fb` |
| 6 | `ForeignLanguageGrouping` deprecation + 今夜の hotfix 4 層除去 | ✅ | Swift `ea902fe` |

### スキーマ migration 結果（実 archive.db）

```
PRAGMA table_info(messages):
  0|id|INTEGER|0||1
  1|conv_id|TEXT|0||0
  2|role|TEXT|0||0
  3|content|TEXT|0||0          ← 既存、無変更
  4|content_json|TEXT|0||0     ← Phase 1 で追加、Phase 5 で 1396 行 populate
  5|msg_index|INTEGER|0||0
```

### Backfill カバレッジ（Phase 5 実行結果）

```
Total messages:    58,857
Backfilled:         1,396 (2.4 %)

Pass 1 (raw_sources):    110 messages from 3 Python-importer batches
Pass 2 (raw_export vault): 1,286 messages from 18 Swift-vault blobs (LZFSE-decompressed via swift CLI)

By source:
  Claude:   40 conversations,   217 messages now carry thinking blocks
  ChatGPT: 250 conversations, 1,179 messages now carry o3 reasoning
```

backfill 不可だった残り 57,461 行は (a) raw_text を保管していなかった古い import か (b) thinking のない通常応答のいずれか。Phase 6 で legacy 言語検出 path を引退させたため、これらは flat content をそのまま render（誤ラベル fold は消滅）。

### 解決された不具合

| 不具合 | 解決経路 |
|--------|---------|
| Bug A: 数式 (`d(x,y)=d(y,x)`) が "Spanish" / "Polish" で誤折りたたみ | Phase 6 で legacy 言語検出 path 引退 → 該当 hotfix（listItem 除外、formula 除外）も deprecated に |
| Bug B: 日本語応答が "Japanese" として誤折りたたみ | Phase 4 で `MessageRenderProfile.collapsesThinking` 経路に切り替え、Phase 5 で 1,396 messages を backfill。Phase 6 で legacy path 引退 |
| Phase 4 hotfix: Claude `message.text` の事前結合による thinking 二重表示 | `contentBlocksExcludingThinking` で flat content から thinking text を substring 除去 |

### 残された判断ポイントとその結論

レポート §8 の判断ポイントを実装中の判断結果で更新:

1. **スキーマ案**: 案 1（`messages.content_json` 列追加）採用 ✅
2. **bookmarks 整合性**: thread-level のみ存在を確認、prompt-level は migration 1-2 で既に lift 済み。UPDATE-only backfill で完全保護 ✅
3. **一括 vs 段階移行**: 案 A（一括 `backfill_content_json.py`）採用 ✅
4. **vault/phase-c マージ**: 一括（30+ commits を Phase 0 で取り込み済み） ✅
5. **Phase 0 着手順序**: Phase 0 → Python (Phase 1, 2, 2b) → Swift (Phase 3, 4) → Phase 5 → Phase 6 の直列で実施 ✅
6. **ChatGPT reasoning 同時実装**: Phase 2 と 2b を同 commit で実装 ✅
7. **翻訳ボタンの処遇**: Phase 4 では一旦省略。`ForeignLanguageBlockView` の `Translation.framework` 統合は deprecated 化しつつコード保持（将来「任意テキストの翻訳ボタン」候補として再利用余地） ⏸
8. **Phase 0 後の Bug B 再現確認**: 不要だった（hotfix 4 層が先行して効いていたため） ✅

### 残された作業 / 未対応

- **Push**: 全 commit が origin に push されていない（ローカルのみ）。オーナーの判断で実施。
- `ForeignLanguageGrouping` / `ForeignLanguageBlockView` の **完全削除**: 現状は file-level deprecation banner のみ。escape hatch として保持。本格削除は次回以降の判断。
- `Translation.framework` 統合の `InlineTranslationButton` への抽出: 別フェーズ（任意）。
- Phase 5 で取りこぼした 57,461 messages: raw_text が無い古い conversation は構造的に救済不可。許容。

### 関連ドキュメントへの影響

- `docs/notes/active-worktrees.md`: thinking-preservation 関連の worktree（tender-heisenberg, investigate-importer-migration, plan-thinking-preservation）はレポート main 保存済み・実装完了で削除可。
- `docs/plans/phase-1-decision-points.md` / `phase-1-implementation-prompt-draft.md` / `phase-1-affected-files.md`: 各判断項目の結論を本サマリーに集約済み。準備物としては役目を終えたが、過去の意思決定経緯を残す資料として保持。

---

## 1. 確定した方針の再掲

### 1.1 アーキテクチャ宣言: core + skinnable-shell

オーナーとの議論で確定した方針:

- **Python core は永続的な portable 土台**。importer、SQLite、FTS5 search、正規化を担当。Swift への書き換え計画はない。
- **GUI 層は着せ替え可能なシェル**: SwiftUI Mac（主用途、開発中）、SwiftUI iOS（読み専用派生）、将来 Windows 等。
- 各社 LLM の export 形式は頻繁に変わるため、Python の反復速度を活かす（`JSONImporter.swift` の既存コメント "Re-porting that logic to Swift would duplicate a living codebase and immediately drift" の通り）。
- `importer-migration` レポートの**戦略 C**（Python core を生かす）を採用。戦略 A（Swift 完全移行）と戦略 B（DB 再生成）は不採用。

### 1.2 直近の解決対象

Bug B（Claude エクスポートの thinking ブロックが Python importer の段階で flat text に結合され、view 層で言語検出による誤判定を引き起こす問題）を、Python core の改修で解決する:

- Claude export JSON の `type: "thinking"` ブロックを構造的に保存する
- ChatGPT export JSON の `content_type: "thoughts"` / `content_type: "reasoning_recap"`（o3 系モデル）も同じ仕組みで保存
- Swift reader 側はこの構造を利用して `MessageRenderProfile` ベースの表示判定を行う
- 言語検出ベースの fragile な judgement（現 `ForeignLanguageGrouping`）を構造ベースの確実な判定に置き換える

### 1.3 設計の3つの不変条件

1. **原本保全**: `raw_sources.raw_text` は無傷。新形式は raw_sources から導出可能であること。
2. **後方互換**: 既存の `messages.content` は維持。既存 reader（Python GUI / iOS / 旧 Swift）が壊れない。
3. **provider 横断**: Claude 専用ではなく、ChatGPT reasoning や将来の Gemini reasoning も同じスキーマで扱える。

---

## 2. スキーマ最終決定

### 2.1 採用案: messages.content_json 列追加

`rendering-framework` レポートの 3 案から **案 1（content_json 列追加）** を採用。

**理由**:

| 観点 | 案 1 (content_json) | 案 2 (messages_blocks) | 案 3 (vault のみ) |
|------|---------------------|------------------------|------------------|
| Python 互換 | ◎ (旧 content そのまま) | △ (二重管理) | ◎ |
| Query 性能 | ○ (1 行 fetch + JSON parse) | △ (JOIN) | × (blob 読み込み) |
| FTS5 対応 | ○ (option) | △ | ○ (既存 raw_export_search_idx) |
| 既存 view 層改修 | 中 | 大 | 小 |
| migration コスト | 小（ALTER TABLE 1 件） | 大（CREATE TABLE + 同期） | 0 |
| **vault に無い古い conversation の救済** | **○** | △ | **×** |

決め手: 案 3 では vault に存在しない古い conversation の thinking 救済が原理的に不可能。`messages.content_json` 列を追加し、raw_sources から再 parse して populate するのが最も筋が良い。

### 2.2 messages.content_json の形式

JSON シリアライズした **provider-agnostic block 配列**。

```json
[
  { "type": "text", "text": "..." },
  { "type": "thinking",
    "provider": "claude",
    "text": "[English thinking preamble — model reasoning before response]",
    "metadata": {
      "start_timestamp": "...",
      "stop_timestamp": "...",
      "signature": "..."
    }
  },
  { "type": "text", "text": "[Japanese response body]" },
  { "type": "tool_use", "name": "...", "input_summary": "..." }
]
```

**block 型一覧**（初期版）:

| `type` | 出現プロバイダ | 説明 |
|--------|---------------|------|
| `"text"` | 全 | 通常の応答テキスト |
| `"thinking"` | claude, chatgpt | 内的独白 / reasoning trace |
| `"tool_use"` | claude, chatgpt | ツール呼び出し |
| `"tool_result"` | claude, chatgpt | ツール結果 |
| `"artifact"` | claude | Claude artifact |
| `"image"` | 全 | 画像参照（vault key） |
| `"attachment"` | claude, chatgpt | 添付ファイル |

**設計原則**:
- `type: "thinking"` は provider 横断の汎用型。`provider` フィールドで出所を区別。
- `metadata` は provider 固有のフィールドを格納（時刻、signature 等）。Swift 側は metadata を opaque に保管する。
- 未知の `type` は将来の Gemini reasoning などに備え、Swift 側で `.unsupported(summary:)` にフォールバック可能な設計。

**JSON ではなく flat text に保つ理由（既存の content 列）**:
- FTS5 検索のソース
- Python GUI の表示
- iOS の暫定表示
- 後方互換ツール

content 列は thinking を含まない応答テキスト（ユーザー向け）。content_json は構造化全体。

### 2.3 SQL migration

**Python 側**（`~/Madini_Dev/archive_store.py`）:

新規関数 `_ensure_message_columns(cursor)` を追加し、`init_db()` から呼び出す:

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

**`messages` の CREATE TABLE 文も更新**（`archive_store.py:37-51`）:

```python
cursor.execute(
    """
    CREATE TABLE IF NOT EXISTS messages (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        conv_id TEXT,
        role TEXT,
        content TEXT,
        content_json TEXT,           -- 新規列。NULL は旧形式 = thinking 情報なし
        msg_index INTEGER,
        FOREIGN KEY(conv_id) REFERENCES conversations(id)
    )
    """
)
```

**インデックス**: 追加なし。content_json は単一行 SELECT でしか使わない。

### 2.4 FTS5（search_idx）への影響

**結論: thinking テキストは検索対象に含めない**。

理由:
- thinking は内部独白であり、オーナー自身の言葉ではない
- 検索 UI は「オーナーとのやり取りを思い出す」用途。thinking がヒットして本来探したい応答が埋もれる
- Python の thinking 抑制方針（"the provider UI doesn't surface these to the user, so we don't either"）と整合

具体的には `register_conversation` の FTS5 INSERT（`archive_store.py:365-371`）は変更しない。`full_text` は引き続き **thinking を除いた応答テキストの結合** とする。

将来の拡張: 「thinking も検索したい」という要望が出た場合、別の FTS5 仮想テーブル `thinking_idx` を新設する案で対応。`search_idx` のスキーマは触らない。

### 2.5 hash 計算への影響

**結論: hash 計算は変更しない**。

`archive_store.py:331`:

```python
conv_hash = hashlib.md5(f"{title}{full_text}".encode("utf-8")).hexdigest()
```

ここで `full_text = "\n".join(m["text"] for m in messages)` の `m["text"]` は **thinking を含まない応答テキスト**を渡す。これにより:

- 既存 archive.db の hash と一致 → 既存 conversation との dedup が成立
- 再 import 時に既存 row を上書きせず、metadata のみ UPDATE 経路で動く
- 新規 conversation にも thinking 有無で hash が変わらない（外部 export ファイルが違っても thinking だけ違う場合は別 conversation として識別したい）

注意: Python の現行コードは Claude 用に `_build_claude_message_text` が `message.get("text")` を使っており、これは Claude が thinking を含めずに返す flat text。dedup 安定性は維持される。

### 2.6 raw_sources テーブルとの整合性

`raw_sources` は無変更。`raw_text` フィールドにファイル全体が verbatim で保管されているため、新 importer はここから再 parse できる（§4 を参照）。

### 2.7 Claude 以外のソースへの影響

| ソース | thinking 相当の構造 | 新スキーマ対応 |
|-------|-------------------|---------------|
| Claude | `content[].type == "thinking"` | ✓ メイン対象 |
| ChatGPT (o3 系) | `content_type == "thoughts"` (配列), `content_type == "reasoning_recap"` (要約) | ✓ 同スキーマで対応 |
| ChatGPT (旧モデル) | なし | content_json は NULL でも可（旧 content のみ） |
| Gemini | export に reasoning trace なし | content_json は不要（既存通り） |
| Markdown | 構造化要素なし | content_json は不要 |

**ChatGPT reasoning の扱い**: o3 系モデルの export には `content_type: "thoughts"` (thoughts 配列) と `content_type: "reasoning_recap"` (要約文字列) が存在する（実機 export 確認済）。これらを Claude thinking と同じく `type: "thinking"` block として content_json に保存する:

- `thoughts` 配列 → 配列要素を結合または個別 block として保存
- `reasoning_recap` → 短い要約として metadata に保管、または別 block として併存

ChatGPT 用の Python parser 改修は本 Phase の範囲内（§3.3）。Gemini と Markdown は無変更。

---

## 3. Python importer 改修計画

### 3.1 改修対象ファイル

| ファイル | 行範囲 | 改修内容 |
|---------|-------|---------|
| `~/Madini_Dev/archive_store.py` | 37-51 | `messages` CREATE TABLE に `content_json` 追加 |
| `~/Madini_Dev/archive_store.py` | 67以降（既存 `_ensure_conversation_columns` の隣） | `_ensure_message_columns()` 新設 |
| `~/Madini_Dev/archive_store.py` | `init_db()` 内 | `_ensure_message_columns(cursor)` 呼び出し追加 |
| `~/Madini_Dev/archive_store.py` | 358-363 (register_conversation の messages INSERT) | content_json 列を含めて INSERT |
| `~/Madini_Dev/split_chatlog.py` | 374-403 (`_build_claude_message_text`) | flat text 抽出は維持（content 列用）。新規に `_build_claude_message_blocks` を追加（content_json 列用） |
| `~/Madini_Dev/split_chatlog.py` | 406-440 (`parse_claude_export`) | message に `text_blocks` フィールドを追加（content_json 用） |
| `~/Madini_Dev/split_chatlog.py` | 271-324 (`parse_chatgpt_export`) | thoughts / reasoning_recap を block として抽出 |
| `~/Madini_Dev/split_chatlog.py` | (新規 helper) | `_build_chatgpt_message_blocks` 新設 |
| `~/Madini_Dev/split_chatlog.py` | 内部の messages dict 構造 | `{"role": ..., "text": ..., "blocks": [...]}` に拡張 |

### 3.2 改修内容の詳細

#### 3.2.1 archive_store.py — DB 層の変更

```python
# 既存 (37-51) の messages CREATE TABLE を拡張
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

# 新規関数（既存 _ensure_conversation_columns の真似）
def _ensure_message_columns(cursor):
    existing = {row["name"] for row in cursor.execute("PRAGMA table_info(messages)")}
    if "content_json" not in existing:
        try:
            cursor.execute("ALTER TABLE messages ADD COLUMN content_json TEXT")
        except sqlite3.OperationalError:
            pass

# init_db() 内に追加
_ensure_conversation_columns(cursor)
_ensure_message_columns(cursor)  # 新規追加
```

`register_conversation` の messages INSERT を拡張:

```python
for index, message in enumerate(messages):
    blocks_json = json.dumps(message.get("blocks"), ensure_ascii=False) if message.get("blocks") else None
    cursor.execute(
        """
        INSERT INTO messages (conv_id, role, content, content_json, msg_index)
        VALUES (?, ?, ?, ?, ?)
        """,
        (conv_id, message["role"], message["text"], blocks_json, index),
    )
```

#### 3.2.2 split_chatlog.py — Claude parser

新規ヘルパー `_build_claude_message_blocks(message)` を `_build_claude_message_text` の隣に追加:

```python
def _build_claude_message_blocks(message):
    """Build a structured block list from Claude's content[] array.
    Returns None if content[] is absent or only contains the legacy text
    field (in which case the flat text path is sufficient).

    Block types emitted:
      - {"type": "text", "text": str}
      - {"type": "thinking", "provider": "claude", "text": str, "metadata": {...}}
      - {"type": "tool_use", "name": str, "input_summary": str}
      - {"type": "tool_result", "name": str, "is_error": bool, "summary": str}
    """
    content = message.get("content")
    if not isinstance(content, list) or not content:
        return None

    blocks = []
    for item in content:
        if not isinstance(item, dict):
            continue
        item_type = item.get("type")
        if item_type == "text":
            text = (item.get("text") or "").strip()
            if text:
                blocks.append({"type": "text", "text": text})
        elif item_type in ("thinking", "redacted_thinking"):
            text = (item.get("thinking") or item.get("text") or "").strip()
            if text:
                blocks.append({
                    "type": "thinking",
                    "provider": "claude",
                    "text": text,
                    "metadata": _extract_claude_thinking_metadata(item),
                })
        elif item_type == "tool_use":
            blocks.append({
                "type": "tool_use",
                "name": item.get("name") or "unknown",
                "input_summary": _summarize_claude_tool_input(item.get("name") or "", item.get("input")),
            })
        elif item_type == "tool_result":
            blocks.append({
                "type": "tool_result",
                "name": item.get("name") or "unknown",
                "is_error": bool(item.get("is_error")),
                "summary": _claude_tool_result_summary(item),
            })
        # 未知の type は無視（将来 Anthropic が新しい block を追加した時の defensive）
    return blocks if blocks else None


def _extract_claude_thinking_metadata(item):
    """Preserve a small set of provider-specific fields verbatim. Keep
    this list explicit so we don't accidentally bloat the JSON column
    with stuff Claude adds later (which we'd then store forever)."""
    keys = ("start_timestamp", "stop_timestamp", "signature", "cut_off", "truncated")
    return {k: item[k] for k in keys if k in item}
```

`parse_claude_export` の messages 構築ループを拡張:

```python
for message in sorted(conv.get("chat_messages", []), key=...):
    sender = message.get("sender")
    role = "user" if sender == "human" else "assistant" if sender == "assistant" else None
    if conversation_model is None:
        conversation_model = _extract_model_from_obj(message)
    timestamp = _format_timestamp(message.get("created_at"))
    if timestamp:
        message_timestamps.append(timestamp)
    text = _build_claude_message_text(message)
    blocks = _build_claude_message_blocks(message)
    if role and (text or blocks):
        # text は thinking を含まない（既存挙動）
        # blocks は thinking 含む構造化版（新規）
        messages.append({"role": role, "text": text, "blocks": blocks})
```

#### 3.2.3 split_chatlog.py — ChatGPT parser

新規ヘルパー `_build_chatgpt_message_blocks(message)`:

```python
def _build_chatgpt_message_blocks(message):
    """Build a structured block list from ChatGPT's content object.
    Mirrors _build_claude_message_blocks but for ChatGPT's content_type
    taxonomy. Returns None if there's nothing structured to preserve
    beyond the flat text we already extract."""
    content = message.get("content")
    if not isinstance(content, dict):
        return None
    content_type = content.get("content_type")

    blocks = []

    if content_type == "thoughts":
        # o3 / research models: content.thoughts is a list of strings/dicts
        thoughts = content.get("thoughts") or []
        joined = _join_chatgpt_thoughts(thoughts)
        if joined:
            blocks.append({
                "type": "thinking",
                "provider": "chatgpt",
                "text": joined,
                "metadata": {"source_analysis_msg_id": content.get("source_analysis_msg_id")},
            })
    elif content_type == "reasoning_recap":
        recap = (content.get("content") or "").strip()
        if recap:
            blocks.append({
                "type": "thinking",
                "provider": "chatgpt",
                "text": recap,
                "metadata": {"recap": True},
            })
    # 既存の text / multimodal_text / code / execution_output 等は flat text
    # 経由で content 列に入っているので blocks は thinking 系のみで十分。
    # 将来必要なら multimodal や code も blocks に出す。

    return blocks if blocks else None


def _join_chatgpt_thoughts(thoughts):
    """thoughts list elements may be strings or {summary, content} dicts.
    Returns a single human-readable string. Drops empty entries."""
    parts = []
    for t in thoughts:
        if isinstance(t, str):
            s = t.strip()
            if s:
                parts.append(s)
        elif isinstance(t, dict):
            s = (t.get("content") or t.get("summary") or "").strip()
            if s:
                parts.append(s)
    return "\n\n".join(parts)
```

### 3.3 後方互換性

**ケース 1: 旧 archive.db を新 importer で開く**
- `_ensure_message_columns()` が `ALTER TABLE messages ADD COLUMN content_json TEXT` を実行
- 既存 row は `content_json IS NULL`
- 新規 import からは `content_json` が populate される
- 既存 row の content_json を埋めるには再 import 必要（§4）

**ケース 2: 新 archive.db を旧 importer で開く**
- 旧 importer は `content_json` 列を知らない
- INSERT 時に旧 importer は `(conv_id, role, content, msg_index)` のみ指定
- SQLite はデフォルトで `content_json = NULL` を埋める
- → forward-compatible

**ケース 3: 旧 reader（PyQt6 GUI / iOS 旧版）で新 archive.db を読む**
- 旧 reader は `content` 列のみ参照
- thinking は表示されない（既存挙動と同じ）
- → 影響なし

### 3.4 テスト戦略

#### 3.4.1 Python ユニットテスト

新規テストファイル `Madini_Dev/tests/test_thinking_extraction.py`（仮称）:

- `test_build_claude_message_blocks_thinking_present`: 実際の Claude export JSON を fixture に、thinking blocks が抽出されることを確認
- `test_build_claude_message_blocks_no_content_array`: legacy text-only message に対し None が返ること
- `test_build_claude_message_blocks_metadata`: thinking block の metadata が start_timestamp 等を含むこと
- `test_build_chatgpt_message_blocks_thoughts`: o3 export fixture から thoughts が thinking block として抽出
- `test_build_chatgpt_message_blocks_reasoning_recap`: reasoning_recap が短い thinking block として抽出
- `test_chatgpt_legacy_no_thinking`: GPT-4 など旧モデル export で blocks が None
- `test_register_conversation_writes_content_json`: register_conversation 後の messages.content_json に期待 JSON

#### 3.4.2 統合テスト

`Madini_Dev/tests/test_full_import.py`:

- 実際の Claude export ファイル（fixture）を import
- archive.db の messages テーブルから content_json を SELECT
- 期待される block 配列と一致することを確認

#### 3.4.3 既存テスト回帰確認

- `test_register_conversation` 系のテストが content / hash 計算で壊れないこと
- `parse_claude_export` の text 抽出が既存の挙動を維持すること
- ChatGPT DAG 平坦化の挙動に変化なし

#### 3.4.4 Swift 側 fixture 共有

Python の test fixture（実際の export JSON）を `Tests/MadiniArchiveTests/Fixtures/` 配下にコピーし、Swift 側のテストでも同じ JSON を使う。これにより両言語で同じ入力に対する期待出力を検証できる。

---

## 4. 既存 archive.db のアップグレード戦略

### 4.1 再 import 設計

raw_sources の verbatim 保管を活かして、既存 conversation の content_json を populate する一回限りのスクリプトを用意する。

**スクリプト名**: `Madini_Dev/scripts/backfill_content_json.py`（新規）

**処理フロー**:

```python
# 擬似コード
for raw_source in fetch_all_raw_sources(cursor):
    raw_text = raw_source["raw_text"]
    source_format = raw_source["source_format"]  # "json" / "markdown" / "text"
    if source_format != "json":
        continue  # markdown は thinking がないのでスキップ

    parsed = json.loads(raw_text)
    # provider 判定（既存の autodetect_provider と同じロジック）
    provider = detect_provider(parsed)
    if provider == "claude":
        conversations = parse_claude_export(parsed)
    elif provider == "chatgpt":
        conversations = parse_chatgpt_export(parsed)
    elif provider == "gemini":
        continue  # Gemini は thinking なし
    else:
        continue

    for conv in conversations:
        for index, message in enumerate(conv["messages"]):
            blocks = message.get("blocks")
            if blocks is None:
                continue  # blocks が空なら content_json も NULL のまま

            blocks_json = json.dumps(blocks, ensure_ascii=False)
            cursor.execute(
                """
                UPDATE messages
                SET content_json = ?
                WHERE conv_id = ? AND msg_index = ?
                """,
                (blocks_json, conv["conv_id"], index),
            )
    conn.commit()  # 1 raw_source ずつ commit
```

**重要な設計ポイント**:

- **INSERT ではなく UPDATE**: 既存の `messages.id`（INTEGER AUTOINCREMENT）と `msg_index` は変えない。`content` 列も触らない。`content_json` 列だけを埋める。
  - → bookmarks の `target_id` 形式（`conv_id:msg_row_id`）を維持
  - → hash 計算結果も変わらない
- **冪等性**: 既に content_json が populate されている row は上書きしない（`WHERE content_json IS NULL` 追加可）
- **commit 粒度**: raw_source 1 件ずつ commit。中断時の再開を可能にする
- **失敗時の挙動**: 1 conversation の parse エラーは skip（log に記録）、他に影響しない

### 4.2 進捗表示・中断・再開

```python
# 全 raw_source 数を取得
total = cursor.execute("SELECT COUNT(*) FROM raw_sources WHERE source_format = 'json'").fetchone()[0]

# 既に処理済みの raw_source を除外（冪等性）
done = cursor.execute("""
    SELECT COUNT(DISTINCT rs.id)
    FROM raw_sources rs
    JOIN conversations c ON c.raw_source_id = rs.id
    JOIN messages m ON m.conv_id = c.id
    WHERE rs.source_format = 'json' AND m.content_json IS NOT NULL
""").fetchone()[0]

print(f"Backfill progress: {done}/{total}")

# 1 件ずつ進めながらログ
```

中断対応: スクリプトを `Ctrl+C` で停止しても、最後に commit された分は残る。再実行で `WHERE content_json IS NULL` のみ処理する。

### 4.3 失敗時のロールバック

- raw_source 1 件単位で SAVEPOINT を貼る（既存 import の SAVEPOINT パターンと同じ）
- parse 失敗 → `ROLLBACK TO SAVEPOINT`、次の raw_source へ
- ファイルシステム/DB 全体の破損が発生した場合: スクリプト実行前に archive.db のバックアップを取る運用ルールにする
  - `cp ~/Library/Application\ Support/Madini\ Archive/archive.db ~/Library/Application\ Support/Madini\ Archive/archive.db.bak.2026-04-30`

### 4.4 bookmarks / saved_filters の整合性維持

調査結果:

| 参照テーブル | 参照キー | 安定性 |
|------------|---------|-------|
| `bookmarks` (target_type='thread') | `target_id = conversations.id` | ◎ 完全に安定 |
| `bookmarks` (target_type='prompt') | `target_id = "{conv_id}:{msg_row_id}"` | △ msg_row_id 依存 |
| `saved_filters.filter_json` | filter 定義のみ（参照なし） | ◎ 安定 |
| `project_memberships.thread_id` | `conversations.id` | ◎ 安定 |
| `project_suggestions.thread_id` | `conversations.id` | ◎ 安定 |
| `conversation_raw_refs.conversation_id` | `conversations.id` | ◎ 安定 |

**重要な発見**: `Sources/Core/AppServices.swift:466-563` の migration 1-2 で、prompt-level bookmarks は既に thread-level に lift されている。実機の bookmarks テーブルには prompt 型は存在しない（または migration 後のレガシ残骸のみ）。

オーナーの bookmark 量（memories 上の "52 pinned" は thread-level の pinned bookmarks）。これらは全て `target_id = conversation_id` 形式で、再 import で **無傷**。

**§4.1 の UPDATE-only 戦略により**:
- conversation_id: 不変（provider-native UUID）
- messages.id: 不変（UPDATE のみ、INSERT/DELETE しない）
- messages.content: 不変
- hash: 不変
- → bookmarks / saved_filters / projects 全て影響なし

### 4.5 一括移行 vs 段階移行

#### 案 A: 一括移行（推奨）

Phase 5 で `backfill_content_json.py` を一度実行し、既存全 raw_source を処理。

メリット:
- 全 conversation で thinking が表示されるようになる（vault が無くても動く）
- 状態がシンプル（全 row が新形式）
- 動作検証が一回で済む

デメリット:
- 実行時間（thousands of conversations × parse + UPDATE）
- 失敗時の影響範囲が広い

実行時間見積もり: archive.db 規模（数百〜数千 conversation）× 1 conversation あたり数 ms → 数十秒〜数分。十分許容範囲。

#### 案 B: 段階移行（lazy migration）

content_json が NULL の row を、reader が初めてアクセスした時に on-demand で populate。

メリット:
- 一括処理が不要
- 失敗時の影響が局所的

デメリット:
- Swift reader 側に lazy migration ロジックが必要（Python 呼び出し）
- archive.db への書き込みが Swift から発生する → AGENTS.md の "DB は readonly で開く" 原則に反する
- `JSONImporter.swift` 経由で Python に書き込み委譲する必要があり、複雑性が高い
- 状態管理（"何 % migrate 済み" を表示する手段）が困難

→ **採用しない**。

#### 案 C: ハイブリッド（Claude のみ一括、他は段階）

Claude conversation のみ Phase 5 で backfill。他ソースは将来のニーズに応じて。

メリット:
- 影響範囲を絞れる
- ChatGPT reasoning は本 Phase の優先度が低ければ後回し

デメリット:
- 部分対応の状態が長く続く

**推奨: 案 A（一括移行）**。raw_sources からの再 parse は失敗してもアボートできる単発バッチで、リスクが低い。

---

## 5. Swift 側対応計画

### 5.1 Phase 0: vault/phase-c-importer-audit を main にマージ

#### 5.1.1 マージ粒度の検討

`vault/phase-c-importer-audit` ブランチは main から **100+ commits ahead**。本件に関係するコミットを抽出すると:

| commit | メッセージ | 本件への関係 |
|-------|----------|-------------|
| `a4aad63` | Parse raw-export JSON into provider-neutral transcripts | ◎ ConversationTranscript 型の基礎 |
| `6c085c5` | Add Source reader that renders transcripts from vaulted raw JSON | ◎ RawTranscriptReaderView |
| `09b321c` | Pick render behavior per conversation source | ◎ MessageRenderProfile |
| `fc6a467` | Detect conversation language for foreign-block grouping | ○ primaryLanguage（ForeignLanguageGrouping を deprecate するなら不要） |
| `3e9fc36` | Phase 9 hotfix: ForeignLanguageGrouping prefix(-N) trap | ○ 同上（クラッシュ修正） |
| `c8b193c` | Render conversation images from the raw export vault | ○ 画像表示。本件と直接関係しないが ConversationTranscript の延長 |
| その他 90+ コミット | sidebar / stats / dashboard / projects 等の UI 改善 | × 本件と無関係 |

**抽出マージは現実的ではない**。理由:

1. `ConversationTranscript` 型を追加した `a4aad63` は、`RawExportVault` API（既に main にある）と `Phase D2 Vault Browser` 等の連鎖変更を含む
2. `09b321c` (`MessageRenderProfile`) は MessageBubbleView の renderItems 改修と連動しており、その親 commit 群（多数の sidebar 改修など）に依存している可能性
3. cherry-pick で多数のコンフリクトが発生する見込み（特に `MessageBubbleView.swift`, `ConversationDetailView.swift` は他 phase でも多数の改修が入っている）

#### 5.1.2 マージ戦略

**推奨: 一括マージ（fast-forward または merge commit）**

`vault/phase-c-importer-audit` が 100+ commits 累積している現状は、本件以外にも多数の機能（stats mode, sidebar, dashboard, projects）が含まれており、これらも並行して main に取り込まれるべき。

手順:

```sh
# main worktree で
git checkout main
git pull origin main

# vault/phase-c との diff を最終確認
git log --oneline main..vault/phase-c-importer-audit
git diff --stat main vault/phase-c-importer-audit

# マージ。merge commit を残してブランチの境界を可視化する
git merge --no-ff vault/phase-c-importer-audit -m "Merge vault/phase-c importer audit
- ConversationTranscript types
- MessageRenderProfile per-source rendering
- RawTranscriptReaderView (Source reader)
- ForeignLanguageGrouping with conversation-level primaryLanguage
- Phase 4-9 features (sidebar, stats, dashboard, projects)
"

# ビルド・テスト確認
swift build
swift test  # vault/phase-c には Tests/ があるはず

# main の動作確認
open .build/debug/MadiniArchive
# 既存 archive.db で既存機能が壊れていないことを確認

git push origin main
```

#### 5.1.3 検証チェックリスト

マージ後、以下を確認:

- [ ] `swift build` 成功
- [ ] `swift test` 全 pass（既存テスト + branch のテスト）
- [ ] `MadiniArchive` 起動成功
- [ ] 既存 archive.db を開いて conversation 一覧表示
- [ ] Claude conversation を開いて表示
- [ ] ChatGPT conversation を開いて表示
- [ ] Source reader（raw transcript path）が動作
- [ ] bookmarks の表示・追加・削除
- [ ] search の動作（FTS5）
- [ ] **既存 ForeignLanguageGrouping の挙動確認**: Bug A/B が起きている状態であることを確認（後で改善されるベースライン）

#### 5.1.4 Phase 0 の規模とリスク

- **規模**: 中（マージ作業自体は1日。検証に追加1日）
- **リスク**: 中（branch の累積期間が長く、想定外の不具合が出る可能性）
- **代替案（リスク回避）**: vault/phase-c をそのまま新 main として扱い、main との合流を本件後に行う。ただし方針的に推奨しない（diverge が拡大する）。

### 5.2 MessageRenderProfile の拡張

既存（vault/phase-c）:

```swift
struct MessageRenderProfile: Hashable, Sendable {
    var collapsesForeignLanguageRuns: Bool

    static let passthrough = MessageRenderProfile(collapsesForeignLanguageRuns: false)
    static let claude = MessageRenderProfile(collapsesForeignLanguageRuns: true)
}
```

拡張後:

```swift
struct MessageRenderProfile: Hashable, Sendable {
    /// 構造化された thinking ブロック（content_json 経由）を折りたたみ表示する。
    /// 言語検出に依存しない。content_json が NULL の場合は何も折りたたまない。
    var collapsesThinking: Bool

    /// 旧言語検出ベースの折りたたみ。content_json が普及しきるまでの fallback。
    /// 既存 archive.db で content_json が NULL の row に対して使う。
    /// 将来 false 固定にして廃止する想定。
    var collapsesForeignLanguageRunsLegacy: Bool

    static let passthrough = MessageRenderProfile(
        collapsesThinking: false,
        collapsesForeignLanguageRunsLegacy: false
    )

    static let claude = MessageRenderProfile(
        collapsesThinking: true,
        collapsesForeignLanguageRunsLegacy: false  // 構造ベースに完全移行後は legacy off
    )

    static let chatgpt = MessageRenderProfile(
        collapsesThinking: true,    // o3 系の reasoning_recap / thoughts に対応
        collapsesForeignLanguageRunsLegacy: false
    )

    static func resolve(source: String?, model: String? = nil) -> MessageRenderProfile {
        guard let normalized = source?.lowercased(), !normalized.isEmpty else {
            return .passthrough
        }
        switch normalized {
        case "claude":
            return .claude
        case "chatgpt":
            return .chatgpt
        default:
            return .passthrough
        }
    }
}
```

`rendering-framework` レポートの推奨案 D（構造的アノテーション + PreambleDetector）からは少し変更:

- `PreambleDetector` の役割は不要（thinking は構造的に明示されているので heuristic 不要）
- 代わりに content_json の `type: "thinking"` block を直接 collapsed group として render

### 5.3 新スキーマ対応の reader 側コード

#### 5.3.1 Repository 層

`Sources/Core/Repositories.swift` の Message struct:

```swift
struct Message: Identifiable, Hashable, Sendable {
    let id: String
    let role: MessageRole
    let content: String
    let contentBlocks: [MessageBlock]?  // 新規。content_json 由来。NULL の場合 nil
    var isUser: Bool { role == .user }
}

enum MessageBlock: Hashable, Sendable, Codable {
    case text(String)
    case thinking(provider: String, text: String, metadata: [String: String])
    case toolUse(name: String, inputSummary: String)
    case toolResult(name: String, isError: Bool, summary: String)
    case unsupported(rawType: String)  // 未知 type の forward-compat
}
```

`Sources/Database/GRDBConversationRepository.swift` (lines 88-90 付近) を拡張:

```swift
let contentJSON: String? = row["content_json"]
let blocks: [MessageBlock]? = contentJSON.flatMap { parseMessageBlocks($0) }

return Message(
    id: "\(id):\(row["id"] as Int64? ?? 0)",
    role: MessageRole(databaseValue: row["role"]),
    content: row["content"] ?? "",
    contentBlocks: blocks
)
```

`parseMessageBlocks` は `JSONDecoder` で `[MessageBlock]` に decode。失敗時は nil。

#### 5.3.2 View 層

`MessageBubbleView` の renderItems 計算で:

```swift
private var renderItems: [MessageRenderItem] {
    let profile = renderProfile
    if let blocks = message.contentBlocks {
        // content_json がある場合: 構造ベースで分類
        return StructuredBlockGrouper.group(blocks: blocks, profile: profile)
    } else if profile.collapsesForeignLanguageRunsLegacy {
        // 旧 archive.db で content_json が NULL: legacy パス
        return ForeignLanguageGrouping.items(
            from: contentBlocks,
            collapseForeignRuns: true,
            nativeLanguage: conversationPrimaryLanguage
        )
    } else {
        // 何もしない（passthrough）
        return contentBlocks.map { .block($0) }
    }
}
```

`StructuredBlockGrouper`（新規）:

```swift
enum StructuredBlockGrouper {
    static func group(
        blocks: [MessageBlock],
        profile: MessageRenderProfile
    ) -> [MessageRenderItem] {
        var result: [MessageRenderItem] = []
        var pendingThinking: [MessageBlock] = []

        func flushThinking() {
            if !pendingThinking.isEmpty {
                result.append(.thinkingGroup(pendingThinking))
                pendingThinking = []
            }
        }

        for block in blocks {
            switch block {
            case .thinking where profile.collapsesThinking:
                pendingThinking.append(block)
            default:
                flushThinking()
                result.append(.block(messageBlockToContentBlock(block)))
            }
        }
        flushThinking()
        return result
    }
}
```

`MessageRenderItem` に新 case 追加:

```swift
enum MessageRenderItem {
    case block(ContentBlock)
    case foreignLanguageGroup(language: NLLanguage, blocks: [ContentBlock])  // legacy
    case thinkingGroup([MessageBlock])  // 新規
}
```

`messageBlockToContentBlock(_:)`: MessageBlock を既存の ContentBlock（markdown parse 済みの `.paragraph` / `.code` 等）に変換するアダプタ。テキスト系は `.paragraph`、tool_use は専用の view、artifact は専用 view など。

#### 5.3.3 旧スキーマ archive.db での挙動

- `messages.content_json IS NULL` → `Message.contentBlocks = nil` → legacy パスへ
- legacy パス: 既存 ForeignLanguageGrouping を使う（Bug B が残るが、強烈ではない暫定動作）
- 既存 archive.db を Phase 5 の backfill 完了まで使い続けるユーザー（あるいは backfill 失敗）への fallback

Phase 5 完了後: `collapsesForeignLanguageRunsLegacy` を false 固定にし、ForeignLanguageGrouping は無効化される。

### 5.4 ForeignLanguageGrouping の処遇

**結論: 段階的に deprecate、最終的に「翻訳ヘルパー」として再生**。

- Phase 4 完了直後: `collapsesForeignLanguageRunsLegacy` トグルとして残す。content_json が NULL の場合の fallback として使う。
- Phase 5 完了後: `collapsesForeignLanguageRunsLegacy` を false 固定。ForeignLanguageGrouping のグルーピング機能は使われなくなる。
- Phase 6: ForeignLanguageBlockView の **翻訳機能のみ** を抽出して別 component（仮: `InlineTranslationButton`）として保存。グルーピングロジックは削除。

  - 翻訳機能は thinking block 以外の本文中外国語（例: 日本語会話に出てきた英語の引用文）に対する付加機能として再利用可能。
  - 「オーナーがハイライトした任意のテキストブロックに対する翻訳」UI として将来 reposition する余地あり。

### 5.5 翻訳ボタンの処遇

**結論: thinking block には翻訳ボタンを併設**。

理由:
- 英語 thinking は今後も多い
- オーナーが thinking 内容を理解したいケースはある
- 既存 ForeignLanguageBlockView の翻訳ロジック（TranslationSession）を再利用可能

実装: `ThinkingGroupView`（新規、`CollapsedBlockGroupView` を改名 or 派生）に翻訳ボタンを内蔵。block の text を翻訳して差し替える既存パターンをそのまま使う。

トリガー条件:
- thinking block の検出言語がシステム言語と異なる場合のみ表示（NLLanguageRecognizer は thinking テキストにのみ適用）
- Bug A の数式誤判定リスクは thinking text ではなく本文 list item の問題なので、thinking 限定での言語検出は安全

---

## 6. Phase 分解と実行順序

### 6.1 全 Phase 一覧

| Phase | タイトル | 担当 | 規模 | 依存 | Bug B 解決寄与 |
|-------|---------|------|------|------|---------------|
| 0 | vault/phase-c を main にマージ | Swift | 中 | なし | 前提（MessageRenderProfile を main に） |
| 1 | Python schema migration（content_json 列追加） | Python | 小 | 0 不要 | 前提 |
| 2 | Python parser 改修（Claude thinking 抽出） | Python | 中 | 1 | △（新 import のみ） |
| 2b | Python parser 改修（ChatGPT reasoning 抽出） | Python | 小 | 1 | △（新 import のみ） |
| 3 | Swift forward-compat read（content_json を読む path 追加） | Swift | 小 | 0 | なし（基盤） |
| 4 | MessageRenderProfile に collapsesThinking 追加 + 構造ベース render | Swift | 中 | 3 | ◎（新 import + Phase 5 後の旧データ） |
| 5 | 既存 archive.db を raw_sources から backfill | Python | 中 | 1, 2, 2b | ◎（旧データの thinking 救済） |
| 6 | ForeignLanguageGrouping の deprecation（legacy トグル off） | Swift | 小 | 4, 5 | クリーンアップ |

### 6.2 依存関係図

```
   Phase 0 ────┐
               │
 Phase 1 ──┬───┼─→ Phase 3 ──→ Phase 4 ──┐
           │   │                          │
           ├──→ Phase 2 (Claude) ─────────┤
           │                              │
           └──→ Phase 2b (ChatGPT) ───────┤
                                          │
                                          ├─→ Phase 6
                                          │
   Phase 5 (Phase 1, 2, 2b 後) ───────────┘
```

### 6.3 各 Phase の詳細

#### Phase 0: vault/phase-c を main にマージ
- **手順**: §5.1 参照
- **検証**: §5.1.3 のチェックリスト
- **規模**: 中（マージ作業 + 検証で 1-2 日）
- **リスク**: 中
- **rollback**: マージ前 commit に reset（push 前なら）

#### Phase 1: Python schema migration
- **対象**: `archive_store.py` のみ
- **作業**:
  - `_ensure_message_columns()` 新設
  - `init_db()` から呼び出し
  - messages CREATE TABLE 文に content_json 追加
- **検証**: 
  - 旧 archive.db を `init_db()` で開いて column が追加されることを確認
  - PRAGMA table_info(messages) で column 確認
  - 既存 import が壊れないこと（content_json は NULL のまま）
- **規模**: 小（数十行の追加、半日）
- **リスク**: 低
- **rollback**: ALTER TABLE は SQLite では DROP COLUMN 不可だが、列が NULL なら無害。最悪 archive.db を backup から復元。

#### Phase 2: Python Claude parser 改修
- **対象**: `split_chatlog.py`
- **作業**:
  - `_build_claude_message_blocks()` 新設
  - `_extract_claude_thinking_metadata()` 新設
  - `parse_claude_export` の messages dict に "blocks" 追加
  - `register_conversation` の messages INSERT に content_json 追加
- **検証**:
  - Python ユニットテスト（§3.4.1）
  - 実 Claude export を import して messages.content_json に thinking が入ることを確認
  - 既存 hash と一致すること（dedup 維持）
- **規模**: 中（1-2 日）
- **リスク**: 低（既存パスは無変更）
- **rollback**: parse_claude_export を旧版に revert。content_json はその後 NULL のまま。

#### Phase 2b: Python ChatGPT parser 改修
- **対象**: `split_chatlog.py`
- **作業**:
  - `_build_chatgpt_message_blocks()` 新設
  - `_join_chatgpt_thoughts()` 新設
  - `parse_chatgpt_export` の messages dict に "blocks" 追加
- **検証**:
  - o3 export fixture でテスト
  - GPT-4 など旧モデル export で blocks が None
  - ChatGPT DAG 平坦化挙動の回帰確認
- **規模**: 小〜中（1 日）
- **リスク**: 低
- **rollback**: 同上

#### Phase 3: Swift forward-compat read
- **対象**: `Sources/Core/Repositories.swift`, `Sources/Database/GRDBConversationRepository.swift`
- **作業**:
  - `MessageBlock` enum 定義
  - `Message` struct に `contentBlocks: [MessageBlock]?` 追加
  - GRDB SELECT に `content_json` を追加
  - JSONDecoder で MessageBlock 配列を parse
- **検証**:
  - 旧 archive.db で `contentBlocks = nil` で動くこと
  - 新 archive.db（Phase 2 後 + 新規 import）で `contentBlocks` が populated
  - 既存 view 層は `Message.content` を引き続き使うので影響なし
- **規模**: 小（半日〜1 日）
- **リスク**: 低
- **rollback**: SELECT に content_json を含めない版に revert

#### Phase 4: MessageRenderProfile + 構造ベース render
- **対象**: 
  - `Sources/Views/Shared/MessageRenderProfile.swift`
  - `Sources/Views/Shared/MessageBubbleView.swift`
  - 新規 `Sources/Rendering/StructuredBlockGrouper.swift`（または `Views/Shared/`）
  - 新規 `Sources/Views/Shared/ThinkingGroupView.swift`
- **作業**:
  - MessageRenderProfile に collapsesThinking 追加
  - resolve(source:model:) に case "chatgpt" 追加
  - StructuredBlockGrouper 新設
  - MessageRenderItem に `.thinkingGroup` case 追加
  - MessageBubbleView の renderItems を構造ベース優先に
  - ThinkingGroupView 新設（CollapsedBlockGroupView 派生 + 翻訳ボタン）
- **検証**:
  - Phase 2 後の新規 import で thinking が折りたたまれて表示
  - 旧データでは legacy パス（ForeignLanguageGrouping）が動く
  - 翻訳ボタンが thinking で動作
- **規模**: 中（2-3 日）
- **リスク**: 中（既存表示への影響）
- **rollback**: renderItems を旧実装に切り替え可能なフラグを残す

#### Phase 5: 既存 archive.db backfill
- **対象**: 新規 `Madini_Dev/scripts/backfill_content_json.py`
- **作業**: §4.1 参照
- **事前作業**:
  - archive.db バックアップ
  - dry-run モード実装（実 UPDATE せずに件数のみカウント）
- **検証**:
  - dry-run で対象 row 数を確認
  - 数件 UPDATE してから content_json を SELECT で確認
  - 全件処理後、Claude conversation を Swift で開いて thinking が表示されることを確認
  - bookmarks / saved_filters の整合性（target_id が変わっていないこと）
- **規模**: 中（スクリプト実装 1 日 + 実行・検証 半日）
- **リスク**: 中（データ更新を伴う）
- **rollback**: backup から archive.db 復元

#### Phase 6: ForeignLanguageGrouping deprecation
- **対象**: 
  - `Sources/Views/Shared/MessageRenderProfile.swift`
  - `Sources/Views/Shared/ForeignLanguageGrouping.swift`
  - `Sources/Views/Shared/MessageBubbleView.swift`
  - `Sources/Views/Shared/ForeignLanguageBlockView.swift`
- **作業**:
  - `collapsesForeignLanguageRunsLegacy` を false 固定
  - ForeignLanguageGrouping のグルーピング機能を削除（または `@available(*, deprecated)`）
  - ForeignLanguageBlockView の翻訳機能を `InlineTranslationButton` に分離
  - ConversationDetailView の primaryLanguage 検出も削除（thinking 検出に不要）
- **検証**:
  - Bug A / Bug B 完全解消の確認
  - thinking 表示・翻訳の正常動作
  - パフォーマンス改善（NLLanguageRecognizer 呼び出し激減）
- **規模**: 小（1 日）
- **リスク**: 低（structure-based path が確立した後の cleanup）
- **rollback**: legacy トグルを true に戻すだけで旧挙動復帰

### 6.4 クリティカルパス

**Bug B 完全解決に必須の Phase**: 0, 1, 2, 3, 4, 5

- Phase 0: MessageRenderProfile を main に
- Phase 1: スキーマ列追加
- Phase 2: Claude thinking を populate（新規 import）
- Phase 3: Swift が読める
- Phase 4: Swift が thinking を構造ベースで折りたたむ
- Phase 5: 既存 conversation の thinking 救済

Phase 2b (ChatGPT) と Phase 6 (cleanup) はクリティカルパス外。

### 6.5 並列実行可能性

- Phase 1, 2, 2b は独立に進められる（Python 内）
- Phase 3 は Phase 0 の後すぐ着手可能（Phase 1, 2 と並列）
- Phase 4 は Phase 3 完了後（Phase 2 とも並列可能）
- Phase 5 は Phase 1, 2, 2b 完了後（Phase 3, 4 と並列可能）
- Phase 6 は Phase 4, 5 完了後

### 6.6 オーナーによる手動チェックポイント

| 時点 | 確認内容 |
|------|---------|
| Phase 0 完了後 | 既存機能が壊れていない（特に ForeignLanguageGrouping の Bug B が再現する状態であることを確認 = ベースライン） |
| Phase 2 完了後 | 新規 Claude import で content_json に thinking が入っている（sqlite3 CLI で SELECT 確認） |
| Phase 4 完了後 | 新規 import の Claude conversation で thinking が折りたたまれて表示 |
| Phase 5 dry-run | UPDATE 対象件数が妥当（既存 Claude conversation 数と概ね一致） |
| Phase 5 完了後 | 既存 conversation で thinking 表示。bookmarks 一覧が変化していない |
| Phase 6 完了後 | Bug A の数式誤判定が消滅。translation ボタンは thinking で動作 |

### 6.7 ロールバック戦略

#### Phase 0 ロールバック
- マージ前 commit に reset（`git reset --hard <pre-merge-commit>`）
- リモート push 前なら容易、push 後なら revert commit を作る

#### Phase 1 ロールバック（スキーマ）
- SQLite は DROP COLUMN を直接サポートしない（SQLite 3.35+ でサポートだが既存データ運用には注意）
- content_json 列が残っていても NULL なので無害
- スクリプトを revert すれば次回 init_db で何もしない

#### Phase 2/2b ロールバック
- parse_claude_export / parse_chatgpt_export を旧版に revert
- 既に書き込まれた content_json データを消したい場合: `UPDATE messages SET content_json = NULL WHERE conv_id IN (...)` を手動実行

#### Phase 3 ロールバック
- GRDBConversationRepository の SELECT に content_json を含めない版に revert
- Message struct の contentBlocks フィールドは ABI 互換のため `default = nil` で残す

#### Phase 4 ロールバック
- MessageRenderProfile を Phase 0 直後の版に revert
- collapsesForeignLanguageRunsLegacy を true に固定で運用

#### Phase 5 ロールバック
- archive.db バックアップから復元
- または `UPDATE messages SET content_json = NULL` で全消去（content / hash は無傷）

#### Phase 6 ロールバック
- ForeignLanguageGrouping を `@available(*, deprecated)` のまま残しておけば、collapsesForeignLanguageRunsLegacy = true で revert 可能

---

## 7. リスクと未解決問題

### 7.1 スキーマ変更による Python core 側の連鎖影響

**Python の検索・表示パスは messages.content だけ読んでいる**ことを調査で確認:

- `fetch_conversation_detail()` (archive_store.py:654-738): `SELECT role, content, msg_index`
- `fetch_conversation_index()` (archive_store.py:616-648): `content` のみ参照
- `fetch_all_conversations()` (archive_store.py:522-532): 同上
- FTS5 search_idx: `content` 由来の text のみ index

→ content_json の追加は **Python core の既存機能に影響なし**。PyQt6 GUI でも追加表示は不要（オーナーは SwiftUI に移行済みで PyQt6 は触らない可能性が高い）。

将来 PyQt6 GUI でも thinking を表示したくなった場合: `fetch_conversation_detail` で content_json も SELECT し、viewer_builder.py で HTML 化する（独立した拡張）。

### 7.2 SwiftUI Mac から Python core を呼ぶ橋

現状の橋（`Sources/Services/JSONImporter.swift`）は **import 時のみ** Python を shell-exec している:

```
ユーザーがファイルをドロップ
  ↓
ImportCoordinator.importDroppedURLs(urls, services:)
  ├── GRDBRawExportVault.ingest(urls:)            ← Swift 完結
  ├── JSONImporter.importFiles(urls:)             ← Python shell-exec (split_chatlog.py)
  └── JSONImportProjectReconciler.reconcileImportedFiles()  ← Swift 完結
```

新スキーマ移行時:
- Python 側 (Phase 1, 2, 2b) を改修すれば、import 経路は自動的に新形式に
- Swift から Python を呼ぶ橋自体は無変更
- Phase 5 の backfill スクリプトはユーザー（オーナー）が手動で実行する想定（GUI からの呼び出しは作らない）

将来の拡張（GUI から backfill 実行）: 別 Phase で `JSONImporter.runBackfill()` 相当を追加。本件のスコープ外。

### 7.3 iOS 派生（読み専用）への影響

iOS は archive.db を読むだけで書き込みはしない（Mac 側で書き、iCloud 等で sync する想定）。

新スキーマ対応:
- iOS の Swift reader が content_json を読めるよう、Phase 3 / Phase 4 の Swift 側対応で完結
- iOS 側で Python を呼ぶ計画は**ない**（モバイルでは Python 実行不可）
- iOS の archive.db が古い形式（content_json IS NULL）の場合、legacy パス（Phase 4 の collapsesForeignLanguageRunsLegacy）にフォールバック
- iOS で backfill する手段はない → ユーザー側で「Mac で backfill → iCloud sync → iOS で受け取る」運用

→ **iOS への直接の影響はなし**。ただし新形式で thinking を見られるようにしたい場合、Mac 側 Phase 5 を実行してから sync する。

### 7.4 将来の Windows 対応

Python core が Windows でも走ること:
- 現状確認: `archive_store.py` / `split_chatlog.py` は標準ライブラリのみ（sqlite3, json, hashlib, datetime, os, pathlib）。Windows 互換のはず。
- Windows 側 GUI: PyQt6 を使うか、Swift on Windows のような将来的選択肢。本件のスコープ外。

スキーマ変更が Windows での移植性を損なうか:
- ALTER TABLE ADD COLUMN は SQLite の標準機能で OS 非依存
- content_json は TEXT 列で純粋に portable
- → 移植性に影響なし

### 7.5 未解決問題

#### 7.5.1 ChatGPT thoughts の境界

ChatGPT o3 の `thoughts` は別 message として export されている可能性がある（assistant の "reasoning_recap" 用 message が独立して存在）。Python で `parse_chatgpt_export` の DAG 平坦化（時系列順）でこれらが混入する場合、メッセージ単位の役割分担をどう扱うか:

- 案 A: reasoning_recap を含む message は本文を空にして blocks のみ持たせる
- 案 B: reasoning_recap message を独立に保持し、Swift 側で「次の assistant message の thinking として表示」
- 案 C: reasoning_recap message を skip し、隣接する assistant message の content_json に注入

→ 実機 ChatGPT export の構造次第。Phase 2b 開始時に再調査が必要。

#### 7.5.2 thinking metadata の長さ制限

Claude thinking は数千文字に達することがある（実 archive 上のサンプルで 1 message あたり ~2,000 文字級も観測）。content_json に丸ごと格納するため、archive.db のサイズが増加する。

- 既存 archive.db サイズ: ~1.8 GB（実機）
- thinking 平均サイズ × 全 Claude assistant message 数 で見積もると: 数百 MB の増加見込み
- raw_sources にも raw_text として既に保管されているため**二重保管**

代替案:
- content_json に thinking text を入れず、raw_sources を参照する pointer だけ入れる
- → reader 側で都度 raw_sources を join する必要があり、性能トレードオフ
- 採用しない（シンプルさ優先）

→ 二重保管を許容。archive.db のサイズが懸念になった時点で別 Phase で圧縮等の対応を検討。

#### 7.5.3 search_idx に thinking を含める判断の再考

§2.4 で「含めない」を決めたが、オーナーの想定ユースケース次第で変更余地あり:

- thinking を検索したいケース: "あの時 Claude が悩んでた話を探したい"
- 含めない方が良いケース: "オーナー自身が書いた言葉を探したい"

→ 暫定「含めない」で進める。要望が出たら別 FTS5 仮想テーブル `thinking_idx` を追加する案で対応。

#### 7.5.4 Phase 5 backfill の対象範囲

raw_sources に保管されている古い conversation は数千件レベル。一部は raw_text が無い古いインポート（`raw_bytes_path` 経由の binary）の可能性 → 無視できると思われるが要確認。

- 確認方法: `SELECT COUNT(*) FROM raw_sources WHERE raw_text IS NULL OR raw_text = ''`
- raw_text 無しの conversation は Phase 5 で skip

#### 7.5.5 vault/phase-c-importer-audit のテスト追加状況

vault/phase-c には Tests/MadiniArchiveTests/ConversationTranscriptExtractorTests.swift と RawExportVaultTests.swift がある。これらは Phase 0 マージで main に取り込まれる。Phase 3 / 4 で新規追加するテストはこれらの隣に置く。

---

## 8. オーナーと相談すべき判断ポイント

### 8.1 スキーマ案の選択（content_json 列 vs 別テーブル）

本レポートは `messages.content_json TEXT` 列追加を推奨（§2.1）。代替案の `messages_blocks` 別テーブルは:
- メリット: 正規化、block 単位のクエリ容易
- デメリット: JOIN コスト、Python 側の改修範囲拡大

→ 推奨に従うか、別テーブル案を選ぶか。

### 8.2 bookmarks 整合性の方針

§4.4 で確認した通り、UPDATE-only の backfill 戦略により thread-level bookmarks（オーナーの 52 pinned を含む）は無傷。prompt-level bookmarks は migration で既に thread-level に lift 済み。

→ この理解で進めて良いか。万一 prompt-level bookmarks が残っているケースの調査が必要か。

### 8.3 一括移行 vs 段階移行

§4.5 で **案 A（一括移行）** を推奨。Phase 5 で `backfill_content_json.py` を一回実行。

代替: 段階移行（lazy）は Swift から DB 書き込みを発生させるため AGENTS.md の "DB は readonly で開く" 原則に反するので非推奨。

→ 推奨に従うか。

### 8.4 vault/phase-c マージの粒度（一括 vs 抽出）

§5.1 で **一括マージを推奨**。100+ commits を選択的 cherry-pick するのは現実的でない。

代替案:
- (a) 一括マージ（推奨）
- (b) vault/phase-c をそのまま新 main として扱う（main との合流を本件後に）
- (c) 関連 commit のみ cherry-pick（コンフリクト多発リスク）

→ どの戦略を採るか。

### 8.5 Phase 0 を最初に着手するか、Python 側 Phase を先に進めるか

Python の Phase 1, 2, 2b は Phase 0 と独立に進められる。並列実行か、Phase 0 を完了させてから Python に着手するか:

- 並列: トータル時間最短。ただし Phase 0 のマージ作業中に Python 側変更が main 側で進むと衝突リスク
- 直列（Phase 0 → Python）: 安全、ただし期間長め

→ オーナーの開発リズムに合わせて選択。

### 8.6 ChatGPT reasoning（Phase 2b）の優先度

Bug B（オーナーの直接の不満）は Claude thinking が原因。ChatGPT o3 系の reasoning は同じ仕組みで保存できるが、Bug B 解決には不要。

- 案 A: Phase 2b を Phase 2 と同時に進める（推奨：将来の手戻り回避）
- 案 B: Phase 2b は後回し（Bug B 解決優先）

→ どちらの方針を採るか。

### 8.7 ForeignLanguageGrouping の翻訳機能の処遇

§5.4 で「翻訳機能のみ抽出して別 component として残す」を推奨。しかし、

- 案 A: 翻訳機能は thinking block 限定（推奨）
- 案 B: 任意のテキスト範囲に対する翻訳ボタンを将来作る（リッチだが本 Phase の範囲外）
- 案 C: 翻訳機能ごと廃止（thinking には付けない）

→ どの方針か。

### 8.8 Phase 0 検証時の "Bug B 再現確認" の要否

§6.6 で Phase 0 完了後に "Bug B が再現する状態" を確認することを推奨。これは後の Phase 4 / 5 で改善が見えるベースライン取りのため。

→ 必要か、省略可能か。
