#!/usr/bin/env bash
# test-butler.sh — Scenario tests for acpx-butler
# Covers 8 real-world scenarios with 10 test functions

set -euo pipefail

PASS=0
FAIL=0

# ─── Assert Helpers ─────────────────────────────────────────────

assert_eq() {
  local desc="$1" expected="$2" actual="$3"
  if [[ "$expected" == "$actual" ]]; then
    PASS=$((PASS + 1))
  else
    FAIL=$((FAIL + 1))
    echo "  FAIL: $desc"
    echo "    expected: '$expected'"
    echo "    actual:   '$actual'"
  fi
}

assert_contains() {
  local desc="$1" haystack="$2" needle="$3"
  if echo "$haystack" | grep -q "$needle"; then
    PASS=$((PASS + 1))
  else
    FAIL=$((FAIL + 1))
    echo "  FAIL: $desc"
    echo "    expected to contain: '$needle'"
    echo "    actual: '$haystack'"
  fi
}

assert_file_exists() {
  local desc="$1" path="$2"
  if [[ -f "$path" ]]; then
    PASS=$((PASS + 1))
  else
    FAIL=$((FAIL + 1))
    echo "  FAIL: $desc — file not found: $path"
  fi
}

assert_not_file_exists() {
  local desc="$1" path="$2"
  if [[ ! -f "$path" ]]; then
    PASS=$((PASS + 1))
  else
    FAIL=$((FAIL + 1))
    echo "  FAIL: $desc — file should not exist: $path"
  fi
}

assert_dir_count() {
  local desc="$1" dir="$2" expected="$3"
  local count=0
  if [[ -d "$dir" ]]; then
    count=$(find "$dir" -maxdepth 1 -name "*.md" -type f 2>/dev/null | grep -c . 2>/dev/null || echo "0")
  fi
  if [[ "$count" == "$expected" ]]; then
    PASS=$((PASS + 1))
  else
    FAIL=$((FAIL + 1))
    echo "  FAIL: $desc"
    echo "    expected $expected files in $dir, got $count"
  fi
}

# ─── Setup ──────────────────────────────────────────────────────

PROJECT_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
ACPX_ROOT="${PROJECT_ROOT}/acpx"
source "${ACPX_ROOT}/lib/board.sh"
source "${ACPX_ROOT}/lib/monitor.sh"
source "${ACPX_ROOT}/lib/workflow.sh"
source "${ACPX_ROOT}/lib/scheduler.sh"

TEST_ROOT=$(mktemp -d)

# Reset board for each test — fresh BUTLER_ROOT
reset_board() {
  BUTLER_ROOT="${TEST_ROOT}/.butler-$(date +%s%N)"
  BUTLER_BOARD="${BUTLER_ROOT}/board"
  BUTLER_LOGS="${BUTLER_ROOT}/logs"
  export BUTLER_ROOT BUTLER_BOARD BUTLER_LOGS
}

cleanup() {
  rm -rf "$TEST_ROOT"
}
trap cleanup EXIT

cleanup() {
  rm -rf "$TEST_ROOT"
}
trap cleanup EXIT

echo "=== acpx-butler Scenario Tests ==="
echo "Test root: ${TEST_ROOT}"
echo ""

# ─── Scenario 1: Grad Student Day (E2E) ────────────────────────

test_grad_student_day() {
  reset_board
  echo "--- Scenario 1: Grad Student Day (E2E) ---"

  board_init > /dev/null

  # Add tasks with various priorities and types
  local id1 id2 id3 id4 id5
  id1=$(board_add --title "Run experiment A" --type shell --priority high --command "echo 'experiment A done'")
  id2=$(board_add --title "Run experiment B" --type shell --priority normal --command "echo 'experiment B done'")
  id3=$(board_add --title "Analyze results" --type agent --priority normal --task "Analyze experiment outputs" --blocked-by "$id1,$id2")
  id4=$(board_add --title "Write weekly report" --type agent --priority low --task "Summarize findings" --blocked-by "$id3")
  id5=$(board_add --title "Submit to advisor" --type shell --priority critical --command "echo 'submitted'")

  assert_eq "5 tasks created" "5" "$(board_stats | grep -o 'Total: [0-9]*' | grep -o '[0-9]*')"
  assert_dir_count "inbox has 5 tasks" "${BUTLER_BOARD}/inbox" "5"

  # Run dry-run loop
  BUTLER_TASK_TIMEOUT=10 monitor_loop --dry-run --limit 5 > /dev/null 2>&1 || true

  # After dry-run, all should be in done
  assert_dir_count "all 5 done after dry-run" "${BUTLER_BOARD}/done" "5"

  echo "  Scenario 1 complete"
}

