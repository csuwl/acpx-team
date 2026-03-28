#!/usr/bin/env bash
# roles.sh — Dynamic role management for acpx council
# Supports builtin, community, and custom roles with auto-inference from task descriptions
# Compatible with Bash 3.2+ (no associative arrays)

set -euo pipefail

ACPX_ROOT="${ACPX_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
ROLE_TEMPLATES_DIR="${ACPX_ROOT}/config/role-templates"
CUSTOM_ROLES_DIR="${ACPX_CUSTOM_ROLES:-$HOME/.acpx/roles}"

# ─── Builtin Role Definitions ──────────────────────────────────
# Using functions instead of associative arrays for Bash 3.2 compat

_role_r1_security() { cat <<'PROMPT'
[ROLE: Security Expert]
Analyze this from a security perspective. Focus on:
- Injection vulnerabilities (SQL, XSS, command injection)
- Authentication and authorization flaws
- Data exposure and PII handling
- Dependency vulnerabilities
- Secure configuration defaults
Rate each finding: CRITICAL / HIGH / MEDIUM / LOW.
PROMPT
}

_role_r2_security() { cat <<'PROMPT'
[ROLE: Security Expert — Deliberation]
Other reviewers provided their analysis below. Maintain your security perspective.
Identify security implications they may have missed. Update your findings if other arguments convince you.
Do not soften your assessment to align with others — escalate disagreements.
PROMPT
}

_role_r1_architect() { cat <<'PROMPT'
[ROLE: Software Architect]
Analyze this from an architectural perspective. Focus on:
- System design and component boundaries
- Scalability and performance characteristics
- Coupling, cohesion, and separation of concerns
- Design pattern appropriateness
- Migration path and backward compatibility
Provide concrete alternatives where you see problems.
PROMPT
}

_role_r2_architect() { cat <<'PROMPT'
[ROLE: Software Architect — Deliberation]
Other reviewers provided their analysis below. Maintain your architectural perspective.
Evaluate their proposals against scalability and maintainability criteria. If their approach has hidden architectural costs, say so.
PROMPT
}

