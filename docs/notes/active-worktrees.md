# Active Worktrees — 整理メモ

2026-04-30 時点の worktree 棚卸し。明日朝以降、ジェンナが「これ消して大丈夫？」を判断するための材料。

`.claude/worktrees/` 配下に存在する worktree を列挙し、目的・現状・削除可否を明示する。

---

## 削除可（調査・設計フェーズの完了済み worktree）

これら 3 つは今夜のレポート作成に使ったが、レポートはすべて main の `docs/` 配下に保存済み。worktree 内の作業状態は main マージで保全されているので削除して問題ない。

### `claude/investigate-rendering-framework`
- **path**: `.claude/worktrees/tender-heisenberg-06101d`
- **目的**: 「内的独白の折りたたみブロック化」機能の判定ロジック調査と、ソース×モデル別レンダリング設定フレームワークの設計提案
- **現状**: 調査完了。レポート `docs/investigations/rendering-framework-2026-04-30.md` が main に保存済み
- **削除可否**: ✅ 削除可
- **削除コマンド**: `git worktree remove .claude/worktrees/tender-heisenberg-06101d` 実行後、`git branch -D claude/investigate-rendering-framework`

### `claude/investigate-importer-migration`
- **path**: `.claude/worktrees/investigate-importer-migration`
- **目的**: Python importer から Swift importer への完全移行の作業量見積もり
- **現状**: 調査完了。レポート `docs/investigations/importer-migration-2026-04-30.md` が main に保存済み。結論は戦略 C 採用（Python core 維持）
- **削除可否**: ✅ 削除可
- **削除コマンド**: `git worktree remove .claude/worktrees/investigate-importer-migration` 実行後、`git branch -D claude/investigate-importer-migration`

### `claude/plan-thinking-preservation`
- **path**: `.claude/worktrees/plan-thinking-preservation`
- **目的**: thinking 保存対応プロジェクトの詳細実装計画
- **現状**: 設計完了。レポート `docs/plans/thinking-preservation-2026-04-30.md` が main に保存済み
- **削除可否**: ✅ 削除可
- **削除コマンド**: `git worktree remove .claude/worktrees/plan-thinking-preservation` 実行後、`git branch -D claude/plan-thinking-preservation`

---

## 削除可（今夜の作業用 worktree）

### `claude/phase-1-preparation`（このブランチ自体）
- **path**: `.claude/worktrees/tonight-integration`
- **目的**: 今夜のタスク 1〜5 全体の作業ベース
- **現状**: タスク 1〜5 完了予定。すべての成果物は main にマージ済み（または最終マージ予定）
- **削除可否**: ✅ Task 5 マージ後に削除可
- **削除コマンド**: main マージ後、`git worktree remove .claude/worktrees/tonight-integration` 実行後、`git branch -D claude/phase-1-preparation`
- **注意**: この worktree から複数のサブブランチを作成・マージしたため、削除前に `git branch | grep claude/` で枝が残っていないか確認

#### このブランチから作成された hotfix 系サブブランチ（main にマージ済み）

以下は今夜の作業中に作って main へ merge 済みのサブブランチ。worktree は持たないので `git branch -D` だけでよい:

- `claude/save-investigation-reports`
- `claude/phase-0-merge-vault-phase-c`
- `claude/bug-a-listitem-exclusion`
- `claude/bug-a-formula-text-exclusion`
- `claude/bug-b-user-message-primary-language`
- `claude/bug-b-user-message-primary-language-v2`
- `claude/bug-b-user-message-primary-language-v3`
- `claude/skip-fold-on-short-runs`
- `claude/body-text-size-control`
- `claude/phase-1-preparation`（最後にマージしたら）

一括削除するなら:
```sh
for b in claude/save-investigation-reports \
         claude/phase-0-merge-vault-phase-c \
         claude/bug-a-listitem-exclusion \
         claude/bug-a-formula-text-exclusion \
         claude/bug-b-user-message-primary-language \
         claude/bug-b-user-message-primary-language-v2 \
         claude/bug-b-user-message-primary-language-v3 \
         claude/skip-fold-on-short-runs \
         claude/body-text-size-control \
         claude/phase-1-preparation
do
    git branch -D "$b" 2>/dev/null || true
done
```

---

## 判断保留（ジェンナの実機状態に関わる worktree）

これらは vault/phase-c 以降の Phase 4〜9 系の累積で、ジェンナの実機運用や検証履歴と紐づく可能性がある。**今夜は判断しない**ため一律保留。明日以降ジェンナが見直して整理する。

- **`claude/phase4-sidebar`** (`.claude/worktrees/phase4-sidebar`)
  - HEAD: `827157c` Phase 4: Sidebar User/Library restructure
- **`claude/phase5-stats-detail`** (`.claude/worktrees/phase5-stats-detail`)
  - HEAD: `69c87af` Phase 5 gamma: Stats chart selection
