#!/usr/bin/env bash
# protocols.sh — Protocol implementations with Plan-First flow
# Each protocol: Phase 1 (Plan) → consensus check → Phase 2 (Execute)
# Compatible with Bash 3.2+ (no mapfile, no associative arrays)

set -euo pipefail

ACPX_ROOT="${ACPX_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
ACPX_WORKSPACE="${ACPX_WORKSPACE:-.acpx-workspace}"

source "${ACPX_ROOT}/lib/workspace.sh"
source "${ACPX_ROOT}/lib/roles.sh"
source "${ACPX_ROOT}/lib/synthesize.sh"

# ─── Portable Helpers ──────────────────────────────────────────
# read_into_array VARNAME < input   (replaces mapfile for Bash 3.2)

read_into_array() {
  local _varname="$1"
  eval "${_varname}=()"
  while IFS= read -r _line; do
    [[ -n "$_line" ]] && eval "${_varname}+=(\"\$_line\")"
  done
}

# ─── Agent Detection ───────────────────────────────────────────

_detect_available_agents() {
  local found=""
  for cmd in claude codex gemini opencode cursor copilot pi qwen openclaw; do
    if command -v "acpx-${cmd}" &>/dev/null; then
      found="${found}${cmd}"$'\n'
    fi
  done
  # If acpx is installed but no acpx-<cmd> wrappers found,
  # return common agents — actual availability verified at runtime by sessions new
  if [[ -z "$found" ]] && command -v acpx &>/dev/null; then
    for cmd in claude codex gemini opencode; do
      found="${found}${cmd}"$'\n'
    done
  fi
  printf '%s' "$found"
}

_get_agents_or_default() {
  local agents_spec="${1:-auto}"
  if [[ "$agents_spec" == "auto" ]]; then
    local detected
    detected=$(_detect_available_agents)
    if [[ -z "$detected" ]]; then
      echo "claude"
    else
      printf '%s' "$detected"
    fi
  else
    echo "$agents_spec" | tr ',' '\n'
  fi
}

_run_agent_plan() {
  local agent="$1"
  local session="$2"
  local prompt="$3"

  acpx "$agent" -s "$session" set-mode plan 2>/dev/null || true
  acpx --format quiet "$agent" -s "$session" "$prompt"
}

_run_agent_execute() {
  local agent="$1"
  local session="$2"
  local prompt="$3"
  local mode="${4:-acceptEdits}"

  acpx "$agent" -s "$session" set-mode "$mode" 2>/dev/null || true
  acpx --format quiet "$agent" -s "$session" "$prompt"
}

# ─── Wait for PIDs and report failures ───────────────────────────
# Arguments: pid1:agent1 pid2:agent2 ...

_wait_agents() {
  local failed=0
  for spec in "$@"; do
    local pid="${spec%%:*}"
    local agent="${spec#*:}"
    if ! wait "$pid" 2>/dev/null; then
      echo "==> WARNING: Agent '${agent}' (pid ${pid}) failed" >&2
      failed=1
    fi
  done
  return $failed
}

# ─── Protocol 1: Parallel Fan-Out ──────────────────────────────

protocol_fanout() {
  local task="${1:?Usage: protocol_fanout <task> [agents] [orchestrator]}"
  local agents_spec="${2:-auto}"
  local orchestrator="${3:-claude}"

  local -a agents=()
  while IFS= read -r line; do
    [[ -n "$line" ]] && agents+=("$line")
  done < <(_get_agents_or_default "$agents_spec")

  workspace_init "$task" "fanout"

  # ── Phase 1: Plan (parallel fan-out) ──
  workspace_set_phase "plan"
  workspace_set_round 1

  echo "==> Protocol 1: Fan-Out | ${#agents[@]} agent(s) | Plan phase"

  local -a pid_specs=()
  for agent in "${agents[@]}"; do
    local session="fanout-${agent}"
    acpx "${agent}" sessions new --name "$session" 2>/dev/null || true

    _run_agent_plan "$agent" "$session" "$task" \
      | workspace_write_agent_output "$agent" 1 &
    pid_specs+=("$!:${agent}")
  done

  _wait_agents "${pid_specs[@]}" || true

  # ── Synthesize ──
  echo "==> Synthesizing..."
  synthesize_round 1 "$orchestrator"

  workspace_set_phase "done"
  echo "==> Fan-Out complete. See $ACPX_WORKSPACE/synthesis.md"

  for agent in "${agents[@]}"; do
    acpx "${agent}" sessions close "fanout-${agent}" 2>/dev/null || true
  done
}

