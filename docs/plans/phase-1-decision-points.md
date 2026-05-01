# Phase 1 着手前の判断ポイント

`docs/plans/thinking-preservation-2026-04-30.md` §8 に列挙された 8 つの判断ポイントを、オーナーがすぐ目を通せる形に整理したもの。明日以降、Phase 1 の実装指示文 (`phase-1-implementation-prompt-draft.md`) に反映するため、各項目の「オーナーの判断」欄を埋めて使う。

詳細・代替案・トレードオフはレポート本文 §8 と関連セクションを参照。

---

## 判断ポイント 1: スキーマ案の選択（content_json 列 vs 別テーブル）

**要約**: `messages` への構造化保存方式を確定する。既存 `content` 列 (TEXT) を残したまま `content_json TEXT` 列を追加する案 1 をレポートは推奨。代替は別テーブル `messages_blocks` 新設（案 2）または raw vault 経由のみ（案 3）。

**本文参照**: `thinking-preservation-2026-04-30.md` §2.1, §2.2, §2.3

**推奨案**: 案 1（`messages.content_json` 列追加）。`content` 列を温存して後方互換、Python と Swift の二重対応コスト最小、vault 不在の古い conversation も backfill で救済可。

**オーナーの判断**:
```
[ ] 案 1（content_json 列追加） — 推奨
[ ] 案 2（messages_blocks 別テーブル）
[ ] 案 3（raw vault のみ、スキーマ無変更）
[ ] その他:

理由・補足:
```

---

## 判断ポイント 2: bookmarks 整合性の方針

**要約**: 既存 archive.db の re-import / backfill で bookmarks が壊れないことの確認。レポート §4.4 の調査では、bookmarks は thread-level（`target_id = conversations.id`）のみ実際に存在しており、message_id への依存はないため UPDATE-only backfill で完全に保護される。

**本文参照**: `thinking-preservation-2026-04-30.md` §4.4, §7.5

**推奨案**: 推奨案無し（結論は「無傷」）。ただし念のため Phase 5 の backfill 直前に `SELECT target_type, COUNT(*) FROM bookmarks GROUP BY target_type` で prompt 型が残っていないことを確認する。

**オーナーの判断**:
```
[ ] 推奨どおり進める（事前確認のみ）
[ ] 追加対応が必要 — 内容:

事前確認の結果（後で記入）:
  thread 件数: ____
  prompt 件数: ____ （0 のはず）
  その他:    ____
```

---

## 判断ポイント 3: 一括移行 vs 段階移行（既存 archive.db アップグレード）

**要約**: 既存 conversation の `content_json` を populate する方法を確定する。一括（Phase 5 で一回実行）か段階（lazy migration）か。

**本文参照**: `thinking-preservation-2026-04-30.md` §4.5

**推奨案**: 一括移行（案 A）。`backfill_content_json.py` を一回実行し全 raw_source を処理。段階移行は Swift 側からの DB 書き込みを発生させるため AGENTS.md の "DB は readonly で開く" 原則に反する。

**オーナーの判断**:
```
[ ] 案 A（一括移行） — 推奨
[ ] 案 B（段階移行 / lazy）
[ ] 案 C（ハイブリッド: Claude のみ一括、他ソースは後回し）

理由・補足:
```

---

## 判断ポイント 4: vault/phase-c マージの粒度（一括 vs 抽出）

**要約**: vault/phase-c-importer-audit ブランチを main に取り込む方法。100+ commits の一括マージか、関連 commit のみ cherry-pick か。

**本文参照**: `thinking-preservation-2026-04-30.md` §5.1.1, §5.1.2

**推奨案**: 一括マージ（既に Task 2 で実施済み、main HEAD に取り込み完了）。

**オーナーの判断**:
```
[x] 一括マージ済み（Task 2 で実施、merge commit 5b6c0f0）

→ この項目は実質的に解決済み。Phase 1 着手時に確認のみ。
```

---

## 判断ポイント 5: Phase 0 を最初に着手するか、Python 側 Phase を先に進めるか

