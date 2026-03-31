#!/usr/bin/env bash
# team.sh — Team persistence layer for cross-session agent collaboration
# Manages .acpx-teams/<name>/ with state machine, agent roles, and butler context
# Reuses board/council/workspace via directory scoping
# Compatible with Bash 3.2+ (no mapfile, no associative arrays)

set -uo pipefail

ACPX_ROOT="${ACPX_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
ACPX_TEAMS_DIR="${ACPX_TEAMS_DIR:-.acpx-teams}"
ACPX_ACTIVE_LINK="${ACPX_TEAMS_DIR}/active"

# Environment variables set by team_load() for downstream scoping
TEAM_NAME="${TEAM_NAME:-}"
TEAM_ROOT="${TEAM_ROOT:-}"
TEAM_ROLE="${TEAM_ROLE:-}"
TEAM_PEERS="${TEAM_PEERS:-}"

# ─── Helpers ────────────────────────────────────────────────────

_team_safe_sed_inplace() {
  local pattern="$1"
  local file="$2"
  sed -i.bak "$pattern" "$file"
  rm -f "${file}.bak"
}

# Read a field from team.yaml (simple key: value, no nesting)
_team_read_field() {
  local file="$1"
  local field="$2"
  [[ -f "$file" ]] || return 1
  sed -n "s/^${field}: *//p" "$file" | head -1 | tr -d '"' | tr -d "'"
}

# Read array field from team.yaml (e.g., agents: [claude, codex])
_team_read_array_field() {
  local file="$1"
  local field="$2"
  local raw
  raw=$(_team_read_field "$file" "$field") || return 1
  echo "$raw" | sed 's/[][]//g' | tr ',' '\n' | sed 's/^ *//;s/ *$//' | grep -v '^$'
}

# Write/replace a field in team.yaml
_team_write_field() {
  local file="$1"
  local field="$2"
  local value="$3"
  if grep -q "^${field}:" "$file" 2>/dev/null; then
    _team_safe_sed_inplace "s/^${field}:.*/${field}: ${value}/" "$file"
  else
    echo "${field}: ${value}" >> "$file"
  fi
}

# Validate team name: alphanumeric, hyphens, underscores only
_team_validate_name() {
  local name="$1"
  [[ "$name" =~ ^[a-zA-Z0-9_-]+$ ]] || { echo "Error: Invalid team name '${name}'. Use only letters, digits, hyphens, underscores." >&2; return 1; }
  [[ "${#name}" -le 64 ]] || { echo "Error: Team name too long (max 64 chars)." >&2; return 1; }
}

# Validate state value
_team_validate_state() {
  local state="$1"
  case "$state" in
    forming|active|paused|archived) return 0 ;;
    *) echo "Error: Invalid state '${state}'. Must be: forming|active|paused|archived" >&2; return 1 ;;
  esac
}

# ─── Agent Detection (reuse from protocols.sh) ──────────────────

_team_detect_agents() {
  local found=""
  for cmd in claude codex gemini opencode cursor copilot pi qwen openclaw; do
    if command -v "acpx-${cmd}" &>/dev/null; then
      found="${found}${cmd}"$'\n'
    fi
  done
  # If acpx installed but no wrappers, return common defaults
  if [[ -z "$found" ]] && command -v acpx &>/dev/null; then
    for cmd in claude codex gemini opencode; do
      found="${found}${cmd}"$'\n'
    done
  fi
  printf '%s' "$found"
}

_team_get_agents_or_default() {
  local agents_spec="${1:-auto}"
  if [[ "$agents_spec" == "auto" ]]; then
    local detected
    detected=$(_team_detect_agents)
    if [[ -z "$detected" ]]; then
      echo "claude"
    else
      printf '%s' "$detected"
    fi
  else
    echo "$agents_spec" | tr ',' '\n'
  fi
}

# ─── Core: Init ────────────────────────────────────────────────

