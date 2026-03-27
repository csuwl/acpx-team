---
name: acpx
repository: https://github.com/csuwl/acpx-skill
description: Multi-agent collaboration and task delegation via the Agent Client Protocol (ACP) using acpx. Form agent teams from Claude Code, Codex, OpenCode, Gemini, Cursor, Copilot, OpenClaw, and other ACP-compatible agents. Run parallel workstreams, switch agent modes, orchestrate deliberation and consensus, or delegate coding tasks to another agent. Triggers include "delegate to Claude", "use Claude Code", "ask Claude to", "parallel agents", "acpx", "ACP", "agent delegation", "form a team", "council", "multi-agent", "debate", "consensus", "code review team", "security audit", "have Claude/Codex/Gemini review/implement/fix", or any request involving multiple AI agents collaborating.
---

# acpx — Multi-Agent Collaboration via ACP

Form teams of AI coding agents, run deliberations, build consensus, and delegate work — all through the Agent Client Protocol.

## Prerequisites

```bash
npm i -g acpx@latest
```

Install the target agents you want to use (e.g., `npm i -g @anthropic-ai/claude-code`).

## Installation

```bash
# Option 1: npm (recommended — gives you the acpx-council CLI globally)
npm i -g acpx-skill

# Option 2: git clone into your global skills directory
git clone https://github.com/csuwl/acpx-skill.git ~/.claude/skills/acpx

# Option 3: git clone into a specific project
git clone https://github.com/csuwl/acpx-skill.git .claude/skills/acpx
```

After `npm i -g`, the `acpx-council` command is available everywhere.

## Your Role: Orchestrator

When you use acpx, **you are the supervisor**. You don't implement everything yourself — you delegate. Your job is to:

1. **Define the task** clearly — what needs doing, constraints, success criteria
2. **Pick the right protocol** — fan-out for quick opinions, council for deliberation, debate for go/no-go
3. **Assign roles** — security expert, architect, skeptic, etc. based on the task domain
4. **Dispatch agents** — via `acpx-council` or manual `acpx` commands
5. **Synthesize results** — read the workspace outputs, make the final call

The agents are your team members. You are the tech lead directing their work.

## Quick Start: One-Command Council

```bash
# Code review — auto-selects protocol, roles, and agents
acpx-council review src/auth.ts

# General council — ask anything
acpx-council council "Should we use Redis or Memcached for session caching?"

# Adversarial debate for go/no-go decisions
acpx-council debate "Migrate from REST to tRPC?"

# Security audit preset
acpx-council council "Review login flow" --preset security_audit

# Single agent (e.g., OpenCode) with 5 role-playing sessions
acpx-council council "Refactor auth module" --single-agent opencode --sessions 5

# Check results
acpx-council status

# Execute the plan
acpx-council execute
```

## Quick Start: Single Agent

```bash
# One-shot (no session state)
acpx claude exec "fix the failing tests"

# Persistent multi-turn session
acpx claude sessions new --name worker
acpx claude -s worker "analyze the auth module"
acpx claude -s worker "now refactor it based on your analysis"
```

## Quick Start: Manual Multi-Agent Council

The fastest way to get multiple opinions on a task:

```bash
# 1. Assemble team (create named sessions for each agent)
acpx claude sessions new --name claude-r && acpx codex sessions new --name codex-r && acpx gemini sessions new --name gemini-r

# 2. Round 1: fan-out the same question to all agents in parallel
acpx --format quiet claude -s claude-r "Review src/auth.ts for security vulnerabilities. Be specific." > /tmp/r1-claude.txt &
acpx --format quiet codex -s codex-r "Review src/auth.ts for security vulnerabilities. Be specific." > /tmp/r1-codex.txt &
acpx --format quiet gemini -s gemini-r "Review src/auth.ts for security vulnerabilities. Be specific." > /tmp/r1-gemini.txt &
wait

# 3. Round 2: each agent sees all responses and revises
acpx --format quiet claude -s claude-r "Other reviewers said:\n[Codex]: $(cat /tmp/r1-codex.txt)\n[Gemini]: $(cat /tmp/r1-gemini.txt)\n\nRevise your assessment." > /tmp/r2-claude.txt &
acpx --format quiet codex -s codex-r "Other reviewers said:\n[Claude]: $(cat /tmp/r1-claude.txt)\n[Gemini]: $(cat /tmp/r1-gemini.txt)\n\nRevise your assessment." > /tmp/r2-codex.txt &
acpx --format quiet gemini -s gemini-r "Other reviewers said:\n[Claude]: $(cat /tmp/r1-claude.txt)\n[Codex]: $(cat /tmp/r1-codex.txt)\n\nRevise your assessment." > /tmp/r2-gemini.txt &
wait

# 4. Synthesize (the orchestrator agent does this)
echo "=== Final Reviews ===\n\n[Claude]: $(cat /tmp/r2-claude.txt)\n\n[Codex]: $(cat /tmp/r2-codex.txt)\n\n[Gemini]: $(cat /tmp/r2-gemini.txt)"
```

