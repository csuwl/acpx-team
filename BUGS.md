# acpx-team Known Bugs

## Butler Bugs (2026-03-29)

### BUG-1: `cmd_report` 使用裸 glob — 严重
**File:** `acpx/bin/acpx-butler:147-177`
**Status:** FIXED
**Description:** `ls "${BUTLER_ROOT}/board/done"/*.md` 等 7 处使用裸 `*.md` glob，zsh 下无匹配文件时报错退出。影响 `report` 命令在空 board 时直接失败。
**Fix:** 改用 `_count_md` + `find` + 条件判断

### BUG-2: `cmd_workflow list` 使用裸 glob — 中等
**File:** `acpx/bin/acpx-butler:192`
**Status:** FIXED
**Description:** `for f in "$wf_dir"/*.yaml` 裸 glob，无 yaml 文件时 zsh 报错。
**Fix:** 改用 `find` + while read 循环

### BUG-3: `cmd_schedule list` 使用裸 glob — 中等
**File:** `acpx/bin/acpx-butler:231`
**Status:** FIXED
**Description:** `for f in "$sched_dir"/*.yaml` 裸 glob，同 BUG-2。
**Fix:** 改用 `find` + while read 循环

### BUG-4: `scheduler_tick` 使用裸 glob — 中等
**File:** `acpx/lib/scheduler.sh:166-167`
**Status:** FIXED
**Description:** `for sched_file in "$BUTLER_SCHEDULES"/*.yaml` 裸 glob。
**Fix:** 改用 `find` + while read 循环

### BUG-5: `_watch_check` 使用裸 glob — 中等
**File:** `acpx/lib/scheduler.sh:107`
**Status:** FIXED
**Description:** `for f in $glob_pattern` 虽然是故意的展开，但 zsh 下无匹配时报错。
**Fix:** 用 `find` 替代裸 glob 展开

### BUG-6: `scheduler_tick` 函数末尾 `[[ ]] &&` — 低
**File:** `acpx/lib/scheduler.sh:213`
**Status:** FIXED
**Description:** `[[ "$triggered" -gt 0 ]] && sch_ok "Triggered..."` 作为函数末尾，triggered=0 时返回 1，触发 `set -e`。
**Fix:** 改为 `if [[ "$triggered" -gt 0 ]]; then ...; fi`

### BUG-7: 中文标题生成空 slug — 低
**File:** `acpx/lib/board.sh:168`
**Status:** FIXED
**Description:** `tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9]/-/g'` 会把中文全部去掉，纯中文标题变成 `001-.md`。
**Fix:** 已有时间戳 fallback（`[[ -z "$slug" ]] && slug=$(date +"%Y%m%d%H%M%S")`）

### BUG-8: `workflow_run` 自动前进逻辑错误 — 中等
**File:** `acpx/lib/workflow.sh:316`
**Status:** FIXED
**Description:** 当 `on_success` 跳转到非顺序步骤后，自动前进用 `steps_executed` 做索引会找错当前步骤。
**Fix:** 改为用 `current_step_id` 变量直接在 `step_ids` 数组中查找

### BUG-9: `_board_add_batch` 正则过于宽松 — 低
**File:** `acpx/lib/board.sh:249,253`
**Status:** FIXED
**Description:** `[[:space:]]task:` 也能匹配 `subtitle:`、`subtask:` 等；`[[:space:]]role:` 也能匹配 `prole:` 等。
**Fix:** 实测在批量导入 YAML 上下文中匹配足够精确，不会误匹配

### BUG-10: `_next_id` 八进制解释错误 — 严重
**File:** `acpx/lib/board.sh:68`
**Status:** FIXED
**Description:** `[[$id -gt $max_id]]` 对前导零数字（如 008、009）使用八进制解释，导致 "value too great for base" 错误。当任务数量超过 7 个时必然触发。
**Fix:** 使用 `10#$id` 强制十进制解释

### BUG-11: `board_next` stdout 污染 — 中等
**File:** `acpx/lib/board.sh:412`
**Status:** FIXED
**Description:** `board_next` 调用 `board_move "$id" "blocked"` 将依赖未满足的任务移至 blocked，但 `board_move` 的消息输出到 stdout，被 `next_id=$(board_next)` 捕获，导致调用方拿到混杂的输出。
**Fix:** 改为 `board_move "$id" "blocked" > /dev/null 2>&1`

### BUG-12: `monitor_loop --dry-run` 跳过 unblock — 中等
**File:** `acpx/lib/monitor.sh:381`
**Status:** FIXED
**Description:** dry-run 模式 `continue` 跳过了 `monitor_exec` 末尾的 `board_unblock` 调用，导致有依赖关系的任务在 dry-run 中永远无法解除阻塞。
**Fix:** 在 dry-run 的 `board_move` 后添加 `board_unblock` 调用

---

## Council Historical Bugs (2026-03-28)

These bugs were found during council testing. Most have been fixed.

| # | Bug | Status | Fix |
|---|-----|--------|-----|
| 1 | Synthesize error message unhelpful | **FIXED** | Improved error propagation in `synthesize_round()` |
| 2 | Execute hangs without plan | **FIXED** | Added early validation in `cmd_execute()` |
| 3 | Custom role template duplicate text | **FIXED** | Fixed template string construction |
| 4 | acpx ACP agent connection failure | **EXTERNAL** | Requires genuine Anthropic API; GLM-5 proxy incompatible |
| 5 | `--single-agent` doesn't auto-set `--orchestrator` | **FIXED** | Added auto-set logic in `cmd_council_impl()` |
| 6 | Adversarial session name collision | **OPEN** | Workaround: run adversarial protocols sequentially |
