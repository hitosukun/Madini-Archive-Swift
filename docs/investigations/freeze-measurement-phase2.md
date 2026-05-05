# フリーズ実測レポート (Phase 2)

- **日付**: 2026-05-05
- **ブランチ**: `claude/practical-vaughan-97314f` (base: main `d3faf4b`)
- **前フェーズ**: [`docs/investigations/freeze-root-cause-investigation.md`](freeze-root-cause-investigation.md)
- **スコープ**: archive.db の実データに対する SQL 計測 + ContentBlock.parse 等の Swift ベンチ。本体コード非改変。

---

## 1. タスク 1 ── archive.db のメッセージ数分布

### 全体統計

| 指標 | 値 |
|------|-----|
| 総会話数 | **686** |
| 総メッセージ数 | **58,857** |
| ファイルサイズ | 1,696.9 MB |
| 平均メッセージ数 / 会話 | 85.8 |
| 中央値 (p50) | 46 |
| p75 / p90 | 117.5 / 232.5 |
| **p95** | **301** |
| **p99** | **470.2** |
| **最大** | **708 メッセージ** |

### 閾値超過の会話数

| 閾値 | 会話数 | 全体比 |
|------|-------|--------|
| > 100 メッセージ | 199 | 29.0% |
| > 300 メッセージ | 35 | 5.1% |
| > 500 メッセージ | **4** | 0.6% |
| > 1000 メッセージ | **0** | 0% |

### メッセージ単体の文字数分布

| 指標 | 値 |
|------|-----|
| 中央値 | 168 |
| 平均 | 692.7 |
| p90 | 1,586 |
| p95 | 1,830 |
| p99 | 2,857 |
| **最大** | **84,546 文字（単一メッセージ）** |
| > 12,000 文字（block cap） | 113 件 |
| > 20,000 文字（msg cap） | **50 件** |

### Top-10 (メッセージ数最大の会話)

| conv_id 先頭 | メッセージ数 | 合計文字数 |
|-------------|-----------|-----------|
| 67e0f1e6-… | 708 | 301,399 |
| 67e64bd0-… | 640 | 306,768 |
| 68a14e85-… | 570 | 379,846 |
| 691d3200-… | 504 | 336,676 |
| 67da1596-… | 495 | 155,119 |
| 69263d19-… | 480 | 332,831 |
| 69210050-… | 477 | 293,254 |
| 692a8c80-… | 469 | 399,841 |
| 693f4db0-… | 461 | 261,535 |
| 67f87c9c-… | 430 | 233,473 |

### 判断: ウィンドウ化の要否

判断ガイド（前フェーズ）:
- 95%ile < 100 かつ 最大 < 500 → ウィンドウ化不要
- 95%ile が 100-300 → 要検討
- 95%ile 300+ または 最大 1000+ → ウィンドウ化必須

実測値:
- p95 = **301**（境界線上、僅かに超過）
- 最大 = **708**（1000 未満）
- 500+ は 4 会話のみ
- p99 = 470 → **アーカイブの 99% は全件取得で許容範囲**

**結論**: 「ウィンドウ化必須」ではなく **「要検討」** ゾーン。
- 最も重い4会話（>500 messages）の合計文字数は最大 399,841 = 約 0.4 MB の content text。これだけならメモリは全件保持で問題ない。
- ただし 0.4 MB の text + JSON 全件パース + ビュー hierarchy 構築は cold-start で
  500 メッセージぶん同時に走る → タスク 3 の単発コスト × N の累積が問題化する閾値である。
- **キャッシュ戦略 + 段階ロード（最初の 100 件のみ即時、残りを後追いロード）で吸収可能**と判断。
  完全なウィンドウ化（スクロール先で都度フェッチ）は過剰。

---

## 2. タスク 2 ── messages テーブルのインデックス構成

### スキーマ

```sql
CREATE TABLE messages (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    conv_id TEXT,
    role TEXT,
    content TEXT,
    msg_index INTEGER,
    content_json TEXT,
    FOREIGN KEY(conv_id) REFERENCES conversations(id)
)
```

### 既存インデックス

