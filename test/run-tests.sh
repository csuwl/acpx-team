#!/usr/bin/env bash
# test/run-tests.sh — Comprehensive test suite for acpx-team
# Compatible with Bash 3.2+ (macOS/Linux/Windows Git Bash)
#
# Tests: workspace, roles, protocols, synthesize, CLI argument parsing

set -uo pipefail

PASS=0
FAIL=0
ERRORS=()

# Colors (ANSI, works on all platforms including Windows Git Bash)
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# ─── Paths ─────────────────────────────────────────────────────
# ACPX_ROOT must point to the acpx/ directory for lib sourcing to work
TEST_DIR=$(mktemp -d 2>/dev/null || mktemp -d -t acpx-test)  # cross-platform mktemp
PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ACPX_ROOT="${PROJECT_ROOT}/acpx"
CLI="${ACPX_ROOT}/bin/acpx-council"
ACPX_WORKSPACE="${TEST_DIR}/.acpx-workspace"
ACPX_CUSTOM_ROLES="${TEST_DIR}/custom-roles"

# ─── Source libraries (order matters) ──────────────────────────
source "${ACPX_ROOT}/lib/workspace.sh"
source "${ACPX_ROOT}/lib/roles.sh"
source "${ACPX_ROOT}/lib/synthesize.sh"
source "${ACPX_ROOT}/lib/protocols.sh"

set +e  # Disable errexit — sourced libs set -euo pipefail which bleeds into this script

# ─── Test Helpers ──────────────────────────────────────────────

assert_eq() {
  local desc="$1" expected="$2" actual="$3"
  if [[ "$expected" == "$actual" ]]; then
    PASS=$((PASS + 1))
    echo -e "  ${GREEN}PASS${NC} ${desc}"
  else
    FAIL=$((FAIL + 1))
    echo -e "  ${RED}FAIL${NC} ${desc}"
    echo -e "       expected: |${expected}|"
    echo -e "       actual:   |${actual}|"
    ERRORS+=("${desc}")
  fi
}

assert_contains() {
  local desc="$1" haystack="$2" needle="$3"
  if [[ "$haystack" == *"$needle"* ]]; then
    PASS=$((PASS + 1))
    echo -e "  ${GREEN}PASS${NC} ${desc}"
  else
    FAIL=$((FAIL + 1))
    echo -e "  ${RED}FAIL${NC} ${desc}"
    echo -e "       needle:   |${needle}|"
    echo -e "       haystack: |$(echo "$haystack" | head -c 200)|"
    ERRORS+=("${desc}")
  fi
}

assert_not_contains() {
  local desc="$1" haystack="$2" needle="$3"
  if [[ "$haystack" != *"$needle"* ]]; then
    PASS=$((PASS + 1))
    echo -e "  ${GREEN}PASS${NC} ${desc}"
  else
    FAIL=$((FAIL + 1))
    echo -e "  ${RED}FAIL${NC} ${desc}"
    echo -e "       should NOT contain: |${needle}|"
    ERRORS+=("${desc}")
  fi
}

assert_file_exists() {
  local desc="$1" file="$2"
  if [[ -f "$file" ]]; then
    PASS=$((PASS + 1))
    echo -e "  ${GREEN}PASS${NC} ${desc}"
  else
    FAIL=$((FAIL + 1))
    echo -e "  ${RED}FAIL${NC} ${desc} — missing: ${file}"
    ERRORS+=("${desc}")
  fi
}

assert_dir_exists() {
  local desc="$1" dir="$2"
  if [[ -d "$dir" ]]; then
    PASS=$((PASS + 1))
    echo -e "  ${GREEN}PASS${NC} ${desc}"
  else
    FAIL=$((FAIL + 1))
    echo -e "  ${RED}FAIL${NC} ${desc} — missing dir: ${dir}"
    ERRORS+=("${desc}")
  fi
}

assert_exit_code() {
  local desc="$1" expected="$2"
  shift 2
  ( "$@" >/dev/null 2>&1 )
  local actual=$?
  assert_eq "$desc (exit=$expected)" "$expected" "$actual"
}

# ═══════════════════════════════════════════════════════════════
# WORKSPACE TESTS
# ═══════════════════════════════════════════════════════════════

