# Active Worktrees — 整理メモ

**最終更新: 2026-05-01**

`.claude/worktrees/` 配下に存在する worktree を列挙し、目的・現状・削除可否を明示する。
オーナーが「これ消して大丈夫？」を判断するための材料。

---

## 削除可（thinking-preservation 関連で役目を終えたもの）

`docs/plans/thinking-preservation-2026-04-30.md` の Phase 1〜6 が完了した結果、これらの調査・設計用 worktree は不要になった。すべてのレポート・成果物は main の `docs/` 配下に保存済み、コード変更も main にマージ済み。

### `claude/investigate-rendering-framework`
- **path**: `.claude/worktrees/tender-heisenberg-06101d`
- **目的**: monologue 折りたたみ判定ロジック調査 + ソース×モデル別レンダリングフレームワーク設計
- **成果物**: `docs/investigations/rendering-framework-2026-04-30.md`（main 保存済み）
- **削除可否**: ✅ 削除可
- **削除コマンド**:
  ```sh
  git worktree remove .claude/worktrees/tender-heisenberg-06101d
  git branch -D claude/investigate-rendering-framework
  ```

### `claude/investigate-importer-migration`
- **path**: `.claude/worktrees/investigate-importer-migration`
- **目的**: Python importer → Swift importer 移行の作業量見積もり
- **成果物**: `docs/investigations/importer-migration-2026-04-30.md`（main 保存済み、結論: 戦略 C = Python core 維持を採用）
- **削除可否**: ✅ 削除可
- **削除コマンド**:
  ```sh
  git worktree remove .claude/worktrees/investigate-importer-migration
  git branch -D claude/investigate-importer-migration
  ```

### `claude/plan-thinking-preservation`
- **path**: `.claude/worktrees/plan-thinking-preservation`
- **目的**: thinking 保存対応プロジェクトの詳細実装計画
- **成果物**: `docs/plans/thinking-preservation-2026-04-30.md`（main 保存済み、Phase 1〜6 全実装完了）
- **削除可否**: ✅ 削除可
- **削除コマンド**:
  ```sh
  git worktree remove .claude/worktrees/plan-thinking-preservation
  git branch -D claude/plan-thinking-preservation
  ```

---

## 削除可（実装ベースの一時 worktree）

### `claude/mark-thinking-preservation-complete`（このブランチ自体）
- **path**: `.claude/worktrees/tonight-integration`
- **目的**: 4/30 夜〜5/1 朝の thinking-preservation 一連実装の作業ベース
- **現状**: 全 Phase の Swift 側実装と doc 更新が main にマージ済み
- **削除可否**: ✅ 本 doc commit + main マージ後に削除可
- **削除コマンド**: main マージ完了後、
  ```sh
  git worktree remove .claude/worktrees/tonight-integration
  git branch -D claude/mark-thinking-preservation-complete
  ```

#### この worktree から派生して main にマージ済みのサブブランチ

ローカル branch ガベージコレクション対象（worktree は持たない）:

```
claude/save-investigation-reports
claude/phase-0-merge-vault-phase-c
claude/bug-a-listitem-exclusion              ← Phase 6 で deprecated 化
claude/bug-a-formula-text-exclusion           ← 同上
claude/bug-b-user-message-primary-language    ← 同上
claude/bug-b-user-message-primary-language-v2 ← 同上
claude/bug-b-user-message-primary-language-v3 ← 同上
claude/skip-fold-on-short-runs                ← 同上
claude/body-text-size-control
claude/phase-1-preparation
claude/readable-text-layout
claude/phase-3-swift-content-json-read
claude/phase-4-structural-thinking-render
claude/phase-4-thinking-duplicate-fix
claude/phase-6-deprecate-language-fold
claude/mark-thinking-preservation-complete
```

一括削除:
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
         claude/phase-1-preparation \
         claude/readable-text-layout \
         claude/phase-3-swift-content-json-read \
         claude/phase-4-structural-thinking-render \
         claude/phase-4-thinking-duplicate-fix \
         claude/phase-6-deprecate-language-fold \
         claude/mark-thinking-preservation-complete
do
    git branch -D "$b" 2>/dev/null || true