| インデックス名 | カラム | 種類 |
|--------------|-------|------|
| `idx_messages_conv_order` | (conv_id, msg_index) | 明示的・複合 |

**重要**: 前フェーズで「不在の可能性」と推測していた `(conv_id, msg_index)` 複合インデックスは
**既に存在している**。

### bookmarks テーブル

```sql
CREATE TABLE bookmarks (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    target_type TEXT NOT NULL,
    target_id TEXT NOT NULL,    -- 形式: "conv_id:..." (LIKE で検索される)
    payload_json TEXT,
    created_at TEXT NOT NULL,
    updated_at TEXT NOT NULL,
    tags TEXT, note TEXT
)
```

| インデックス名 | カラム | 用途 |
|--------------|-------|------|
| `idx_bookmarks_recent` | (target_type, updated_at DESC, created_at DESC) | 一覧並び替え |
| `idx_bookmarks_target` | (target_type, target_id) | UNIQUE / 等価検索 |

`target_id` は `target_type`単位の prefix インデックス内に配置されているが、
`LIKE c.id || ':%'` のような **動的に組み立てた連結文字列に対する LIKE** は SQLite の
LIKE-optimization 条件（`column LIKE '<literal>%'`）を満たさず、インデックス
seek にはならない。

### 行数

| テーブル | 行数 |
|---------|------|
| conversations | 686 |
| messages | 58,857 |
| bookmarks | 189 |

### 実行計画 ── LIKE fallback path

クエリ: `SELECT c.id, c.title FROM conversations c WHERE EXISTS (SELECT 1 FROM messages m WHERE m.conv_id = c.id AND m.content LIKE ?) LIMIT 50` (param=`%編集%`)

```
SCAN c
CORRELATED SCALAR SUBQUERY 1
SEARCH m USING INDEX idx_messages_conv_order (conv_id=?)
```

**読み解き**:
- `SCAN c`: conversations を順次読み出し
- 各会話について相関サブクエリで `idx_messages_conv_order` の `conv_id` 一致行を取得
  （**インデックス利用OK**）
- ただし取得した各行の `content` カラムに対して `LIKE '%編集%'` を行う ── **LIKE 部分はインデックス
  を使えない**ので、その会話のメッセージ全件の content に対して substring match が走る
- 平均 86 メッセージ × 686 会話 = 58,857 行の content スキャン（メッセージ毎に平均
  693 文字の substring match）

**推定コスト**: 1メッセージあたり content の文字数に比例した substring 比較。SQLite の
LIKE 実装は単純線形比較なので、平均 693 文字 × 58,857 行 = 約 4,000 万文字比較で
1 検索クエリ。**LIMIT 50 が効いて早期打ち切りされる場合のみ高速化**するが、
マッチが少ないクエリでは完走する。

### 実行計画 ── fetchDetail 等価クエリ

クエリ: `SELECT id, role, content, content_json FROM messages WHERE conv_id = ? ORDER BY msg_index`

```
SEARCH messages USING INDEX idx_messages_conv_order (conv_id=?)
```

**読み解き**: `idx_messages_conv_order` がそのまま使える。`ORDER BY msg_index` も
インデックス順なので追加 sort 不要。**この経路は最適**。
問題は SQL 側ではなく、Swift 側で全件を一度に配列化する点（Phase 1 で指摘済み）。

### 実行計画 ── Bookmark フィルタ (LIKE 連結パターン)

クエリ: `SELECT c.id FROM conversations c WHERE EXISTS (SELECT 1 FROM bookmarks b WHERE b.target_id LIKE c.id || ':%') LIMIT 50`

```
SCAN c USING COVERING INDEX sqlite_autoindex_conversations_1
CORRELATED SCALAR SUBQUERY 1
SCAN b USING COVERING INDEX idx_bookmarks_target
```

**読み解き**:
- 外側は covering index で安価にスキャン
- 各会話について bookmarks を **SCAN**（SEARCH ではない！） ── インデックス seek が
  使えていない
- 一回あたり 189 行スキャン × 686 会話 = 約 130K 比較。bookmarks が少数なので致命的
  ではないが、bookmarks が増えるほど線形に悪化する
- 期待される最適形：`b.conv_id = c.id`（直接列マッチ）にできれば SEARCH 化される

