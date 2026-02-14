# Autonomous Multi-Agent Coordinator

## Overview

Unlike the basic `orchestrate.sh` (sequential pipeline), `coordinator.sh` runs agents in an **autonomous feedback loop** where they communicate, delegate tasks, and iterate until the work is approved.

## Flow

```
                    ┌─────────────┐
             ┌─────│   PLANNER   │─────┐
             │     └─────────────┘     │
             │          │ plan.md      │
             │          ▼              │
             │     ┌─────────────┐     │
     replan  │     │  EXECUTOR   │     │ re-consult on
     request │     └─────────────┘     │ major issues
             │          │ code changes │
             │          ▼              │
             │     ┌─────────────┐     │
             │     │  REVIEWER   │─────┘
             │     └──────┬──────┘
             │            │
             │     ┌──────┴──────┐
             │     │             │
             ▼   APPROVED    NEEDS_CHANGES
            DONE     ✓      │
                            │ feedback
                            ▼
                     ┌─────────────┐
                     │  EXECUTOR   │ ← fixes issues
                     └──────┬──────┘
                            │
                            ▼
                     ┌─────────────┐
                     │  REVIEWER   │ ← re-checks
                     └──────┬──────┘
                            │
                     APPROVED or loop again
                     (max N iterations)
```

## Key Features

### 1. Message Bus
All agents communicate through a file-based message bus at `<project>/.agentic/bus/`. Every message is a timestamped markdown file that any agent can read.

### 2. Feedback Loop
When the reviewer says `NEEDS_CHANGES`, the executor automatically gets the feedback and tries again. No human intervention needed.

### 3. Planner Re-consultation
If the reviewer flags `BLOCKER`, `ARCHITECTURE`, or `FUNDAMENTAL` issues, the coordinator automatically re-consults the planner to update the plan before the executor tries again.

### 4. Session History
All messages, prompts, and outputs are saved to `<project>/.codeswarm/sessions/<session_id>/`, creating a full audit trail.

### 5. Configurable Iterations
Set `--max-iterations` to control how many execute→review cycles are allowed (default: 5).

## Usage

### Basic

```bash
./coordinator.sh \
  --project ~/IdeaProjects/blue-flow \
  --task "Add leave approval notification endpoint"
```

### Custom Agents & Models

```bash
./coordinator.sh \
  --project ~/IdeaProjects/blue-flow \
  --task "Implement İşe Başlayan Personel Girişi process" \
  --planner codex --planner-model gpt-5.3 \
  --executor claude --executor-model opus \
  --reviewer gemini \
  --context "İşe Başlayan Personel Girişi.xml" \
  --max-iterations 5
```

### With Context Files

```bash
./coordinator.sh \
  --project ~/IdeaProjects/blue-flow \
  --task "Implement the leave process from XML" \
  --context "IdariPersonelIzinSureci.xml,src/main/java/com/app/blue/domain/Leave.java"
```

### Verbose Mode

```bash
./coordinator.sh \
  --project ~/IdeaProjects/blue-flow \
  --task "Fix bug in process engine" \
  --verbose
```

### Dry Run (see commands without executing)

```bash
./coordinator.sh \
  --project ~/IdeaProjects/blue-flow \
  --task "Test task" \
  --dry-run
```

## Session Artifacts

After a run, you'll find:

```
<project>/.agentic/
├── plan.md                         # Current plan
├── execution.log                   # Latest executor output
├── review.md                       # Latest review
├── report-<timestamp>.md           # Final summary report
└── sessions/session_<timestamp>/
    ├── coordinator.log             # Full coordinator log
    ├── msg_001_planner_to_executor.md
    ├── msg_002_executor_to_reviewer.md
    ├── msg_003_reviewer_to_executor.md  # Feedback
    ├── msg_004_executor_to_reviewer.md  # Re-implementation
    ├── msg_005_reviewer_to_executor.md  # APPROVED!
    ├── prompt_codex_iter1.md       # Exact prompts sent
    ├── output_codex_iter1.md       # Exact outputs received
    ├── output_claude_iter1.md
    ├── output_gemini_iter1.md
    └── ...
```

## CLI Reference

| Flag | Description | Default |
|------|-------------|---------|
| `--project` | Target project directory | required |
| `--task` | Task description | required |
| `--planner` | Agent for planning | codex |
| `--executor` | Agent for execution | claude |
| `--reviewer` | Agent for review | gemini |
| `--planner-model` | Model for planner | (default) |
| `--executor-model` | Model for executor | (default) |
| `--reviewer-model` | Model for reviewer | (default) |
| `--context` | Comma-separated context files | none |
| `--max-iterations` | Max execute→review cycles | 5 |
| `--verbose` | Show full agent output | false |
| `--dry-run` | Print commands only | false |


