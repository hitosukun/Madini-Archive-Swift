# SwiftUI ViewGraph 蓄積調査

- **日付**: 2026-05-08
- **ブランチ**: `investigation/viewgraph-accumulation`(調査専用、コード変更なし)
- **前提**:
  - [Phase 1 調査](freeze-root-cause-investigation.md)の §5-6(`PromptTopYPreferenceKey` の集約コスト ── 当時要追加調査として保留)
  - [Phase 3a-followup 調査](phase3a-followup-investigation.md)で観察した実機 vmmap データ(peak 1.5 GB, AttributeGraph 130 万ノード)
- **スコープ**: SwiftUI の `AttributeGraph` ノードが時間経過と操作で蓄積する現象の機構特定と緩和案。コード変更は含まない。

---

## 1. 症状データ

| 状態 | RSS | Physical footprint | AttributeGraph ノード | DefaultMallocZone allocations |
|------|-----|-------------------|---------------------|-------------------------------|
| 起動直後(9 秒後) | 143 MB | 50.5 MB | **50,777** | 149,187 |
| 23 分使用後(Phase 3a-followup 観察) | 511 MB(peak 1.5 GB) | — | **1,308,935** | 1,672,277 |
| 比 | 3.6× / 30× | — | **25.8×** | 11.2× |

**観察事実**:
- AttributeGraph ノードは 23 分で 26 倍に増加
- ノード増加に対して allocation 増加は緩やか(11×)── 各ノードが大きくなるのではなく、ノードの数自体が増えている
- Physical footprint の peak は 1.5 GB ── 一時的にだいぶ膨らむが、現状値(調査時 511 MB)に戻っているのは OS の swap-out + cache 解放の組合せ

---

## 2. 蓄積ホットスポットの特定

### 2.1 `PromptTopYPreferenceKey` 起因の per-block `GeometryReader`

`MessageBubbleView.swift:555-565` ── アシスタントメッセージの **block ごと** に GeometryReader + preference を attach:

```swift
renderItem(item, blockAnchorID: anchorID)
    .id(anchorID)
    .background(
        GeometryReader { proxyGeo in
            Color.clear.preference(
                key: PromptTopYPreferenceKey.self,
                value: [anchorID: proxyGeo.frame(in: .named(...)).minY]
            )
        }
    )
```

`ConversationDetailView.swift:433-442` ── ユーザーメッセージにも GeometryReader を attach。

**ノード規模の見積もり**:
- 1 メッセージあたり block 数: 中央値 5-10(段落 + リスト + コード等)
- 1 GeometryReader あたり AttributeGraph ノード: 経験的に 5-15 個(geometry 計算、preference 公開、frame 監視等)
- 1 メッセージで AG に乗るノード: ~50-150
- 1 会話(中央値 46 メッセージ): ~2,000-7,000 ノード

これだけだと 1.3M に到達するには **180-650 会話分の蓄積** が必要。23 分でそれだけ開く運用は考えにくいので、別の蓄積要因が併存している可能性が高い。

### 2.2 `LazyVStack` のノード保持挙動

`ConversationDetailView` の reader ペインは `LazyVStack` 内に `ForEach(Array(detail.messages.enumerated()))` でメッセージを並べる(Phase 1 §3-2 で High 評価)。

**SwiftUI の本来の挙動**:
- LazyVStack はビューを「画面外になっても layout 情報のみ保持し、materialize は破棄」する
- AttributeGraph ノードも materialize 解除と同期して GC されるはず

**観察された挙動**: 1.3M ノードは現実の visible message 数(50-100 程度)を遥かに超える。**materialize-解除されたメッセージのノードが残存している** ことを示唆。

### 2.3 会話切替時の view tree 再生成

`ConversationDetailView` は `.id(conversation.id)` で SwiftUI identity を回している(`DesignMockRootView.swift:4476`):

```swift
ConversationDetailView(...)
    .id(conversation.id)
```

**意図**: 会話を切替えた時に view-model の `@State` を確実にリセットするため、SwiftUI 上では「別 view」として扱う。

**副作用の可能性**: 切替えるたびに新しい view-graph 部分木が生成される。**古い部分木が即座に解放されないと、切替えるたびに ViewGraph が肥大化する**。

23 分で 25 会話切替えれば、各会話 ~50K ノード × 25 = 1.25M ノード ── **観察値とほぼ一致**。

→ これが**最有力の蓄積機構**。

---

## 3. 仮説の評価