### 実行計画 ── Role フィルタ

クエリ: `SELECT c.id FROM conversations c WHERE EXISTS (SELECT 1 FROM messages m WHERE m.conv_id = c.id AND lower(COALESCE(m.role, '')) = ?) LIMIT 50`

```
SCAN c USING COVERING INDEX sqlite_autoindex_conversations_1
CORRELATED SCALAR SUBQUERY 1
SEARCH m USING INDEX idx_messages_conv_order (conv_id=?)
```

**読み解き**: `conv_id` 部分はインデックス利用OK。Phase 1 で「`lower()` でインデックス
無効化」と指摘していたが、**実態は `conv_id` 列のインデックスは効いている**。
`lower(role)` の部分はインデックスがないので row-fetch 後の filter になるだけ。
Role 列の cardinality が低い（user/assistant/system 程度）ため、ここを SARGable
にしても利得は限定的。**Phase 1 の Medium 評価は過大**だった ── Low に格下げ妥当。

### Migration 履歴の確認

`Sources/Core/AppServices.swift` 内のスキーマ定義箇所のみ抜粋:

- ALTER TABLE は `saved_filters` 系のみ（line 218-225）
- 過去にインデックス追加/削除を伴う migration: `idx_conversations_primary_time_expr`,
  `idx_conversations_source_created_at`, `idx_conversations_imported_at` (line 622-636)
- bookmarks テーブルは `target_type, target_id` UNIQUE の単純構成（過去に
  `conversation_id` 列追加の試行履歴は無し）

### 判断: インデックス追加の要否

**追加不要** ── 主要パスのインデックスは既に存在しており、計画上も活用されている。

**残る最適化余地**:
1. **LIKE fallback の content スキャン** ── インデックスでは解決できない（LIKE
   `%foo%` は本質的に non-SARGable）。FTS5 tokenizer 変更（trigram → unicode61）
   で 2-char 検索を FTS path に取り込むのが正攻法
2. **bookmark filter の SCAN-on-b** ── `bookmarks.conv_id` 列追加 + 等価結合への
   migration が必要。現状の bookmarks=189 では実害小だが、設計上は改善対象

---

## 3. タスク 3 ── ContentBlock.parse() の実測コスト

### 計測条件

- ビルド: `swift build -c release` (M-series Mac, macOS 16.0)
- 各 100 iterations（warmup 5 を別途実施）、平均 / 最大 / 最小を記録
- フィクスチャは synthetic（日本語段落 + 構造要素）。実データに代わる近似

### ContentBlock.parse 単体

| 入力 | 文字数 | avg | max | min |
|------|-------|-----|-----|-----|
| 2k JP + 短いコードブロック | 1,754 | **0.150 ms** | 0.176 | 0.141 |
| 8k JP + リスト/コード/引用 | 6,668 | **0.564 ms** | 0.586 | 0.541 |
| 20k JP プレーン | 20,000 | **1.605 ms** | 1.638 | 1.573 |
| 20k 数式+コード混在 | 19,572 | **1.172 ms** | 1.221 | 1.073 |

### AttributedString(markdown:)

| 入力 | 文字数 | avg | max | min |
|------|-------|-----|-----|-----|
| 2k 一括 | 1,754 | 0.167 ms | 0.180 | 0.159 |
| 8k 一括 | 6,668 | 0.628 ms | 0.643 | 0.617 |
| 20k 一括 | 20,000 | 1.782 ms | 1.837 | 1.760 |
| 8k を 111 段落に分割し各 markdown parse | 4,995 (実体) | **0.007 ms / 段落** | — | — |

**所見**: 段落ごと parse のオーバーヘッドは段落あたり 7µs と極小。
`InlineMarkdownCache` の 2048 エントリ規模なら cache hit 時は実質ゼロ。
miss 時も短文段落なら問題にならない。

### contentBlocksExcludingThinking 等価フロー

| 操作 | 文字数 | avg | max |
|------|-------|-----|-----|
| `removeSubrange(of:)` × 1 件 + `\n{3,}→\n\n` 正規表現 + `ContentBlock.parse(collapsed)` | 20,070 | **1.730 ms** | 1.768 |

