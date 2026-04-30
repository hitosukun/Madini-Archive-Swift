# Phase 1 実装指示文（下書き）

`docs/plans/thinking-preservation-2026-04-30.md` の Phase 1 を Code に依頼するときの雛形。`phase-1-decision-points.md` の判断結果を `<<<判断 X: 結論>>>` プレースホルダに埋め込んでから投げる。

---

## 着手前の必須確認

- main HEAD の現在地を確認（最新の hotfix 状態であること）
- 既存の調査・設計レポートを読む:
  - `docs/investigations/rendering-framework-2026-04-30.md`
  - `docs/investigations/importer-migration-2026-04-30.md`
  - `docs/plans/thinking-preservation-2026-04-30.md`（本実装計画の本体）
  - `docs/plans/phase-1-decision-points.md`（判断結果はこのファイル末尾参照）
- 新規 worktree を main HEAD から切る（ブランチ名: `claude/phase-1-python-schema-migration`）
- Python 環境の確認（`/Users/ichijouhotaru/Madini_Dev/` で `python3 -c "import sqlite3, json, hashlib"` が成功すること）
- 既存の Python テストが通る状態であることを確認（テストが存在する場合のみ）

---

## 確定した方針（前提）

ジェンナとの議論で確定した方針を再掲:

- **アーキテクチャ宣言**: Python core は永続的な portable 土台。Swift への完全移行はしない。GUI 層が着せ替え可能なシェル。
- **直近の解決対象**: Bug B（Claude の thinking ブロックが Python importer の段階で flat text に結合される）を、Python core の改修で構造保存することにより解決する。
- **後方互換**: 既存 reader（Python GUI / 旧 Swift / iOS）が壊れない設計。`messages.content` は無変更で残す。
- **原本保全**: `raw_sources.raw_text` は無傷。新形式は raw_sources から導出可能。

---

## 確定した判断（`phase-1-decision-points.md` より）

以下のプレースホルダをジェンナの判断結果で置換してから Code に投げる:

- **スキーマ案**: <<<判断 1: 結論。例「案 1（messages.content_json TEXT 列追加）」>>>
- **一括 vs 段階**: <<<判断 3: 結論。例「案 A（一括移行、Phase 5 で `backfill_content_json.py` 一回実行）」>>>
- **ChatGPT reasoning の同時実装**: <<<判断 6: 結論。例「Phase 2 と Phase 2b を同時実装」>>>

判断 2, 4, 5, 7, 8 は Phase 1 のスコープ外（Phase 進行中に確認）。

---

## Phase 1 のスコープ

`thinking-preservation-2026-04-30.md` §3 の Phase 1 + §3.1 の改修対象から、**Python core 側のスキーマ migration のみ** を切り出す。Phase 2（Claude parser 改修）と Phase 2b（ChatGPT parser 改修）は別 Phase で扱う。

### Phase 1 でやること

1. `archive_store.py` に新規関数 `_ensure_message_columns(cursor)` を追加。
   - `PRAGMA table_info(messages)` で既存列を取得
   - `content_json` 列が無ければ `ALTER TABLE messages ADD COLUMN content_json TEXT` を実行
   - エラーハンドリングは既存の `_ensure_conversation_columns` パターンに合わせる
2. `archive_store.py` の `messages` CREATE TABLE 文（lines 37-51 周辺）に `content_json TEXT` 列を追加。
   - 新規 archive.db では CREATE 時点で列が含まれている形にする
   - 既存 DB は (1) の ALTER で追補される
3. `archive_store.py` の `init_db()` から `_ensure_message_columns(cursor)` を呼び出す。
   - 呼び出し位置は既存の `_ensure_conversation_columns(cursor)` の直後
4. 動作確認:
   - 旧 archive.db を `init_db()` で開いて column が追加されることを確認（`PRAGMA table_info(messages)` で `content_json` 列の存在を確認）
   - 既存 import が壊れないこと（`split_chatlog.py` で実際の export を 1 件 import し、`messages.content` が従来通り、`content_json` が NULL のままであることを確認）
   - 旧 importer がコケないこと（古い列セットでの INSERT も SQLite が暗黙に NULL を埋めるため動くはず、これも実機で確認）

### Phase 1 でやらないこと