---

## acpx-council CLI

The `acpx-council` command provides one-line access to all protocols and presets. It manages sessions, workspace, synthesis, and cleanup automatically.

### Commands

```
acpx-council <command> [options] [task]

Commands:
  review <file>        Code review with auto-assigned expert roles
  council <task>       Run a multi-agent council with auto-selected protocol
  debate <task>        Adversarial debate (advocate vs critic + judge)
  synthesize           Synthesize current workspace outputs into consensus
  execute              Execute the plan from current workspace
  status               Show current workspace status
  roles <subcommand>   Manage roles (list, create, infer)
  workspace <subcmd>   Manage workspace (init, cleanup, archive, status)
```

### Options

| Flag | Short | Default | Description |
|------|-------|---------|-------------|
| `--protocol` | `-p` | auto | Protocol: auto\|fanout\|deliberation\|role-council\|adversarial\|pipeline |
| `--agents` | `-a` | auto | Comma-separated agent list (e.g., `claude,codex,gemini`) |
| `--roles` | `-r` | auto | Comma-separated role list (e.g., `security,perf,testing`) |
| `--orchestrator` | `-o` | claude | Agent used for synthesis |
| `--preset` | `-t` | — | Team preset (see below) |
| `--single-agent` | `-s` | — | Use one agent client with multiple sessions |
| `--sessions` | `-n` | 3 | Number of sessions for single-agent mode |
| `--workspace` | `-w` | .acpx-workspace | Workspace directory |

### Plan-First Workflow

Every council protocol follows a two-phase flow:

```
Phase 1: PLAN (all agents in plan mode — analysis only, no code changes)
  → Discuss approach, identify risks, form consensus
  → Output: consensus plan document

Phase 2: EXECUTE (agents switch to execution mode)
  → Implement based on the agreed plan
  → Cross-review results
```

Plan mode is automatically enabled for Phase 1. The council checks consensus after Round 1 — if agents already agree, it skips Round 2 and goes straight to synthesis.

### Examples

```bash
# Auto everything — best for most cases
acpx-council review src/auth.ts

# Specific protocol and agents
acpx-council council "Design caching strategy" -p role-council -a claude,codex,gemini

# Custom roles for a specific domain
acpx-council council "Add Stripe payments" -r security,payments,testing,dx

# Single agent, multiple perspectives (no multi-agent setup needed)
acpx-council council "Review API design" -s opencode -n 4

# Quick fan-out opinion poll
acpx-council council "What testing framework?" -p fanout

# Full adversarial debate
acpx-council debate "Should we use microservices?"
```

---

## Shared Workspace

The council uses `.acpx-workspace/` for inter-agent context sharing:

```
.acpx-workspace/
├── context.md          # Task description, protocol, phase, round
├── plan.md             # Consensus plan from Phase 1
├── decisions.md        # Agreed points, divergences, action items
├── open-questions.md   # Unresolved questions
├── synthesis.md        # Final synthesis from all agent outputs
└── agents/
    ├── claude/
    │   ├── round-1.md  # Claude's Round 1 output
    │   ├── round-2.md  # Claude's Round 2 output
    │   └── latest.md   # Symlink to most recent round
    ├── codex/
    └── gemini/
```

