# acpx-team Known Bugs

## Found During Testing (2026-03-28)

### Medium Severity

#### 1. Synthesize error message unhelpful
**Location:** `acpx/lib/synthesize.sh` (called from `cmd_synthesize`)

**Description:** When `synthesize_round` fails (e.g., no agent outputs found or acpx call fails), the error message is just "Internal error" which doesn't help the user understand what went wrong.

**Example:**
```
$ acpx-council synthesize
[acpx] Synthesizing round 1...
Internal error
```

**Expected:** Should indicate what failed (e.g., "No agent outputs found for round 1", "Failed to call orchestrator agent", etc.)

**Fix:** Improve error handling in `synthesize_round()` and `cmd_synthesize()` to propagate meaningful error messages.

---

#### 2. Execute hangs without plan instead of failing fast
**Location:** `acpx/lib/protocols.sh:protocol_execute()`

**Description:** When calling `acpx-council execute` without a valid plan.md in the workspace, the command hangs trying to run `acpx` commands instead of immediately failing with a clear message.

**Example:**
```
$ acpx-council execute
[acpx] Executing plan...
(hangs indefinitely)
```

**Expected:** Should check if plan.md exists AND has content before attempting execution, and fail with "No plan found. Run a council first to generate a plan."

**Fix:** Add early validation in `cmd_execute()` before calling `protocol_execute()`.

---

### Low Severity

#### 3. Custom role template has duplicate text
**Location:** `acpx/lib/roles.sh:258` (in `role_create()`)

**Description:** When creating custom roles, the generated prompt has duplicate "best practices" text.

**Example:**
```markdown
[ROLE: api-expert]
Analyze this from a API design and REST best practices perspective. Focus on:
- API design and REST best practices best practices and patterns
```

Notice "best practices best practices" - the word appears twice.

**Fix:** The template in `role_create()` appends "best practices and patterns" but the `$focus` variable already ends with "best practices". Need to handle this better.

---

#### 5. `--single-agent` does not auto-set `--orchestrator`
**Location:** `acpx/bin/acpx-council` (parse_opts / cmd_council_impl)
**Severity:** High

**Description:** When using `--single-agent opencode`, the orchestrator still defaults to `claude`. This causes synthesis to fail with "Internal error" because the claude agent requires genuine Anthropic API credentials.

**Example:**
```bash
$ acpx-council council "List 3 best practices" --single-agent opencode --sessions 1
# Fan-out agent step works (opencode responds)
# Synthesis fails: "Internal error" (tries to use claude as orchestrator)
```

**Expected:** `--single-agent X` should auto-set `--orchestrator X` when no explicit `--orchestrator` is provided.

**Workaround:** Pass `--orchestrator opencode` explicitly alongside `--single-agent opencode`.

**Fix:** In `cmd_council_impl()`, after handling `SINGLE_AGENT`, add:
```bash
if [[ -n "$SINGLE_AGENT" && "$ORCHESTRATOR" == "claude" ]]; then
  ORCHESTRATOR="$SINGLE_AGENT"
fi
```

---

#### 6. Adversarial protocol session names are hardcoded
**Location:** `acpx/lib/protocols.sh` (protocol_adversarial)
**Severity:** Medium

**Description:** Session names `bull`, `bear`, `judge` are hardcoded in `protocol_adversarial()`. Running two adversarial protocols simultaneously causes session name collisions — both use the same session names on the same agent, leading to corrupted/empty output.

**Example:**
```bash
# These two running simultaneously will conflict:
acpx-council debate "Topic A" --single-agent opencode &
acpx-council debate "Topic B" --single-agent opencode &
# Both create sessions: bull, bear, judge on opencode agent
# Critic output becomes 0 bytes (empty)
```

**Expected:** Session names should be unique per workspace or include a random suffix.

**Fix:** Use workspace-specific session names, e.g., `adv-${RANDOM}-bull` or derive from workspace path hash.

---

## Testing Notes

### Environment
- acpx version: 0.3.1
- Available agents: claude, opencode
- Node.js: v18+
- OS: macOS (Darwin 25.3.0)

### Tests Run
- All 135 unit tests pass
- CLI validation tests pass
- Sessions validation (--sessions 0, abc) works correctly
- Phase/round validation works correctly
- Role inference works correctly
- Protocol auto-selection works correctly
- Workspace init/status/archive works correctly

---

## Found During Real Agent Testing (2026-03-28)

### Critical - External Dependency

#### 4. acpx ACP agent connection failure
**Location:** External - acpx CLI tool

**Description:** When attempting to run any acpx command that calls a real agent, the ACP protocol fails with "Query closed before response received".

**Example:**
```
$ acpx --verbose claude exec "Say hello"
[acpx] spawning agent: npx -y @zed-industries/claude-agent-acp@^0.21.0
[client] initialize (running)
[acpx] initialized protocol version 1
[client] session/new (running)
Error handling request {
  code: -32603,
  message: 'Internal error',
  data: { details: 'Query closed before response received' }
}
```

**Impact:** Cannot perform real multi-agent testing. All agent calls fail.

**Root Cause:** The `@zed-industries/claude-agent-acp` package requires genuine Anthropic API. The environment uses Alibaba Cloud GLM-5 proxy (`ANTHROPIC_BASE_URL=https://coding.dashscope.aliyuncs.com/apps/anthropic`) which is incompatible with the ACP protocol implementation.

**Workaround:**
1. Use genuine Anthropic API credentials
2. Or find/create an ACP agent package compatible with GLM-5
3. Or test using a different agent client that supports your provider

---

## Real Agent Testing Results (2026-03-28)

**Agent used:** opencode v1.3.3 (ACP-compatible)
**All 135 unit tests:** PASS

### Protocol Test Results

| Test | Result | Notes |
|------|--------|-------|
| Smoke test (`acpx opencode exec`) | PASS | Agent responds correctly |
| Workspace (init/status/cleanup) | PASS | All workspace commands work |
| Roles (list/infer) | PASS | 8 builtin roles listed, inference works |
| Protocol 1: Fanout | PASS | Single-agent, synthesis generated |
| Protocol 3: Role-Council | PASS | 2 roles (security+architect), MEDIUM consensus → Round 2 deliberation → synthesis + plan |
| Protocol 4: Adversarial | PASS | Advocate/Critic/Judge, 2 rounds, structured debate output |
| Protocol 5: Pipeline | PASS | Writer → Reviewer → Editor, reviewer caught false positives |
| Code Review | PASS | 2 roles (security+testing), identified heredoc injection vulnerability |

### Fixes Applied During Testing

| Bug | Status | Fix |
|-----|--------|-----|
| #5 `--single-agent` doesn't auto-set `--orchestrator` | **FIXED** | Added auto-set logic in `cmd_council_impl()` |
| #1 Synthesize error message | **FIXED** (prior session) | Improved error propagation |
| #2 Execute hangs without plan | **FIXED** (prior session) | Added early validation in `cmd_execute()` |
| #3 Custom role template duplicate text | **FIXED** (prior session) | Fixed template string construction |
| #6 Adversarial session name collision | **OPEN** | Workaround: run adversarial protocols sequentially |

### Known Limitations

1. **opencode ACP timeout**: Complex multi-round protocols with 4+ roles may timeout. Use 2-3 roles for reliability.
2. **claude agent incompatible**: `@agentclientprotocol/claude-agent-acp` requires genuine Anthropic API; fails with GLM-5 proxy.
3. **Sequential only**: Running multiple protocols simultaneously causes session name collisions (Bug #6).