#!/usr/bin/env bash
# monitor.sh — Task execution and supervision for acpx-butler
# Executes tasks (shell/agent/council), checks results, handles retry
# Compatible with Bash 3.2+ (no mapfile, no associative arrays)

set -euo pipefail

BUTLER_ROOT="${BUTLER_ROOT:-.butler}"
BUTLER_BOARD="${BUTLER_ROOT}/board"
BUTLER_LOGS="${BUTLER_ROOT}/logs"

ACPX_ROOT="${ACPX_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
source "${ACPX_ROOT}/lib/board.sh"

# ─── Color Output ──────────────────────────────────────────────

MON_RED='\033[0;31m'
MON_GREEN='\033[0;32m'
MON_YELLOW='\033[1;33m'
MON_BLUE='\033[0;34m'
MON_NC='\033[0m'

mon_info()  { echo -e "${MON_BLUE}[butler]${MON_NC} $*"; }
mon_ok()    { echo -e "${MON_GREEN}[ok]${MON_NC} $*"; }
mon_warn()  { echo -e "${MON_YELLOW}[warn]${MON_NC} $*"; }
mon_err()   { echo -e "${MON_RED}[error]${MON_NC} $*" >&2; }

# ─── Task Execution ─────────────────────────────────────────────

# Execute a single task by ID
# Returns 0 on success, 1 on failure
monitor_exec() {
  local id="${1:?Usage: monitor_exec <id>}"

  local task_file
  task_file=$(_find_task "$id") || { mon_err "Task ${id} not found"; return 1; }

  # Read task fields
  local title type priority command task_desc assign_to role
  title=$(_read_field "$task_file" "title")
  type=$(_read_field "$task_file" "type")
  priority=$(_read_field "$task_file" "priority")
  command=$(_read_field "$task_file" "command")
  task_desc=$(_read_field "$task_file" "task_desc")
  assign_to=$(_read_field "$task_file" "assign_to")
  role=$(_read_field "$task_file" "role")

  # For shell type, read command from the body section
  if [[ "$type" == "shell" && -z "$command" ]]; then
    command=$(sed -n '/^## Command$/,/^## /{ /^## /d; p; }' "$task_file" | head -20 | grep -v '^$' | head -1)
  fi

  # For agent type, read task from the body section
  if [[ "$type" == "agent" && -z "$task_desc" ]]; then
    task_desc=$(sed -n '/^## Task$/,/^## /{ /^## /d; p; }' "$task_file" | head -5 | grep -v '^$' | head -1)
  fi

  mon_info "Executing [${id}] ${title} (type: ${type})"

  # Move to active
  board_move "$id" "active" 2>/dev/null || true

  # Ensure log directory exists
  mkdir -p "$BUTLER_LOGS"
  local log_file="${BUTLER_LOGS}/${id}.log"

  local exit_code=0

  # Dispatch based on type
  case "$type" in
    shell)
      _monitor_exec_shell "$id" "$command" "$log_file" || exit_code=$?
      ;;
    agent)
      _monitor_exec_agent "$id" "$task_desc" "$assign_to" "$role" "$log_file" || exit_code=$?
      ;;
    council)
      _monitor_exec_council "$id" "$task_desc" "$role" "$log_file" || exit_code=$?
      ;;
    pipeline)
      _monitor_exec_pipeline "$id" "$task_desc" "$log_file" || exit_code=$?
      ;;
    *)
      mon_err "Unknown task type: ${type}"
      exit_code=1
      ;;
  esac

  # Check success
  local success=false
  if [[ "$exit_code" -eq 0 ]]; then
    if monitor_check "$id" "$log_file"; then
      success=true
    fi
  fi

  # Handle result
  if [[ "$success" == "true" ]]; then
    board_move "$id" "done"
    mon_ok "Task ${id} completed successfully"

    # Trigger on_success
    _monitor_trigger_hook "$id" "on_success"
  else
    # Handle retry
    local retry_count max_retries
    retry_count="0"
    max_retries="2"

    # Re-read in case file moved
    task_file=$(_find_task "$id" 2>/dev/null || echo "")
    if [[ -n "$task_file" ]]; then
      retry_count=$(_read_field "$task_file" "retry_count")
      max_retries=$(_read_field "$task_file" "max_retries")
    fi

    if [[ "$retry_count" -lt "$max_retries" ]]; then
      mon_warn "Task ${id} failed (attempt $((retry_count + 1))/${max_retries}), retrying..."
      board_retry "$id" 2>/dev/null || board_move "$id" "failed" 2>/dev/null || true
    else
      board_move "$id" "failed"
      mon_err "Task ${id} failed permanently after ${max_retries} attempts"
    fi

    # Trigger on_failure
    _monitor_trigger_hook "$id" "on_failure"
  fi

  # Unblock dependent tasks
  board_unblock 2>/dev/null || true

  return $([[ "$success" == "true" ]] && echo 0 || echo 1)
}

