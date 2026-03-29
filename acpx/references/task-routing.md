# Task Routing Reference

Command templates and dispatch patterns for the butler.
Use these patterns when you need to write the actual acpx commands to delegate work.

---

## Dispatch Methods (4 tiers)

### Tier 1: Quick Dispatch — Simple one-liner

For simple, immediate tasks that don't need tracking:

```bash
# Single agent, one-shot
acpx claude exec "implement feature X in src/module.ts"

# Parallel agents
acpx claude exec "task A" & acpx codex exec "task B" & wait

# With role prompt
acpx claude -s worker "[ROLE: security expert]\n\nReview src/auth.ts for vulnerabilities"
```

**Use when:** Simple task, no dependencies, no need for retry tracking.

---

### Tier 2: Board Dispatch — Tracked with retry/dependencies

For important tasks or tasks with dependencies:

```bash
# Initialize board (first time only)
acpx-butler board init

# Add tasks
acpx-butler board add \
  --title "Implement auth module" \
  --type agent \
  --task "Implement JWT authentication in src/auth.ts with refresh token support" \
  --assign-to claude \
  --role "security" \
  --priority high \
  --tags "auth,security"

acpx-butler board add \
  --title "Write auth tests" \
  --type agent \
  --task "Write comprehensive tests for the auth module" \
  --assign-to codex \
  --role "testing" \
  --blocked-by "001" \
  --on-success "003"

# Execute
acpx-butler do 001     # single task
acpx-butler run         # all pending
acpx-butler run --limit 3  # up to 3 tasks
```

**Use when:** Task needs tracking, retries, dependency chains, or priority scheduling.

---

### Tier 3: Council Dispatch — Multi-agent deliberation

For decisions, reviews, and complex analysis:

```bash
# Auto-select everything
acpx-council review src/auth.ts

# Specific protocol
acpx-council council "Design caching strategy" -p role-council -a claude,codex,gemini

# Adversarial debate for decisions
acpx-council debate "Should we use microservices?"

# With preset
acpx-council council "Review login flow" --preset security_audit

# Custom roles
acpx-council council "Add Stripe payments" -r security,payments,testing,dx

# Single agent, multiple perspectives
acpx-council council "Review API design" --single-agent opencode --sessions 4

# Check results
acpx-council status

# Execute the plan
acpx-council execute
```

**Use when:** Multiple perspectives needed, go/no-go decisions, architecture discussions, code reviews.

---

### Tier 4: Workflow Dispatch — Multi-step pipelines

For ordered sequences with branching logic:

```bash
# Define workflow in .butler/workflows/<name>.yaml
acpx-butler workflow run experiment-pipeline config=A output_dir=results/A
```

**Workflow YAML template:**

```yaml
name: experiment-pipeline
description: "Collect → process → analyze → report"

steps:
  - id: collect
    type: shell
    command: "python scripts/collect.py --config {{config}}"
    on_success: process

  - id: process
    type: shell
    command: "python scripts/process.py --input {{output_dir}}"
    on_success: analyze

  - id: analyze
    type: agent
    task: "Analyze the experiment results in {{output_dir}}. Provide statistical conclusions, key findings, and recommendations for next steps."
    assign_to: claude
    role: "data analyst"
    on_success: report

  - id: report
    type: agent
    task: "Generate a PDF report summarizing the experiment: methodology, results, statistical analysis, and recommendations. Save to {{output_dir}}/report.md"
    assign_to: claude
    role: "technical writer"
    on_success: done

  - id: done
    type: done
```

**Use when:** Multi-step process with clear stages, conditional branching, or reusable pipelines.

---

## Decision Tree: Which Tier?

```
User gives task
  → Is it a simple one-off? → Tier 1 (quick dispatch)
  → Does it need tracking/retry? → Tier 2 (board dispatch)
  → Is it a multi-step pipeline? → Tier 4 (workflow dispatch)
  → Need multiple perspectives? → Tier 3 (council dispatch)
  → Not sure? → Tier 2 (board dispatch — safest default)
```

---

## Common Patterns

### Pattern: Parallel Independent Tasks

```bash
# User: "同时跑实验A、B、C"
acpx-butler board add --title "Experiment A" --type shell --command "python exp.py --config A" &
acpx-butler board add --title "Experiment B" --type shell --command "python exp.py --config B" &
acpx-butler board add --title "Experiment C" --type shell --command "python exp.py --config C" &
acpx-butler run
```

### Pattern: Sequential Pipeline

```bash
# User: "先收集数据，再清洗，最后分析"
ID1=$(acpx-butler board add --title "Collect data" --type shell --command "python collect.py")
ID2=$(acpx-butler board add --title "Clean data" --type shell --command "python clean.py" --blocked-by "$ID1")
ID3=$(acpx-butler board add --title "Analyze" --type agent --task "Analyze cleaned data" --assign-to claude --blocked-by "$ID2")
acpx-butler run
```

### Pattern: Review Then Implement

```bash
# User: "review一下这个设计，没问题就开始实现"
acpx-council council "Review the API design" --preset architecture_review
# After council reaches consensus:
acpx-council execute
```

### Pattern: Experiment with Auto-Analysis

```bash
# User: "跑一下实验，结果出来后帮我分析"
acpx-butler board add \
  --title "Run experiment" \
  --type shell \
  --command "python train.py --config experiment.yaml" \
  --on-success "analyze-results"

# The on_success hook moves the analyze task to inbox
acpx-butler board add \
  --title "Analyze results" \
  --type agent \
  --task "Analyze the experiment output. Provide statistical conclusions and recommendations." \
  --assign-to claude \
  --role "data analyst" \
  --blocked-by "001"

acpx-butler run
```

### Pattern: Self-Session Parallel (single agent client)

```bash
# User: "帮我同时分析三组实验数据"
acpx claude sessions new --name analyst-1
acpx claude sessions new --name analyst-2
acpx claude sessions new --name analyst-3

acpx --format quiet claude -s analyst-1 "Analyze experiment A results in results/A/" > /tmp/a1.txt &
acpx --format quiet claude -s analyst-2 "Analyze experiment B results in results/B/" > /tmp/a2.txt &
acpx --format quiet claude -s analyst-3 "Analyze experiment C results in results/C/" > /tmp/a3.txt &
wait

# Synthesize
acpx --format quiet claude exec "Compare and synthesize these three analyses:\nA: $(cat /tmp/a1.txt)\nB: $(cat /tmp/a2.txt)\nC: $(cat /tmp/a3.txt)"

acpx claude sessions close analyst-1
acpx claude sessions close analyst-2
acpx claude sessions close analyst-3
```

---

## Monitoring Commands

```bash
# Check board status
acpx-butler board list
acpx-butler board list --status active
acpx-butler board list --tag experiment
acpx-butler board stats

# Check specific task
acpx-butler board show <id>

# Health check
acpx-butler health

# Progress report
acpx-butler report today
acpx-butler report weekly
```
