#!/usr/bin/env bash
# scheduler.sh — Cron and event-based triggers for acpx-butler
# Checks schedule YAML files and triggers workflows when due
# Compatible with Bash 3.2+ (no mapfile, no associative arrays)

set -euo pipefail

BUTLER_ROOT="${BUTLER_ROOT:-.butler}"
BUTLER_SCHEDULES="${BUTLER_ROOT}/schedules"

ACPX_ROOT="${ACPX_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
source "${ACPX_ROOT}/lib/board.sh"

# ─── Color Output ──────────────────────────────────────────────

SCH_BLUE='\033[0;34m'
SCH_GREEN='\033[0;32m'
SCH_YELLOW='\033[1;33m'
SCH_NC='\033[0m'

sch_info() { echo -e "${SCH_BLUE}[scheduler]${SCH_NC} $*"; }
sch_ok()   { echo -e "${SCH_GREEN}[ok]${SCH_NC} $*"; }
sch_warn() { echo -e "${SCH_YELLOW}[warn]${SCH_NC} $*"; }

# ─── Cron Matching ─────────────────────────────────────────────

# Check if current time matches a cron expression
# Supports: minute hour day-of-month month day-of-week
# Usage: _cron_matches "0 9 * * 1-5"
_cron_matches() {
  local cron_expr="${1:?Usage: _cron_matches <cron>}"
  local now_min now_hour now_dom now_month now_dow
  now_min=$(date +"%M" | sed 's/^0//')
  now_hour=$(date +"%H" | sed 's/^0//')
  now_dom=$(date +"%d" | sed 's/^0//')
  now_month=$(date +"%m" | sed 's/^0//')
  now_dow=$(date +"%u")  # 1=Mon..7=Sun

  # Split cron into 5 fields
  local cron_min cron_hour cron_dom cron_month cron_dow
  read -r cron_min cron_hour cron_dom cron_month cron_dow <<< "$cron_expr"

  _cron_field_matches "$cron_min" "$now_min" && \
  _cron_field_matches "$cron_hour" "$now_hour" && \
  _cron_field_matches "$cron_dom" "$now_dom" && \
  _cron_field_matches "$cron_month" "$now_month" && \
  _cron_field_matches "$cron_dow" "$now_dow"
}