# ─── Execution Dispatchers ──────────────────────────────────────

_monitor_exec_shell() {
  local id="$1"
  local command="$2"
  local log_file="$3"

  if [[ -z "$command" ]]; then
    mon_err "No command specified for shell task ${id}"
    return 1
  fi

  # Security: basic command validation (no newlines — bash strings can't hold null bytes)
  if [[ "$command" == *$'\n'* ]]; then
    mon_err "Command contains invalid characters for task ${id}"
    return 1
  fi

  mon_info "Running: ${command}"
  local start_time
  start_time=$(date +%s)

  # Security: use mktemp for unpredictable temp file name
  local tmp_script
  tmp_script=$(mktemp "${BUTLER_ROOT}/tmp-script-${id}.XXXXXXXXXX.sh") || {
    mon_err "Failed to create temp script for task ${id}"
    return 1
  }

  printf '#!/bin/bash\n%s\n' "$command" > "$tmp_script"
  chmod +x "$tmp_script"

  # Execute with timeout (default 600s = 10 min)
  local timeout_secs="${BUTLER_TASK_TIMEOUT:-600}"
  local ec=0
  if command -v timeout &>/dev/null; then
    timeout "$timeout_secs" "$tmp_script" > "$log_file" 2>&1 || ec=$?
  else
    # macOS fallback — no timeout command available
    "$tmp_script" > "$log_file" 2>&1 || ec=$?
  fi

  # Clean up temp script (always run, even if timeout/interrupt)
  rm -f "$tmp_script"

  local end_time
  end_time=$(date +%s)
  local duration=$((end_time - start_time))

  {
    echo "---"
    echo "Exit code: ${ec}"
    echo "Duration: ${duration}s"
    echo "Finished: $(date -u +"%Y-%m-%dT%H:%M:%SZ")"
  } >> "$log_file"

  return $ec
}

_monitor_exec_agent() {
  local id="$1"
  local task_desc="$2"
  local assign_to="${3:-claude}"
  local role="${4:-}"
  local log_file="$5"

  if [[ -z "$task_desc" ]]; then
    mon_err "No task description for agent task ${id}"
    return 1
  fi

  local session="butler-${id}"
  local prompt="$task_desc"
  if [[ -n "$role" ]]; then
    prompt="[ROLE: ${role}]\n\n${task_desc}"
  fi

  mon_info "Dispatching to ${assign_to} (session: ${session})"

  # Create session if needed
  acpx "${assign_to}" sessions new --name "$session" 2>/dev/null || true

  # Execute via acpx
  local ec=0
  acpx --format quiet --timeout 600 "${assign_to}" -s "$session" "$prompt" > "$log_file" 2>&1 || ec=$?

  # Close session
  acpx "${assign_to}" sessions close "$session" 2>/dev/null || true

  return $ec
}