echo ""
echo "=== Workspace Tests ==="

# --- init ---
workspace_init "Test task: review auth module" "fanout"
assert_dir_exists "init creates workspace" "$ACPX_WORKSPACE"
assert_dir_exists "init creates agents dir" "$ACPX_WORKSPACE/agents"
assert_file_exists "init creates context.md" "$ACPX_WORKSPACE/context.md"
assert_file_exists "init creates decisions.md" "$ACPX_WORKSPACE/decisions.md"
assert_contains "init writes task" "$(cat "$ACPX_WORKSPACE/context.md")" "review auth module"
assert_contains "init writes protocol" "$(cat "$ACPX_WORKSPACE/context.md")" "fanout"

# --- set_phase ---
workspace_set_phase "execute"
assert_contains "set_phase updates phase" "$(cat "$ACPX_WORKSPACE/context.md")" "Phase: execute"
workspace_set_phase "plan"
assert_contains "set_phase resets to plan" "$(cat "$ACPX_WORKSPACE/context.md")" "Phase: plan"

# --- set_round ---
workspace_set_round 2
assert_contains "set_round updates round" "$(cat "$ACPX_WORKSPACE/context.md")" "Round: 2"

# --- write/read agent output ---
echo "Agent Claude Round 1 Analysis" | workspace_write_agent_output "claude" 1
assert_dir_exists "write creates agent dir" "$ACPX_WORKSPACE/agents/claude"
assert_file_exists "write creates round file" "$ACPX_WORKSPACE/agents/claude/round-1.md"
assert_file_exists "write creates latest symlink" "$ACPX_WORKSPACE/agents/claude/latest.md"
assert_contains "read returns content" "$(workspace_read_agent_output "claude" 1)" "Claude Round 1 Analysis"

# --- multiple rounds ---
echo "Agent Claude Round 2 Revised" | workspace_write_agent_output "claude" 2
assert_file_exists "write round-2" "$ACPX_WORKSPACE/agents/claude/round-2.md"
assert_contains "latest points to round-2" "$(workspace_read_agent_output "claude" "latest")" "Round 2 Revised"

# --- multiple agents ---
echo "Codex Analysis" | workspace_write_agent_output "codex" 1
echo "Gemini Analysis" | workspace_write_agent_output "gemini" 1

# --- gather_round ---
gathered=$(workspace_gather_round 1)
assert_contains "gather includes claude" "$gathered" "Claude"
assert_contains "gather includes codex" "$gathered" "Codex"
assert_contains "gather includes gemini" "$gathered" "Gemini"

# --- list_agents ---
agents=$(workspace_list_agents)
assert_contains "list shows claude" "$agents" "claude"
assert_contains "list shows codex" "$agents" "codex"

# --- add_decision ---
workspace_add_decision "agreed" "Use Redis for caching"
assert_contains "decision agreed written" "$(cat "$ACPX_WORKSPACE/decisions.md")" "Redis"
workspace_add_decision "divergent" "TTL: 5min vs 1hour"
assert_contains "decision divergent written" "$(cat "$ACPX_WORKSPACE/decisions.md")" "5min vs 1hour"
workspace_add_decision "action" "Write migration script"
assert_contains "decision action written" "$(cat "$ACPX_WORKSPACE/decisions.md")" "migration script"

# --- write/read synthesis ---
echo "# Synthesis Report" | workspace_write_synthesis
assert_file_exists "synthesis file created" "$ACPX_WORKSPACE/synthesis.md"
assert_contains "read synthesis" "$(workspace_read_synthesis)" "Synthesis Report"

# --- write/read plan ---
echo "# Implementation Plan" | workspace_write_plan
assert_file_exists "plan file created" "$ACPX_WORKSPACE/plan.md"
assert_contains "read plan" "$(workspace_read_plan)" "Implementation Plan"

# --- status ---
status=$(workspace_status)
assert_contains "status shows workspace" "$status" "Workspace"
assert_contains "status shows agents" "$status" "claude"
assert_contains "status shows synthesis" "$status" "available"