Each agent can read shared context and write to its own directory. The workspace enables:
- **Agent continuity** — agents see their prior rounds via session resume
- **Cross-agent awareness** — Round 2 gathers all outputs from the workspace
- **Synthesis** — orchestrator reads all outputs to produce consensus
- **Archival** — `acpx-council workspace archive` saves workspace for future reference

```bash
acpx-council status        # Show workspace phase, agents, rounds
acpx-council workspace archive auth-review   # Save for later
acpx-council workspace cleanup               # Remove workspace
```

---

## Auto Synthesis

After deliberation rounds, the orchestrator agent automatically analyzes all outputs and produces a structured synthesis:

```markdown
### CONSENSUS
Points where ALL or MOST agents agree.

### DIVERGENCES
Points where agents disagree — with each side's position and evidence assessment.

### ACTION ITEMS
Concrete next steps.

### HUMAN DECISIONS NEEDED
Tradeoffs requiring human judgment — options and implications.

### CONFIDENCE
HIGH / MEDIUM / LOW with justification.

### RECOMMENDATION
One clear recommended path forward.
```

This replaces the manual `echo` / `cat` approach from the original protocol. The synthesis is written to `.acpx-workspace/synthesis.md`.

---

## Dynamic Roles

### Builtin Roles (8)

| Role | Focus | Use When |
|------|-------|----------|
| `security` | Vulnerabilities, auth, data protection | Any code handling user input, auth, PII |
| `architect` | System design, scalability, patterns | Architecture decisions, tech debt |
| `skeptic` | Challenge assumptions, find flaws | Go/no-go decisions, proposals |
| `perf` | Latency, throughput, optimization | Performance-sensitive code |
| `testing` | Coverage, edge cases, regression | Test planning, quality gates |
| `maintainer` | Code quality, readability, long-term | PR reviews, refactoring |
| `dx` | API ergonomics, developer workflow | API design, tooling changes |
| `neutral` | Balanced, no specialization | General tasks |

### Auto Role Inference

Roles are automatically inferred from the task description:

```bash
# Auto-inferring: task mentions "Stripe payment" → roles: security, payments, testing, dx
acpx-council council "Add Stripe payment integration"

# Explicit roles override inference
acpx-council council "Add Redis caching" -r perf,testing,architect
```

Keywords mapped to roles: `security/vulnerability/auth` → security, `performance/latency/caching` → perf, `test/coverage/regression` → testing, etc.

### Custom Roles

Create domain-specific roles for your project:

```bash
# Create a role
acpx-council roles create "database-expert" "Query optimization, indexing, migration safety" "PostgreSQL,Prisma,Drizzle"

# Use it in a council
acpx-council council "Optimize slow queries" -r database-expert,perf,testing

# List all available roles
acpx-council roles list
```

Custom roles are stored in `~/.acpx/roles/` and persist across sessions.

### Community Roles (Planned)

```bash
# Install from community registry (future)
acpx-council roles install @community/stripe-expert
acpx-council roles install @community/a11y-expert
```

---

## Single-Agent Multi-Session

You don't need multiple agent clients. Use `--single-agent` to create multiple sessions of the same agent, each with a different role:

```bash
# OpenCode with 5 different expert perspectives
acpx-council council "Review the auth module" --single-agent opencode --sessions 5

# Under the hood:
#   session 1: opencode with [ROLE: Security Expert]
#   session 2: opencode with [ROLE: Performance Expert]
#   session 3: opencode with [ROLE: Testing Expert]
#   session 4: opencode with [ROLE: Maintainer]
#   session 5: opencode with [ROLE: Skeptic]
```

**When single-agent is enough**: Most code reviews, architecture discussions, and quality assessments. The role prompt is the primary quality driver, not the model identity.

**When multi-agent is better**: When you need genuinely different LLM capabilities (e.g., Claude for complex reasoning + Codex for fast implementation), or when you want model-diverse perspectives to reduce single-model bias.

---

## Agent Profiles

Each agent has a capability profile used for automatic role assignment:

| Agent | Strengths | Preferred Roles |
|-------|-----------|-----------------|
| Claude Code | Complex reasoning, architecture, security | architect, security, maintainer, skeptic |
| Codex | Implementation, testing, algorithmic | testing, maintainer |
| Gemini CLI | Broad knowledge, performance, multimodal | perf, neutral, testing |
| OpenCode | Flexibility, local-first | maintainer, testing, dx |
| OpenClaw | Protocol-native, headless, automation | neutral (can fill any role) |
| Cursor | IDE integration, refactoring | dx, maintainer |
| Copilot | IDE integration, code suggestions | dx, maintainer |