_monitor_exec_council() {
  local id="$1"
  local task_desc="$2"
  local roles="${3:-auto}"
  local log_file="$4"

  if [[ -z "$task_desc" ]]; then
    mon_err "No task description for council task ${id}"
    return 1
  fi

  mon_info "Running council protocol"

  # Source protocols and run role-council
  source "${ACPX_ROOT}/lib/protocols.sh"

  local ec=0
  protocol_role_council "$task_desc" "auto" "$roles" "claude" > "$log_file" 2>&1 || ec=$?

  # Copy synthesis to log
  if [[ -f ".acpx-workspace/synthesis.md" ]]; then
    cat ".acpx-workspace/synthesis.md" >> "$log_file"
  fi

  return $ec
}

_monitor_exec_pipeline() {
  local id="$1"
  local task_desc="$2"
  local log_file="$3"

  if [[ -z "$task_desc" ]]; then
    mon_err "No task description for pipeline task ${id}"
    return 1
  fi

  mon_info "Running pipeline protocol"

  source "${ACPX_ROOT}/lib/protocols.sh"

  local ec=0
  protocol_pipeline "$task_desc" "auto" "claude" > "$log_file" 2>&1 || ec=$?

  if [[ -f ".acpx-workspace/synthesis.md" ]]; then
    cat ".acpx-workspace/synthesis.md" >> "$log_file"
  fi

  return $ec
}

# ─── Success Checking ───────────────────────────────────────────

# Check if a task's success criteria are met
# Usage: monitor_check <id> <log_file>
monitor_check() {
  local id="${1:?Usage: monitor_check <id> <log_file>}"
  local log_file="${2:-${BUTLER_LOGS}/${id}.log}"

  local task_file
  task_file=$(_find_task "$id" 2>/dev/null) || return 0

  # Read success criteria from task body
  local criteria_section
  criteria_section=$(sed -n '/^## Success Criteria$/,/^## /{ /^## /d; p; }' "$task_file")

  [[ -z "$criteria_section" ]] && return 0  # No criteria = pass

  # Regex patterns stored in variables for Bash 3.2 compat
  local re_file_exists='file_exists\(([^)]+)\)'
  local re_file_contains='file_contains\(([^,]+),[[:space:]]*([^)]+)\)'

  # Check each criteria line
  while IFS= read -r line; do
    [[ -z "$line" ]] && continue

    # file_exists(path)
    if [[ "$line" =~ $re_file_exists ]]; then
      local path="${BASH_REMATCH[1]}"
      if [[ ! -f "$path" ]]; then
        mon_warn "Success criteria not met: file not found: ${path}"
        return 1
      fi
    fi

    # file_contains(path, pattern)
    if [[ "$line" =~ $re_file_contains ]]; then
      local path="${BASH_REMATCH[1]}"
      local pattern="${BASH_REMATCH[2]}"
      if ! grep -q "$pattern" "$path" 2>/dev/null; then
        mon_warn "Success criteria not met: ${path} does not contain '${pattern}'"
        return 1
      fi
    fi

    # exit_code checks handled by the execution result
  done <<< "$criteria_section"

  return 0
}

# ─── Hooks ──────────────────────────────────────────────────────

# Trigger on_success/on_failure hooks defined in task
_monitor_trigger_hook() {
  local id="$1"
  local hook_name="$2"  # on_success or on_failure

  local task_file
  task_file=$(_find_task "$id" 2>/dev/null) || return 0

  local hook_value
  hook_value=$(_read_field "$task_file" "$hook_name")
  [[ -z "$hook_value" ]] && return 0

  mon_info "Hook ${hook_name}: ${hook_value}"

  # If hook is a task ID, move it to inbox
  if [[ "$hook_value" =~ ^[0-9]+$ ]]; then
    local hook_task
    hook_task=$(_find_task "$hook_value" 2>/dev/null) || return 0
    board_move "$hook_value" "inbox" 2>/dev/null || true
  fi

  # If hook references a workflow, note it for the scheduler
  if [[ "$hook_value" =~ ^workflow: ]]; then
    local wf_name
    wf_name=$(echo "$hook_value" | sed 's/workflow://')
    echo "${wf_name}" >> "${BUTLER_ROOT}/pending-workflows.txt"
  fi
}

# ─── Main Loop ──────────────────────────────────────────────────

