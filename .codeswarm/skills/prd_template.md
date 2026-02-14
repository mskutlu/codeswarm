# PRD Generator Skill

Generate a structured Product Requirements Document (PRD) for autonomous agent execution.

## Goal
Create a PRD that breaks work into small, dependency-ordered user stories with verifiable acceptance criteria.

## PRD Format

Write the PRD using this exact structure:

```markdown
# PRD: <Project Title>

## Overview
<2-3 sentence description of the feature and what problem it solves>

## Tech Stack
<language, framework, database — from project analysis>

## User Stories

### US-001: <Title> [priority: 1]
**Description:** As a <user>, I want <feature> so that <benefit>.
**Files:** `path/to/file1`, `path/to/file2`
**Acceptance Criteria:**
- [ ] <specific, testable criterion>
- [ ] <specific, testable criterion>
- [ ] Build passes (e.g. `mvn compile`, `npm run build`)
**Dependencies:** none
**Notes:** <patterns to follow, gotchas>

### US-002: <Title> [priority: 2]
...
```

## Story Sizing Rules

Each user story MUST be completable by one agent in ~10 minutes (one context window).

### Right-sized:
- Add a database column and migration
- Add a UI component to an existing page
- Update a service method with new logic
- Add a filter/dropdown to a list
- Create a single REST endpoint

### Too big — split these:
- "Build the entire dashboard" → Split: schema, queries, UI, filters
- "Add authentication" → Split: schema, middleware, login UI, session
- "Refactor the API" → Split: one story per endpoint

**Rule of thumb:** If you cannot describe the change in 2-3 sentences, it's too big.

## Story Ordering

Stories execute in priority order. Earlier stories must NOT depend on later ones.

**Correct Order:**
1. Schema/database changes (migrations, tables)
2. Domain entities/models
3. Service layer / business logic
4. REST controllers / API endpoints
5. UI components that use the backend
6. Integration / summary views

## Acceptance Criteria Rules

Each criterion must be verifiable — something an agent can CHECK.

### Good (verifiable):
- "Add `status` column to tasks table with default 'PENDING'"
- "GET /api/tasks returns 200 with JSON array"
- "Filter dropdown has options: All, Active, Completed"
- "Build passes (`mvn compile` / `npm run build`)"

### Bad (vague):
- "Works correctly"
- "Good UX"
- "Handles edge cases"

### Always include as the last criterion:
- `Build passes` (e.g. `mvn compile`, `npm run build`, `tsc --noEmit`)

### For UI stories, also include:
- `Verify in browser` (visual confirmation via screenshot or dev tools)

## Before Saving

Verify:
- [ ] Read existing code first to understand patterns and conventions
- [ ] Each story is completable in one iteration (~10 min)
- [ ] Stories ordered by dependency (schema → entities → services → controllers → UI)
- [ ] Every story has "Build passes" in acceptance criteria
- [ ] Acceptance criteria are specific and verifiable
- [ ] No story depends on a later story
- [ ] File paths are specific (name files, classes, methods)
- [ ] Referenced existing implementations as patterns to follow