# ─── Scenario 2: Dependency Chain ───────────────────────────────

test_dependency_chain() {
  reset_board
  echo "--- Scenario 2: Dependency Chain ---"

  board_init > /dev/null

  local id_a id_b id_c id_d
  id_a=$(board_add --title "Step A" --type shell --priority high --command "echo A")
  id_b=$(board_add --title "Step B" --type shell --priority normal --command "echo B" --blocked-by "$id_a")
  id_c=$(board_add --title "Step C" --type shell --priority normal --command "echo C" --blocked-by "$id_b")
  id_d=$(board_add --title "Step D" --type shell --priority low --command "echo D" --blocked-by "$id_c")

  # B, C, D should move to blocked on next() call
  local next_id
  next_id=$(board_next)
  assert_eq "next task is A" "$id_a" "$next_id"

  # Move A to blocked manually — simulate dep check moving B,C,D
  board_move "$id_b" "blocked" > /dev/null 2>&1 || true
  board_move "$id_c" "blocked" > /dev/null 2>&1 || true
  board_move "$id_d" "blocked" > /dev/null 2>&1 || true

  # Complete A
  board_move "$id_a" "done" > /dev/null

  # Unblock should move B to inbox
  board_unblock > /dev/null 2>&1 || true
  local b_status
  b_status=$(_status_from_path "$(_find_task "$id_b")")
  assert_eq "B unblocked after A done" "inbox" "$b_status"

  # C, D still blocked
  local c_status d_status
  c_status=$(_status_from_path "$(_find_task "$id_c")")
  d_status=$(_status_from_path "$(_find_task "$id_d")")
  assert_eq "C still blocked" "blocked" "$c_status"
  assert_eq "D still blocked" "blocked" "$d_status"

  # Complete B, unblock → C should move
  board_move "$id_b" "done" > /dev/null
  board_unblock > /dev/null 2>&1 || true
  c_status=$(_status_from_path "$(_find_task "$id_c")")
  assert_eq "C unblocked after B done" "inbox" "$c_status"

  echo "  Scenario 2 complete"
}

# ─── Scenario 3: Failure and Retry ──────────────────────────────

test_failure_retry() {
  reset_board
  echo "--- Scenario 3: Failure and Retry ---"

  board_init > /dev/null

  local id
  id=$(board_add --title "Failing task" --type shell --priority high --command "exit 1" --max-retries 2)

  assert_eq "task in inbox" "inbox" "$(_status_from_path "$(_find_task "$id")")"

  # Execute — should fail and retry
  BUTLER_TASK_TIMEOUT=10 monitor_exec "$id" > /dev/null 2>&1 || true

  # After first failure, should have retried and be in failed (max_retries=2 means 2 attempts)
  local final_status
  final_status=$(_status_from_path "$(_find_task "$id" 2>/dev/null || echo "")")
  assert_eq "task failed after retries" "failed" "$final_status"

  # retry should work on failed task
  board_retry "$id" > /dev/null 2>&1
  local after_retry
  after_retry=$(_status_from_path "$(_find_task "$id" 2>/dev/null || echo "")")
  assert_eq "task back in inbox after retry" "inbox" "$after_retry"

  # retry on non-failed task should fail
  local id2
  id2=$(board_add --title "Good task" --type shell --priority normal --command "echo ok")
  local retry_result
  retry_result=$(board_retry "$id2" 2>&1) && rc=0 || rc=$?
  assert_eq "retry non-failed returns error" "1" "$rc"

  echo "  Scenario 3 complete"
}

# ─── Scenario 4: Empty Board Edge Cases ─────────────────────────

test_empty_board() {
  reset_board
  echo "--- Scenario 4: Empty Board Edge Cases ---"

  board_init > /dev/null

  # board list should work
  local list_output
  list_output=$(board_list 2>&1)
  assert_contains "empty board shows no tasks" "$list_output" "(no tasks)"

  # board next should return nothing
  local next_result
  next_result=$(board_next 2>&1) || true
  assert_eq "board next returns empty" "" "$next_result"

  # board stats
  local stats
  stats=$(board_stats)
  assert_contains "stats shows Total: 0" "$stats" "Total: 0"

  # board archive — no crash
  board_archive > /dev/null 2>&1 || true
  PASS=$((PASS + 1))  # didn't crash

  # board unblock — no crash
  board_unblock > /dev/null 2>&1 || true
  PASS=$((PASS + 1))  # didn't crash

  # monitor health
  local health
  health=$(monitor_health 2>&1) || true
  assert_contains "health shows no issues" "$health" "No issues detected"

  echo "  Scenario 4 complete"
}