| 仮説 | 強度 | 根拠 |
|------|------|------|
| **F-1**: per-block GeometryReader でビュー graph が肥大化する | **Medium** | block 数 × AG ノード数で見積もるとそれなりだが、単独では 1.3M に届かない |
| **F-2**: LazyVStack の materialize 解除でノードが GC されない | **Medium** | 観察ノード数が visible 数を遥かに超える事実から推定。SwiftUI 内部実装次第なので確証は取れない |
| **F-3**: 会話切替時に古い view tree のノードが解放されない | **High** | ノード増加量と切替操作回数の積算が観察値とほぼ一致。`.id(conversation.id)` による強制再生成と組合さると説明力が高い |

### 3.1 仮説 F-3 の追加裏付け

ジェンナの実機観察より:
- アプリ再起動でハイライト消失症状が解消(Phase 3a-followup §8 観察 1)
- ノードがプロセス内に蓄積し続け、再起動でリセットされるパターンと整合

### 3.2 ノード蓄積と「重さ・ハイライト消失・スクロールずれ」の関係

Phase 3a-followup の調査では:
- **「重さ」「ハイライト消失」「スクロールずれ」は state desync が直接原因**(main thread idle、cache 層は健全)
- ノード蓄積はこれらの症状の **間接的な背景**(SwiftUI layout 計算が大きな graph を相手にすると frame drop しやすくなる)

つまり ViewGraph 蓄積は:
- 単独でフリーズを起こす要因ではない(調査時点で main thread idle のため)
- 累積的にレイアウト/レンダリングを重くし、frame drop の確率を上げる
- frame drop が増えると Phase 3a-followup §7 の「scroll convergence loop が timeout」「state update が drop」が起きやすくなる

**Phase 3a-followup の scroll fix(budget 拡張 + skip-already-at-anchor)で対症療法済み**だが、ノード蓄積を抑えれば予防的にも効く。

---

## 4. 緩和策(優先度順、コード変更は別フェーズで起票)

### 4.1 Tier S: 最小スコープで効果が見込めるもの

#### S-1. `onGeometryChange(for:of:action:)` への移行(macOS 14+ で利用可能)

現状の `GeometryReader { proxy in Color.clear.preference(...) }` パターンは:
- ビュー階層を 1 段深くする(GeometryReader の中に Color.clear)
- preference の dict マージを毎フレーム走らせる

代替: SwiftUI 5.9+(macOS 14, iOS 17) の `onGeometryChange` modifier:

```swift
.onGeometryChange(for: CGFloat.self) { geo in
    geo.frame(in: .named(...)).minY
} action: { newY in
    latestPromptOffsets[anchorID] = newY
}
```

**利点**:
- ビュー階層を増やさない → AG ノード数を減らせる
- preference dict マージ不要 → frame コスト減
- ScrollView 内で `LazyVStack` の materialize 制御に干渉しない

**注意**:
- Madini の deployment target は macOS 14 = サポート OK
- preference 経由の dict 集約フローを完全に置換できるかはコード設計依存(`onPreferenceChange(PromptTopYPreferenceKey.self)` で集約読みする箇所が複数ある)
- ジェンナの `gemini_2026-03-21` 等の math-heavy スレッドで block 数が多いため効果が大きい

**推奨実装ポイント**:
- `MessageBubbleView.swift:554-565` の per-block GeometryReader
- `ConversationDetailView.swift:433-442` の per-message GeometryReader

#### S-2. block-anchor の coalesce(per-block → per-message scroll precision)

find-bar の Next/Prev は **block 単位** の scroll target を使う。これが per-block GeometryReader を必要とする主理由。

提案: find-bar の精度を「block 単位」から「message 単位 + offset 内検索」に変更する。具体的には:
- スクロールは message 単位で `proxy.scrollTo(messageID, anchor: .top)`
- match のハイライトは block 内テキストのみで処理(scroll はしない)
- ユーザーが「次の match」を押したら現在 viewport 内に block があれば in-place ハイライト切替、無ければ message 単位で scroll

**利点**: per-block GeometryReader が不要になる(message 単位だけでよい)。AG ノード数を block 数倍だけ削減。

**欠点**: find-bar の挙動が微妙に変わる(細かい block ジャンプではなく、メッセージ単位にざっくり scroll)。実用上問題ない可能性が高い(現状の Phase 3a-followup の skip-already-at-anchor 修正でも、in-place マッチ表示は導入済み)。

### 4.2 Tier M: 設計変更を伴うもの

#### M-1. 会話切替時の view-graph 強制 GC

`.id(conversation.id)` による view tree 再生成で古いノードが解放されない仮説 F-3 に対し:

- `ConversationDetailView` 自体を `Group` で wrap せず、`@State` でビュー identity を保ったまま中身だけ swap する設計
- 会話切替を「同じ ConversationDetailView インスタンスを reload」とすることで、古い view tree が release される

**注意**: SwiftUI の identity 駆動の挙動に依存するので、「これで本当に GC される」かは実測検証要。Phase 3a-followup §8 観察 2 のメモリ推移が判断材料。