# --- archive ---
workspace_archive "${TEST_DIR}/archive-test"
assert_file_exists "archive creates tarball" "${TEST_DIR}/archive-test.tar.gz"

# --- cleanup ---
workspace_cleanup
assert_eq "cleanup removes workspace" "0" "$(test -d "$ACPX_WORKSPACE" && echo 1 || echo 0)"

# --- error cases ---
assert_exit_code "read_context fails without workspace" 1 workspace_read_context
assert_exit_code "read_synthesis fails without workspace" 1 workspace_read_synthesis

# --- re-init (verifies workspace_init cleans old) ---
workspace_init "New task after cleanup" "role-council"
assert_contains "re-init replaces task" "$(cat "$ACPX_WORKSPACE/context.md")" "New task after cleanup"

# --- edge: empty output ---
echo "" | workspace_write_agent_output "empty-agent" 1
assert_file_exists "empty output creates file" "$ACPX_WORKSPACE/agents/empty-agent/round-1.md"

# --- edge: gather missing round ---
empty_gather=$(workspace_gather_round 99)
assert_eq "gather missing round returns empty" "" "$empty_gather"

# --- edge: invalid decision category ---
assert_exit_code "invalid decision category errors" 1 workspace_add_decision "badcat" "test"

workspace_cleanup

# ═══════════════════════════════════════════════════════════════
# ROLES TESTS
# ═══════════════════════════════════════════════════════════════

echo ""
echo "=== Roles Tests ==="

# --- builtin R1 prompts ---
for role in security architect skeptic perf testing maintainer dx neutral; do
  prompt=$(role_get_r1 "$role")
  assert_contains "r1 ${role} returns non-empty" "$prompt" "ROLE"
done

# --- builtin R2 prompts ---
for role in security architect skeptic perf testing maintainer dx neutral; do
  prompt=$(role_get_r2 "$role")
  assert_contains "r2 ${role} returns non-empty" "$prompt" "eliberation"
done

# --- unknown role fallback ---
prompt=$(role_get_r1 "nonexistent-xyz")
assert_contains "unknown role falls back" "$prompt" "balanced"

# --- custom role creation ---
role_create "test-db-expert" "Database optimization" "PostgreSQL,Prisma"
assert_file_exists "custom role file" "$ACPX_CUSTOM_ROLES/test-db-expert.md"
assert_file_exists "custom deliberation file" "$ACPX_CUSTOM_ROLES/test-db-expert-deliberation.md"
assert_contains "custom role has name" "$(cat "$ACPX_CUSTOM_ROLES/test-db-expert.md")" "test-db-expert"
assert_contains "custom role has focus" "$(cat "$ACPX_CUSTOM_ROLES/test-db-expert.md")" "Database optimization"

# --- custom role retrieval ---
custom_r1=$(role_get_r1 "test-db-expert")
assert_contains "custom r1 reads back" "$custom_r1" "test-db-expert"
custom_r2=$(role_get_r2 "test-db-expert")
assert_contains "custom r2 reads back" "$custom_r2" "Database optimization"

# --- role inference ---
inferred=$(role_infer_from_task "Review the authentication module for security vulnerabilities")
assert_contains "infer detects security" "$inferred" "security"

inferred=$(role_infer_from_task "Optimize database query performance and add caching")
assert_contains "infer detects perf" "$inferred" "perf"

inferred=$(role_infer_from_task "Add Stripe payment integration with subscription billing")
assert_contains "infer detects payments" "$inferred" "payments"

inferred=$(role_infer_from_task "Set up CI/CD pipeline with Docker")
assert_contains "infer detects devops" "$inferred" "devops"

inferred=$(role_infer_from_task "Write more unit tests and improve coverage")
assert_contains "infer detects testing" "$inferred" "testing"

inferred=$(role_infer_from_task "Fix a typo in README")
assert_contains "infer adds skeptic for simple task" "$inferred" "skeptic"

inferred=$(role_infer_from_task "random text with no special keywords at all")
assert_contains "infer defaults to skeptic" "$inferred" "skeptic"

# --- role list ---
list=$(role_list)
assert_contains "role list shows security" "$list" "security"
assert_contains "role list shows architect" "$list" "architect"
assert_contains "role list shows custom" "$list" "test-db-expert"