- **`claude/phase5-stats-drilldown`** (`.claude/worktrees/phase5-stats-drilldown`)
  - HEAD: `03e6397` Merge Phase 4
- **`claude/phase5.1-dashboard-lock`** (`.claude/worktrees/phase5.1-dashboard-lock`)
  - HEAD: `9070441` Merge Phase 5 gamma
- **`claude/phase5.2-passive-source-rows`** (`.claude/worktrees/phase5.2-passive-source-rows`)
  - HEAD: `08929ba` Phase 5.2
- **`claude/phase6-stats-mode-redefine`** (`.claude/worktrees/phase6-stats-mode-redefine`)
  - HEAD: `08929ba` Phase 5.2（同 sha、ブランチが追従しているだけ）
- **`claude/phase7-stats-user-prompt-filter`** (`.claude/worktrees/phase7-stats-user-prompt-filter`)
  - HEAD: `277feba` Phase 6 + 7
- **`claude/phase8-dashboard-sidebar-filter`** (`.claude/worktrees/phase8-dashboard-sidebar-filter`)
  - HEAD: `656d518` Phase 8
- **`claude/phase9-foreign-language-grouping-prefix-trap-fix`** (`.claude/worktrees/phase9-foreign-language-grouping-prefix-trap-fix`)
  - HEAD: `3e9fc36` Phase 9 hotfix（vault/phase-c の最終 commit と同じ）

これらの内容は Task 2（vault/phase-c マージ）で main に取り込み済みなので、技術的には削除して main から再生可能。ただし worktree 自体に何か検証メモ・未コミット作業が残っている可能性があるため、機械的に削除せず、ジェンナが各 worktree の `git status` を確認してから判断する。

---

## その他（独立した worktree）

### `claude/busy-bardeen-87607b`
- **path**: `.claude/worktrees/busy-bardeen-87607b`
- HEAD: `92bf6d9` (= 旧 main HEAD)
- 命名から自動生成された worktree と推測。**ジェンナに用途確認**してから判断
- 削除可否: 保留

### `claude/interesting-chaum-a48d33`
- **path**: `.claude/worktrees/interesting-chaum-a48d33`
- HEAD: `70a0b2c`（main / vault/phase-c の系譜にない sha）
- 何らかの独立した試行ブランチの可能性。**ジェンナに用途確認**してから判断
- 削除可否: 保留

### `claude/stats-mode-impl`
- **path**: `.claude/worktrees/stats-mode-impl`
- HEAD: `06ffcea` Align SPEC.md / AGENTS.md with Phase 2 Stats implementation
- Phase 2 Stats 実装の作業 worktree。Phase 系と類似の事情で保留
- 削除可否: 保留

### `design/parts`
- **path**: `.claude/worktrees/parts`
- HEAD: `92f14f6` Refine design mock navigation shell（vault/phase-c 系譜）
- デザインモック作業。**ジェンナに用途確認**してから判断
- 削除可否: 保留

### `vault/phase-c-importer-audit`（主 worktree）
- **path**: `/Users/ichijouhotaru/Projects/Madini Archive`（リポジトリのルート）
- HEAD: `3e9fc36` Phase 9 hotfix
- 主 worktree。`git status` 上で `docs/tasks/` の untracked と stash@{0} がある
- **削除しない**（リポジトリのルート worktree。チェックアウト先を切り替えるだけ可能）
- 主 worktree の checkout 先を main に切り替えたい場合: `git checkout main` を実行する前に stash と untracked の処理方針をジェンナと相談する

---

## 削除手順の標準形

### 単体削除
```sh
# 1. worktree を削除
git worktree remove .claude/worktrees/<path>

# 2. ブランチを削除（worktree 削除だけではブランチは残る）
git branch -D claude/<branch-name>
```

### 一括削除（"削除可" カテゴリの 4 つを処分する場合）
```sh
cd /Users/ichijouhotaru/Projects/Madini\ Archive

# Task 5 までマージ済みであることを確認
git log --oneline -3

# 削除可な worktree を順次削除
for entry in \
    "tender-heisenberg-06101d:claude/investigate-rendering-framework" \
    "investigate-importer-migration:claude/investigate-importer-migration" \
    "plan-thinking-preservation:claude/plan-thinking-preservation" \
    "tonight-integration:claude/phase-1-preparation"
do
    path="${entry%%:*}"
    branch="${entry##*:}"
    git worktree remove ".claude/worktrees/$path" 2>&1 || echo "  failed to remove worktree: $path"
    git branch -D "$branch" 2>&1 || echo "  failed to delete branch: $branch"
done
```

実行前に各 worktree の `git status` と `git stash list` を確認して、未コミット作業が残っていないことを確認する。

---

## 注意点

- worktree を削除しても、ブランチが他の worktree からも参照されている場合は削除に失敗する
- 削除した worktree は復旧できない（`.git/worktrees/` 配下のメタデータが消える）
- 主 worktree（リポジトリのルート）は `git worktree remove` できない。`git worktree list` で `*` 付きと判別できる