`ContentBlock.parse` 単独 (1.6 ms) との差 = 約 0.13 ms が
substring 検索 + regex 置換の追加コスト。**比率としては 8% 増し**で、
parse 自体が支配的。

### LineBreakHints.softWrap

| 入力 | 文字数 | avg | max |
|------|-------|-----|-----|
| 1.5k JP+URL+EN 混在 (典型段落) | 1,500 | **0.133 ms** | 0.140 |
| 20k JP 連続 | 20,000 | **2.217 ms** | 2.589 |

**所見**: 1段落 1.5k で 0.13 ms ≪ 1ms。typical 段落（500 chars 程度）なら
0.05 ms オーダー。20k を一気に渡すと 2.2 ms だが、実際は段落ごと呼ばれるため
合計値は段落数 × 段落サイズに比例。

### Per-message 全パイプライン (parse + 全ブロックの markdown render)

| 入力 | 文字数 | avg | max | min |
|------|-------|-----|-----|-----|
| 2k | 1,754 | **0.397 ms** | 0.408 | 0.391 |
| 8k | 6,668 | **1.702 ms** | 1.732 | 1.689 |
| 20k プレーン | 20,000 | **4.691 ms** | 5.140 | 4.533 |
| 20k 数式+コード | 19,572 | **2.977 ms** | 3.207 | 2.811 |

### 判断: 非同期化の要否

判断ガイド（前フェーズ）:
- < 16 ms → メインスレッドで許容
- 16-50 ms → 軽い引っかかり、非同期化推奨
- 50ms+ → 非同期化必須

実測: **1メッセージ単発処理は最悪でも 5 ms 強**（20k cap message のフルパイプライン）。
これは 60fps の 1 フレーム budget (16.7ms) の 3 分の 1。

**単発の非同期化は不要**。Phase 1 の High 評価 (1-1, 1-2, 1-3) は
**「単発コストが大」という意味では過大評価** ── 現実は単発で数 ms。

ただし以下の **累積シナリオでは話が変わる**:

#### シナリオ A: 500 messages の会話を開く瞬間

- 平均メッセージ ≈ 693 chars → parse 単発 ≈ 0.06 ms（線形補間）
- 全 500 msgs パース: 500 × 0.06 ms = **30 ms**
- うち 50 件は 20k 超のキャップに当たり 1.6 ms × 50 = **80 ms** 追加
- 合計推定: **約 110 ms メインスレッド占有**（cold cache 時）
- → 体感では「カクッと止まる」レベル（1 frame drop）

#### シナリオ B: 高速スクロールでキャッシュ miss が連続

- LazyVStack が一度に instantiate するレンジで複数の cache miss が同フレームに発生
- 例: 5 メッセージが同時 miss、それぞれ 8k 程度 → 5 × 1.7 ms = **8.5 ms**
- 1 フレームに収まる範囲だが、複数フレーム連続するとカクつき体感
- LineBreakHints.softWrap が body 内の段落数だけ呼ばれる ── 段落 50 個 × 0.05 ms
  = 2.5 ms 追加

#### シナリオ C: NSCache eviction 後の一斉再パース

- countLimit=500 が一括 purge → 可視メッセージ全部がキャッシュ miss
- 100 visible messages × 1.7 ms = **170 ms**（これは確実にビーチボール）
- 突発的に発生するため再現条件が掴みにくい

**結論**:
- 単一メッセージの非同期化は **不要**
- ただし **会話切り替え時の bulk pre-parse** は推奨（cold start 110ms を
  バックグラウンドに追い出す）
- NSCache の **byte-aware 制御 + 段階的 eviction** が最も影響が大きい設計改善
- LineBreakHints は body 内 inline でも問題なし

---

## 4. 総合判断 ── 引き継ぎ事項 6 項目への実測ベース回答