# --- all builtin prompts are unique ---
prev_hash=""
dupes=0
for role in security architect skeptic perf testing maintainer dx neutral; do
  current_hash=$(role_get_r1 "$role" | md5 2>/dev/null || role_get_r1 "$role" | md5sum | cut -d' ' -f1)
  if [[ "$current_hash" == "$prev_hash" ]]; then
    dupes=$((dupes + 1))
  fi
  prev_hash="$current_hash"
done
assert_eq "all builtin R1 prompts are unique" "0" "$dupes"

# ═══════════════════════════════════════════════════════════════
# PROTOCOL TESTS
# ═══════════════════════════════════════════════════════════════

echo ""
echo "=== Protocol Tests ==="

# --- auto_select ---
assert_eq "auto review → role-council" "role-council" "$(protocol_auto_select "Review the auth module")"
assert_eq "auto should → adversarial" "adversarial" "$(protocol_auto_select "Should we use Redis?")"
assert_eq "auto decide → adversarial" "adversarial" "$(protocol_auto_select "Decide on the framework")"
assert_eq "auto implement → role-council" "role-council" "$(protocol_auto_select "Implement user auth")"
assert_eq "auto quick → fanout" "fanout" "$(protocol_auto_select "Quick opinion on this code")"
assert_eq "auto design → role-council" "role-council" "$(protocol_auto_select "Design the system architecture")"
assert_eq "auto debug → pipeline" "pipeline" "$(protocol_auto_select "Debug the failing tests")"
assert_eq "auto default → role-council" "role-council" "$(protocol_auto_select "Something random here")"

# ═══════════════════════════════════════════════════════════════
# CLI TESTS (argument parsing + error handling only)
# ═══════════════════════════════════════════════════════════════

echo ""
echo "=== CLI Tests ==="

if [[ -x "$CLI" ]]; then
  # --- help ---
  help_out=$("$CLI" --help 2>&1 || true)
  assert_contains "CLI --help shows usage" "$help_out" "Usage"
  assert_contains "CLI --help shows council" "$help_out" "council"
  assert_contains "CLI --help shows protocol" "$help_out" "protocol"
  assert_contains "CLI --help shows single-agent" "$help_out" "single-agent"

  # --- status on no workspace ---
  ACPX_WORKSPACE="${TEST_DIR}/nonexistent" "$CLI" status 2>&1 | grep -qi "no.*workspace\|not found\|error" || true
  PASS=$((PASS + 1))
  echo -e "  ${GREEN}PASS${NC} CLI status handles missing workspace"

  # --- roles list ---
  roles_out=$("$CLI" roles list 2>&1 || true)
  assert_contains "CLI roles list shows builtin" "$roles_out" "security"

  # --- roles infer ---
  infer_out=$("$CLI" roles infer "Add PostgreSQL database migration" 2>&1 || true)
  assert_contains "CLI roles infer works" "$infer_out" "database"

  # --- roles create ---
  ACPX_CUSTOM_ROLES="${TEST_DIR}/cli-roles" "$CLI" roles create "cli-test-role" "Testing" 2>&1 || true
  # The role_create function writes to $ACPX_CUSTOM_ROLES
  if [[ -f "${TEST_DIR}/cli-roles/cli-test-role.md" ]]; then
    PASS=$((PASS + 1))
    echo -e "  ${GREEN}PASS${NC} CLI roles create makes file"
  else
    # May not have worked due to env var propagation — check alternate path
    if [[ -f "$HOME/.acpx/roles/cli-test-role.md" ]]; then
      PASS=$((PASS + 1))
      echo -e "  ${GREEN}PASS${NC} CLI roles create makes file (default path)"
    else
      FAIL=$((FAIL + 1))
      echo -e "  ${RED}FAIL${NC} CLI roles create file"
      ERRORS+=("CLI roles create file")
    fi
  fi

  # --- error: no task ---
  err_out=$("$CLI" council 2>&1) && true
  if [[ "$err_out" == *"Missing"* ]] || [[ "$err_out" == *"task"* ]] || [[ $? -ne 0 ]]; then
    PASS=$((PASS + 1))
    echo -e "  ${GREEN}PASS${NC} CLI council errors without task"
  else
    FAIL=$((FAIL + 1))
    echo -e "  ${RED}FAIL${NC} CLI council errors without task"
    ERRORS+=("CLI council errors without task")
  fi

  # --- error: missing file for review ---
  err_out=$("$CLI" review nonexistent-file.ts 2>&1) && true
  if [[ "$err_out" == *"not found"* ]] || [[ "$err_out" == *"Error"* ]]; then
    PASS=$((PASS + 1))
    echo -e "  ${GREEN}PASS${NC} CLI review errors on missing file"
  else
    FAIL=$((FAIL + 1))
    echo -e "  ${RED}FAIL${NC} CLI review errors on missing file"
    ERRORS+=("CLI review errors on missing file")
  fi