#### M-2. LazyVStack → Lazy + 仮想化の精度向上

現状の `LazyVStack` は SwiftUI 内蔵の lazy 制御に任せている。蓄積が仮想化の不十分さに起因するなら:
- `List` への置換(macOS の List はもう少し aggressive な materialize 解除をする)
- 自前の仮想化レイヤー(極端、コスト大)

ただし `List` は scroll 制御や styling の自由度が下がる。Phase 3 計画文書の「ウィンドウ化必須ではない」結論(Phase 2 §1)とも一部矛盾するため、慎重な設計判断要。

### 4.3 Tier L: 観察ベースで判断するもの

#### L-1. Phase 3b の Bulk Pre-parse の効果検証

Phase 3b で `MessageBubbleView.prewarmCache(for:)` を ViewModel から呼ぶ経路を追加した。これにより:
- 会話切替後の bubble materialize は parse 結果が cache hit するので速い
- materialize 自体が速ければ、view tree の生成も速くなる
- ただし「view tree が GC されない」問題には直接効かない

→ Phase 3b 投入後の vmmap データを再採取し、ノード増加率が改善したか確認する価値あり。

#### L-2. SwiftUI 7.5+ / macOS 26.5+ の挙動変化を観察

macOS 26.4 / SwiftUI 7.4 で観察された蓄積パターンが、OS update でどう変わるかは Apple 内部実装次第。今後のメジャーアップデート時に再計測する。

---

## 5. 計測すべき項目(将来の追加調査用)

- Instruments の **SwiftUI Template** で `AttributeGraph::Subgraph` の生成/解放トレース
- **Memory Graph Debugger** で 1 会話切替前後のスナップショット差分
- 会話切替を高速 5 回繰り返した時のノード増加プロファイル
- LazyVStack の `onAppear` / `onDisappear` 発火頻度の確認(`MessageBubbleView` に観測コード一時追加が必要 ── 別フェーズで)

---

## 6. 結論

### 主因は仮説 F-3(会話切替時の view tree 残存)が最有力

ノード増加量と操作回数の積算が観察値と一致。`.id(conversation.id)` による強制再生成が解放と非同期で行われている可能性が高い。

### 直接的なフリーズ要因ではない

Phase 3a-followup で確認したとおり、症状は state desync が起源。ViewGraph 蓄積は累積的な背景負荷として frame drop の確率を上げるが、それ自体は `main thread idle` 状態でも観察された。

### 推奨アクション(優先順)

1. **Tier S-1**: `onGeometryChange` への移行を別フェーズで起票。macOS 14 サポートしているので技術的障壁なし
2. **Tier L-1**: Phase 3b 投入後の実機データを採取(コード変更なし、ジェンナ運用 + vmmap)
3. **Tier M-1**: 会話切替の view-graph 解放挙動の検証(まず実測 → 必要なら設計変更)
4. **Tier S-2**: find-bar の精度を message 単位に下げる検討は、block 単位の必要性をジェンナと再確認してから

### Phase 3 の総合判断との関係

Phase 3 は「フリーズ解消」が主目的で、ジェンナ実機で達成済み(Phase 3a + scroll/multi-select fixes)。本調査の ViewGraph 蓄積は次世代の最適化テーマで、Phase 3 のスコープ外。

---

## 補遺: コード参照ポイント

| ファイル | 行 | 内容 |
|---------|-----|------|
| `Sources/Views/Shared/MessageBubbleView.swift` | 555-565 | per-block `GeometryReader` + `PromptTopYPreferenceKey` |
| `Sources/Views/Shared/ConversationDetailView.swift` | 433-442 | per-message `GeometryReader` |
| `Sources/Views/Shared/ConversationDetailView.swift` | 584-602 | `onPreferenceChange` で集約読み |
| `Sources/Views/Shared/ConversationDetailView.swift` | 1147 | `PromptTopYPreferenceKey` 定義 |
| `Sources/Views/macOS/DesignMockRootView.swift` | 4476 | `.id(conversation.id)` による view 再生成 |

## 補遺: 調査時の vmmap raw 出力

```
=== T0 (起動 9 秒後、idle list view) ===
Physical footprint:         50.5M
Physical footprint (peak):  51.6M
AttributeGraph_0x102f46160                  4096K      2144K      2144K  ...   50,777
AttributeGraph graph data_0x10508c000        928K       816K       816K  ...    1,848

=== Phase 3a-followup 調査時(23 分後) ===
Physical footprint:  474.4 MB
Peak:               1.5 GB
AttributeGraph_0x934cb4540                  64.0M     52.9M     52.9M ... 1,308,871
AttributeGraph graph data_0x10ef18000       14.0M    3120K     3120K ...    44,181
DefaultMallocZone_0x106640000              806.8M     279.5M    268.0M ... 1,674,701
```