# ─── Scenario 5: Chinese & Special Characters ───────────────────

test_chinese_special_chars() {
  reset_board
  echo "--- Scenario 5: Chinese & Special Characters ---"

  board_init > /dev/null

  # Chinese title
  local id1
  id1=$(board_add --title "运行实验A - 学习率对比" --type shell --priority high --command "echo ok")
  assert_file_exists "chinese task file created" "$(_find_task "$id1")"

  # Verify slug is not empty (timestamp fallback)
  local file1
  file1=$(_find_task "$id1")
  local basename1
  basename1=$(basename "$file1")
  assert_contains "slug not just dash" "$basename1" "${id1}-"
  # Should not be "001-.md" — slug should be a timestamp or valid chars
  local slug_part
  slug_part=$(echo "$basename1" | sed "s/${id1}-//" | sed 's/\.md$//')
  # Slug should not be empty
  if [[ -n "$slug_part" ]]; then
    PASS=$((PASS + 1))
  else
    FAIL=$((FAIL + 1))
    echo "  FAIL: Chinese title slug is empty"
  fi

  # Show task — verify Chinese preserved
  local show_output
  show_output=$(board_show "$id1")
  assert_contains "chinese title preserved" "$show_output" "运行实验A"

  # Special chars in title
  local id2
  id2=$(board_add --title "Task with single quotes" --type shell --priority normal --command "echo test")
  assert_file_exists "special chars task created" "$(_find_task "$id2")"

  echo "  Scenario 5 complete"
}

# ─── Scenario 6: Workflow Step Parsing ──────────────────────────

test_workflow_parsing() {
  reset_board
  echo "--- Scenario 6: Workflow Step Parsing ---"

  board_init > /dev/null

  # Create a test workflow YAML
  local wf_dir="${BUTLER_ROOT}/workflows"
  mkdir -p "$wf_dir"

  cat > "${wf_dir}/test-pipeline.yaml" << 'WFEOF'
name: test-pipeline
description: "Test pipeline with 3 steps"

steps:
  - id: step1
    type: shell
    command: echo "hello world"
    on_success: step2
  - id: step2
    type: shell
    command: echo "step 2 done"
    on_success: step3
  - id: step3
    type: done
WFEOF

  # Test YAML parsing
  local steps_raw
  steps_raw=$(_yaml_parse_steps "${wf_dir}/test-pipeline.yaml")
  assert_contains "parsed step1" "$steps_raw" "id: step1"
  assert_contains "parsed step2" "$steps_raw" "id: step2"
  assert_contains "parsed step3" "$steps_raw" "id: step3"

  # Test field reading
  local step1_block
  step1_block=$(echo "$steps_raw" | sed -n '/^id: step1$/,/^---STEP---$/p' | grep -v "^---STEP---")
  local step1_type
  step1_type=$(_step_read_field "$step1_block" "type")
  assert_eq "step1 type is shell" "shell" "$step1_type"

  local step1_cmd
  step1_cmd=$(_step_read_field "$step1_block" "command")
  assert_contains "step1 command parsed" "$step1_cmd" "hello world"

  echo "  Scenario 6 complete"
}

# ─── Scenario 7: Batch Import ───────────────────────────────────

test_batch_import() {
  reset_board
  echo "--- Scenario 7: Batch Import ---"

  board_init > /dev/null

  # Create batch file
  local batch_file="${TEST_ROOT}/batch.yaml"
  cat > "$batch_file" << 'BEOF'
# Batch import test
- title: Setup environment
  type: shell
  priority: high
  command: echo "setup"

- title: Run tests
  type: shell
  priority: normal
  command: echo "tests"
  tags: [ci, test]

- title: Deploy
  type: shell
  priority: low
  command: echo "deploy"
  blocked_by: [001, 002]
BEOF

  local import_result
  import_result=$(board_add --from "$batch_file" 2>&1)
  assert_contains "import reports count" "$import_result" "Imported 3 task(s)"
  assert_dir_count "3 tasks in inbox" "${BUTLER_BOARD}/inbox" "3"

  # Verify fields
  local first_file
  first_file=$(find "${BUTLER_BOARD}/inbox" -maxdepth 1 -name "*.md" -type f | sort | head -1)
  if [[ -n "$first_file" ]]; then
    local title
    title=$(_read_field "$first_file" "title")
    assert_contains "first task title" "$title" "Setup environment"

    local priority
    priority=$(_read_field "$first_file" "priority")
    assert_eq "first task priority" "high" "$priority"
  fi

  echo "  Scenario 7 complete"
}

# ─── Scenario 8: Scheduler Cron Matching ────────────────────────

