# Advanced Workflows & Examples

## Workflow 1: Full-Stack Feature (Backend + Frontend)

```bash
# Step 1: Plan with Claude Opus across both repos
./orchestrate.sh \
  --project ~/IdeaProjects/blue-flow \
  --task "Add leave approval notification: create REST endpoint in blue-flow, \
          add Kafka event, consume in derin-ui-manager to show real-time toast" \
  --planner claude --model opus

# Step 2: Execute backend with Gemini
./orchestrate.sh \
  --project ~/IdeaProjects/blue-flow \
  --task "Implement the backend changes from plan" \
  --skip-plan --executor gemini --skip-review

# Step 3: Execute frontend with Gemini
./orchestrate.sh \
  --project ~/WebstormProjects/derin-ui-manager \
  --task "Implement the frontend notification toast from plan in blue-flow/.agentic/plan.md" \
  --skip-plan --executor gemini --skip-review

# Step 4: Review everything with Codex
./orchestrate.sh \
  --project ~/IdeaProjects/blue-flow \
  --task "Review all changes for leave approval notification" \
  --skip-plan --reviewer codex

# Step 5: Browser test the frontend
./orchestrate.sh \
  --project ~/WebstormProjects/derin-ui-manager \
  --task "Test leave approval notification appears after triggering approval" \
  --skip-plan --skip-review --browser-test --test-url "http://localhost:4200"
```

---

## Workflow 2: Bug Fix Pipeline

```bash
# All-in-one: plan, fix, review
./orchestrate.sh \
  --project ~/IdeaProjects/derin-purchase \
  --task "Fix: Purchase order total calculation returns 0 when \
          discount percentage is applied. Error in PurchaseOrderService.calculateTotal()"
```

---

## Workflow 3: Code Review Only

```bash
# Use Codex to review current uncommitted changes
cd ~/IdeaProjects/blue-planning
codex review

# Or via orchestrator with only review phase
./orchestrate.sh \
  --project ~/IdeaProjects/blue-planning \
  --task "Review uncommitted changes for quality and security" \
  --skip-plan --skip-review \
  --reviewer codex
```

---

## Workflow 4: Multi-Agent with Claude Agent Teams

Use Claude's native `--agents` flag for intra-Claude orchestration:

```bash
claude --agents '{
  "planner": {
    "description": "Plans architecture changes",
    "prompt": "You are a senior architect. Analyze tasks and produce detailed plans.",
    "model": "opus",
    "allowedTools": ["Read", "Bash(find:*,grep:*,cat:*)"]
  },
  "coder": {
    "description": "Implements code changes",
    "prompt": "You implement changes following the plan precisely.",
    "model": "sonnet",
    "allowedTools": ["Read", "Edit", "Bash"]
  },
  "tester": {
    "description": "Tests changes",
    "prompt": "You write and run tests. Use browser tools for UI testing.",
    "model": "sonnet",
    "allowedTools": ["Read", "Bash", "Browser"]
  }
}' --add-dir ~/IdeaProjects/blue-flow
```

---

## Workflow 5: Parallel Multi-Project

Run agents in parallel across related services:

```bash
#!/bin/bash
# parallel-deploy.sh — Fix the same issue across multiple services

TASK="Update blue-citrus-tools dependency to 0.4.84 and fix any compilation errors"

for PROJECT in blue-planning blue-material-recipe blue-inventory-production derin-execution derin-purchase; do
  echo "Processing $PROJECT..."
  ./orchestrate.sh \
    --project ~/IdeaProjects/$PROJECT \
    --task "$TASK" &
done

wait
echo "All projects updated!"
```

---

## Workflow 6: Frontend Visual Regression

```bash
# Generate baseline screenshots
./orchestrate.sh \
  --project ~/WebstormProjects/derin-ui-manager \
  --task "Take screenshots of every page: login, dashboard, inventory, \
          planning, materials, quality control, settings" \
  --skip-plan --skip-review --browser-test --test-url "http://localhost:4200"

# After making changes, generate new screenshots and compare
./orchestrate.sh \
  --project ~/WebstormProjects/derin-ui-manager \
  --task "Take the same screenshots as before and compare with \
          baseline in .agentic/screenshots/. Report any visual differences." \
  --skip-plan --skip-review --browser-test --test-url "http://localhost:4200"
```

---

## Workflow 7: Using Windsurf as Executor

When you prefer interactive development:

1. Run the planner:
   ```bash
   ./orchestrate.sh --project ~/IdeaProjects/blue-flow \
     --task "Add batch confirmation cancellation endpoint" \
     --planner claude --model opus \
     --skip-review
   ```

2. Open the project in Windsurf and tell Cascade:
   > "Read `.agentic/plan.md` and implement all the changes described in it"

3. After implementing, run the reviewer:
   ```bash
   ./orchestrate.sh --project ~/IdeaProjects/blue-flow \
     --task "Review batch confirmation cancellation implementation" \
     --skip-plan --reviewer codex
   ```

---

## Workflow 8: Database Migration

```bash
./orchestrate.sh \
  --project ~/IdeaProjects/blue-migration \
  --task "Create Liquibase migration for new leave_requests table: \
    columns: id (bigserial), employee_id (bigint FK), start_date, end_date, \
    type (varchar), status (varchar), created_at, updated_at. \
    Add indexes on employee_id and status. Follow existing changelog patterns."
```