Profiles are defined in `config/agent-profiles.yaml` and used for automatic role assignment when `--roles auto` is set.

---

## Council Protocol

The standard multi-agent collaboration pipeline:

```
PLAN → DELIBERATE → CONVERGE → EXECUTE → REVIEW → DELIVER
 规划   交叉讨论     形成共识    分工执行   交叉审查   交付成果
```

### Step-by-Step

**1. PLAN** — All agents enter plan mode, analyze independently:

```bash
# Automatic via acpx-council — plan mode is the default first phase
acpx-council council "Design a caching layer for our API"
```

**2. DELIBERATE** — Each agent reviews all other responses and revises:

```bash
# Automatic Round 2 — agents see each other's analysis
# Skipped if Round 1 consensus is HIGH
```

**3. CONVERGE** — Orchestrator synthesizes a consensus plan:

```bash
# Automatic synthesis → .acpx-workspace/synthesis.md + plan.md
```

**4. EXECUTE** — Delegate implementation to agents:

```bash
acpx-council execute
# Agents switch from plan mode to acceptEdits mode
```

**5. REVIEW** — Cross-review implementations.

**6. DELIVER** — Final output.

### Adaptive Protocol Selection

When `--protocol auto` (default), the protocol is chosen based on task keywords:

| Task Pattern | Auto-Selected Protocol |
|---|---|
| "review", "audit", "assess" | role-council |
| "should", "decide", "choose", "whether" | adversarial |
| "implement", "build", "create" | role-council |
| "quick", "opinion", "think" | fanout |
| "design", "architect", "plan" | role-council |
| "debug", "fix", "investigate" | pipeline |

### Adaptive Consensus

After Round 1, the council checks agreement level:

| Consensus | Action |
|-----------|--------|
| HIGH (>80% agreement) | Skip Round 2, synthesize immediately |
| MEDIUM (40-80%) | Run Round 2 focused on divergent points |
| LOW (<40%) | Run full Round 2 or upgrade to more rigorous protocol |

---

## Team Presets

Pre-configured role assignments for common scenarios:

| Preset | Roles | Best For |
|---|---|---|
| `code_review` | security, perf, testing, maintainer, dx | PR reviews, quality gates |
| `security_audit` | security, skeptic, architect, dx, testing | Security-sensitive changes |
| `architecture_review` | architect, perf, skeptic, maintainer, testing | Design decisions, tech debt |
| `devil_advocate` | skeptic, skeptic, architect, maintainer | Go/no-go decisions |
| `balanced` | neutral × N | General tasks, no specialization |
| `build_deploy` | architect, testing, maintainer | Feature implementation |

```bash
acpx-council council "Review PR #42" --preset code_review
acpx-council council "Is this API secure?" --preset security_audit
```

---

## Supported Agents

| Agent | Command | Install |
|---|---|---|
| Claude Code | `acpx claude` | `npm i -g @anthropic-ai/claude-code` |
| Codex | `acpx codex` | `npm i -g @openai/codex` |
| OpenCode | `acpx opencode` | `npm i -g opencode-ai` |
| Gemini CLI | `acpx gemini` | `npm i -g @anthropic-ai/gemini-cli` |
| OpenClaw | `acpx openclaw` | `npm i -g @openclaw/acpx` |
| Cursor | `acpx cursor` | Cursor app |
| GitHub Copilot | `acpx copilot` | `npm i -g @githubnext/github-copilot-cli` |
| Pi | `acpx pi` | github.com/mariozechner/pi |
| Qwen Code | `acpx qwen` | `npm i -g @qwen/qwen-code` |

### OpenClaw — The Protocol Foundation