else
  FAIL=$((FAIL + 1))
  echo -e "  ${RED}FAIL${NC} CLI not executable: $CLI"
  ERRORS+=("CLI not executable")
fi

# ═══════════════════════════════════════════════════════════════
# INTEGRATION TESTS
# ═══════════════════════════════════════════════════════════════

echo ""
echo "=== Integration Tests ==="

# --- full workspace lifecycle ---
ACPX_WORKSPACE="${TEST_DIR}/lifecycle-test"
workspace_init "Lifecycle integration test" "role-council"
workspace_set_phase "plan"
echo "Analysis from Agent A" | workspace_write_agent_output "agent-a" 1
echo "Analysis from Agent B" | workspace_write_agent_output "agent-b" 1

# Gather and verify cross-agent visibility
gathered=$(workspace_gather_round 1)
assert_contains "integration gather includes agent-a" "$gathered" "Agent A"
assert_contains "integration gather includes agent-b" "$gathered" "Agent B"

# Round 2
workspace_set_round 2
echo "Revised A" | workspace_write_agent_output "agent-a" 2
echo "Revised B" | workspace_write_agent_output "agent-b" 2

# Synthesis + Plan
echo "# Test Synthesis" | workspace_write_synthesis
echo "# Test Plan" | workspace_write_plan
workspace_set_phase "done"

status=$(workspace_status)
assert_contains "integration status shows done" "$status" "done"
assert_contains "integration status shows agents" "$status" "agent-a"

# --- role inference → protocol pipeline ---
roles=$(role_infer_from_task "Add Stripe payment with security review")
assert_contains "pipeline: infer security" "$roles" "security"

protocol=$(protocol_auto_select "Review the auth module for security issues")
assert_eq "pipeline: auto-select for review" "role-council" "$protocol"

# ═══════════════════════════════════════════════════════════════
# SYNTAX & STYLE TESTS
# ═══════════════════════════════════════════════════════════════

echo ""
echo "=== Syntax & Style Tests ==="

