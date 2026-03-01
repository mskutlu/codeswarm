# GSD Pipeline — Autonomous Multi-Agent Development

> Combines **GSD's methodology** (research → plan → execute → verify) with **Codeswarm's multi-agent orchestration** (any AI provider, parallel execution, dashboard).

## The Problem

| Tool | Strength | Weakness |
|------|----------|----------|
| **GSD** | Deep planning, research, context engineering, verification | Single agent (Claude only), asks too many questions, not autonomous |
| **Codeswarm** | Multi-agent, any AI provider, parallel, autonomous | Simple planning, no research, no verification loop |

## The Solution

The GSD Pipeline takes GSD's proven methodology and makes it:
- **Multi-agent** — different AI providers for different roles
- **Fully autonomous** — no questions asked, planner makes all decisions
- **Modular** — run the full pipeline or individual modules

## Architecture

```
┌──────────────────────────────────────────────────────────┐
│  GSD PIPELINE                                             │
│                                                           │
│  ┌─── context.sh ──────────────────────────────────────┐ │
│  │  Planner auto-generates PROJECT.md, ROADMAP.md,     │ │
│  │  REQUIREMENTS.md, CONTEXT.md — no questions asked    │ │
│  └─────────────────────────────────────────────────────┘ │
│                          ↓                                │
│  ┌─── research.sh ─────────────────────────────────────┐ │
│  │  4 agents run in parallel (any provider):            │ │
│  │  • Stack → gemini    • Features → claude             │ │
│  │  • Architecture → codex  • Pitfalls → gemini         │ │
│  │  → Synthesized into RESEARCH.md                      │ │
│  └─────────────────────────────────────────────────────┘ │
│                          ↓                                │
│  ┌─── plan.sh ─────────────────────────────────────────┐ │
│  │  Planner creates XML plans → Checker verifies        │ │
│  │  Iterate until plans pass (max 3 rounds)             │ │
│  │  Plans grouped into dependency waves                 │ │
│  └─────────────────────────────────────────────────────┘ │
│                          ↓                                │
│  ┌─── execute.sh ──────────────────────────────────────┐ │
│  │  WAVE 1 (parallel): Plan-01 → claude                │ │
│  │                      Plan-02 → gemini                │ │
│  │  WAVE 2 (sequential after wave 1):                   │ │
│  │                      Plan-03 → codex                 │ │
│  │  Each agent = fresh context, atomic commits          │ │
│  │  Optional: parallel reviewers after each wave        │ │
│  └─────────────────────────────────────────────────────┘ │
│                          ↓                                │
│  ┌─── verify.sh ───────────────────────────────────────┐ │
│  │  Verifier checks deliverables vs requirements        │ │
│  │  If FAIL → auto-generate fix plans → re-execute      │ │
│  │  If PASS → finalize phase, git tag, update state     │ │
│  └─────────────────────────────────────────────────────┘ │
│                                                           │
│  Dashboard tracks everything in real-time                 │
└──────────────────────────────────────────────────────────┘
```

## Quick Start

```bash
# Full autonomous pipeline
./gsd.sh --project ~/my-app --task "Add user authentication with JWT"

# With PRD file
./gsd.sh --project ~/my-app --prd docs/feature.md

# Multi-agent power run
./gsd.sh --project ~/my-app --prd docs/prd.md \
  --planner claude \
  --executor gemini,claude,codex \
  --reviewer codex \
  --researcher gemini,claude,codex,gemini \
  --dashboard

# Via npm global binary
codeswarm gsd --project ~/my-app --task "Add auth"
```

## Modules

Each module can run independently or as part of the full pipeline.

### context.sh — Auto-Context Generation
Replaces GSD's `discuss-phase` (which asks 20+ questions) with autonomous context generation.

```bash
./gsd.sh --project ~/app --only context --task "Add JWT authentication"
```

**Creates:**
- `PROJECT.md` — project vision, tech stack, architecture
- `REQUIREMENTS.md` — scoped v1/v2 requirements
- `ROADMAP.md` — phased implementation plan
- `CONTEXT.md` — implementation decisions (autonomous)
- `STATE.md` — progress tracking

### research.sh — Parallel Multi-Agent Research
Runs 4 research agents in parallel, each investigating a different aspect.

```bash
./gsd.sh --project ~/app --only research --phase 1 \
  --researcher gemini,claude,codex,gemini
```

**Agents:**
1. **Stack** — dependencies, versions, compatibility
2. **Features** — existing patterns, reusable components
3. **Architecture** — integration points, schema changes
4. **Pitfalls** — edge cases, common issues

**Creates:** `{phase}-RESEARCH.md`

### plan.sh — Structured Planning with Verification
Creates XML-structured plans (GSD format) and verifies them with a checker agent.

```bash
./gsd.sh --project ~/app --only plan --phase 1 \
  --planner claude --checker codex
```

**Loop:** Planner creates plans → Checker verifies → iterate until PASS (max 3 rounds)

**Creates:** `{phase}-{N}-PLAN.md` (1-3 plan files per phase)

### execute.sh — Wave-Based Multi-Agent Execution
Executes plans in dependency-aware waves with parallel agents.

```bash
./gsd.sh --project ~/app --only execute --phase 1 \
  --executor claude,gemini --reviewer codex
```