# ─── Protocol 2: Round-Robin Deliberation ──────────────────────

protocol_deliberation() {
  local task="${1:?Usage: protocol_deliberation <task> [agents] [orchestrator]}"
  local agents_spec="${2:-auto}"
  local orchestrator="${3:-claude}"

  local -a agents=()
  while IFS= read -r line; do
    [[ -n "$line" ]] && agents+=("$line")
  done < <(_get_agents_or_default "$agents_spec")

  workspace_init "$task" "deliberation"

  # ── Phase 1: Plan - Round 1 ──
  workspace_set_phase "plan"
  workspace_set_round 1

  echo "==> Protocol 2: Deliberation | ${#agents[@]} agent(s) | Round 1 (Plan)"

  local -a pid_specs=()
  for agent in "${agents[@]}"; do
    local session="delib-${agent}"
    acpx "${agent}" sessions new --name "$session" 2>/dev/null || true

    _run_agent_plan "$agent" "$session" "$task" \
      | workspace_write_agent_output "$agent" 1 &
    pid_specs+=("$!:${agent}")
  done
  _wait_agents "${pid_specs[@]}" || true

  # ── Consensus check ──
  local consensus
  consensus=$(consensus_check 1 "$orchestrator")
  echo "==> Round 1 consensus: ${consensus}"

  if [[ "$consensus" == "HIGH" ]]; then
    echo "==> High consensus after Round 1 — skipping Round 2"
    synthesize_round 1 "$orchestrator"
    synthesize_plan "$orchestrator"
    workspace_set_phase "done"
    echo "==> Deliberation complete. See $ACPX_WORKSPACE/synthesis.md"
    return
  fi

  # ── Round 2: Deliberation ──
  workspace_set_round 2
  echo "==> Round 2 (Deliberation)"

  local all_r1
  all_r1=$(workspace_gather_round 1)

  local -a pid_specs=()
  for agent in "${agents[@]}"; do
    local session="delib-${agent}"
    local r2_prompt="[Round 2: Deliberation]
Other reviewers provided their analysis below. Consider their points fairly.
Update your analysis where you find their arguments convincing. Note any remaining disagreements.

${all_r1}"

    _run_agent_plan "$agent" "$session" "$r2_prompt" \
      | workspace_write_agent_output "$agent" 2 &
    pid_specs+=("$!:${agent}")
  done
  _wait_agents "${pid_specs[@]}" || true

  # ── Synthesize ──
  echo "==> Synthesizing..."
  synthesize_round 2 "$orchestrator"
  synthesize_plan "$orchestrator"

  workspace_set_phase "execute"
  echo "==> Plan phase complete. Ready to execute."
  echo "==> Run: acpx-council execute --from-workspace"

  for agent in "${agents[@]}"; do
    acpx "${agent}" sessions close "delib-${agent}" 2>/dev/null || true
  done
}

# ─── Protocol 3: Role-Specialized Council (Recommended) ────────

