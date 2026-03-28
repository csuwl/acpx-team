#!/usr/bin/env bash
# workspace.sh — Shared workspace management for acpx council
# Manages .acpx-workspace/ for inter-agent context sharing

set -euo pipefail

ACPX_WORKSPACE="${ACPX_WORKSPACE:-.acpx-workspace}"

# ─── Core Functions ────────────────────────────────────────────

workspace_init() {
  local task="${1:?Usage: workspace_init <task_description>}"
  local protocol="${2:-auto}"

  rm -rf "$ACPX_WORKSPACE"
  mkdir -p "$ACPX_WORKSPACE/agents"

  # Write shared context
  cat > "$ACPX_WORKSPACE/context.md" <<CTX
# Council Context

## Task
${task}

## Protocol
${protocol}

## Created
$(date -u +"%Y-%m-%dT%H:%M:%SZ")

## Status
Phase: plan
Round: 0
CTX

  # Initialize empty decision log
  cat > "$ACPX_WORKSPACE/decisions.md" <<DEC
# Decisions Log
_Auto-populated as consensus forms_

## Agreed Points
_(none yet)_

## Divergent Points
_(none yet)_

## Action Items
_(none yet)_
DEC

  # Initialize open questions
  > "$ACPX_WORKSPACE/open-questions.md"
  > "$ACPX_WORKSPACE/plan.md"

  echo "$ACPX_WORKSPACE"
}

workspace_set_phase() {
  local phase="${1:?Usage: workspace_set_phase <plan|execute|review|done>}"
  if [[ ! -d "$ACPX_WORKSPACE" ]]; then
    echo "Error: workspace not initialized. Run workspace_init first." >&2
    return 1
  fi
  sed -i.bak "s/Phase: .*/Phase: ${phase}/" "$ACPX_WORKSPACE/context.md"
  rm -f "$ACPX_WORKSPACE/context.md.bak"
}

workspace_set_round() {
  local round="${1:?Usage: workspace_set_round <number>}"
  if [[ ! -d "$ACPX_WORKSPACE" ]]; then
    echo "Error: workspace not initialized." >&2
    return 1
  fi
  sed -i.bak "s/Round: .*/Round: ${round}/" "$ACPX_WORKSPACE/context.md"
  rm -f "$ACPX_WORKSPACE/context.md.bak"
}

# ─── Context ───────────────────────────────────────────────────

workspace_write_context() {
  local key="${1:?Usage: workspace_write_context <key> <value>}"
  local value="${2:?missing value}"
  local file="$ACPX_WORKSPACE/context.md"

  # Append key-value under a section
  printf '\n## %s\n%s\n' "$key" "$value" >> "$file"
}

workspace_read_context() {
  if [[ -f "$ACPX_WORKSPACE/context.md" ]]; then
    cat "$ACPX_WORKSPACE/context.md"
  else
    echo "Error: workspace not initialized." >&2
    return 1
  fi
}

# ─── Agent Outputs ─────────────────────────────────────────────

workspace_write_agent_output() {
  local agent="${1:?Usage: workspace_write_agent_output <agent> <round> [file]}"
  local round="${2:?missing round}"
  local source="${3:-/dev/stdin}"

  local dir="$ACPX_WORKSPACE/agents/${agent}"
  mkdir -p "$dir"

  # Write round output
  if [[ "$source" == "/dev/stdin" ]]; then
    cat > "$dir/round-${round}.md"
  else
    cp "$source" "$dir/round-${round}.md"
  fi

  # Update latest symlink
  ln -sf "round-${round}.md" "$dir/latest.md"
}

workspace_read_agent_output() {
  local agent="${1:?Usage: workspace_read_agent_output <agent> [round]}"
  local round="${2:-latest}"

  local file="$ACPX_WORKSPACE/agents/${agent}/round-${round}.md"
  if [[ -f "$file" ]]; then
    cat "$file"
  elif [[ "$round" == "latest" && -L "$ACPX_WORKSPACE/agents/${agent}/latest.md" ]]; then
    cat "$ACPX_WORKSPACE/agents/${agent}/latest.md"
  else
    echo "Error: no output for agent=${agent} round=${round}" >&2
    return 1
  fi
}

workspace_list_agents() {
  if [[ ! -d "$ACPX_WORKSPACE/agents" ]]; then
    echo "Error: workspace not initialized." >&2
    return 1
  fi
  ls -1 "$ACPX_WORKSPACE/agents/" 2>/dev/null || echo "(no agents)"
}

# ─── Decisions ─────────────────────────────────────────────────