| # | 引き継ぎ項目（Phase 1） | 実測ベースの推奨 |
|---|---------------------|-----------------|
| 1 | メッセージのウィンドウ化 / 仮想化 | **段階ロード推奨 / 完全仮想化は不要**。最大 708、p99 470。最も重い 4 会話のみ要対応。「最初の 100 件即時 + 残り後追いロード」で十分 |
| 2 | テキスト処理の非同期化 | **単発は不要**（5ms 以下）、**会話切り替え時の bulk pre-parse のみ推奨**。`.equatable()` の short-circuit を維持できる |
| 3 | LIKE fallback の改善方針 | **案B (FTS5 tokenizer 変更) を推奨**。インデックス追加（案A）は不要 ── 既存 `idx_messages_conv_order` は機能している。本質コストは LIKE substring 自体 |
| 4 | Bookmark クエリの正規化 | **migration 推奨だが緊急度 Low**。bookmarks=189 行で実害小。設計上の改善として後回し可 |
| 5 | NSCache の制御戦略 | **最重要**。byte-aware eviction + thermalState/memoryPressure 監視導入。シナリオ C のフリーズ説明に最も整合 |
| 6 | (Phase 1 5項目に追加) PromptTopYPreferenceKey | 計測未実施。追加調査の余地あり |

### 主要フリーズ要因の再評価

| Phase 1 評価 | Phase 2 実測後の評価 | 根拠 |
|------------|---------------------|------|
| 1-1 (parse 同期) High | **Medium（単発）/ High（バルク）** | 単発 1.6ms、500件バルクで 30ms |
| 1-2 (excludeThinking) High | **Medium** | 単発 1.7ms |
| 1-3 (AttributedString miss) High | **Low（per-paragraph）** | 段落あたり 7µs |
| 2-1 (LIKE fallback) High | **High（変更なし）** | 4000万文字の content scan が裏付け |
| 2-2 (Bookmark LIKE) High | **Medium** | 189 行 × SCAN は実害小 |
| 3-1+5-1 (fetchDetail 全件) High | **Medium** | 最大 708 件で許容範囲、ただし bulk parse とセットで Medium |
| 5-2 (listBookmarks 無制限) High | **Low（189 行のみ）** | 行数ベースで実害確認できず |
| 6-1〜6-3 (NSCache eviction) Medium | **High（昇格）** | 単発が安いゆえに、一斉 miss で 170ms 級のビーチボール説明可能 |

---

## 5. 作成した一時ファイル一覧 (Phase 2 完了後に削除可)

すべて本体コード非依存。`scripts/benchmarks/` 配下のみ。

```
scripts/benchmarks/
├── measure_message_distribution.py   ── タスク1の SQL 集計 (Python)
├── measure_schema_indexes.py         ── タスク2の schema/index/EXPLAIN (Python)
└── parse_benchmark/                  ── タスク3の Swift ベンチマーク
    ├── Package.swift
    └── Sources/ParseBenchmark/
        ├── ContentBlock.swift        (Sources/Views/Shared/MessageBubbleView.swift から逐語コピー)
        ├── LineBreakHints.swift      (Sources/Views/Shared/LineBreakHints.swift から逐語コピー)
        ├── Fixtures.swift            (合成テキスト)
        └── main.swift                (ベンチランナー)
```

**削除手順**: `rm -rf scripts/benchmarks/` で完了。本体コード参照は無い。

---

## 6. 次フェーズ（修正フェーズ）への引き継ぎ事項

### 修正アプローチの優先順位（実測根拠付き）

1. **NSCache の制御強化（最優先）**
   - `blocksCache`, `renderItemsCache`, `InlineMarkdownCache`, `InlineMathImageCache`
     に `totalCostLimit` 設定 + entry に cost (concrete byte estimate) を付与
   - **根拠**: 単発処理は安いのに「突発的フリーズ」が起きるパターンは、
     一斉キャッシュ purge → 100+ メッセージ同時 miss で 170ms 級のビーチボールに
     なるシナリオで最もよく説明できる
   - macOS では `DidReceiveMemoryWarningNotification` 相当が無いため、
     `NSCache.totalCostLimit` でハードキャップを設けるか、`ProcessInfo.processInfo
     .thermalState` 監視で proactive eviction
   - 「全 purge → 一斉再パース」の代わりに「LRU 段階 eviction」になるよう設計

