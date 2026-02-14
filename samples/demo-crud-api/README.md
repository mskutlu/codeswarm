# Demo CRUD API — Agentic Test Project

A simple Express.js project designed to test the multi-agent coordinator.

## What This Tests

| Phase | Agents Exercised | Expected Outcome |
|-------|-----------------|------------------|
| **Phase 1**: Basic CRUD | Executor builds routes | Straightforward — should pass review |
| **Phase 2**: Validation (COMPLEX) | Executor + Reviewer catches bug | Has intentional mass-assignment vulnerability. Reviewer should reject and request fix |
| **Phase 3**: Search & Pagination | Executor implements, reviewer approves | Medium complexity — should pass |

## Run with Coordinator

```bash
cd ~/IdeaProjects/agentic

./coordinator.sh \
  --project ~/IdeaProjects/agentic/samples/demo-crud-api \
  --plan "docs/plan.md" \
  --planner codex \
  --executor claude \
  --reviewer gemini,amp \
  --dashboard
```

## Manual Test

```bash
cd samples/demo-crud-api
npm install
npm start
# In another terminal:
npm test
```