**Features:**
- Plans round-robin across executors
- Same-wave plans run in parallel
- Each agent gets fresh context
- Atomic git commits per task
- Optional parallel review after each wave

**Creates:** `{phase}-{N}-SUMMARY.md` per plan

### verify.sh — Post-Execution Verification
Verifies deliverables against requirements. Auto-generates fix plans if issues found.

```bash
./gsd.sh --project ~/app --only verify --phase 1 --verifier claude
```

**Loop:** Verify → if FAIL → generate fix plans → execute fixes → re-verify (max 2 rounds)

**Creates:** `{phase}-VERIFICATION.md`, `{phase}-FIX-{N}-PLAN.md` (if needed)

## CLI Reference

| Flag | Description | Default |
|------|-------------|---------|
| `--project` | Target project directory | **required** |
| `--task` | Task description | — |
| `--prd` | PRD file path | — |
| `--phase` | Start from specific phase | auto |
| `--only` | Run single module | full pipeline |
| `--planner` | Planning agent | `claude` |
| `--executor` | Execution agent(s), comma-separated | `claude` |
| `--reviewer` | Review agent(s), comma-separated | — |
| `--researcher` | 4 research agents, comma-separated | planner×4 |
| `--checker` | Plan verification agent | planner |
| `--verifier` | Deliverable verification agent | planner |
| `--model` | Model per agent: `agent:model[,...]` | defaults |
| `--skip-research` | Skip research phase | false |
| `--skip-verify` | Skip verification phase | false |
| `--map-codebase` | Map existing codebase first | false |
| `--dashboard` | Start real-time dashboard | false |
| `--dry-run` | Print prompts without executing | false |
| `--context` | Extra context files, comma-separated | — |
| `--max-phases` | Max phases per run | 20 |
| `--max-fix-rounds` | Max verify→fix cycles | 2 |

## Artifacts

After a pipeline run:

```
<project>/.codeswarm/
├── planning/
│   ├── PROJECT.md              # Project context
│   ├── REQUIREMENTS.md         # Scoped requirements
│   ├── ROADMAP.md              # Phase structure + status
│   ├── CONTEXT.md              # Implementation decisions
│   ├── STATE.md                # Progress tracking
│   ├── CODEBASE.md             # Codebase map (if --map-codebase)
│   ├── research/
│   │   ├── 1-stack.md          # Stack research
│   │   ├── 1-features.md       # Feature research
│   │   ├── 1-architecture.md   # Architecture research
│   │   └── 1-pitfalls.md       # Pitfall research
│   ├── 1-RESEARCH.md           # Synthesized research
│   ├── 1-01-PLAN.md            # Phase 1, Plan 1
│   ├── 1-02-PLAN.md            # Phase 1, Plan 2
│   ├── 1-01-SUMMARY.md         # Execution summary
│   ├── 1-02-SUMMARY.md
│   ├── 1-VERIFICATION.md       # Verification report
│   └── 1-CHECKER-FEEDBACK.md   # Plan checker feedback
└── sessions/
    └── session_<timestamp>/
        ├── pipeline.log        # Full pipeline log
        ├── metadata.json       # Session metadata
        ├── prompt_001_*.md     # Agent prompts
        └── log_001_*.md        # Agent outputs
```

## Comparison: GSD vs Codeswarm vs GSD Pipeline

| Feature | GSD | Codeswarm | **GSD Pipeline** |
|---------|-----|-----------|-----------------|
| Multi-agent providers | ❌ Claude only | ✅ Any | ✅ Any |
| Autonomous (no questions) | ❌ Many questions | ✅ | ✅ |
| Research phase | ✅ 4 Claude subagents | ❌ | ✅ 4 any-provider agents |
| Structured plans (XML) | ✅ | ❌ | ✅ |
| Plan verification loop | ✅ | ❌ | ✅ |
| Wave-based execution | ✅ Within Claude | ❌ | ✅ Across providers |
| Post-execution verification | ✅ | ❌ | ✅ |
| Auto-fix plans | ✅ | ❌ | ✅ |
| Fresh context per plan | ✅ | ✅ | ✅ |
| Real-time dashboard | ❌ | ✅ | ✅ |
| Context engineering | ✅ Full suite | ❌ Basic | ✅ Full suite |
| Modular (run parts independently) | ❌ Commands but coupled | ❌ | ✅ |
| Git commits per task | ✅ | ✅ | ✅ |

## Examples

### Java Spring Boot Feature
```bash
./gsd.sh --project ~/IdeaProjects/blue-flow \
  --task "Implement leave request approval workflow with manager escalation" \
  --planner claude --executor claude,gemini \
  --reviewer codex \
  --researcher gemini,claude,codex,gemini \
  --dashboard
```

### Brownfield Project (map first)
```bash
./gsd.sh --project ~/IdeaProjects/legacy-app \
  --task "Migrate authentication from sessions to JWT" \
  --map-codebase \
  --planner claude --executor claude
```

### Quick Single-Phase
```bash
# Just plan and execute phase 3
./gsd.sh --project ~/app --only plan --phase 3 --planner claude
./gsd.sh --project ~/app --only execute --phase 3 --executor claude,gemini
./gsd.sh --project ~/app --only verify --phase 3 --verifier claude
```

### Budget Run (fewer agents)
```bash
./gsd.sh --project ~/app --task "Add dark mode" \
  --planner claude --executor claude \
  --skip-research --skip-verify
```