2. **会話切り替え時の bulk pre-parse**
   - `ConversationDetailViewModel.attachRawServices()` の延長で `Task.detached`
     により全メッセージの `ContentBlock.parse()` をバックグラウンド実行し、
     `blocksCache` を warm 状態にしてから view を表示
   - **根拠**: 500 messages × 0.06 ms = 30 ms (median message 168 chars 換算)
     をメインスレッドから外せる
   - 巨大メッセージ（>20k cap）50 件の追加コスト 80 ms も同じバックグラウンド経路で吸収
   - `.equatable()` の short-circuit はそのまま維持される（state 変更なし）

3. **FTS5 tokenizer の見直し（要長期検討）**
   - 現状: `trigram case_sensitive 0` ── 3-char 未満は LIKE fallback
   - 案: `unicode61` に変更すれば 2-char Japanese 検索も FTS path に乗る
   - **コスト**: AGENTS.md 記載のとおり既存 search_idx の rebuild が必要 ──
     58,857 messages 規模の rebuild は launch 時 progress UI 必須
   - **代替**: trigram のまま、アプリ側で「2-char 検索は LIKE fallback、ただし
     content の prefix N 文字を conversations テーブルに denormalize して
     一次フィルタとする」案も検討余地あり

4. **bookmark target_id の正規化（緊急度 Low）**
   - bookmarks に `conversation_id` 列を追加する migration
   - 現状 189 行では実害なし。bookmarks がスケールしてからでも遅くない
   - 既存 `target_id LIKE c.id || ':%'` パスは互換のため残せる

### 修正不要（Phase 2 で却下）

- ❌ メッセージ取得の SQL ページネーション ── max 708 件で許容、index 既に存在
- ❌ messages テーブルへのインデックス追加 ── `idx_messages_conv_order` で十分
- ❌ ContentBlock.parse() の非同期化（単発） ── 1.6 ms はメインスレッド許容
- ❌ Role フィルタの SARGable 化 ── role は既に conv_id index 経由で seek 済み

### 計測未実施で追加調査余地あり

1. **PromptTopYPreferenceKey の集約コスト** ── スクロール中の SwiftUI preference
   merge 頻度。Instruments の SwiftUI template で実測必要
2. **LazyVStack の materialize 動作** ── macOS 14/15/16 での差異。Time Profiler で
   `_VStackLayoutComputer`系のシンボルを観察
3. **シナリオ C (NSCache 一斉 purge) の実再現** ── メモリ圧力下でのフリーズ
   再現テストハーネスは Phase 2 のスコープ外
4. **84,546 文字の単一メッセージ** ── `maxRenderedMessageLength = 20,000` で
   切り捨てられる挙動の確認（コード上はそうなっているが、実 UI で確認していない）

---

## 補遺 ── ベンチ結果の生ログ

```
=== ContentBlock.parse ===
  / 2k JP + small code           1754 chars   avg=  0.150 ms   max=  0.176 ms   min=  0.141 ms
  / 8k JP + lists/code           6668 chars   avg=  0.564 ms   max=  0.586 ms   min=  0.541 ms
  / 20k JP plain                20000 chars   avg=  1.605 ms   max=  1.638 ms   min=  1.573 ms
  / 20k math+code mix           19572 chars   avg=  1.172 ms   max=  1.221 ms   min=  1.073 ms

=== AttributedString(markdown:) ===
  / 2k                  1754 chars   avg=  0.167 ms
  / 8k                  6668 chars   avg=  0.628 ms
  / 20k                20000 chars   avg=  1.782 ms
  per paragraph (8k fixture, 111 paras): avg per paragraph: 0.007 ms

=== contentBlocksExcludingThinking — substring + regex collapse ===
  20070 chars   avg=  1.730 ms

=== LineBreakHints.softWrap ===
  / 1.5k mixed              1500 chars   avg=  0.133 ms
  / 20k JP                 20000 chars   avg=  2.217 ms

=== Per-message full pipeline (parse + per-block markdown) ===
  / 2k                                1754 chars   avg=  0.397 ms
  / 8k                                6668 chars   avg=  1.702 ms
  / 20k plain                        20000 chars   avg=  4.691 ms
  / 20k math+code                    19572 chars   avg=  2.977 ms
```