**要約**: Phase 0（vault/phase-c マージ）と Python の Phase 1〜2 を並列に進めるか直列にするか。

**本文参照**: `thinking-preservation-2026-04-30.md` §6.5

**推奨案**: Phase 0 はすでに完了。次は Python の Phase 1 → 2 を直列で進めるのが安全。Swift 側 Phase 3〜4 は Python 完了後に並列着手可能。

**オーナーの判断**:
```
[x] Phase 0 完了済み（Task 2）

次の進め方:
[ ] Python Phase 1 → Phase 2（Claude）→ Phase 2b（ChatGPT）→ Swift Phase 3 → 4 → Phase 5 → Phase 6 — 安全側
[ ] Python Phase 1 → Phase 2 と Swift Phase 3 を並列 — トータル時間短縮

理由・補足:
```

---

## 判断ポイント 6: ChatGPT reasoning（Phase 2b）の優先度

**要約**: ChatGPT o3 系の `thoughts` / `reasoning_recap` を Phase 2 と同時に実装するか、Bug B 解決優先で後回しにするか。

**本文参照**: `thinking-preservation-2026-04-30.md` §3.3, §6.1

**推奨案**: 同時に実装（手戻り回避）。スキーマと Swift 側ロジックは provider-agnostic に設計済みなので、ChatGPT 用 parser を別ヘルパーとして並べるだけで完結する。

**オーナーの判断**:
```
[ ] Phase 2 と Phase 2b を同時実装 — 推奨
[ ] Phase 2b は後回し（Bug B 解決優先）

理由・補足:
```

---

## 判断ポイント 7: ForeignLanguageGrouping の翻訳機能の処遇

**要約**: Phase 6 で言語ベースのグルーピングを廃止する際、翻訳ボタン機能を残すか・どこに移すか。

**本文参照**: `thinking-preservation-2026-04-30.md` §5.4, §5.5

**推奨案**: 翻訳機能のみ別 component（`InlineTranslationButton`）に抽出して、thinking block 内の翻訳に再利用。本文中の引用文への翻訳機能は将来拡張余地として保留。

**オーナーの判断**:
```
[ ] 案 A: 翻訳機能を thinking block 限定で残す — 推奨
[ ] 案 B: 任意のテキスト範囲に対する翻訳ボタン（リッチ、Phase 6 範囲外）
[ ] 案 C: 翻訳機能ごと廃止

理由・補足:
```

---

## 判断ポイント 8: Phase 0 検証時の "Bug B 再現確認" の要否

**要約**: Phase 0 マージ直後に「Bug B が再現する状態」をベースラインとして確認しておくか。後の Phase 4/5 の改善が見えやすくなる。

**本文参照**: `thinking-preservation-2026-04-30.md` §6.6

**推奨案**: 必要。ただし Task 1〜3 の hotfix 群（main `fd85dca` 時点）で Bug B は既に部分的に緩和されているため、「hotfix 後の状態」を新しいベースラインとして記録するのが現実的。

**オーナーの判断**:
```
[x] hotfix 後の現状をベースラインとして記録（実機の既存挙動を撮影/メモ）
[ ] スキップ

ベースライン記録（後で記入）:
  対象会話 1: ____ ／ 観察された折りたたみの誤動作: ____
  対象会話 2: ____ ／ 観察された折りたたみの誤動作: ____
  ...
```

---

## まとめ: Phase 1 着手前に確定が必要な事項

最低限以下が決まっていれば Phase 1 に進める:

1. 判断ポイント 1: **スキーマ案** — Phase 1 の SQL migration の形が決まる
2. 判断ポイント 3: **一括 vs 段階** — Phase 5 のスクリプト形が決まる（Phase 1 では未着手だが方針として）
3. 判断ポイント 6: **ChatGPT reasoning の同時実装** — Phase 2 のスコープが決まる

判断ポイント 2, 4, 5, 7, 8 は Phase 進行中に確認すれば足りる。