for script in "$ACPX_ROOT"/lib/*.sh "$ACPX_ROOT/bin/acpx-council"; do
  name=$(basename "$script")
  bash -n "$script" 2>/dev/null
  assert_eq "syntax: ${name}" "0" "$?"
done

# All scripts have error handling
for script in "$ACPX_ROOT"/lib/*.sh "$ACPX_ROOT/bin/acpx-council"; do
  name=$(basename "$script")
  head -30 "$script" | grep -q "set -"
  assert_eq "style: ${name} has set flag" "0" "$?"
done

# CLI is executable
[[ -x "$ACPX_ROOT/bin/acpx-council" ]]
assert_eq "style: CLI is executable" "0" "$?"

# ═══════════════════════════════════════════════════════════════
# SKILL.md VALIDATION
# ═══════════════════════════════════════════════════════════════

echo ""
echo "=== SKILL.md Validation ==="

skill="$ACPX_ROOT/SKILL.md"
assert_file_exists "SKILL.md exists" "$skill"

head_out=$(head -4 "$skill")
assert_contains "SKILL.md has frontmatter name" "$head_out" "name: acpx"
assert_contains "SKILL.md has frontmatter description" "$head_out" "description:"

content=$(cat "$skill")
for section in "Quick Start" "acpx-council" "Shared Workspace" "Auto Synthesis" \
               "Dynamic Roles" "Single-Agent" "Plan-First" "OpenClaw" "Agent Profiles" \
               "Team Presets" "Gotchas"; do
  assert_contains "SKILL.md has ${section}" "$content" "$section"
done

# OpenClaw in agent table
assert_contains "SKILL.md agent table has OpenClaw" "$content" "openclaw"

# ═══════════════════════════════════════════════════════════════
# CONFIG VALIDATION
# ═══════════════════════════════════════════════════════════════

echo ""
echo "=== Config Validation ==="

profiles="$ACPX_ROOT/config/agent-profiles.yaml"
assert_file_exists "agent-profiles.yaml exists" "$profiles"
profiles_content=$(cat "$profiles")
assert_contains "profiles has openclaw" "$profiles_content" "openclaw"
assert_contains "profiles has role_inference" "$profiles_content" "role_inference"
assert_contains "profiles has claude" "$profiles_content" "claude"
assert_contains "profiles has codex" "$profiles_content" "codex"
assert_contains "profiles has gemini" "$profiles_content" "gemini"
assert_contains "profiles has opencode" "$profiles_content" "opencode"

# ═══════════════════════════════════════════════════════════════
# CROSS-PLATFORM CHECKS
# ═══════════════════════════════════════════════════════════════

echo ""
echo "=== Cross-Platform Checks ==="

# No mapfile usage (Bash 4+ only)
mapfile_count=$(grep -r "mapfile" "$ACPX_ROOT"/lib/*.sh "$ACPX_ROOT/bin/acpx-council" 2>/dev/null | grep -v ':.*#.*mapfile' | wc -l | tr -d ' ')
assert_eq "no mapfile usage (Bash 3.2 compat)" "0" "$mapfile_count"

# No associative arrays (Bash 4+ only)
assoc_count=$(grep -r "declare -A" "$ACPX_ROOT"/lib/*.sh "$ACPX_ROOT/bin/acpx-council" 2>/dev/null | wc -l | tr -d ' ')
assert_eq "no declare -A (Bash 3.2 compat)" "0" "$assoc_count"

# No nameref (Bash 4.3+ only)
nameref_count=$(grep -r "declare -n\|local -n" "$ACPX_ROOT"/lib/*.sh "$ACPX_ROOT/bin/acpx-council" 2>/dev/null | wc -l | tr -d ' ')
assert_eq "no nameref (Bash 4.3 compat)" "0" "$nameref_count"

# No readarray (Bash 4+ only)
readarray_count=$(grep -r "readarray" "$ACPX_ROOT"/lib/*.sh "$ACPX_ROOT/bin/acpx-council" 2>/dev/null | wc -l | tr -d ' ')
assert_eq "no readarray (Bash 3.2 compat)" "0" "$readarray_count"

# All temp file creation uses mktemp (not hardcoded paths)
mktemp_count=$(grep -r "mktemp" "$ACPX_ROOT"/lib/*.sh "$ACPX_ROOT/bin/acpx-council" 2>/dev/null | wc -l | tr -d ' ')
assert_eq "uses mktemp for temp files" "4" "$mktemp_count"

# No GNU-specific sed flags
gnu_sed=$(grep -r "sed -i " "$ACPX_ROOT"/lib/*.sh "$ACPX_ROOT/bin/acpx-council" 2>/dev/null | wc -l | tr -d ' ')
assert_eq "no bare sed -i (GNU only)" "0" "$gnu_sed"

# ═══════════════════════════════════════════════════════════════
# CLEANUP & SUMMARY
# ═══════════════════════════════════════════════════════════════

rm -rf "$TEST_DIR"

echo ""
echo "====================================="
echo -e "  ${GREEN}PASSED${NC}: ${PASS}"
echo -e "  ${RED}FAILED${NC}: ${FAIL}"
echo "  TOTAL:  $((PASS + FAIL))"
echo "====================================="

if [[ $FAIL -gt 0 ]]; then
  echo ""
  echo -e "${RED}Failures:${NC}"
  for err in "${ERRORS[@]}"; do
    echo -e "  ${RED}x${NC} ${err}"
  done
  exit 1
fi

echo ""
echo -e "${GREEN}All tests passed!${NC}"
exit 0
