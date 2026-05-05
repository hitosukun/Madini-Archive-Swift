# Phase 3 設計判断 ── キャッシュ層と Bulk Pre-parse

- **日付**: 2026-05-05
- **前提**:
  - [Phase 1 調査](../investigations/freeze-root-cause-investigation.md)
  - [Phase 2 実測](../investigations/freeze-measurement-phase2.md)
- **目的**: Phase 2 の主要結論「真のフリーズ要因は NSCache 一斉 purge → 100+ msgs 同時 miss = 170ms 級」を踏まえた修正方針の判断記録。
- **形式**: 各項目について検討した選択肢 (α/β/γ)、推奨案、最終採用、採用理由を記録。**B-2 のみ推奨案と異なる β を採用、それ以外は推奨案をそのまま採用**。

---

## A. NSCache 改修

### A-1. NSCache の扱い

| | 選択肢 | 概要 | コスト | リスク |
|--|------|------|------|------|
| α | NSCache 廃止 → 自前 LRU | 完全制御。totalCost / age どちらでも eviction 可 | 高（実装+テスト） | スレッド安全性を一から組む |
| β | NSCache 維持 + countLimit のみ（現状） | 変更なし | ゼロ | Phase 2 で問題と特定済み |
| γ | NSCache 維持 + countLimit + totalCostLimit | 既存 API で byte-aware 化 | 低 | NSCache の eviction 順は外から触れない |

**推奨**: γ（既存 NSCache の枠組みを残し、`totalCostLimit` で byte-aware 化）

**採用**: ☑ γ

**理由**: NSCache はスレッド安全性とメモリ警告連動を OS が面倒見てくれる。自前実装の利得は小さく、回帰リスクが高い。eviction 順を外から触れない問題は A-5 のラッパー併用で回避する。

---

### A-2. cost 見積もり方式

| | 選択肢 | 式 | 精度 | 計算コスト |
|--|------|------|------|------|
| α | 生 utf8 byte | `text.utf8.count` | 低（AttributedString は ~3-5x 膨らむ） | O(n) |
| β | 単純係数法 | `text.utf8.count * 4` | 中 | O(n) |
| γ | 実測ベース | NSAttributedString の length / NSImage の bytes を実測 | 高 | API 呼び出しのオーバーヘッド |

**推奨**: β（単純係数 4）

**採用**: ☑ β

**理由**: AttributedString の内部 storage は CommonMark tree + run table を含み、概ね原文の 3〜5 倍。係数 4 は中央値として妥当。実測法は eviction 判断に過剰な精度。値は後から調整可能。

---

### A-3. totalCostLimit 値

| | 選択肢 | 値 | 想定 |
|--|------|------|------|
| α | 保守的 | 64 MB | メモリ余裕の少ない環境向け |
| β | 標準 | 128 MB | 16GB Mac での妥当ライン |
| γ | 寛大 | 256 MB | 大量メモリ前提 |

**推奨**: β（合計 128 MB を 4 キャッシュに分割配分）

**採用**: ☑ β

**配分**:

| キャッシュ | 割当 | 理由 |
|----------|------|------|
| InlineMarkdownCache | 64 MB | エントリ最大、ヒット率最高 |
| blocksCache | 32 MB | parse 結果、再生成コスト低 |
| renderItemsCache | 16 MB | rendering items |
| InlineMathImageCache | 16 MB | NSImage、再生成コスト高だが頻度低 |
| **合計** | **128 MB** | |

**理由**: 1.7 GB の archive.db を扱うアプリで 128 MB のキャッシュは過大ではない。重み付けは Phase 2 でのキャッシュ規模実績（2048 / 500 / 500 / 512 entry）に整合。

---

### A-4. メモリ圧力監視

| | 選択肢 | 仕組み | macOS サポート |
|--|------|------|---------|
| α | 監視なし | NSCache 自動 eviction に任せる | OS 任せ（一斉 purge の問題が残る） |
| β | thermalState 監視 | `ProcessInfo.processInfo.thermalState` | 直接の指標ではない（CPU 熱） |
| γ | DispatchSource | `DispatchSource.makeMemoryPressureSource(.warning)` | macOS 直接サポート |

**推奨**: γ（DispatchSource）

**採用**: ☑ γ

**理由**: macOS は iOS の `UIApplicationDidReceiveMemoryWarningNotification` を持たないが、`DispatchSource.makeMemoryPressureSource` がカーネル直結の memory pressure 通知を提供する。これが正攻法。thermalState は熱負荷指標で、メモリ圧力とは別軸。

---

### A-5. 段階 eviction 戦略

| | 選択肢 | 振る舞い | 弊害 |
|--|------|------|------|
| α | 全 purge | `removeAllObjects()` | Phase 2 で問題と特定済み（170ms 級） |
| β | LRU 古い側半分削除 | `LRUTrackedCache` で順序保持 → 古い 50% を `removeObject` | 平常時オーバーヘッド（順序更新） |
| γ | cost ベースで上位 25% 削除 | サイズ大きい順に削る | LRU との二重管理 |

**推奨**: β

**採用**: ☑ β

**理由**: 一斉 purge を避けるのが Phase 3 の主目的。LRU 順保持のオーバーヘッドは get/set 1 回あたり O(1) Dict 操作で許容範囲。「古い側半分」は eviction の単位として粒度が荒いが、warning 検知頻度が高くないため適切。

