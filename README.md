# acpx-skill

Multi-agent collaboration skill for AI coding agents. Form agent teams, run deliberations, build consensus, and delegate work — all through the Agent Client Protocol (ACP).

Works with any ACP-compatible agent: Claude Code, Codex, OpenCode, Gemini CLI, Cursor, Copilot, OpenClaw, and more.

## Install

```bash
npm i -g acpx-skill
```

Requires [acpx](https://www.npmjs.com/package/acpx) and at least one agent client (e.g. `npm i -g @anthropic-ai/claude-code`).

## Quick Start

```bash
# Code review with auto-assigned expert roles
acpx-council review src/auth.ts

# Ask a multi-agent council anything
acpx-council council "Should we use Redis or Memcached for session caching?"

# Adversarial debate for go/no-go decisions
acpx-council debate "Migrate from REST to tRPC?"

# Single agent with 5 role-playing sessions (no multi-agent setup needed)
acpx-council council "Refactor auth module" --single-agent opencode --sessions 5
```

## How It Works

1. **PLAN** — All agents analyze the task independently (plan mode, no code changes)
2. **DELIBERATE** — Agents review each other's analysis and revise
3. **CONVERGE** — Orchestrator synthesizes consensus with action items
4. **EXECUTE** — Agents implement based on the agreed plan

```
acpx-council council "Design caching strategy"
  → Round 1: 3 agents analyze independently
  → Round 2: agents review each other's analysis
  → Synthesis: consensus plan with action items
  → acpx-council execute  # implement the plan
```

## Key Features

- **Auto protocol selection** — `review`/`audit` → role-council, `should`/`decide` → adversarial, `quick`/`opinion` → fanout
- **Dynamic roles** — 8 builtin roles (security, architect, skeptic, perf, testing, maintainer, dx, neutral) + custom roles
- **Auto role inference** — task keywords map to relevant roles automatically
- **Adaptive consensus** — skip Round 2 if agents already agree (>80%), or escalate if they disagree
- **Team presets** — `code_review`, `security_audit`, `architecture_review`, `devil_advocate`, `balanced`, `build_deploy`
- **Single-agent mode** — one agent client with multiple role-playing sessions
- **Shared workspace** — `.acpx-workspace/` for inter-agent context sharing

## CLI Reference

```
acpx-council <command> [options] [task]

Commands:
  review <file>        Code review with auto-assigned expert roles
  council <task>       Multi-agent council with auto-selected protocol
  debate <task>        Adversarial debate (advocate vs critic + judge)
  synthesize           Synthesize workspace outputs into consensus
  execute              Execute the plan from current workspace
  status               Show current workspace status
  roles <subcommand>   Manage roles (list, create, infer)
  workspace <subcmd>   Manage workspace (init, cleanup, archive, status)

Options:
  -p, --protocol       auto|fanout|deliberation|role-council|adversarial|pipeline
  -a, --agents         auto|comma-separated (e.g. claude,codex,gemini)
  -r, --roles          auto|comma-separated (e.g. security,perf,testing)
  -o, --orchestrator   Synthesis agent (default: claude)
  -t, --preset         Team preset (code_review, security_audit, etc.)
  -s, --single-agent   Use one agent with multiple sessions (e.g. opencode)
  -n, --sessions       Number of sessions for single-agent mode (default: 3)
  -w, --workspace      Workspace directory (default: .acpx-workspace)
```

## Supported Agents

| Agent | Install |
|---|---|
| Claude Code | `npm i -g @anthropic-ai/claude-code` |
| Codex | `npm i -g @openai/codex` |
| OpenCode | `npm i -g opencode-ai` |
| Gemini CLI | `npm i -g @anthropic-ai/gemini-cli` |
| OpenClaw | `npm i -g @openclaw/acpx` |
| Cursor | Cursor app |
| GitHub Copilot | `npm i -g @githubnext/github-copilot-cli` |
| Qwen Code | `npm i -g @qwen/qwen-code` |

## Examples

```bash
# Security audit preset
acpx-council council "Review login flow" --preset security_audit

# Custom roles for a specific domain
acpx-council council "Add Stripe payments" -r security,payments,testing,dx

# Specific protocol and agents
acpx-council council "Design caching strategy" -p role-council -a claude,codex,gemini

# Create a custom role
acpx-council roles create "database-expert" "Query optimization" "PostgreSQL,Prisma"

# Check workspace status
acpx-council status

# Archive workspace for later
acpx-council workspace archive auth-review
```

## License

MIT