done
```

---

## 判断保留（オーナーの実機状態に関わる worktree）

vault/phase-c-importer-audit ブランチの累積 phase 系。Phase 0 で main に取り込み済みなので技術的には main から再生可能だが、各 worktree に検証メモや未コミット作業が残っている可能性がある。**機械的に削除せず、オーナーが各 worktree の `git status` を確認してから判断**する。

| ブランチ | path | HEAD | 由来 |
|---------|------|------|------|
| `claude/phase4-sidebar` | `.claude/worktrees/phase4-sidebar` | `827157c` | Phase 4: Sidebar restructure |
| `claude/phase5-stats-detail` | `.claude/worktrees/phase5-stats-detail` | `69c87af` | Phase 5 gamma: Stats chart selection |
| `claude/phase5-stats-drilldown` | `.claude/worktrees/phase5-stats-drilldown` | `03e6397` | Merge Phase 4 |
| `claude/phase5.1-dashboard-lock` | `.claude/worktrees/phase5.1-dashboard-lock` | `9070441` | Merge Phase 5 gamma |
| `claude/phase5.2-passive-source-rows` | `.claude/worktrees/phase5.2-passive-source-rows` | `08929ba` | Phase 5.2 |
| `claude/phase6-stats-mode-redefine` | `.claude/worktrees/phase6-stats-mode-redefine` | `08929ba` | Phase 5.2（同 sha） |
| `claude/phase7-stats-user-prompt-filter` | `.claude/worktrees/phase7-stats-user-prompt-filter` | `277feba` | Phase 6+7 |
| `claude/phase8-dashboard-sidebar-filter` | `.claude/worktrees/phase8-dashboard-sidebar-filter` | `656d518` | Phase 8 |
| `claude/phase9-foreign-language-grouping-prefix-trap-fix` | `.claude/worktrees/phase9-foreign-language-grouping-prefix-trap-fix` | `3e9fc36` | Phase 9 hotfix（vault/phase-c の最終 commit） |

これらは UI 関連の旧 phase 群で、本サマリーが対象とする **thinking-preservation プロジェクトとは別系統**。後者は完了したが、これらは独立に整理する案件。

---

## その他（独立した worktree）

### `claude/busy-bardeen-87607b`
- **path**: `.claude/worktrees/busy-bardeen-87607b`
- **HEAD**: `92bf6d9`（旧 main HEAD、Phase 0 マージ前）
- 命名から自動生成された worktree と推測。**オーナーに用途確認**してから判断
- 削除可否: 保留

### `claude/interesting-chaum-a48d33`
- **path**: `.claude/worktrees/interesting-chaum-a48d33`
- **HEAD**: `70a0b2c`（main / vault/phase-c のいずれの系譜にもない sha）
- 何らかの独立した試行ブランチの可能性。**オーナーに用途確認**してから判断
- 削除可否: 保留

### `claude/stats-mode-impl`
- **path**: `.claude/worktrees/stats-mode-impl`
- **HEAD**: `06ffcea` Align SPEC.md / AGENTS.md with Phase 2 Stats implementation
- Phase 2 Stats 実装の作業 worktree。Phase 系と類似の事情で保留
- 削除可否: 保留

### `design/parts`
- **path**: `.claude/worktrees/parts`
- **HEAD**: `92f14f6` Refine design mock navigation shell（vault/phase-c 系譜）
- デザインモック作業。**オーナーに用途確認**してから判断
- 削除可否: 保留

### `vault/phase-c-importer-audit`(主 worktree)
- **path**: `~/Projects/Madini Archive`(リポジトリのルート)
- **HEAD**: `3e9fc36` Phase 9 hotfix
- 主 worktree。`git status` 上で `docs/tasks/` 等の untracked と stash@{0} がある可能性
- **削除しない**(リポジトリのルート worktree)
- **注意**: thinking-preservation 一連の Swift commit は main ブランチに 159 個積まれているが、主 worktree は依然として `vault/phase-c-importer-audit` ブランチを指している。`git checkout main` する場合は untracked / stash の処理を先に行う必要あり
- 主 worktree のブランチを main に切り替えたい場合の手順:
  ```sh
  cd "~/Projects/Madini Archive"
  git status                    # untracked と stash を確認
  git stash list                # 残ってる stash を確認
  # 必要なものを処理してから:
  git checkout main
  ```

---

## origin への push 状況（2026-05-01）

| repo | 状態 |
|------|------|
| Madini Archive (Swift) | 159 commits ahead of origin/main、未 push |
| Madini_Dev (Python) | Phase 1+2+2b は `claude/phase-1-python-schema-migration` branch、Phase 5 は `claude/phase-5-backfill-content-json` branch、いずれも main 未マージ・未 push |

オーナーの判断で push 実施。Python 側は2ブランチを順次 main へマージしてから push する必要あり。

---

## 削除手順の標準形

### 単体削除
```sh
# 1. worktree を削除
git worktree remove .claude/worktrees/<path>

# 2. ブランチを削除（worktree 削除だけではブランチは残る）
git branch -D claude/<branch-name>
```

### 一括削除（"削除可" カテゴリ全部を処分する場合）
```sh
cd ~/Projects/Madini\ Archive

# 削除前に main にマージ済みであることを確認
git log --oneline -5

# 削除可な worktree を順次削除
for entry in \
    "tender-heisenberg-06101d:claude/investigate-rendering-framework" \
    "investigate-importer-migration:claude/investigate-importer-migration" \
    "plan-thinking-preservation:claude/plan-thinking-preservation" \
    "tonight-integration:claude/mark-thinking-preservation-complete"
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