# Check if a value matches a single cron field
# Supports: *, specific values, ranges (1-5), lists (1,3,5), steps (*/5)
_cron_field_matches() {
  local pattern="${1:?Usage: _cron_field_matches <pattern> <value>}"
  local value="${2:?missing value}"

  # * matches everything
  [[ "$pattern" == "*" ]] && return 0

  # Handle comma-separated list (e.g., 1,3,5)
  if [[ "$pattern" == *,* ]]; then
    local IFS=','
    for part in $pattern; do
      if _cron_field_matches "$part" "$value"; then
        return 0
      fi
    done
    return 1
  fi

  # Handle range (e.g., 1-5)
  if [[ "$pattern" == *-* ]]; then
    local start="${pattern%-*}"
    local end="${pattern#*-}"
    [[ "$value" -ge "$start" && "$value" -le "$end" ]]
    return
  fi

  # Handle step (e.g., */5)
  if [[ "$pattern" == */* ]]; then
    local step="${pattern#*/}"
    [[ "$((value % step))" -eq 0 ]]
    return
  fi

  # Exact match
  [[ "$pattern" -eq "$value" ]] 2>/dev/null && return 0
  return 1
}

# ─── File Watch ────────────────────────────────────────────────

# Check if files matching a glob have been created/modified since last check
# Uses .butler/watch-state/<hash> to track last seen mtime
_watch_check() {
  local glob_pattern="$1"
  local event_type="${2:-create}"  # create | modify
  local watch_state_dir="${BUTLER_ROOT}/watch-state"
  mkdir -p "$watch_state_dir"

  # Create a safe filename from the glob pattern
  local state_hash
  state_hash=$(echo "$glob_pattern" | md5 2>/dev/null | head -8 || echo "$glob_pattern" | cksum | awk '{print $1}')
  local state_file="${watch_state_dir}/${state_hash}.txt"

  # Get current file list and mtimes (use find to avoid zsh nomatch)
  local current_state=""
  local glob_dir glob_base
  glob_dir=$(dirname "$glob_pattern")
  glob_base=$(basename "$glob_pattern")
  while IFS= read -r f; do
    [[ -z "$f" ]] && continue
    local mtime
    mtime=$(stat -f %m "$f" 2>/dev/null || stat -c %Y "$f" 2>/dev/null || echo "0")
    current_state="${current_state}${mtime} ${f}"$'\n'
  done < <(command find "$glob_dir" -maxdepth 1 -name "$glob_base" -type f 2>/dev/null || true)

  # First run — just save state
  if [[ ! -f "$state_file" ]]; then
    echo "$current_state" > "$state_file"
    return 1
  fi

  local prev_state
  prev_state=$(cat "$state_file")

  # Save current state for next check
  echo "$current_state" > "$state_file"

  # Compare to find new/changed files
  local triggered=false

  while IFS= read -r line; do
    [[ -z "$line" ]] && continue
    local file_path
    file_path=$(echo "$line" | sed 's/^[0-9]* //')
    if ! echo "$prev_state" | grep -q "$file_path"; then
      # New file detected
      if [[ "$event_type" == "create" ]]; then
        triggered=true
        echo "$file_path"
      fi
    else
      # Existing file — check if modified
      if [[ "$event_type" == "modify" ]]; then
        local old_mtime
        old_mtime=$(echo "$prev_state" | grep "$file_path" | awk '{print $1}')
        local new_mtime
        new_mtime=$(echo "$line" | awk '{print $1}')
        if [[ "$new_mtime" != "$old_mtime" ]]; then
          triggered=true
          echo "$file_path"
        fi
      fi
    fi
  done <<< "$current_state"

  [[ "$triggered" == "true" ]]
}

# ─── Schedule Tick ─────────────────────────────────────────────

# Check all schedules and trigger any that are due
# Usage: scheduler_tick
scheduler_tick() {
  [[ -d "$BUTLER_SCHEDULES" ]] || return 0

  local triggered=0

  while IFS= read -r sched_file; do
    [[ -z "$sched_file" ]] && continue

    local name sched_type
    name=$(grep '^name:' "$sched_file" | head -1 | sed 's/name: *//' | tr -d '"' | tr -d "'")

    # Detect schedule type: cron or watch
    local cron_line watch_glob
    cron_line=$(grep '^cron:' "$sched_file" | head -1 | sed 's/cron: *//' | tr -d '"' | tr -d "'")
    watch_glob=$(grep '^watch:' "$sched_file" | head -1 | sed 's/watch: *//' | tr -d '"' | tr -d "'")

    local should_trigger=false

    if [[ -n "$cron_line" ]]; then
      # Cron-based schedule
      if _cron_matches "$cron_line"; then
        # Check if already triggered this period (avoid duplicate triggers)
        local last_trigger="${BUTLER_ROOT}/last-trigger-${name}.txt"
        local trigger_key="${cron_line}-$(date +"%Y%m%d%H")"  # Hourly dedup
        if [[ -f "$last_trigger" ]] && [[ "$(cat "$last_trigger")" == "$trigger_key" ]]; then
          continue  # Already triggered this period
        fi
        should_trigger=true
        echo "$trigger_key" > "$last_trigger"
      fi
    elif [[ -n "$watch_glob" ]]; then
      # File watch schedule
      local event_type
      event_type=$(grep '^event:' "$sched_file" | head -1 | sed 's/event: *//' | tr -d '"' | tr -d "'")
      event_type="${event_type:-create}"

      local changed_files
      changed_files=$(_watch_check "$watch_glob" "$event_type")
      if [[ -n "$changed_files" ]]; then
        should_trigger=true
        # Store triggered files for parameter substitution
        echo "$changed_files" > "${BUTLER_ROOT}/trigger-files-${name}.txt"
      fi
    fi

    if [[ "$should_trigger" == "true" ]]; then
      sch_info "Triggering schedule: ${name}"
      _scheduler_fire "$sched_file"
      triggered=$((triggered + 1))
    fi
  done < <(command find "$BUTLER_SCHEDULES" -maxdepth 1 -name "*.yaml" -type f 2>/dev/null || true)

  if [[ "$triggered" -gt 0 ]]; then sch_ok "Triggered ${triggered} schedule(s)"; fi
}

# Fire a schedule — read workflow name and params, then run it
_scheduler_fire() {
  local sched_file="$1"

  local wf_name
  wf_name=$(grep '^workflow:' "$sched_file" | head -1 | sed 's/workflow: *//' | tr -d '"' | tr -d "'")

  if [[ -z "$wf_name" ]]; then
    sch_warn "Schedule $(basename "$sched_file") has no workflow defined"
    return
  fi

  # Parse params from schedule
  local -a params=()
  # Simple param parsing: look for lines under "params:" section
  local in_params=0
  while IFS= read -r line; do
    if [[ "$line" =~ ^params: ]]; then
      in_params=1
      continue
    fi
    [[ "$in_params" -eq 0 ]] && continue
    # Stop at next non-indented section
    [[ "$line" =~ ^[^[:space:]] && ! "$line" =~ ^$ ]] && break
    [[ -z "${line// /}" ]] && continue
    # Parse "  key: value"
    local key val
    key=$(echo "$line" | sed 's/^[[:space:]]*//' | sed 's/:.*$//')
    val=$(echo "$line" | sed 's/^[^:]*: *//' | tr -d '"' | tr -d "'")
    params+=("${key}=${val}")
  done < "$sched_file"

  # Load workflow engine and run
  source "${ACPX_ROOT}/lib/workflow.sh"
  workflow_run "$wf_name" "${params[@]}" 2>/dev/null || {
    sch_warn "Workflow ${wf_name} failed — tasks may be added to board for manual retry"
  }
}

# ─── Schedule Init ─────────────────────────────────────────────

# Create the schedules directory with an example schedule
scheduler_init() {
  mkdir -p "$BUTLER_SCHEDULES"

  if [[ ! -f "${BUTLER_SCHEDULES}/example.yaml" ]]; then
    cat > "${BUTLER_SCHEDULES}/example.yaml" <<EXAMPLE
name: daily-experiment
description: "Run experiments every weekday morning"

# Cron schedule (minute hour day-of-month month day-of-week)
cron: "0 9 * * 1-5"

# Workflow to trigger
workflow: experiment-pipeline

# Parameters to pass to the workflow
params:
  config: daily-run.yaml
  output_dir: results/daily
EXAMPLE
    sch_ok "Created example schedule at ${BUTLER_SCHEDULES}/example.yaml"
  fi
}