# Run the main execution loop: pick next task, execute, repeat
# Usage: monitor_loop [--limit N] [--dry-run]
monitor_loop() {
  [[ -d "$BUTLER_BOARD" ]] || { mon_err "Board not initialized"; return 1; }

  local limit=0 dry_run=false
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --limit)   limit="$2"; shift 2 ;;
      --dry-run) dry_run=true; shift ;;
      *) shift ;;
    esac
  done

  # First unblock any tasks whose deps are met
  board_unblock 2>/dev/null || true

  local executed=0 failed=0

  while true; do
    # Get next task
    local next_id
    next_id=$(board_next)

    [[ -z "$next_id" ]] && break

    if [[ "$dry_run" == "true" ]]; then
      mon_info "[dry-run] Would execute: ${next_id}"
      executed=$((executed + 1))
      # Move to done in dry-run for simulation
      board_move "$next_id" "done" > /dev/null 2>&1 || true
      board_unblock > /dev/null 2>&1 || true
      continue
    fi

    # Execute
    if monitor_exec "$next_id"; then
      executed=$((executed + 1))
    else
      failed=$((failed + 1))
    fi

    # Check limit
    if [[ "$limit" -gt 0 ]] && [[ $((executed + failed)) -ge "$limit" ]]; then
      mon_info "Reached limit of ${limit} tasks"
      break
    fi
  done

  mon_info "Loop complete: ${executed} succeeded, ${failed} failed"
  board_stats
}

# ─── Health Check ───────────────────────────────────────────────

# Check board health: stuck tasks, circular deps, timeouts
monitor_health() {
  [[ -d "$BUTLER_BOARD" ]] || { echo "Board not initialized."; return 1; }

  local issues=0

  # Check for stuck active tasks (running > 30 min)
  local active_dir="${BUTLER_BOARD}/active"
  if [[ -d "$active_dir" ]]; then
    while IFS= read -r f; do
      [[ -z "$f" ]] && continue
      local id
      id=$(_read_field "$f" "id")
      # Active tasks should not sit for too long
      local log_file="${BUTLER_LOGS}/${id}.log"
      if [[ -f "$log_file" ]]; then
        local log_age
        log_age=$(( $(date +%s) - $(stat -f %m "$log_file" 2>/dev/null || stat -c %Y "$log_file" 2>/dev/null || echo 0) ))
        if [[ "$log_age" -gt 1800 ]]; then
          mon_warn "Task ${id} may be stuck (active for >30 min)"
          issues=$((issues + 1))
        fi
      fi
    done < <(_list_md_files "$active_dir")
  fi

  # Check for blocked-by-failed tasks
  local blocked_dir="${BUTLER_BOARD}/blocked"
  if [[ -d "$blocked_dir" ]]; then
    while IFS= read -r f; do
      [[ -z "$f" ]] && continue
      local id
      id=$(_read_field "$f" "id")
      local blocked_by
      blocked_by=$(_read_array_field "$f" "blocked_by")
      while IFS= read -r dep_id; do
        [[ -z "$dep_id" ]] && continue
        local dep_file
        dep_file=$(_find_task "$dep_id" 2>/dev/null) || continue
        local dep_status
        dep_status=$(_status_from_path "$dep_file")
        if [[ "$dep_status" == "failed" ]]; then
          mon_warn "Task ${id} blocked by failed task ${dep_id} — will never unblock"
          issues=$((issues + 1))
        fi
      done <<< "$blocked_by"
    done < <(_list_md_files "$blocked_dir")
  fi

  # Check failed tasks count
  local failed_count=0
  failed_count=$(_count_md "${BUTLER_BOARD}/failed")
  if [[ "$failed_count" -gt 3 ]]; then
    mon_warn "${failed_count} failed tasks — investigate with: acpx-butler board list --status failed"
    issues=$((issues + 1))
  fi

  # Summary
  board_stats

  if [[ "$issues" -eq 0 ]]; then
    mon_ok "No issues detected"
  else
    mon_warn "${issues} issue(s) detected"
    return 1
  fi
}