---

## B. Bulk Pre-parse

### B-1. pre-parse の配置

| | 選択肢 | 場所 | 注意点 |
|--|------|------|------|
| α | ConversationDetailViewModel + Task.detached | ViewModel 責務として明示 | 既存ライフサイクルに乗せやすい |
| β | View 側 .task modifier | view 出現時に開始 | view が二度マウントされると重複起動 |
| γ | 別ワーカークラス（PrewarmService） | 単一責務クラスで分離 | DI 配線が増える |

**推奨**: α

**採用**: ☑ α

**理由**: 会話詳細のロードは ViewModel 責務であり、その延長線上に置くのが自然。`Task.detached(priority: .userInitiated)` でメインスレッドから外す。既存の `attachConversation` 系エントリポイントから 1 行で起動可能。

---

### B-2. UI 戦略 ★推奨案と異なる選択

| | 選択肢 | 振る舞い | UX |
|--|------|------|------|
| α | 全件バックグラウンド | 表示は cache miss から始まる、スクロール中に warm | 初回スクロールがカクつく可能性 |
| β | 最初の N 件同期 + 残り背景 (N=20) | 開いた直後の画面は warm 済み、スクロール先で warm | 開く瞬間に小ブロック発生だがスクロール開始は滑らか |
| γ | 全件同期 | 現状（フリーズの原因） | 200ms+ ブロック |

**推奨**: α（実装が単純、Task.detached で完全に非同期）

**採用**: ☑ β（**推奨案を覆して採用**）

**理由**:
- 推奨 α は実装が一番シンプル。しかし開いた瞬間に最初のスクロール領域が cache miss だと、ユーザーがスクロールする前のフレームで body 評価が走り、結局メインスレッドで 5ms 級の処理が連続する（Phase 2 シナリオ B）。
- β は「画面に最初に映る領域だけは確実に warm」を保証する。Phase 2 実測で平均メッセージ 0.05 ms × 20 件 = **1 ms** 程度の同期コストで、これはユーザーが感じない。
- N=20 は LazyVStack の初期 instantiate 数の上限近傍を狙った設定。スクロールバー出現前の可視領域をほぼ覆う。
- 「推奨案を覆す」判断の動機: シンプルさより perceived snappiness を優先。1 ms の同期コストは許容できる、とジェンナ判断。

---

### B-3. スクロール優先順位付け

| | 選択肢 | 振る舞い | 複雑度 |
|--|------|------|------|
| α | 付けない（msg_index 順） | バックグラウンドで先頭から順次 | 低 |
| β | scrollProxy で可視範囲を優先 | スクロール先のメッセージを先に warm | 高（SwiftUI の visibility 検出が脆い） |
| γ | 二段階（可視先 → 残り） | β + 完了後に残りを warm | 高 |

**推奨**: α

**採用**: ☑ α

**理由**: B-2 で最初の 20 件は同期 warm 済みなので、ユーザーがそこから外れて高速スクロールしない限り背景処理は間に合う。複雑な可視性検出は後回し。3c の完了後にフリーズが残ればこの方針を再評価。

---

### B-4. cache hit スキップ

| | 選択肢 | 振る舞い |
|--|------|------|
| α | する（miss のメッセージのみ warm） | 2 回目以降の会話オープンは無コスト |
| β | 常に再計算 | 誤った cache 状態の修復が早い、ただし無駄が多い |

**推奨**: α

**採用**: ☑ α

**理由**: NSCache の get は O(1)。hit 確認のオーバーヘッドは無視できる。再計算は不要。

---

## C. 後始末

### C-3. ベンチスクリプトの扱い

| | 選択肢 | 振る舞い |
|--|------|------|
| α | 削除 | `rm -rf scripts/benchmarks/` |
| β | 残す + AGENTS.md に手順追記 | regression 確認の常設ツール |
| γ | 残すが README にだけ書く | AGENTS.md は不変 |

**推奨**: β

**採用**: ☑ β

**理由**: 同じパフォーマンス問題の再発時、毎回 ContentBlock.parse をコピーして測るのは非効率。一度動く形で残しておけば、誰でも `swift run -c release` で再計測できる。AGENTS.md に書くのは「プロジェクトの公式手順」と位置づけるため。

---

## 判断のまとめ

| 項目 | 採用 | 推奨と一致 |
|------|------|---------|
| A-1 NSCache 方式 | γ（NSCache + countLimit + totalCostLimit） | ✓ |
| A-2 cost 見積もり | β（utf8 × 4） | ✓ |
| A-3 totalCostLimit | β（128 MB） | ✓ |
| A-4 メモリ圧力監視 | γ（DispatchSource） | ✓ |
| A-5 段階 eviction | β（LRU 古い側半分） | ✓ |
| B-1 pre-parse 配置 | α（ViewModel + Task.detached） | ✓ |
| **B-2 UI 戦略** | **β（20 同期 + 残り背景）** | **✗（推奨は α）** |
| B-3 スクロール優先順位 | α（付けない） | ✓ |
| B-4 cache hit スキップ | α（する） | ✓ |
| C-3 ベンチ後始末 | β（残す + AGENTS.md） | ✓ |

採用一覧を Phase 3 計画文書（`docs/plans/phase3-implementation.md` 相当）の冒頭サマリ表と整合させること。