[OpenClaw](https://github.com/openclaw/acpx) is the headless agent client that implements the Agent Client Protocol (ACP). It is the foundation that acpx builds on:

- **ACP Protocol**: OpenClaw provides the standardized protocol for agent-to-agent communication
- **Headless Mode**: Run agents without interactive UI — essential for automation and CI
- **Session Management**: Persistent sessions, mode switching, and lifecycle control
- **Multi-Agent Orchestration**: The underlying infrastructure for acpx's council protocols

If you want to build custom agent integrations or understand how acpx works internally, explore the [OpenClaw repository](https://github.com/openclaw/acpx).

---

## Agent Mode Switching

Set working modes (Claude Code example; other agents may vary):

| Mode | Behavior | Use When |
|---|---|---|
| `plan` | Plan only, no execution | Architecture, analysis (Phase 1 default) |
| `default` | Ask before changes | Standard work |
| `acceptEdits` | Auto-accept edits | Trusted refactoring (Phase 2 default) |
| `dontAsk` | Auto-accept everything | Batch tasks |
| `bypassPermissions` | Skip all checks | CI/automation |

```bash
acpx claude -s worker set-mode plan
acpx claude -s worker set model opus      # or sonnet
```

## Session Management

```bash
acpx claude sessions new --name worker    # create named session
acpx claude sessions ensure               # create if missing
acpx claude sessions list                 # list all
acpx claude sessions show                 # inspect current
acpx claude -s worker sessions history    # recent turns
acpx claude -s worker status              # pid, uptime
acpx claude sessions close worker         # soft-close (keeps history)
```

## Output & Permissions

```bash
# Output formats
acpx --format quiet claude exec "task"    # final text only
acpx --format json claude exec "task"     # NDJSON stream

# Permissions
acpx --approve-all claude -s w "task"     # auto-approve all
acpx --approve-reads claude -s w "task"   # auto-approve reads
acpx --deny-all claude -s w "task"        # analysis only

# Lifecycle
acpx --cwd ~/repo claude "task"           # set working directory
acpx --timeout 300 claude "task"          # set timeout (seconds)
acpx --no-wait claude -s w "task"         # fire-and-forget
acpx claude -s w cancel                   # cancel in-flight prompt
```

## Bidirectional Communication

Any agent can call any other agent through acpx:

```bash
# From OpenCode → Claude Code
acpx claude -s worker "review src/auth.ts"

# From Claude Code → OpenCode
acpx opencode -s helper "analyze test results"

# From any → Codex → Gemini (chain)
acpx codex -s coder "implement X" && acpx gemini -s reviewer "review: $(cat result.txt)"
```

---

## Reference Files

- **`references/roles.md`** — All 8 builtin role definitions with Round 1 and Round 2 prompt prefixes, plus team presets with agent-to-role mappings.
- **`references/protocols.md`** — 7 collaboration patterns with decision matrix and cost estimates.
- **`config/agent-profiles.yaml`** — Agent capability definitions for automatic role assignment.
- **`config/role-templates/`** — Custom role templates directory.
- **`lib/workspace.sh`** — Shared workspace management (init, read, write, archive).
- **`lib/synthesize.sh`** — Auto consensus detection and structured synthesis.
- **`lib/roles.sh`** — Dynamic role management (builtin, custom, auto-inference).
- **`lib/protocols.sh`** — Protocol implementations with plan-first flow.
- **`bin/acpx-council`** — High-level CLI for one-command council invocation.

## Gotchas

- **Mode not settable at creation**: Use `set-mode` after `sessions new`
- **session/update warnings**: Claude Code adapter may emit `Invalid params` — harmless
- **Dead session recovery**: acpx auto-detects and reconnects, replaying mode settings
- **No direct agent-to-agent messaging**: All communication goes through the orchestrator
- **`--format quiet` is essential for piping**: Returns only final text, no tool calls or thinking
- **2 rounds is optimal**: Research shows diminishing returns beyond 2 deliberation rounds
- **Session resume preserves context**: Use the same `-s name` across rounds for continuity
- **Plan mode first**: `acpx-council` always starts in plan mode — agents analyze before executing
- **Single-agent works**: Use `--single-agent` when you only have one agent client installed
- **Workspace is per-directory**: `.acpx-workspace/` is created in the current directory

<!-- acpx-skill · https://github.com/csuwl/acpx-skill -->

<!-- acpx-skill by csuwl · https://github.com/csuwl/acpx-skill -->
