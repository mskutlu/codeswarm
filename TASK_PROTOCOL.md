# Task Protocol — Inter-Agent Communication

This document defines how agents communicate through the shared `.codeswarm/` directory.

## Directory Structure

Every project that uses the orchestrator gets a `.codeswarm/` directory:

```
<project-root>/
└── .codeswarm/
    ├── plan.md                    # Planner output
    ├── execution.log              # Executor output
    ├── review.md                  # Reviewer output
    ├── test-report.md             # Browser test results
    ├── screenshots/               # Browser test screenshots
    │   ├── step-01-login.png
    │   ├── step-02-navigate.png
    │   └── ...
    └── report-<timestamp>.md      # Final orchestration report
```

## Message Format

All inter-agent files use **Markdown** with structured sections. This ensures both humans and agents can read them.

### Plan (plan.md)

```markdown
# Implementation Plan

## Task Summary
<What needs to be done>

## File Changes
### [MODIFY] src/main/java/com/app/Service.java
- Add new method `processLeave()`
- Inject `NotificationService`

### [NEW] src/main/java/com/app/dto/LeaveRequestDTO.java
- Fields: employeeId, startDate, endDate, type

## Testing Strategy
- Unit test for `processLeave()`
- Integration test for API endpoint

## Risk Assessment
- Breaking change to existing API contract
```

### Execution Log (execution.log)

Raw output from the executor agent. Contains:
- Files read and modified
- Commands executed (build, test)
- Any errors or warnings
- Deviations from the plan

### Review (review.md)

```markdown
# Code Review Report

## Summary
**Verdict:** APPROVED | NEEDS_CHANGES | REJECTED

## Findings
### Critical
- None

### Warnings
- Missing null check in processLeave() line 45

### Suggestions
- Consider using Optional<> for return type

## Plan Adherence
All planned changes implemented correctly.
```

## Agent Prompting Rules

1. **Planner** receives: task description + project context
2. **Executor** receives: task description + plan.md content
3. **Reviewer** receives: task description + plan.md + git diff

Each agent should:
- Stay in its role (don't plan during execution, don't execute during review)
- Reference file paths relative to project root
- Use structured markdown for outputs
- Flag blockers immediately

## IDE Integration (Windsurf / Antigravity)

IDEs can participate by:
1. **Reading** `.codeswarm/plan.md` to understand what the CLI agents planned
2. **Editing** files interactively when the executor needs human guidance
3. **Running** browser tests using IDE's built-in browser tools
4. **Reviewing** by opening `review.md` in the IDE's markdown preview

### Windsurf Integration
```
# In Windsurf, open the project and use Cascade to review:
"Read .codeswarm/plan.md and implement the changes described in it"
```

### Antigravity Integration
```
# In Antigravity, use the built-in browser for visual testing:
"Read .codeswarm/plan.md, implement changes, then use browser to verify at http://localhost:4200"
```