team_init() {
  local name="${1:?Usage: team_init <name> [agents_spec] [roles_spec]}"
  local agents_spec="${2:-auto}"
  local roles_spec="${3:-auto}"

  _team_validate_name "$name" || return 1

  local team_dir="${ACPX_TEAMS_DIR}/${name}"

  # Check if team already exists
  if [[ -d "$team_dir" ]]; then
    echo "Error: Team '${name}' already exists. Use 'team_load ${name}' to resume." >&2
    return 1
  fi

  # Create directory structure
  mkdir -p "$team_dir"
  mkdir -p "${team_dir}/board/inbox"
  mkdir -p "${team_dir}/board/active"
  mkdir -p "${team_dir}/board/blocked"
  mkdir -p "${team_dir}/board/done"
  mkdir -p "${team_dir}/board/failed"
  mkdir -p "${team_dir}/board/archive"
  mkdir -p "${team_dir}/workspace/agents"
  mkdir -p "${team_dir}/workflows"
  mkdir -p "${team_dir}/logs"
  mkdir -p "${team_dir}/sessions"

  # Resolve agents
  local -a agents=()
  while IFS= read -r line; do
    [[ -n "$line" ]] && agents+=("$line")
  done < <(_team_get_agents_or_default "$agents_spec")

  local agents_yaml=""
  local first=1
  for agent in "${agents[@]}"; do
    if [[ "$first" -eq 1 ]]; then
      agents_yaml="${agent}"
      first=0
    else
      agents_yaml="${agents_yaml}, ${agent}"
    fi
  done

  # Resolve roles
  local -a roles=()
  if [[ "$roles_spec" == "auto" ]]; then
    # Assign roles based on agent count
    local builtin_roles=("architect" "security" "testing" "skeptic" "perf" "maintainer" "dx" "neutral")
    local i=0
    for agent in "${agents[@]}"; do
      if [[ "$i" -lt "${#builtin_roles[@]}" ]]; then
        roles+=("${builtin_roles[$i]}")
      else
        roles+=("neutral")
      fi
      i=$((i + 1))
    done
  else
    while IFS= read -r line; do
      [[ -n "$line" ]] && roles+=("$line")
    done < <(echo "$roles_spec" | tr ',' '\n')
  fi

  # Ensure at least as many roles as agents
  while [[ ${#roles[@]} -lt ${#agents[@]} ]]; do
    roles+=("neutral")
  done

  local roles_yaml=""
  first=1
  for role in "${roles[@]}"; do
    if [[ "$first" -eq 1 ]]; then
      roles_yaml="${role}"
      first=0
    else
      roles_yaml="${roles_yaml}, ${role}"
    fi
  done

  # Write team.yaml manifest
  cat > "${team_dir}/team.yaml" <<MANIFEST
name: ${name}
state: forming
created: $(date -u +"%Y-%m-%dT%H:%M:%SZ")
updated: $(date -u +"%Y-%m-%dT%H:%M:%SZ")
agents: [${agents_yaml}]
roles: [${roles_yaml}]
orchestrator: ${agents[0]:-claude}
MANIFEST

  # Write agent-role mappings
  i=0
  for agent in "${agents[@]}"; do
    local role="${roles[$i]:-neutral}"
    echo "${agent}: ${role}" >> "${team_dir}/agent-roles.txt"
    i=$((i + 1))
  done

  # Write butler context (empty initially)
  cat > "${team_dir}/butler-context.md" <<CTX
# Butler Context: ${name}
_Auto-saved working memory — persists across sessions_

## Summary
Team initialized with ${#agents[@]} agent(s): ${agents_yaml}

## Recent Activity
_(none yet)_

## Key Decisions
_(none yet)_
CTX

  # Write history log
  cat > "${team_dir}/history.md" <<HIST
# Team History: ${name}

## $(date -u +"%Y-%m-%dT%H:%M:%SZ") — Team Created
- State: forming
- Agents: ${agents_yaml}
- Roles: ${roles_yaml}
HIST

  # Write workspace context
  cat > "${team_dir}/workspace/context.md" <<WCTX
# Council Context

## Task
_(no task yet)_

## Protocol
auto

## Created
$(date -u +"%Y-%m-%dT%H:%M:%SZ")

## Status
Phase: plan
Round: 0
WCTX

  # Set as active
  _team_set_active "$name"

  # Auto-transition to active if agents detected
  if [[ ${#agents[@]} -gt 0 ]]; then
    _team_write_field "${team_dir}/team.yaml" "state" "active"
  fi

  echo "Team '${name}' created with ${#agents[@]} agent(s): ${agents_yaml}"
  echo "  Roles: ${roles_yaml}"
  echo "  Active: ${ACPX_ACTIVE_LINK} → ${team_dir}"
  echo "  Board:  ${team_dir}/board/"
  echo "  Workspace: ${team_dir}/workspace/"
}

# ─── Core: Load ────────────────────────────────────────────────

team_load() {
  local name="${1:?Usage: team_load <name>}"

  _team_validate_name "$name" || return 1

  local team_dir="${ACPX_TEAMS_DIR}/${name}"
  if [[ ! -d "$team_dir" ]]; then
    echo "Error: Team '${name}' not found." >&2
    return 1
  fi

  local state
  state=$(_team_read_field "${team_dir}/team.yaml" "state") || state="unknown"

  if [[ "$state" == "archived" ]]; then
    echo "Error: Team '${name}' is archived. Use 'team_set_state ${name} active' to reactivate." >&2
    return 1
  fi

  # Set as active
  _team_set_active "$name"

  # Set environment variables for downstream scoping
  export TEAM_NAME="$name"
  export TEAM_ROOT="$team_dir"
  export BUTLER_ROOT="${team_dir}"
  export ACPX_WORKSPACE="${team_dir}/workspace"

  # Resolve role and peers for agent header injection
  local agents
  agents=$(_team_read_array_field "${team_dir}/team.yaml" "agents") || agents=""
  export TEAM_PEERS=$(echo "$agents" | tr '\n' ',' | sed 's/,$//')

  # Update last-loaded timestamp
  _team_write_field "${team_dir}/team.yaml" "updated" "$(date -u +"%Y-%m-%dT%H:%M:%SZ")"

  # Log to history
  echo "" >> "${team_dir}/history.md"
  echo "## $(date -u +"%Y-%m-%dT%H:%M:%SZ") — Team Loaded" >> "${team_dir}/history.md"
  echo "- State: ${state}" >> "${team_dir}/history.md"

  echo "Loaded team '${name}' (state: ${state})"
  echo "  BUTLER_ROOT=${BUTLER_ROOT}"
  echo "  ACPX_WORKSPACE=${ACPX_WORKSPACE}"
}

# ─── Core: State Machine ──────────────────────────────────────

team_set_state() {
  local name="${1:?Usage: team_set_state <name> <state>}"
  local state="${2:?Usage: team_set_state <name> <state>}"

  _team_validate_name "$name" || return 1
  _team_validate_state "$state" || return 1

  local team_dir="${ACPX_TEAMS_DIR}/${name}"
  if [[ ! -d "$team_dir" ]]; then
    echo "Error: Team '${name}' not found." >&2
    return 1
  fi

  local old_state
  old_state=$(_team_read_field "${team_dir}/team.yaml" "state") || old_state="unknown"

  _team_write_field "${team_dir}/team.yaml" "state" "$state"
  _team_write_field "${team_dir}/team.yaml" "updated" "$(date -u +"%Y-%m-%dT%H:%M:%SZ")"

  # If pausing, clear active symlink if this team is active
  if [[ "$state" == "paused" ]]; then
    if [[ -L "$ACPX_ACTIVE_LINK" ]]; then
      local target
      target=$(readlink "$ACPX_ACTIVE_LINK" 2>/dev/null || echo "")
      if [[ "$target" == *"${name}" ]]; then
        rm -f "$ACPX_ACTIVE_LINK"
        unset TEAM_NAME TEAM_ROOT TEAM_PEERS TEAM_ROLE 2>/dev/null || true
      fi
    fi
  fi

  # If archiving, always clear active
  if [[ "$state" == "archived" ]]; then
    if [[ -L "$ACPX_ACTIVE_LINK" ]]; then
      local target
      target=$(readlink "$ACPX_ACTIVE_LINK" 2>/dev/null || echo "")
      if [[ "$target" == *"${name}" ]]; then
        rm -f "$ACPX_ACTIVE_LINK"
      fi
    fi
  fi

  # Log
  echo "" >> "${team_dir}/history.md"
  echo "## $(date -u +"%Y-%m-%dT%H:%M:%SZ") — State Changed" >> "${team_dir}/history.md"
  echo "- ${old_state} → ${state}" >> "${team_dir}/history.md"

  echo "Team '${name}': ${old_state} → ${state}"
}

# ─── Active Team Management ───────────────────────────────────

_team_set_active() {
  local name="$1"
  mkdir -p "$ACPX_TEAMS_DIR"
  # Atomic symlink replacement
  ln -sfn "${ACPX_TEAMS_DIR}/${name}" "$ACPX_ACTIVE_LINK"
}

team_active() {
  if [[ -L "$ACPX_ACTIVE_LINK" ]]; then
    local target
    target=$(readlink "$ACPX_ACTIVE_LINK" 2>/dev/null || echo "")
    if [[ -n "$target" && -d "$target" ]]; then
      basename "$target"
      return 0
    fi
    # Symlink target might be relative
    if [[ -d "$ACPX_ACTIVE_LINK" ]]; then
      local name
      name=$(_team_read_field "${ACPX_ACTIVE_LINK}/team.yaml" "name") || return 1
      echo "$name"
      return 0
    fi
  fi
  return 1
}

# ─── Agent Management ─────────────────────────────────────────

team_agent_add() {
  local name="${1:?Usage: team_agent_add <team_name> <agent> [role]}"
  local agent="${2:?Usage: team_agent_add <team_name> <agent> [role]}"
  local role="${3:-neutral}"

  _team_validate_name "$name" || return 1

  local team_dir="${ACPX_TEAMS_DIR}/${name}"
  [[ -d "$team_dir" ]] || { echo "Error: Team '${name}' not found." >&2; return 1; }

  local yaml="${team_dir}/team.yaml"
  local current_agents
  current_agents=$(_team_read_field "$yaml" "agents") || current_agents="[]"

  # Check if already present
  if echo "$current_agents" | grep -q "$agent"; then
    echo "Agent '${agent}' already in team '${name}'"
    return 0
  fi

  # Append to agents array in YAML
  local new_agents
  if [[ "$current_agents" == *"["* ]]; then
    # Remove closing bracket, add agent
    new_agents=$(echo "$current_agents" | sed 's/]$//' | sed 's/ *$//')
    new_agents="${new_agents}, ${agent}]"
  else
    new_agents="[${agent}]"
  fi
  _team_write_field "$yaml" "agents" "$new_agents"

  # Append to roles array
  local current_roles
  current_roles=$(_team_read_field "$yaml" "roles") || current_roles="[]"
  local new_roles
  if [[ "$current_roles" == *"["* ]]; then
    new_roles=$(echo "$current_roles" | sed 's/]$//' | sed 's/ *$//')
    new_roles="${new_roles}, ${role}]"
  else
    new_roles="[${role}]"
  fi
  _team_write_field "$yaml" "roles" "$new_roles"

  # Add to agent-roles mapping
  echo "${agent}: ${role}" >> "${team_dir}/agent-roles.txt"

  # Log
  _team_write_field "$yaml" "updated" "$(date -u +"%Y-%m-%dT%H:%M:%SZ")"
  echo "" >> "${team_dir}/history.md"
  echo "## $(date -u +"%Y-%m-%dT%H:%M:%SZ") — Agent Added" >> "${team_dir}/history.md"
  echo "- ${agent} (role: ${role})" >> "${team_dir}/history.md"

  echo "Added agent '${agent}' (role: ${role}) to team '${name}'"
}

team_agent_remove() {
  local name="${1:?Usage: team_agent_remove <team_name> <agent>}"
  local agent="${2:?Usage: team_agent_remove <team_name> <agent>}"

  _team_validate_name "$name" || return 1

  local team_dir="${ACPX_TEAMS_DIR}/${name}"
  [[ -d "$team_dir" ]] || { echo "Error: Team '${name}' not found." >&2; return 1; }

  local yaml="${team_dir}/team.yaml"
  local current_agents
  current_agents=$(_team_read_field "$yaml" "agents") || current_agents="[]"

  # Check if present
  if ! echo "$current_agents" | grep -q "$agent"; then
    echo "Agent '${agent}' not in team '${name}'"
    return 0
  fi

  # Rebuild agent list excluding the removed agent
  local -a remaining=()
  while IFS= read -r a; do
    [[ -n "$a" && "$a" != "$agent" ]] && remaining+=("$a")
  done < <(echo "$current_agents" | sed 's/[][]//g' | tr ',' '\n' | sed 's/^ *//;s/ *$//')

  if [[ ${#remaining[@]} -eq 0 ]]; then
    _team_write_field "$yaml" "agents" "[]"
    _team_write_field "$yaml" "roles" "[]"
  else
    local new_agents=""
    local first=1
    for a in "${remaining[@]}"; do
      if [[ "$first" -eq 1 ]]; then
        new_agents="${a}"
        first=0
      else
        new_agents="${new_agents}, ${a}"
      fi
    done
    _team_write_field "$yaml" "agents" "[${new_agents}]"
  fi

  # Remove from agent-roles mapping
  if [[ -f "${team_dir}/agent-roles.txt" ]]; then
    local tmp
    tmp=$(grep -v "^${agent}:" "${team_dir}/agent-roles.txt" 2>/dev/null || true)
    echo "$tmp" > "${team_dir}/agent-roles.txt"
  fi

  # Close sessions for this agent
  acpx "$agent" sessions close "team-${name}-${agent}" 2>/dev/null || true
  acpx "$agent" sessions close "council-${agent}" 2>/dev/null || true

  # Log
  _team_write_field "$yaml" "updated" "$(date -u +"%Y-%m-%dT%H:%M:%SZ")"
  echo "" >> "${team_dir}/history.md"
  echo "## $(date -u +"%Y-%m-%dT%H:%M:%SZ") — Agent Removed" >> "${team_dir}/history.md"
  echo "- ${agent}" >> "${team_dir}/history.md"

  echo "Removed agent '${agent}' from team '${name}'"
}

team_agent_list() {
  local name="${1:?Usage: team_agent_list <team_name>}"

  local team_dir="${ACPX_TEAMS_DIR}/${name}"
  [[ -d "$team_dir" ]] || { echo "Error: Team '${name}' not found." >&2; return 1; }

  if [[ -f "${team_dir}/agent-roles.txt" ]]; then
    echo "Agents in team '${name}':"
    while IFS=: read -r agent role; do
      [[ -z "$agent" ]] && continue
      printf "  %-15s %s\n" "$agent" "$role"
    done < "${team_dir}/agent-roles.txt"
  else
    echo "No agents in team '${name}'"
  fi
}

# ─── Butler Context ───────────────────────────────────────────

team_save_context() {
  local name="${1:?Usage: team_save_context <team_name> <key> <value>}"
  local key="${2:?Usage: team_save_context <team_name> <key> <value>}"
  local value="${3:?Usage: team_save_context <team_name> <key> <value>}"

  local team_dir="${ACPX_TEAMS_DIR}/${name}"
  [[ -d "$team_dir" ]] || { echo "Error: Team '${name}' not found." >&2; return 1; }

  local ctx_file="${team_dir}/butler-context.md"
  local marker="## ${key}"

  if grep -q "$marker" "$ctx_file" 2>/dev/null; then
    # Replace section content
    local escaped_value
    escaped_value=$(printf '%s' "$value" | sed 's/[&/\]/\\&/g')
    _team_safe_sed_inplace "/${marker}/,\${
      /^## /!{
        /^_/!{
          s/.*/${escaped_value}/
          t
          s/.*/${escaped_value}/
        }
      }
    }" "$ctx_file"
  else
    # Append new section
    echo "" >> "$ctx_file"
    echo "## ${key}" >> "$ctx_file"
    echo "${value}" >> "$ctx_file"
  fi
}

team_load_context() {
  local name="${1:-}"

  # Use active team if no name given
  if [[ -z "$name" ]]; then
    name=$(team_active) || { echo "No active team." >&2; return 1; }
  fi

  local team_dir="${ACPX_TEAMS_DIR}/${name}"
  if [[ -f "${team_dir}/butler-context.md" ]]; then
    cat "${team_dir}/butler-context.md"
  else
    echo "No butler context for team '${name}'." >&2
    return 1
  fi
}

# ─── Resume Token ─────────────────────────────────────────────

team_resume_token() {
  local name="${1:-}"

  if [[ -z "$name" ]]; then
    name=$(team_active) || { echo "No active team." >&2; return 1; }
  fi

  cat <<TOKEN
---
**Resume Team: ${name}**
Run: \`acpx-team resume ${name}\`
Or paste in any Claude session: "Continue team ${name}"
---
TOKEN
}

# ─── Quick Create ─────────────────────────────────────────────

team_quick_create() {
  local task="${1:?Usage: team_quick_create <task> [agents_spec]}"
  local agents_spec="${2:-auto}"

  # Generate team name from task (first 3 words, lowercase, hyphens)
  local name
  name=$(echo "$task" | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9 ]//g' | awk '{print $1"-"$2"-"$3}' | sed 's/ *$//;s/-$//' | sed 's/--*/-/g')
  # Fallback for CJK or short tasks
  [[ -z "$name" ]] && name="team-$(date +%Y%m%d%H%M%S)"

  # Ensure unique
  local suffix=""
  while [[ -d "${ACPX_TEAMS_DIR}/${name}${suffix}" ]]; do
    suffix="-$((${suffix:-0} + 1))"
  done
  name="${name}${suffix}"

  team_init "$name" "$agents_spec" "auto" || return 1

  # Auto-infer roles from task
  source "${ACPX_ROOT}/lib/roles.sh"
  local inferred
  inferred=$(role_infer_from_task "$task" 2>/dev/null || echo "neutral")
  local -a roles=()
  while IFS= read -r line; do
    [[ -n "$line" ]] && roles+=("$line")
  done <<< "$inferred"

  # Update team.yaml with inferred roles
  if [[ ${#roles[@]} -gt 0 ]]; then
    local roles_yaml=""
    local first=1
    for role in "${roles[@]}"; do
      if [[ "$first" -eq 1 ]]; then
        roles_yaml="${role}"
        first=0
      else
        roles_yaml="${roles_yaml}, ${role}"
      fi
    done
    _team_write_field "${ACPX_TEAMS_DIR}/${name}/team.yaml" "roles" "[${roles_yaml}]"

    # Update agent-roles mapping
    local i=0
    local agents
    agents=$(_team_read_array_field "${ACPX_TEAMS_DIR}/${name}/team.yaml" "agents") || agents=""
    : > "${ACPX_TEAMS_DIR}/${name}/agent-roles.txt"
    while IFS= read -r agent; do
      [[ -z "$agent" ]] && continue
      local role="${roles[$i]:-neutral}"
      echo "${agent}: ${role}" >> "${ACPX_TEAMS_DIR}/${name}/agent-roles.txt"
      i=$((i + 1))
    done <<< "$agents"
  fi

  echo ""
  echo "==> Quick team '${name}' ready!"
  echo "    Run: acpx-team council \"${task}\""
  team_resume_token "$name"
}

# ─── List / Status ────────────────────────────────────────────

team_list() {
  [[ -d "$ACPX_TEAMS_DIR" ]] || { echo "No teams found."; return 0; }

  local found=0
  for team_dir in "${ACPX_TEAMS_DIR}"/*/; do
    [[ -d "$team_dir" ]] || continue
    local yaml="${team_dir}team.yaml"
    [[ -f "$yaml" ]] || continue

    local name state agents created
    name=$(_team_read_field "$yaml" "name") || continue
    state=$(_team_read_field "$yaml" "state") || state="?"
    agents=$(_team_read_field "$yaml" "agents") || agents="[]"
    created=$(_team_read_field "$yaml" "created") || created="?"

    local active_marker=""
    if [[ "$(team_active 2>/dev/null)" == "$name" ]]; then
      active_marker=" [ACTIVE]"
    fi

    printf "  %-20s %-10s %-20s %s%s\n" "$name" "$state" "$agents" "$created" "$active_marker"
    found=1
  done

  if [[ "$found" -eq 0 ]]; then
    echo "No teams found. Create one with: team_init <name>"
  fi
}

team_status() {
  local name="${1:-}"

  # Use active team if no name given
  if [[ -z "$name" ]]; then
    name=$(team_active) || { echo "No active team. Create one with: acpx-team create <name>"; return 0; }
  fi

  local team_dir="${ACPX_TEAMS_DIR}/${name}"
  if [[ ! -d "$team_dir" ]]; then
    echo "Team '${name}' not found."
    return 1
  fi

  local yaml="${team_dir}/team.yaml"
  if [[ ! -f "$yaml" ]]; then
    echo "Team '${name}' has no manifest."
    return 1
  fi

  local state agents roles orchestrator created updated
  name=$(_team_read_field "$yaml" "name")
  state=$(_team_read_field "$yaml" "state")
  agents=$(_team_read_field "$yaml" "agents")
  roles=$(_team_read_field "$yaml" "roles")
  orchestrator=$(_team_read_field "$yaml" "orchestrator")
  created=$(_team_read_field "$yaml" "created")
  updated=$(_team_read_field "$yaml" "updated")

  echo "Team: ${name} (state: ${state})"
  echo "  Created:     ${created}"
  echo "  Updated:     ${updated}"
  echo "  Agents:      ${agents}"
  echo "  Roles:       ${roles}"
  echo "  Orchestrator: ${orchestrator}"

  # Show agent-role details
  if [[ -f "${team_dir}/agent-roles.txt" ]]; then
    echo ""
    echo "  Agent-Role Map:"
    while IFS=: read -r agent role; do
      [[ -z "$agent" ]] && continue
      printf "    %-15s → %s\n" "$agent" "$role"
    done < "${team_dir}/agent-roles.txt"
  fi

  # Show board stats
  local board_dir="${team_dir}/board"
  if [[ -d "$board_dir" ]]; then
    local inbox=0 active=0 blocked=0 done=0 failed=0
    for status_dir in inbox active blocked done failed; do
      local count
      count=$(find "${board_dir}/${status_dir}" -maxdepth 1 -name "*.md" -type f 2>/dev/null | wc -l | tr -d ' ')
      case "$status_dir" in
        inbox)   inbox="$count" ;;
        active)  active="$count" ;;
        blocked) blocked="$count" ;;
        done)    done="$count" ;;
        failed)  failed="$count" ;;
      esac
    done
    echo ""
    echo "  Board: inbox=${inbox} active=${active} blocked=${blocked} done=${done} failed=${failed}"
  fi

  # Show workspace phase
  local ctx="${team_dir}/workspace/context.md"
  if [[ -f "$ctx" ]]; then
    local phase round
    phase=$(grep "^Phase:" "$ctx" 2>/dev/null | head -1 | sed 's/Phase: *//') || phase="?"
    round=$(grep "^Round:" "$ctx" 2>/dev/null | head -1 | sed 's/Round: *//') || round="0"
    echo "  Workspace: phase=${phase} round=${round}"
  fi

  # Active marker
  if [[ "$(team_active 2>/dev/null)" == "$name" ]]; then
    echo ""
    echo "  * This is the active team *"
  fi
}

# ─── Destroy ──────────────────────────────────────────────────

team_destroy() {
  local name="${1:?Usage: team_destroy <name>}"

  _team_validate_name "$name" || return 1

  local team_dir="${ACPX_TEAMS_DIR}/${name}"
  if [[ ! -d "$team_dir" ]]; then
    echo "Error: Team '${name}' not found." >&2
    return 1
  fi

  # Clear active if this is the active team
  if [[ "$(team_active 2>/dev/null)" == "$name" ]]; then
    rm -f "$ACPX_ACTIVE_LINK"
  fi

  # Archive first, then remove
  local archive_name="${name}-$(date +%Y%m%d%H%M%S).tar.gz"
  tar czf "$archive_name" -C "$ACPX_TEAMS_DIR" "$name" 2>/dev/null || true
  rm -rf "$team_dir"

  echo "Team '${name}' destroyed. Archive: ${archive_name}"
}

# ─── Context for Agent Header Injection ───────────────────────
# Used by protocols.sh to inject team context into agent prompts

team_get_agent_role() {
  local agent="$1"
  local name="${2:-$(team_active 2>/dev/null)}"

  [[ -z "$name" ]] && { echo "neutral"; return; }

  local team_dir="${ACPX_TEAMS_DIR}/${name}"
  if [[ -f "${team_dir}/agent-roles.txt" ]]; then
    local role
    role=$(grep "^${agent}:" "${team_dir}/agent-roles.txt" 2>/dev/null | head -1 | cut -d: -f2 | tr -d ' ')
    if [[ -n "$role" ]]; then
      echo "$role"
      return
    fi
  fi
  echo "neutral"
}
