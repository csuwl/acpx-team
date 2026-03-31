#!/usr/bin/env bash
# workflow.sh — Multi-step workflow engine for acpx-butler
# YAML-defined workflows with condition branching and variable substitution
# Compatible with Bash 3.2+ (no mapfile, no associative arrays)

set -euo pipefail

BUTLER_ROOT="${BUTLER_ROOT:-.butler}"
BUTLER_WORKFLOWS="${BUTLER_ROOT}/workflows"
BUTLER_BOARD="${BUTLER_ROOT}/board"

ACPX_ROOT="${ACPX_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
source "${ACPX_ROOT}/lib/board.sh"
source "${ACPX_ROOT}/lib/monitor.sh"

# ─── Color Output ──────────────────────────────────────────────

WF_BLUE='\033[0;34m'
WF_GREEN='\033[0;32m'
WF_YELLOW='\033[1;33m'
WF_RED='\033[0;31m'
WF_NC='\033[0m'

wf_info()  { echo -e "${WF_BLUE}[workflow]${WF_NC} $*"; }
wf_ok()    { echo -e "${WF_GREEN}[ok]${WF_NC} $*"; }
wf_warn()  { echo -e "${WF_YELLOW}[warn]${WF_NC} $*"; }
wf_err()   { echo -e "${WF_RED}[error]${WF_NC} $*" >&2; }

# ─── Simple YAML Parser ────────────────────────────────────────
# Parses flat YAML with limited nesting (steps section only)
# Outputs key=value pairs, one per line

_yaml_parse_simple() {
  local file="$1"
  # Extract top-level name and description
  sed -n 's/^name: *//p; s/^description: *//p' "$file" | head -2
}

# Parse steps from YAML into a format we can iterate
# Outputs blocks separated by "---STEP---" markers
_yaml_parse_steps() {
  local file="$1"
  local in_steps=0
  local in_step=0

  while IFS= read -r line; do
    # Detect steps section
    if [[ "$line" =~ ^steps: ]]; then
      in_steps=1
      continue
    fi

    [[ "$in_steps" -eq 0 ]] && continue

    # Detect new step entry (starts with "  - id:" or similar)
    if [[ "$line" =~ ^[[:space:]]*-[[:space:]]*id: ]]; then
      if [[ "$in_step" -eq 1 ]]; then
        echo "---STEP---"
      fi
      in_step=1
      echo "$line" | sed 's/^[[:space:]]*-[[:space:]]*//'
      continue
    fi

    # Accumulate step fields
    if [[ "$in_step" -eq 1 ]]; then
      # Stop if we hit a non-indented line (end of steps section)
      if [[ "$line" =~ ^[^[:space:]] && ! "$line" =~ ^$ ]]; then
        echo "---STEP---"
        break
      fi
      # Skip blank lines
      [[ -z "${line// /}" ]] && continue
      # Output indented field (strip leading spaces)
      echo "$line" | sed 's/^[[:space:]]*//'
    fi
  done < "$file"

  # Close last step
  if [[ "$in_step" -eq 1 ]]; then
    echo "---STEP---"
  fi
}

# Read a field from a step block
_step_read_field() {
  local block="$1"
  local field="$2"
  echo "$block" | grep "^${field}:" | head -1 | sed "s/^${field}: *//" | tr -d '"' | tr -d "'"
}

# ─── Variable Substitution ─────────────────────────────────────

# Escape sed special characters (|, &, \, and newlines)
_sed_escape() {
  local text="$1"
  # Escape backslashes first, then other special chars
  text="${text//\\/\\\\}"
  text="${text//|/\\|}"
  text="${text//&/\\&}"
  text="${text//$'\n'/\\n}"
  printf '%s' "$text"
}

