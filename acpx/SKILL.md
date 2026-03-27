---
name: acpx
description: Delegate work to Claude Code, Codex, OpenCode, and other AI coding agents via the Agent Client Protocol (ACP) using acpx. Use when the user wants to delegate coding tasks to another agent, run parallel agent workstreams, switch Claude Code modes (plan/execute), communicate bidirectionally between agents, or orchestrate multi-agent collaboration. Triggers include "delegate to Claude", "use Claude Code", "ask Claude to", "run in Claude", "parallel agents", "acpx", "ACP", "agent delegation", "tell Claude to", "have Claude review/implement/fix", or any request to involve another coding agent.
---

# acpx — Inter-Agent Delegation via ACP

Delegate coding tasks to Claude Code, Codex, OpenCode, Gemini CLI, and other ACP-compatible agents directly from the command line. No PTY scraping — structured protocol communication.

## Prerequisites

```bash
npm i -g acpx@latest
```

Claude Code must also be installed (`npm i -g @anthropic-ai/claude-code`) if delegating to it.

## Quick Start

```bash
# One-shot task (no session state)
acpx claude exec "fix the failing tests"

# Persistent session for multi-turn work
acpx claude sessions new --name worker
acpx claude -s worker "analyze the auth module"
acpx claude -s worker "now refactor it based on your analysis"

# Parallel named sessions
acpx claude sessions new --name frontend
acpx claude sessions new --name backend
acpx claude -s frontend "build the login page"
acpx claude -s backend "implement the auth API"
```

## Supported Agents

| Agent | Command | Wraps |
|---|---|---|
| Claude Code | `acpx claude` | Claude Code CLI |
| Codex | `acpx codex` | OpenAI Codex CLI |
| OpenCode | `acpx opencode` | OpenCode |
| Gemini CLI | `acpx gemini` | Google Gemini CLI |
| Cursor | `acpx cursor` | Cursor CLI |
| GitHub Copilot | `acpx copilot` | GitHub Copilot CLI |
| Pi | `acpx pi` | Pi Coding Agent |

## Claude Code Mode Switching

Set Claude Code's working mode via acpx. Modes are permission profiles that control agent behavior:

| Mode | Behavior | Use When |
|---|---|---|
| `plan` | Plan only, no execution | Architecture decisions, complex analysis |
| `default` | Ask before changes | Standard interactive work |
| `acceptEdits` | Auto-accept edits | Trusted refactoring |
| `dontAsk` | Auto-accept everything | Batch tasks, trusted agent |
| `bypassPermissions` | Skip all checks | CI/automation (not as root) |

```bash
# Switch modes (both commands are equivalent)
acpx claude -s worker set-mode plan
acpx claude -s worker set mode plan

# Switch model
acpx claude -s worker set model opus
acpx claude -s worker set model sonnet
```

Mode persists across reconnections — acpx replays the desired mode when a dead session is detected.

## Session Management

```bash
# Create / ensure sessions
acpx claude sessions new                       # default session
acpx claude sessions new --name review         # named session
acpx claude sessions ensure                    # idempotent (create if missing)

# List / inspect
acpx claude sessions list                     # all sessions
acpx claude sessions show                     # current session metadata
acpx claude sessions history --limit 10        # recent turn history

# Status check
acpx claude -s worker status                  # pid, uptime, last prompt

# Lifecycle
acpx claude sessions close                    # soft-close (keeps history)
acpx claude sessions close worker             # close named session
```

## Prompt Patterns

```bash
# Direct prompt
acpx claude -s worker "implement user signup flow"

# From file
acpx claude -s worker --file task.md

# From stdin
echo "review this code" | acpx claude -s worker

# Fire-and-forget (don't wait for completion)
acpx claude -s worker --no-wait "run full test suite"

# With specific working directory
acpx --cwd ~/projects/myapp claude "fix the bug"

# Cancel in-flight prompt
acpx claude -s worker cancel
```

## Permission Flags

```bash
# Auto-approve all tool calls (recommended for delegation)
acpx --approve-all claude -s worker "implement feature X"

# Auto-approve reads only
acpx --approve-reads claude -s worker "analyze this repo"

# Deny all (analysis only)
acpx --deny-all claude -s worker "explain the architecture"
```

## Output Formats

```bash
# Human-readable stream (default)
acpx claude -s worker "task"

# JSON stream for scripting
acpx --format json claude exec "summarize this repo"

# Final text only (no intermediate output)
acpx --format quiet claude exec "one-line summary"
```

## Parallel Delegation Pattern

For complex tasks requiring multiple agents working simultaneously:

```bash
# Step 1: Create parallel sessions
acpx claude sessions new --name planner
acpx claude sessions new --name implementer
acpx claude sessions new --name tester

# Step 2: Set modes
acpx claude -s planner set mode plan
acpx claude -s implementer set mode acceptEdits
acpx claude -s tester set mode dontAsk

# Step 3: Delegate in parallel
acpx --approve-all claude -s planner "design the caching layer"
acpx --approve-all claude -s implementer "implement the auth middleware"
acpx --no-wait claude -s tester "write tests for the API endpoints"

# Step 4: Collect results
acpx claude -s planner sessions history
acpx claude -s implementer sessions history
acpx claude -s tester sessions history
```

## Bidirectional Communication

acpx supports full bidirectional agent-to-agent communication:

```bash
# OpenCode -> Claude Code
acpx claude -s worker "review src/auth.ts for security issues"

# Claude Code -> OpenCode (from any ACP-compatible harness)
acpx opencode -s helper "analyze the test results and summarize failures"
```

## Config

```bash
# Show resolved config
acpx config show

# Create default config template
acpx config init

# Or edit manually at ~/.acpx/config.json
```

Session state lives in `~/.acpx/sessions/`.

## Timeout and Lifecycle

```bash
# Set execution timeout (seconds)
acpx --timeout 300 claude "long running task"

# Keep queue owner alive for follow-ups
acpx --ttl 60 claude "task"
```

## Gotchas

- **Mode not settable at creation**: Use `set-mode` after `sessions new`, not as a creation flag
- **session/update warnings**: Claude Code adapter may emit `Invalid params` on `session/update` — harmless, does not affect functionality
- **Dead session recovery**: acpx auto-detects dead agent processes and reconnects, replaying mode settings
- **Queue awareness**: If a prompt is running, new prompts queue automatically and execute in order