protocol_role_council() {
  local task="${1:?Usage: protocol_role_council <task> [agents] [roles] [orchestrator]}"
  local agents_spec="${2:-auto}"
  local roles_spec="${3:-auto}"
  local orchestrator="${4:-claude}"

  local -a agents=()
  while IFS= read -r line; do
    [[ -n "$line" ]] && agents+=("$line")
  done < <(_get_agents_or_default "$agents_spec")

  # Infer roles if auto
  local -a roles=()
  if [[ "$roles_spec" == "auto" ]]; then
    while IFS= read -r line; do
      [[ -n "$line" ]] && roles+=("$line")
    done < <(role_infer_from_task "$task")
    # Ensure at least as many roles as agents
    while [[ ${#roles[@]} -lt ${#agents[@]} ]]; do
      roles+=("neutral")
    done
  else
    while IFS= read -r line; do
      [[ -n "$line" ]] && roles+=("$line")
    done < <(echo "$roles_spec" | tr ',' '\n')
  fi

  workspace_init "$task" "role-council"

  # ── Phase 1: Plan - Round 1 with roles ──
  workspace_set_phase "plan"
  workspace_set_round 1

  echo "==> Protocol 3: Role Council | ${#agents[@]} agent(s)"
  echo "    Agents: ${agents[*]}"
  echo "    Roles:  ${roles[*]}"

  local -a pid_specs=()
  local i=0
  for agent in "${agents[@]}"; do
    local role="${roles[$i]:-neutral}"
    local session="council-${agent}"

    acpx "${agent}" sessions new --name "$session" 2>/dev/null || true

    local r1_prompt
    r1_prompt="$(role_get_r1 "$role")

${task}"

    _run_agent_plan "$agent" "$session" "$r1_prompt" \
      | workspace_write_agent_output "$agent" 1 &
    pid_specs+=("$!:${agent}")
    i=$((i + 1))
  done
  _wait_agents "${pid_specs[@]}" || true

  # ── Consensus check ──
  local consensus
  consensus=$(consensus_check 1 "$orchestrator")
  echo "==> Round 1 consensus: ${consensus}"

  if [[ "$consensus" == "HIGH" ]]; then
    echo "==> High consensus — synthesizing plan"
    synthesize_round 1 "$orchestrator"
    synthesize_plan "$orchestrator"
    workspace_set_phase "execute"
    echo "==> Plan ready. See $ACPX_WORKSPACE/plan.md"
    return
  fi

  # ── Round 2: Role-persistent deliberation ──
  workspace_set_round 2
  echo "==> Round 2 (Role Deliberation)"

  local all_r1
  all_r1=$(workspace_gather_round 1)

  pid_specs=()
  i=0
  for agent in "${agents[@]}"; do
    local role="${roles[$i]:-neutral}"
    local session="council-${agent}"

    local r2_prompt
    r2_prompt="$(role_get_r2 "$role")

Other experts' analysis:
${all_r1}"

    _run_agent_plan "$agent" "$session" "$r2_prompt" \
      | workspace_write_agent_output "$agent" 2 &
    pid_specs+=("$!:${agent}")
    i=$((i + 1))
  done
  _wait_agents "${pid_specs[@]}" || true

  # ── Synthesize ──
  echo "==> Synthesizing..."
  synthesize_round 2 "$orchestrator"
  synthesize_plan "$orchestrator"

  workspace_set_phase "execute"
  echo "==> Plan ready. See $ACPX_WORKSPACE/plan.md"

  for agent in "${agents[@]}"; do
    acpx "${agent}" sessions close "council-${agent}" 2>/dev/null || true
  done
}

# ─── Protocol 4: Adversarial Debate ────────────────────────────

protocol_adversarial() {
  local task="${1:?Usage: protocol_adversarial <task> [agents] [orchestrator]}"
  local agents_spec="${2:-claude,codex}"
  local orchestrator="${3:-gemini}"

  local -a agents=()
  while IFS= read -r line; do
    [[ -n "$line" ]] && agents+=("$line")
  done < <(_get_agents_or_default "$agents_spec")

  local advocate="${agents[0]:-claude}"
  local critic="${agents[1]:-codex}"
  local judge="${agents[2]:-$orchestrator}"

  # Unique session suffix to avoid collisions when running multiple adversarial debates
  local adv_suffix="${RANDOM}${RANDOM}"
  local s_advocate="adv-${adv_suffix}-bull"
  local s_critic="adv-${adv_suffix}-bear"
  local s_judge="adv-${adv_suffix}-judge"

  workspace_init "$task" "adversarial"
  workspace_set_phase "plan"
  workspace_set_round 1

  echo "==> Protocol 4: Adversarial Debate"
  echo "    Advocate: ${advocate} | Critic: ${critic} | Judge: ${judge}"

  acpx "$advocate" sessions new --name "$s_advocate" 2>/dev/null || true
  acpx "$critic" sessions new --name "$s_critic" 2>/dev/null || true
  acpx "$judge" sessions new --name "$s_judge" 2>/dev/null || true

  # Round 1: Opening arguments
  echo "==> Opening arguments..."

  _run_agent_plan "$advocate" "$s_advocate" "Argue FOR the following proposal. Provide specific technical benefits and evidence.
${task}" | workspace_write_agent_output "advocate" 1 &
  local pid1=$!

  _run_agent_plan "$critic" "$s_critic" "Argue AGAINST the following proposal. Provide specific technical risks and counter-evidence.
${task}" | workspace_write_agent_output "critic" 1 &
  local pid2=$!

  _wait_agents "${pid1}:advocate" "${pid2}:critic" || true

  # Round 2: Cross-arguments
  workspace_set_round 2
  echo "==> Cross-arguments..."

  # Check if Round 1 outputs exist before reading
  local advocate_r1_file="$ACPX_WORKSPACE/agents/advocate/round-1.md"
  local critic_r1_file="$ACPX_WORKSPACE/agents/critic/round-1.md"
  if [[ ! -f "$advocate_r1_file" ]]; then
    echo "==> WARNING: advocate round-1 output missing, debate may be incomplete" >&2
  fi
  if [[ ! -f "$critic_r1_file" ]]; then
    echo "==> WARNING: critic round-1 output missing, debate may be incomplete" >&2
  fi

  local bull_r1 critic_r1
  bull_r1=$(workspace_read_agent_output "advocate" 1 2>/dev/null || echo "(no advocate output)")
  critic_r1=$(workspace_read_agent_output "critic" 1 2>/dev/null || echo "(no critic output)")

  _run_agent_plan "$advocate" "$s_advocate" "The critic argues:
${critic_r1}

Counter-argue. Address each concern specifically." | workspace_write_agent_output "advocate" 2 &
  pid1=$!

  _run_agent_plan "$critic" "$s_critic" "The advocate argues:
${bull_r1}

Counter-argue. Address each claim specifically." | workspace_write_agent_output "critic" 2 &
  pid2=$!

  _wait_agents "${pid1}:advocate" "${pid2}:critic" || true

  # Judge synthesis
  echo "==> Judge synthesizing..."

  # Check if Round 2 outputs exist
  local advocate_r2_file="$ACPX_WORKSPACE/agents/advocate/round-2.md"
  local critic_r2_file="$ACPX_WORKSPACE/agents/critic/round-2.md"
  if [[ ! -f "$advocate_r2_file" ]]; then
    echo "==> WARNING: advocate round-2 output missing" >&2
  fi
  if [[ ! -f "$critic_r2_file" ]]; then
    echo "==> WARNING: critic round-2 output missing" >&2
  fi

  local bull_r2 critic_r2
  bull_r2=$(workspace_read_agent_output "advocate" 2 2>/dev/null || echo "(no advocate output)")
  critic_r2=$(workspace_read_agent_output "critic" 2 2>/dev/null || echo "(no critic output)")

  acpx --format quiet "$judge" -s "$s_judge" "You are the judge. Synthesize this debate into a final recommendation.

[FOR]:
${bull_r2}

[AGAINST]:
${critic_r2}

Provide:
1. Summary of key arguments on each side
2. Points of agreement
3. Unresolved tensions
4. Your final recommendation with confidence level (HIGH/MEDIUM/LOW)" \
    | workspace_write_agent_output "judge" 1

  local judge_file="$ACPX_WORKSPACE/agents/judge/round-1.md"
  if [[ -f "$judge_file" ]]; then
    cp "$judge_file" "$ACPX_WORKSPACE/synthesis.md"
  else
    echo "==> WARNING: judge output missing, synthesis.md not created" >&2
  fi

  synthesize_plan "$orchestrator"
  workspace_set_phase "execute"
  echo "==> Debate complete. See $ACPX_WORKSPACE/synthesis.md"

  acpx "$advocate" sessions close "$s_advocate" 2>/dev/null || true
  acpx "$critic" sessions close "$s_critic" 2>/dev/null || true
  acpx "$judge" sessions close "$s_judge" 2>/dev/null || true
}

# ─── Protocol 5: Sequential Pipeline ───────────────────────────

protocol_pipeline() {
  local task="${1:?Usage: protocol_pipeline <task> [agents] [orchestrator]}"
  local agents_spec="${2:-claude,codex,claude}"
  local orchestrator="${3:-claude}"

  local -a agents=()
  while IFS= read -r line; do
    [[ -n "$line" ]] && agents+=("$line")
  done < <(_get_agents_or_default "$agents_spec")

  local writer="${agents[0]:-claude}"
  local reviewer="${agents[1]:-codex}"
  local editor="${agents[2]:-$writer}"
  local editor_uses_writer_session=0
  if [[ "$editor" == "$writer" ]]; then
    editor_uses_writer_session=1
  fi

  workspace_init "$task" "pipeline"
  workspace_set_phase "plan"

  echo "==> Protocol 5: Pipeline"
  echo "    Writer: ${writer} → Reviewer: ${reviewer} → Editor: ${editor}"

  # Step 1: Plan (writer)
  echo "==> [Plan] Writer analyzing..."
  acpx "$writer" sessions new --name "pipe-writer" 2>/dev/null || true
  _run_agent_plan "$writer" "pipe-writer" "$task" \
    | workspace_write_agent_output "writer" 1

  # Step 2: Review
  echo "==> [Plan] Reviewer checking..."
  acpx "$reviewer" sessions new --name "pipe-reviewer" 2>/dev/null || true
  local writer_output
  writer_output=$(workspace_read_agent_output "writer" 1)

  _run_agent_plan "$reviewer" "pipe-reviewer" "Review this analysis for gaps, errors, and edge cases:
${writer_output}

Rate each finding: CRITICAL/HIGH/MEDIUM/LOW." | workspace_write_agent_output "reviewer" 1

  # Step 3: Edit (use editor's own session if different from writer)
  echo "==> [Plan] Editor revising..."
  local review_output
  review_output=$(workspace_read_agent_output "reviewer" 1)

  if [[ "$editor_uses_writer_session" -eq 0 ]]; then
    # Editor is a different agent — create its own session
    acpx "$editor" sessions new --name "pipe-editor" 2>/dev/null || true
    _run_agent_plan "$editor" "pipe-editor" "Incorporate this review feedback into your original analysis:
${review_output}

Original output:
${writer_output}" | workspace_write_agent_output "editor" 1
  else
    # Editor is same as writer — reuse writer's session
    _run_agent_plan "$writer" "pipe-writer" "Incorporate this review feedback into your original analysis:
${review_output}

Original output:
${writer_output}" | workspace_write_agent_output "editor" 1
  fi

  synthesize_round 1 "$orchestrator"
  synthesize_plan "$orchestrator"

  workspace_set_phase "execute"
  echo "==> Pipeline complete. See $ACPX_WORKSPACE/synthesis.md"

  acpx "$writer" sessions close "pipe-writer" 2>/dev/null || true
  acpx "$reviewer" sessions close "pipe-reviewer" 2>/dev/null || true
  if [[ "$editor_uses_writer_session" -eq 0 ]]; then
    acpx "$editor" sessions close "pipe-editor" 2>/dev/null || true
  fi
}

# ─── Protocol Auto-Select ──────────────────────────────────────

protocol_auto_select() {
  local task="${1:?Usage: protocol_auto_select <task>}"
  local task_lower
  task_lower=$(echo "$task" | tr '[:upper:]' '[:lower:]')

  case "$task_lower" in
    *review*|*audit*|*assess*)   echo "role-council" ;;
    *should*|*decide*|*choose*|*whether*) echo "adversarial" ;;
    *implement*|*build*|*create*|*add*)   echo "role-council" ;;
    *quick*|*opinion*|*think*)   echo "fanout" ;;
    *design*|*architect*|*plan*) echo "role-council" ;;
    *debug*|*fix*|*investigate*) echo "pipeline" ;;
    *)                           echo "role-council" ;;
  esac
}

# ─── Execute Phase ─────────────────────────────────────────────

protocol_execute() {
  local plan_file="${1:-$ACPX_WORKSPACE/plan.md}"
  local agents_spec="${2:-auto}"
  local orchestrator="${3:-claude}"

  if [[ ! -f "$plan_file" ]]; then
    echo "Error: No plan found at $plan_file. Run plan phase first." >&2
    return 1
  fi

  local plan
  plan=$(cat "$plan_file")

  local -a agents=()
  while IFS= read -r line; do
    [[ -n "$line" ]] && agents+=("$line")
  done < <(_get_agents_or_default "$agents_spec")

  workspace_set_phase "execute"
  echo "==> Executing plan with ${#agents[@]} agent(s)"

  local primary="${agents[0]}"
  local session="exec-${primary}"

  acpx "$primary" sessions new --name "$session" 2>/dev/null || true

  _run_agent_execute "$primary" "$session" "Execute this plan. Follow each step in order:
${plan}" "acceptEdits" | workspace_write_agent_output "executor" 1

  echo "==> Execution complete. See $ACPX_WORKSPACE/agents/executor/round-1.md"

  acpx "$primary" sessions close "$session" 2>/dev/null || true
  workspace_set_phase "review"
}
