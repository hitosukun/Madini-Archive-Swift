# 自動駆動ループ — 設計メモ

Madini エコシステム全体が目指してきた「書く・読む・抽出するの循環」の
**自動駆動版** に関する設計メモ。Phase A 完了時点での整理であり、実装は
将来 Phase で別途検討する。

## Madini 全体の設計哲学との整合

ジェンナの設計判断を整理すると、全領域で同一パターン:

| 領域 | 自動 (Code/LLM バッチ) | 手作業 (人間) |
|---|---|---|
| 会話ログ | 取り込み・正規化・FTS5 検索 | (なし、原典保護) |
| Wiki entity | LLM で抽出 | `madini_managed: false` で上書き編集 |
| ブックマーク分類 | Code で一括クラスタリング | 不満ある時だけ修正 |
| 編集履歴 | git auto-commit | Obsidian で通常編集 |
| あらすじ生成 | 既存 LLM プラグイン | 推敲 |

**メタ原則: 機械が下書きを作る、人間は上書きと拒否権を持つ**

## 前提条件

- テキスト選択の柔軟化 (M.Archive 側の機能拡張が必要)
- Phase B 完了 (M.Wiki が Obsidian vault に書き込める状態)
- Phase A 完了 (M.Archive で Obsidian vault が読める) ✅ 達成

## 設計上の論点 (将来詰める)

1. **ブックマーク → entity の紐付けタイミング**: バッチのみ確定
2. **ブックマーク自体は entity になる?** → ならない (sources にだけ参照される)
3. **クラスタリングの粒度**: LLM の判断に委ねるか、人間が事前に大カテゴリを
   指定するか
4. **ハイライト + コメントは原典保護とどう両立する?** → 注釈レイヤーを
   別 DB に持つ設計が必要

## Phase 配置の選択肢

- **案 A**: Phase B のスコープを拡張して内包
- **案 B**: Phase D として独立 (M.Archive 側のテキスト選択強化と組み合わせ)
- **案 C**: Phase B 完了後に運用しながら判断

現時点では **案 C が安全**。Phase B の Obsidian 互換化が完了してから
判断する。

## 参考: 過去の関連設計

- **M.Wiki**: 人間タグ付け廃止 + LLM 抽出 + `madini_managed` フィールド
- **M.Archive**: prompt-centered design、原典保護、ブックマーク機能
- **Phase B HANDOFF**: human/llm 二層化廃止、Obsidian vault 統一