workspace_add_decision() {
  local category="${1:?Usage: workspace_add_decision <agreed|divergent|action> <text>}"
  local text="${2:?missing text}"
  local file="$ACPX_WORKSPACE/decisions.md"

  local marker
  case "$category" in
    agreed)     marker="## Agreed Points" ;;
    divergent)  marker="## Divergent Points" ;;
    action)     marker="## Action Items" ;;
    *)          echo "Error: category must be agreed|divergent|action" >&2; return 1 ;;
  esac

  # Escape sed special characters in text
  local escaped_text
  escaped_text=$(printf '%s' "$text" | sed 's/[&/\]/\\&/g')

  # Replace the _(none yet)_ or append after the section
  if grep -q "_((none yet))_" "$file" 2>/dev/null || grep -q "_(none yet)_" "$file" 2>/dev/null; then
    sed -i.bak "/${marker}/,+1 s/_(none yet)_/- ${escaped_text}/" "$file"
    rm -f "$file.bak"
  else
    # Insert after the section header
    sed -i.bak "/${marker}/a\\- ${escaped_text}" "$file"
    rm -f "$file.bak"
  fi
}

# ─── Synthesis ─────────────────────────────────────────────────

workspace_write_synthesis() {
  local source="${1:-/dev/stdin}"
  if [[ "$source" == "/dev/stdin" ]]; then
    cat > "$ACPX_WORKSPACE/synthesis.md"
  else
    cp "$source" "$ACPX_WORKSPACE/synthesis.md"
  fi
}

workspace_read_synthesis() {
  if [[ -f "$ACPX_WORKSPACE/synthesis.md" ]]; then
    cat "$ACPX_WORKSPACE/synthesis.md"
  else
    echo "Error: no synthesis available yet." >&2
    return 1
  fi
}

# ─── Plan ──────────────────────────────────────────────────────

workspace_write_plan() {
  local source="${1:-/dev/stdin}"
  if [[ "$source" == "/dev/stdin" ]]; then
    cat > "$ACPX_WORKSPACE/plan.md"
  else
    cp "$source" "$ACPX_WORKSPACE/plan.md"
  fi
}

workspace_read_plan() {
  if [[ -f "$ACPX_WORKSPACE/plan.md" ]]; then
    cat "$ACPX_WORKSPACE/plan.md"
  else
    echo "Error: no plan available yet." >&2
    return 1
  fi
}

# ─── Gather all agent outputs for a round ──────────────────────

workspace_gather_round() {
  local round="${1:?Usage: workspace_gather_round <round>}"
  local result=""

  for agent_dir in "$ACPX_WORKSPACE/agents"/*/; do
    [[ -d "$agent_dir" ]] || continue
    local agent_name
    agent_name=$(basename "$agent_dir")
    local file="${agent_dir}round-${round}.md"
    if [[ -f "$file" ]]; then
      result="${result}---\n## ${agent_name}\n\n$(cat "$file")\n\n"
    fi
  done

  printf '%b' "$result"
}

# ─── Cleanup ───────────────────────────────────────────────────

workspace_cleanup() {
  if [[ -d "$ACPX_WORKSPACE" ]]; then
    rm -rf "$ACPX_WORKSPACE"
    echo "Workspace cleaned up."
  fi
}

workspace_archive() {
  local name="${1:-council-$(date +%Y%m%d-%H%M%S)}"
  if [[ -d "$ACPX_WORKSPACE" ]]; then
    tar czf "${name}.tar.gz" -C "$(dirname "$ACPX_WORKSPACE")" "$(basename "$ACPX_WORKSPACE")"
    echo "Workspace archived to ${name}.tar.gz"
  fi
}

# ─── Status ────────────────────────────────────────────────────

workspace_status() {
  if [[ ! -d "$ACPX_WORKSPACE" ]]; then
    echo "No active workspace."
    return 0
  fi

  echo "Workspace: $ACPX_WORKSPACE"
  grep -E "^(Phase|Round):" "$ACPX_WORKSPACE/context.md" 2>/dev/null || true
  echo ""
  echo "Agents:"
  for agent_dir in "$ACPX_WORKSPACE/agents"/*/; do
    [[ -d "$agent_dir" ]] || continue
    local name rounds
    name=$(basename "$agent_dir")
    rounds=$(ls -1 "${agent_dir}"round-*.md 2>/dev/null | wc -l | tr -d ' ')
    echo "  ${name}: ${rounds} round(s)"
  done
  echo ""
  if [[ -f "$ACPX_WORKSPACE/synthesis.md" ]]; then
    echo "Synthesis: available"
  else
    echo "Synthesis: pending"
  fi
  if [[ -f "$ACPX_WORKSPACE/plan.md" && -s "$ACPX_WORKSPACE/plan.md" ]]; then
    echo "Plan: available"
  else
    echo "Plan: pending"
  fi
}