# Replace {{var}} with actual values from params
_render_template() {
  local text="$1"
  shift

  # Parse params (key=value pairs)
  while [[ $# -gt 0 ]]; do
    local param="$1"
    shift
    local key="${param%%=*}"
    local val="${param#*=}"
    # Security: escape sed special characters in replacement value
    local escaped_val
    escaped_val=$(_sed_escape "$val")
    text=$(echo "$text" | sed "s|{{${key}}}|${escaped_val}|g")
  done

  echo "$text"
}

# ─── Workflow Execution ─────────────────────────────────────────

# Run a workflow by name
# Usage: workflow_run <name> [--params key=value ...]
workflow_run() {
  local wf_name="${1:?Usage: workflow_run <name> [params...]}"
  shift || true

  # Parse --params
  local -a params=()
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --params)
        # Split comma-separated params
        IFS=',' read -ra param_arr <<< "$2"
        for p in "${param_arr[@]}"; do
          params+=("$p")
        done
        shift 2
        ;;
      *=*)
        params+=("$1")
        shift
        ;;
      *)
        shift
        ;;
    esac
  done

  # Find workflow file
  local wf_file=""
  for f in "${BUTLER_WORKFLOWS}/${wf_name}.yaml" "${BUTLER_WORKFLOWS}/${wf_name}.yml"; do
    if [[ -f "$f" ]]; then
      wf_file="$f"
      break
    fi
  done

  if [[ -z "$wf_file" ]]; then
    wf_err "Workflow not found: ${wf_name}"
    wf_info "Available workflows:"
    ls -1 "${BUTLER_WORKFLOWS}"/*.yaml 2>/dev/null | while read -r f; do
      echo "  $(basename "$f" .yaml)"
    done
    return 1
  fi

  wf_info "Loading workflow: ${wf_name}"

  # Initialize workflow state
  local wf_state_dir="${BUTLER_ROOT}/wf-state/${wf_name}"
  mkdir -p "$wf_state_dir"

  # Parse steps
  local steps_raw
  steps_raw=$(_yaml_parse_steps "$wf_file")

  if [[ -z "$steps_raw" ]]; then
    wf_err "No steps found in workflow"
    return 1
  fi

  # Split steps into individual blocks
  local -a step_ids=()
  local current_step=""

  while IFS= read -r line; do
    if [[ "$line" == "---STEP---" ]]; then
      if [[ -n "$current_step" ]]; then
        local sid
        sid=$(_step_read_field "$current_step" "id")
        if [[ -n "$sid" ]]; then
          step_ids+=("$sid")
          echo "$current_step" > "${wf_state_dir}/step-${sid}.txt"
        fi
        current_step=""
      fi
      continue
    fi
    current_step="${current_step}
${line}"
  done <<< "$steps_raw"

  # Handle last step (no trailing marker)
  if [[ -n "$current_step" ]]; then
    local sid
    sid=$(_step_read_field "$current_step" "id")
    if [[ -n "$sid" ]]; then
      step_ids+=("$sid")
      echo "$current_step" > "${wf_state_dir}/step-${sid}.txt"
    fi
  fi

  wf_info "Workflow has ${#step_ids[@]} steps: ${step_ids[*]}"

  # Write initial state
  cat > "${wf_state_dir}/state.md" <<STATE
# Workflow: ${wf_name}

## Status
running
Started: $(date -u +"%Y-%m-%dT%H:%M:%SZ")

## Parameters
$(for p in "${params[@]}"; do echo "- $p"; done)

## Steps
$(for sid in "${step_ids[@]}"; do echo "- [ ] ${sid}"; done)
STATE

  # Execute from first step
  local current_step_id="${step_ids[0]}"
  local steps_executed=0

  while [[ -n "$current_step_id" ]]; do
    local step_file="${wf_state_dir}/step-${current_step_id}.txt"
    if [[ ! -f "$step_file" ]]; then
      wf_err "Step not found: ${current_step_id}"
      break
    fi

    local step_block
    step_block=$(cat "$step_file")

    local step_type step_command step_task step_assign step_role
    local step_on_success step_on_failure
    step_type=$(_step_read_field "$step_block" "type")
    step_command=$(_step_read_field "$step_block" "command")
    step_task=$(_step_read_field "$step_block" "task")
    step_assign=$(_step_read_field "$step_block" "assign_to")
    step_role=$(_step_read_field "$step_block" "role")
    step_on_success=$(_step_read_field "$step_block" "on_success")
    step_on_failure=$(_step_read_field "$step_block" "on_failure")

    # Variable substitution
    step_command=$(_render_template "$step_command" "${params[@]}")
    step_task=$(_render_template "$step_task" "${params[@]}")

    wf_info "Step: ${current_step_id} (type: ${step_type})"

    # Execute step
    local step_ec=0
    case "$step_type" in
      shell)
        if [[ -n "$step_command" ]]; then
          # Security: validate command (no newlines/null bytes)
          if [[ "$step_command" == *$'\n'* ]] || [[ "$step_command" == *$'\0'* ]]; then
            wf_err "Step command contains invalid characters"
            step_ec=1
          else
            # Security: use mktemp for unpredictable temp file name
            local tmp_script
            tmp_script=$(mktemp "${BUTLER_ROOT}/tmp-wf-${current_step_id}.XXXXXXXXXX.sh") || {
              wf_err "Failed to create temp script for step ${current_step_id}"
              step_ec=1
            }
            if [[ $step_ec -eq 0 ]]; then
              printf '#!/bin/bash\n%s\n' "$step_command" > "$tmp_script"
              chmod +x "$tmp_script"
              "$tmp_script" || step_ec=$?
              rm -f "$tmp_script"
            fi
          fi
        fi
        ;;
      agent)
        if [[ -n "$step_task" ]]; then
          # Add task to board and execute
          local task_id
          task_id=$(board_add \
            --title "[wf:${wf_name}] ${current_step_id}" \
            --type agent \
            --task "$step_task" \
            --assign-to "${step_assign:-claude}" \
            --role "${step_role:-}")
          monitor_exec "$task_id" || step_ec=$?
        fi
        ;;
      council)
        if [[ -n "$step_task" ]]; then
          local task_id
          task_id=$(board_add \
            --title "[wf:${wf_name}] ${current_step_id}" \
            --type council \
            --task "$step_task" \
            --role "${step_role:-}")
          monitor_exec "$task_id" || step_ec=$?
        fi
        ;;
      done|end)
        wf_ok "Workflow complete"
        step_on_success=""
        ;;
      *)
        wf_warn "Unknown step type: ${step_type}"
        step_ec=1
        ;;
    esac

    # Update state
    steps_executed=$((steps_executed + 1))
    _safe_sed_inplace "s/- \[ \] ${current_step_id}/- [x] ${current_step_id} ($(date -u +"%H:%M"))/" "${wf_state_dir}/state.md"

    # Determine next step
    if [[ "$step_ec" -eq 0 ]]; then
      if [[ -n "$step_on_success" ]]; then
        current_step_id="$step_on_success"
      else
        # Auto-advance to next step after current_step_id
        local found_current=0
        local next_id=""
        for sid in "${step_ids[@]}"; do
          if [[ "$found_current" -eq 1 ]]; then
            next_id="$sid"
            break
          fi
          [[ "$sid" == "$current_step_id" ]] && found_current=1
        done
        current_step_id="$next_id"
      fi
    else
      wf_err "Step ${current_step_id} failed"
      if [[ -n "$step_on_failure" ]]; then
        current_step_id="$step_on_failure"
      else
        # Stop workflow on failure
        current_step_id=""
        _safe_sed_inplace "s/^running$/failed/" "${wf_state_dir}/state.md"
        return 1
      fi
    fi
  done

  # Mark complete
  if [[ -f "${wf_state_dir}/state.md" ]]; then
    _safe_sed_inplace "s/^running$/completed/" "${wf_state_dir}/state.md"
    printf '\nCompleted: %s' "$(date -u +"%Y-%m-%dT%H:%M:%SZ")" >> "${wf_state_dir}/state.md"
  fi

  wf_ok "Workflow ${wf_name} completed (${steps_executed} steps)"
}

# Show workflow status
workflow_status() {
  local wf_name="${1:-}"

  if [[ -z "$wf_name" ]]; then
    # Show all workflows
    local state_dir="${BUTLER_ROOT}/wf-state"
    if [[ ! -d "$state_dir" ]]; then
      wf_info "No workflow runs recorded"
      return 0
    fi

    for dir in "$state_dir"/*/; do
      [[ -d "$dir" ]] || continue
      local name
      name=$(basename "$dir")
      local status
      status=$(grep '^Status' "${dir}/state.md" 2>/dev/null | tail -1 | awk '{print $2}' || echo "unknown")
      echo "  ${name}: ${status}"
    done
    return 0
  fi

  local state_file="${BUTLER_ROOT}/wf-state/${wf_name}/state.md"
  if [[ -f "$state_file" ]]; then
    cat "$state_file"
  else
    wf_info "No recorded runs for workflow: ${wf_name}"
  fi
}