_role_r1_skeptic() { cat <<'PROMPT'
[ROLE: Skeptic / Devil's Advocate]
Your job is to find problems. Assume the proposal will fail and explain why:
- What assumptions does this design make that could be wrong?
- What are the failure modes?
- What happens under edge cases, high load, or adversarial input?
- What would you need to see to be convinced this will work?
Be specific. "This might not scale" is not enough — explain how and why it would break.
PROMPT
}

_role_r2_skeptic() { cat <<'PROMPT'
[ROLE: Skeptic — Deliberation]
Other reviewers responded to your concerns below. For each of your original objections:
- Was it adequately addressed? (YES / PARTIALLY / NO)
- If partially or no, restate the concern with additional evidence.
- If yes, acknowledge the resolution.
Do NOT concede just to reach consensus. Persist where evidence supports your position.
PROMPT
}

_role_r1_perf() { cat <<'PROMPT'
[ROLE: Performance Expert]
Analyze this from a performance perspective. Focus on:
- Time complexity and algorithmic efficiency
- Memory allocation patterns and GC pressure
- I/O patterns (database queries, network calls, file operations)
- Caching opportunities and cache invalidation
- Bottleneck identification
Quantify where possible (O(n), expected latency, memory bounds).
PROMPT
}

_role_r2_perf() { cat <<'PROMPT'
[ROLE: Performance Expert — Deliberation]
Other reviewers provided their analysis below. Maintain your performance perspective.
Check if their proposals introduce performance regressions you can identify.
PROMPT
}

_role_r1_testing() { cat <<'PROMPT'
[ROLE: Testing Expert]
Analyze this from a testing perspective. Focus on:
- Test coverage gaps (what is NOT tested)
- Edge cases and boundary conditions
- Integration vs unit test coverage
- Regression risk areas
- Testability of the proposed design
List specific test cases that should exist.
PROMPT
}

_role_r2_testing() { cat <<'PROMPT'
[ROLE: Testing Expert — Deliberation]
Other reviewers provided their analysis below. Maintain your testing perspective.
Identify testing implications of their proposals that they may have missed.
PROMPT
}

_role_r1_maintainer() { cat <<'PROMPT'
[ROLE: Maintainer]
Analyze this from a maintenance perspective. Focus on:
- Code clarity and readability
- Documentation adequacy
- Naming conventions and consistency
- Error handling patterns
- How easy it is for a new team member to understand and modify
Flag anything that would cause confusion in a PR review.
PROMPT
}

_role_r2_maintainer() { cat <<'PROMPT'
[ROLE: Maintainer — Deliberation]
Other reviewers provided their analysis below. Maintain your maintenance perspective.
Assess whether their proposals improve or degrade overall code health.
PROMPT
}

_role_r1_dx() { cat <<'PROMPT'
[ROLE: DX Expert]
Analyze this from a developer experience perspective. Focus on:
- API ergonomics and discoverability
- Error messages and debugging experience
- Configuration complexity
- Developer workflow integration
- Breaking changes and migration burden
Suggest concrete DX improvements.
PROMPT
}

_role_r2_dx() { cat <<'PROMPT'
[ROLE: DX Expert — Deliberation]
Other reviewers provided their analysis below. Maintain your DX perspective.
Ensure their proposals don't introduce unnecessary complexity for developers.
PROMPT
}

_role_r1_neutral() { cat <<'PROMPT'
[ROLE: Neutral Analyst]
Provide a thorough, balanced analysis. Consider multiple perspectives and state your reasoning clearly.
PROMPT
}

_role_r2_neutral() { cat <<'PROMPT'
[ROLE: Neutral Analyst — Deliberation]
Other reviewers provided their analysis below. Consider their points fairly. Update your analysis where you find their arguments convincing. Note any remaining disagreements.
PROMPT
}

# ─── Role Prompt Access ────────────────────────────────────────

role_get_r1() {
  local role="${1:?Usage: role_get_r1 <role_name>}"
  # Check builtin via function dispatch
  if type "_role_r1_${role}" &>/dev/null; then
    "_role_r1_${role}"
    return
  fi
  # Check template file
  if [[ -f "$ROLE_TEMPLATES_DIR/${role}.md" ]]; then
    head -50 "$ROLE_TEMPLATES_DIR/${role}.md"
    return
  fi
  # Check custom role
  if [[ -f "$CUSTOM_ROLES_DIR/${role}.md" ]]; then
    cat "$CUSTOM_ROLES_DIR/${role}.md"
    return
  fi
  # Fallback to neutral
  _role_r1_neutral
}

role_get_r2() {
  local role="${1:?Usage: role_get_r2 <role_name>}"
  if type "_role_r2_${role}" &>/dev/null; then
    "_role_r2_${role}"
    return
  fi
  if [[ -f "$ROLE_TEMPLATES_DIR/${role}-deliberation.md" ]]; then
    cat "$ROLE_TEMPLATES_DIR/${role}-deliberation.md"
    return
  fi
  if [[ -f "$CUSTOM_ROLES_DIR/${role}-deliberation.md" ]]; then
    cat "$CUSTOM_ROLES_DIR/${role}-deliberation.md"
    return
  fi
  _role_r2_neutral
}

# ─── List Available Roles ──────────────────────────────────────

role_list() {
  echo "=== Builtin Roles ==="
  for role in security architect skeptic perf testing maintainer dx neutral; do
    echo "  ${role}"
  done

  echo ""
  echo "=== Template Roles ==="
  if [[ -d "$ROLE_TEMPLATES_DIR" ]]; then
    for f in "$ROLE_TEMPLATES_DIR"/*.md; do
      [[ -f "$f" ]] || continue
      local name
      name=$(basename "$f" .md)
      [[ "$name" == *"-deliberation" ]] && continue
      [[ "$name" == _* ]] && continue
      echo "  ${name}"
    done
  fi

  echo ""
  echo "=== Custom Roles ==="
  if [[ -d "$CUSTOM_ROLES_DIR" ]]; then
    local found=0
    for f in "$CUSTOM_ROLES_DIR"/*.md; do
      [[ -f "$f" ]] || continue
      found=1
      echo "  $(basename "$f" .md)"
    done
    if [[ "$found" -eq 0 ]]; then
      echo "  (none — create with: acpx-council roles create <name>)"
    fi
  else
    echo "  (none — create with: acpx-council roles create <name>)"
  fi
}

# ─── Create Custom Role ────────────────────────────────────────

role_create() {
  local name="${1:?Usage: role_create <name> [focus] [technologies]}"
  local focus="${2:-General analysis}"
  local tech="${3:-}"

  mkdir -p "$CUSTOM_ROLES_DIR"

  cat > "$CUSTOM_ROLES_DIR/${name}.md" <<ROLE
[ROLE: ${name}]
Analyze this from a ${focus} perspective. Focus on:
- ${focus} best practices and patterns
- Common pitfalls and anti-patterns
${tech:+- Technology-specific considerations: ${tech}}
- Impact on overall system quality
Provide specific, actionable findings.
ROLE

  cat > "$CUSTOM_ROLES_DIR/${name}-deliberation.md" <<ROLE2
[ROLE: ${name} — Deliberation]
Other reviewers provided their analysis below. Maintain your ${focus} perspective.
Identify ${focus} implications they may have missed.
Do not soften your assessment to align with others.
ROLE2

  echo "Created custom role: ${name}"
  echo "  Prompt: $CUSTOM_ROLES_DIR/${name}.md"
  echo "  Deliberation: $CUSTOM_ROLES_DIR/${name}-deliberation.md"
}

# ─── Auto-Infer Roles from Task ────────────────────────────────

role_infer_from_task() {
  local task="${1:?Usage: role_infer_from_task <task_description>}"
  local task_lower
  task_lower=$(echo "$task" | tr '[:upper:]' '[:lower:]')

  local -a inferred=()
  local inferred_str=""

  # Keyword→role matching (Bash 3.2 safe)
  _match_role() {
    local role="$1"
    shift
    for kw in "$@"; do
      if [[ "$task_lower" == *"$kw"* ]]; then
        # Deduplicate
        if [[ "$inferred_str" != *":${role}:"* ]]; then
          inferred+=("$role")
          inferred_str="${inferred_str}:${role}:"
        fi
        return
      fi
    done
  }

  _match_role security "security" "vulnerability" "auth" "authentication" "authorization" "xss" "injection" "owasp" "encryption" "token"
  _match_role architect "architecture" "system design" "scalability" "migration" "refactor" "microservice" "monorepo"
  _match_role perf "performance" "latency" "throughput" "optimization" "bottleneck" "caching" "memory" "slow"
  _match_role testing "test" "coverage" "edge case" "regression" "integration test" "unit test" "e2e"
  _match_role database "database" "sql" "query" "index" "migration" "schema" "postgresql" "redis" "mongodb" "prisma" "drizzle"
  _match_role frontend "ui" "frontend" "react" "next.js" "css" "component" "accessibility" "a11y"
  _match_role payments "payment" "stripe" "billing" "checkout" "subscription"
  _match_role devops "deploy" "ci/cd" "docker" "kubernetes" "infrastructure" "pipeline"
  _match_role dx "developer experience" "dx" "api design" "ergonomics" "error message" "usability"
  _match_role i18n "internationalization" "i18n" "localization" "locale" "translation"

  # Always add skeptic if fewer than 2 roles matched
  if [[ ${#inferred[@]} -lt 2 ]]; then
    if [[ "$inferred_str" != *":skeptic:"* ]]; then
      inferred+=("skeptic")
    fi
  fi

  # Output one per line
  for role in "${inferred[@]}"; do
    echo "$role"
  done
}

# ─── Assign Roles to Agents ────────────────────────────────────

role_assign_to_agents() {
  local agents_str="${1:?Usage: role_assign_to_agents <agents,comma,sep> <roles,comma,sep>}"
  local roles_str="${2:?missing roles}"

  local IFS=','
  local -a agents_arr=($agents_str)
  local -a roles_arr=($roles_str)
  unset IFS

  local i=0
  for agent in "${agents_arr[@]}"; do
    local role="${roles_arr[$((i % ${#roles_arr[@]}))]:-neutral}"
    echo "${agent}:${role}"
    ((i++))
  done
}
