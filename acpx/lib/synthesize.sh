#!/usr/bin/env bash
# synthesize.sh — Auto consensus detection and synthesis for acpx council
# Analyzes multi-agent outputs, detects agreements/divergences, produces structured synthesis
# Compatible with Bash 3.2+, cross-platform (macOS/Linux/Windows Git Bash)

set -euo pipefail

ACPX_ROOT="${ACPX_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
ACPX_WORKSPACE="${ACPX_WORKSPACE:-.acpx-workspace}"

# ─── Source workspace functions ─────────────────────────────────
source "${ACPX_ROOT}/lib/workspace.sh"

# ─── Gather All Outputs for a Round ────────────────────────────

_gather_all_outputs() {
  local round="${1:?Usage: _gather_all_outputs <round>}"
  local ws="${2:-$ACPX_WORKSPACE}"

  for agent_dir in "${ws}/agents"/*/; do
    [[ -d "$agent_dir" ]] || continue
    local agent_name
    agent_name=$(basename "$agent_dir")
    local file="${agent_dir}round-${round}.md"
    if [[ -f "$file" ]]; then
      echo "---"
      echo "## Agent: ${agent_name}"
      echo ""
      cat "$file"
      echo ""
      echo ""
    fi
  done
}

# ─── Synthesize Round ──────────────────────────────────────────
# Analyzes all agent outputs for a round and produces structured synthesis

synthesize_round() {
  local round="${1:?Usage: synthesize_round <round> [orchestrator] [output_file]}"
  local orchestrator="${2:-claude}"
  local output_file="${3:-$ACPX_WORKSPACE/synthesis.md}"

  local all_outputs
  all_outputs=$(_gather_all_outputs "$round")

  if [[ -z "$all_outputs" ]]; then
    echo "Error: no agent outputs found for round ${round}" >&2
    return 1
  fi

  # Build synthesis prompt using heredoc (avoids quoting issues)
  local prompt
  prompt=$(cat <<SYNPROMPT
You are a synthesis analyst. Review the following multi-agent deliberation outputs and produce a structured consensus report.

## Agent Outputs

${all_outputs}

## Instructions

Analyze the above outputs and produce a structured report with EXACTLY these sections:

### CONSENSUS
Points where ALL or MOST agents agree. Format as bullet points.

### DIVERGENCES
Points where agents DISAGREE. For each:
- State the point of disagreement
- Quote each opposing position
- Assess which position has stronger evidence

### ACTION ITEMS
Concrete next steps derived from the discussion. Format as numbered list.

### HUMAN DECISIONS NEEDED
Questions or tradeoffs that require human judgment. For each:
- State the question
- Summarize the options
- Note any time/cost/quality implications

### CONFIDENCE
Overall confidence in the consensus (HIGH / MEDIUM / LOW) with brief justification.

### RECOMMENDATION
One clear recommended path forward based on the analysis above.
SYNPROMPT
)

  # Run orchestrator agent to synthesize
  acpx --format quiet "$orchestrator" exec "$prompt" > "$output_file"

  echo "Synthesis written to $output_file"
}

# ─── Quick Consensus Check ─────────────────────────────────────
# Lightweight check: do agents broadly agree? Returns HIGH/MEDIUM/LOW

consensus_check() {
  local round="${1:?Usage: consensus_check <round> [orchestrator]}"
  local orchestrator="${2:-claude}"

  local all_outputs=""
  for agent_dir in "$ACPX_WORKSPACE/agents"/*/; do
    [[ -d "$agent_dir" ]] || continue
    local agent_name
    agent_name=$(basename "$agent_dir")
    local file="${agent_dir}round-${round}.md"
    if [[ -f "$file" ]]; then
      all_outputs="${all_outputs}[${agent_name}]: $(head -100 "$file")"$'\n\n'
    fi
  done

  if [[ -z "$all_outputs" ]]; then
    echo "LOW"
    return
  fi

  local result
  result=$(acpx --format quiet "$orchestrator" exec "$(cat <<CHKPROMPT
Analyze these agent responses and rate their agreement level.
Respond with EXACTLY one word: HIGH (mostly agree), MEDIUM (some disagreements), or LOW (fundamentally different views).

${all_outputs}
CHKPROMPT
)" 2>/dev/null | head -1)

  # Normalize
  case "${result:-LOW}" in
    *HIGH*)   echo "HIGH" ;;
    *MEDIUM*) echo "MEDIUM" ;;
    *LOW*)    echo "LOW" ;;
    *)        echo "MEDIUM" ;;
  esac
}

# ─── Plan Synthesis ────────────────────────────────────────────
# Synthesize plan-phase outputs into an actionable plan document

synthesize_plan() {
  local orchestrator="${1:-claude}"
  local output_file="${2:-$ACPX_WORKSPACE/plan.md}"
  local task=""
  if [[ -f "$ACPX_WORKSPACE/context.md" ]]; then
    task=$(grep -A1 "^## Task$" "$ACPX_WORKSPACE/context.md" 2>/dev/null | tail -1 | xargs || true)
  fi

  local all_outputs=""
  for agent_dir in "$ACPX_WORKSPACE/agents"/*/; do
    [[ -d "$agent_dir" ]] || continue
    local agent_name
    agent_name=$(basename "$agent_dir")
    local file="${agent_dir}round-1.md"
    if [[ -f "$file" ]]; then
      all_outputs="${all_outputs}---"$'\n'"## ${agent_name}"$'\n\n'"$(cat "$file")"$'\n\n'
    fi
  done

  local prompt
  prompt=$(cat <<PLANPROMPT
You are a technical lead synthesizing a plan from multiple expert opinions.

## Original Task
${task}

## Expert Opinions
${all_outputs}

## Instructions
Produce a clear, actionable implementation plan that:
1. Incorporates the strongest points from each expert
2. Resolves any contradictions (explain why you chose one approach over another)
3. Is ordered by dependency (what to do first, second, etc.)
4. Includes verification steps

Format as a numbered plan with:
- Step description
- Rationale (brief)
- Files/modules affected
- Verification criteria
PLANPROMPT
)

  acpx --format quiet "$orchestrator" exec "$prompt" > "$output_file"
  echo "Plan written to $output_file"
}
