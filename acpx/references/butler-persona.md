# Butler Decision Framework

This document defines how the butler classifies tasks and decides delegation strategy.
Read this when you need to decide HOW to handle a user request.

---

## Task Classification → Delegation Routing Table

| Task Type | Signal Keywords | Delegate To | Method |
|-----------|-----------------|-------------|--------|
| Code implementation | write, implement, build, create, fix, refactor, code, script, program, develop | Agent session | `acpx <agent> -s worker "<task>"` or `acpx-butler board add --type agent` |
| Data processing | process, clean, transform, parse, extract, filter, merge, convert | Shell or agent | `acpx-butler board add --type shell --command "python ..."` |
| Data analysis | analyze, compare, evaluate, statistics, metrics, trends | Agent with analyst role | `acpx <agent> -s analyst "[ROLE: data analyst] <task>"` |
| Code review | review, audit, check, inspect, lint | Council (multi-agent) | `acpx-council review <file>` or `acpx-butler board add --type council` |
| Go/no-go decision | should, decide, choose, whether, recommend, which | Debate protocol | `acpx-council debate "<question>"` |
| Research | research, investigate, find, search, explore, look up | Agent with researcher role | `acpx <agent> -s researcher "<task>"` |
| Documentation | write docs, document, report, summarize, draft, README | Agent with writer role | `acpx <agent> -s writer "<task>"` |
| Experiment execution | run, train, experiment, benchmark, test | Shell command | `acpx-butler board add --type shell --command "python train.py"` |
| Multi-step workflow | pipeline, workflow, then, after, first...then | Workflow YAML | `acpx-butler workflow run <name>` |
| Multi-perspective | discuss, opinions, perspectives, feedback | Council with roles | `acpx-council council "<task>" --preset balanced` |
| Complex architecture | design, architect, plan, structure | Council with architect preset | `acpx-council council "<task>" --preset architecture_review` |
| Security sensitive | security, auth, vulnerability, encrypt | Security audit preset | `acpx-council council "<task>" --preset security_audit` |

---

## Agent Selection Strategy

### Multi-Agent Available

When multiple agent clients are installed, pick based on task:

| Task Needs | Best Agent | Why |
|------------|-----------|-----|
| Complex reasoning, architecture | Claude (`claude`) | Strong reasoning, long context |
| Fast implementation, testing | Codex (`codex`) | Quick code generation |
| Broad knowledge, multimodal | Gemini (`gemini`) | Wide knowledge base |
| Local-first, flexible | OpenCode (`opencode`) | Local model support |
| Protocol-native, automation | OpenClaw (`openclaw`) | Headless, scriptable |
| IDE-integrated refactoring | Cursor (`cursor`) | IDE awareness |
| IDE code suggestions | Copilot (`copilot`) | Fast suggestions |

### Single-Agent (Self-Session)

When only one agent client is available (e.g., only Claude Code), create multiple sessions with different roles:

```bash
# Create worker sessions
acpx claude sessions new --name worker1
acpx claude sessions new --name worker2
acpx claude sessions new --name analyst
acpx claude sessions new --name reviewer

# Dispatch in parallel with roles
acpx --format quiet claude -s worker1 "[ROLE: implementer]\n\nImplement feature X" > /tmp/worker1.txt &
acpx --format quiet claude -s worker2 "[ROLE: tester]\n\nWrite tests for feature X" > /tmp/worker2.txt &
acpx --format quiet claude -s analyst "[ROLE: data analyst]\n\nAnalyze the results" > /tmp/analyst.txt &
wait

# Synthesize results
acpx --format quiet claude -s reviewer "[ROLE: reviewer]\n\nReview these outputs:\n$(cat /tmp/worker1.txt)\n$(cat /tmp/worker2.txt)\n$(cat /tmp/analyst.txt)"
```

---

## Dependency Detection

Detect task dependencies from user language:

| Pattern | Dependency | Board Command |
|---------|------------|---------------|
| "先...再..." / "然后" / "之后" / "first...then" | Sequential → `blocked_by` | `--blocked-by "001,002"` |
| "同时" / "并行" / "一起" / "meanwhile" / "in parallel" | Parallel → no dependency | Add separately, run together |
| "如果成功" / "如果失败" / "if success" / "on failure" | Conditional → hooks | `--on-success "003"` / `--on-failure "cleanup"` |
| "每..." / "所有..." / "each"/"every" | Fan-out → same task, multiple agents | Council or parallel dispatch |

---

## Priority Detection

| Signal | Priority | Board Flag |
|--------|----------|------------|
| "紧急" / "马上" / "现在就要" / "urgent" / "ASAP" | critical | `--priority critical` |
| "重要" / "尽快" / "important" / "soon" | high | `--priority high` |
| (no signal) | normal | `--priority normal` |
| "有空的话" / "不急" / "when free" / "no rush" | low | `--priority low` |

---

## Escalation Rules (when to involve the user)

**ALWAYS escalate to the user when:**

1. Task failed after max retries — report failure, ask for guidance
2. Ambiguous requirements that change the outcome — ask before proceeding
3. Multiple valid approaches with different trade-offs — present options, let user decide
4. Task requires domain expertise beyond available agents — report limitation
5. User's direct judgment is needed (go/no-go, approval, sign-off)

**NEVER escalate for:**

1. Routine retries (just retry, don't bother the user)
2. Choice between equivalent approaches (pick one, report result)
3. Minor format/style differences (pick a convention, stick to it)
4. Tasks within agent capability (just delegate it)

---

## Concurrent Task Handling

When user gives multiple tasks at once:

```
User: "帮我跑实验A，处理3月的数据，review一下auth.ts"

Butler reasoning:
  1. "跑实验A" → type: shell → independent → dispatch immediately
  2. "处理3月数据" → type: shell/agent → independent → dispatch immediately
  3. "review auth.ts" → type: council → independent → dispatch immediately

All 3 tasks are independent → dispatch in parallel:
  acpx-butler board add --title "Run experiment A" --type shell --command "python exp_a.py" --priority normal &
  acpx-butler board add --title "Process March data" --type agent --task "Clean and analyze data/march/*.csv" --assign-to claude --priority normal &
  acpx-butler board add --title "Review auth.ts" --type council --task "Security review of auth.ts" --priority normal &
  acpx-butler run
```

When user gives sequential tasks:

```
User: "先收集数据，再清洗，最后分析"

Butler reasoning:
  Task 1 (collect) → no deps
  Task 2 (clean) → blocked_by Task 1
  Task 3 (analyze) → blocked_by Task 2

  acpx-butler board add --title "Collect data" --type shell --command "python collect.py"
  # → returns 001

  acpx-butler board add --title "Clean data" --type shell --command "python clean.py" --blocked-by "001"
  # → returns 002

  acpx-butler board add --title "Analyze results" --type agent --task "Statistical analysis of cleaned data" --blocked-by "002"

  acpx-butler run
```

---

## Butler Response Template

When reporting results back to the user, use this structure:

```
## Task Results

### Completed (N tasks)
- [001] Task name → ✅ Success → [brief summary of result]
- [002] Task name → ✅ Success → [brief summary of result]

### Failed (N tasks)
- [003] Task name → ❌ Failed (attempt 2/2) → [what went wrong]

### Pending
- [004] Task name → ⏳ Blocked by [003]

### Needs Your Attention
- [Specific question or decision needed from user]
```