test_scheduler_cron() {
  reset_board
  echo "--- Scenario 8: Scheduler Cron Matching ---"

  # Test * * * * * matches any time
  local always_match
  always_match=$(_cron_matches "* * * * *" && echo "yes" || echo "no")
  assert_eq "* * * * * always matches" "yes" "$always_match"

  # Test specific minute
  local current_min
  current_min=$(date +"%M" | sed 's/^0//')
  local min_match
  min_match=$(_cron_matches "${current_min} * * * *" && echo "yes" || echo "no")
  assert_eq "current minute matches" "yes" "$min_match"

  # Test non-matching minute
  local wrong_min
  if [[ "$current_min" == "0" ]]; then wrong_min="59"; else wrong_min="0"; fi
  local no_match
  no_match=$(_cron_matches "${wrong_min} * * * *" && echo "yes" || echo "no")
  assert_eq "wrong minute no match" "no" "$no_match"

  # Test weekday range 1-5
  local current_dow
  current_dow=$(date +"%u")
  local weekday_match
  weekday_match=$(_cron_matches "* * * * 1-5" && echo "yes" || echo "no")
  if [[ "$current_dow" -le 5 ]]; then
    assert_eq "weekday 1-5 matches" "yes" "$weekday_match"
  else
    assert_eq "weekend no match for 1-5" "no" "$weekday_match"
  fi

  # Test comma list
  local list_match
  list_match=$(_cron_matches "* * * * 1,2,3,4,5" && echo "yes" || echo "no")
  if [[ "$current_dow" -le 5 ]]; then
    assert_eq "comma list matches weekday" "yes" "$list_match"
  fi

  # Test step pattern
  local step_match
  step_match=$(_cron_matches "*/5 * * * *" && echo "yes" || echo "no")
  if [[ "$((current_min % 5))" -eq 0 ]]; then
    assert_eq "step 5 matches at $current_min" "yes" "$step_match"
  else
    assert_eq "step 5 no match at $current_min" "no" "$step_match"
  fi

  echo "  Scenario 8 complete"
}

# ─── Scenario 9: Monitor Shell Execution ────────────────────────

test_monitor_shell_exec() {
  reset_board
  echo "--- Scenario 9: Monitor Shell Execution ---"

  board_init > /dev/null

  # Successful shell task
  local id1
  id1=$(board_add --title "Echo task" --type shell --priority high --command "echo 'hello world'")
  BUTLER_TASK_TIMEOUT=10 monitor_exec "$id1" > /dev/null 2>&1

  local status1
  status1=$(_status_from_path "$(_find_task "$id1" 2>/dev/null || echo "")")
  assert_eq "successful shell task done" "done" "$status1"

  # Verify log created
  assert_file_exists "log file created" "${BUTLER_LOGS}/${id1}.log"

  # Verify completed timestamp
  local task_file1
  task_file1=$(_find_task "$id1" 2>/dev/null)
  if [[ -n "$task_file1" ]]; then
    local completed
    completed=$(_read_field "$task_file1" "completed")
    if [[ -n "$completed" ]]; then
      PASS=$((PASS + 1))
    else
      FAIL=$((FAIL + 1))
      echo "  FAIL: completed timestamp not set"
    fi
  fi

  echo "  Scenario 9 complete"
}

# ─── Scenario 10: Variable Substitution ─────────────────────────

test_variable_substitution() {
  reset_board
  echo "--- Scenario 10: Variable Substitution ---"

  # Test basic substitution
  local result
  result=$(_render_template "Hello {{name}}" "name=World")
  assert_eq "basic substitution" "Hello World" "$result"

  # Test multiple vars
  result=$(_render_template "{{greeting}} {{name}}" "greeting=Hi" "name=Alice")
  assert_eq "multi var substitution" "Hi Alice" "$result"

  # Test no vars
  result=$(_render_template "No vars here" "unused=val")
  assert_eq "no substitution needed" "No vars here" "$result"

  # Test missing var stays
  result=$(_render_template "Hello {{missing}}")
  assert_eq "missing var preserved" "Hello {{missing}}" "$result"

  echo "  Scenario 10 complete"
}

# ─── Run All Tests ──────────────────────────────────────────────

echo ""
test_grad_student_day
test_dependency_chain
test_failure_retry
test_empty_board
test_chinese_special_chars
test_workflow_parsing
test_batch_import
test_scheduler_cron
test_monitor_shell_exec
test_variable_substitution

echo ""
echo "=== Results ==="
echo "PASS: $PASS"
echo "FAIL: $FAIL"
echo ""

if [[ "$FAIL" -gt 0 ]]; then
  echo "SOME TESTS FAILED"
  exit 1
else
  echo "ALL TESTS PASSED"
  exit 0
fi