- Python parser の改修（`parse_claude_export`、`parse_chatgpt_export`、`_build_claude_message_text` 等は Phase 2 / 2b で扱う）
- `register_conversation` の messages INSERT 拡張（content_json への書き込みは Phase 2 で）
- `_build_claude_message_blocks()` の新設（Phase 2 で）
- `_build_chatgpt_message_blocks()` の新設（Phase 2b で）
- `messages.content` の意味変更（無変更）
- `conversations.hash` の計算方法変更（無変更）
- FTS5 (`search_idx`) の改修（無変更）
- Swift 側の対応（Phase 3 で forward-compat read を追加、Phase 4 で構造ベース render）
- 既存データの backfill（Phase 5）
- ForeignLanguageGrouping の deprecation（Phase 6）

### スコープを限定する理由

スキーマ migration を独立 Phase にすることで:
- ALTER TABLE のみのコミットなので失敗時の影響範囲が最小（列追加だけなら NULL のまま既存挙動）
- 旧 importer / 旧 reader との後方互換を確実に検証してから Phase 2 に進める
- Swift 側は無変更のまま（Phase 3 で forward-compat read を追加するまで `Message.contentBlocks` は `nil`）

---

## 改修対象ファイル

`thinking-preservation-2026-04-30.md` §3.1 を再掲:

| ファイル | 行範囲 | 改修内容 |
|---------|-------|---------|
| `/Users/ichijouhotaru/Madini_Dev/archive_store.py` | 37-51 周辺 | `messages` CREATE TABLE に `content_json TEXT` 追加 |
| `/Users/ichijouhotaru/Madini_Dev/archive_store.py` | `_ensure_conversation_columns` 直後 | `_ensure_message_columns()` 新設 |
| `/Users/ichijouhotaru/Madini_Dev/archive_store.py` | `init_db()` 内 | `_ensure_message_columns(cursor)` 呼び出し追加 |

詳細なファイル一覧は `phase-1-affected-files.md` を参照。

---

## 手順

1. 上記 worktree を切る
2. `archive_store.py` に変更を加える（3 箇所、合計 ~20 行追加）
3. 旧 archive.db のバックアップを取る（`cp ~/Library/Application\ Support/Madini\ Archive/archive.db ~/Library/Application\ Support/Madini\ Archive/archive.db.bak.phase-1-pre`）
4. `init_db()` を実行して migration を適用（Python REPL or 簡単なスクリプト）
5. `PRAGMA table_info(messages)` で `content_json` 列が追加されたことを確認
6. 既存 archive.db で Python GUI を起動し、表示が壊れていないことを確認（messages.content は読まれている）
7. 旧 export を 1 件 import して `register_conversation` が壊れないことを確認（content_json は NULL）
8. コミット（メッセージ: `Phase 1: Add messages.content_json column for thinking-block preservation`）
9. main にマージ（`--no-ff`、メッセージ: `Merge Phase 1: Python schema migration for thinking blocks`）

---

## ロールバック手順

万一問題が発生した場合:

- バックアップ archive.db を復元: `cp ~/Library/Application\ Support/Madini\ Archive/archive.db.bak.phase-1-pre ~/Library/Application\ Support/Madini\ Archive/archive.db`
- Python 改修の revert: `git revert <merge-commit>` または該当ブランチに戻す
- SQLite では `ALTER TABLE ... DROP COLUMN` は SQLite 3.35+ でサポートだが、`content_json` が NULL のままなら無害なので消す必要はない

---

## 完了の判定

- `archive_store.py` に `_ensure_message_columns` 関数が追加されている
- `messages` CREATE TABLE に `content_json TEXT` が含まれている
- `init_db()` から `_ensure_message_columns` が呼ばれている
- 既存 archive.db で `PRAGMA table_info(messages)` の結果に `content_json` 列が含まれる
- 既存 reader（Python GUI）が無変更で動作する
- 新規 import が壊れず、`content_json` が NULL のまま記録される
- main に Phase 1 のマージコミットが追加されている

完了したら次は Phase 2（Claude parser 改修）に進む。Phase 2 の指示文も同様の構造で別途用意する。

---

## やらないこと（再掲）

- Python parser の改修（thinking 抽出ロジック）
- Swift 側の変更
- 既存 archive.db への破壊的書き込み（ALTER ADD COLUMN は破壊的でない）
- 既存 hash の再計算
- FTS5 索引の再構築
- レポート本文の修正
