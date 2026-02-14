# PRD: Todo List REST API

## Overview
Build a simple Todo List REST API with CRUD operations. This is a sample PRD for testing the agentic coordinator's PRD workflow.

## Tech Stack
Node.js, Express, SQLite (in-memory for testing)

## User Stories

### US-001: Initialize project structure [priority: 1]
**Description:** As a developer, I want a clean project structure so that the codebase is organized from the start.
**Files:** `package.json`, `src/index.js`, `src/database.js`
**Acceptance Criteria:**
- [ ] package.json exists with express and better-sqlite3 dependencies
- [ ] src/index.js creates Express app listening on port 3000
- [ ] src/database.js initializes SQLite with a `todos` table (id, title, completed, created_at)
- [ ] `npm start` runs without errors
**Dependencies:** none
**Notes:** Use ES modules (type: module in package.json)

### US-002: Implement GET /api/todos endpoint [priority: 2]
**Description:** As a user, I want to list all todos so that I can see my tasks.
**Files:** `src/routes/todos.js`, `src/index.js`
**Acceptance Criteria:**
- [ ] GET /api/todos returns 200 with JSON array of all todos
- [ ] Response includes id, title, completed, created_at fields
- [ ] Empty database returns empty array (not error)
- [ ] `npm start` runs without errors
**Dependencies:** US-001
**Notes:** Use Express Router for modular routing

### US-003: Implement POST /api/todos endpoint [priority: 3]
**Description:** As a user, I want to create new todos so that I can track my tasks.
**Files:** `src/routes/todos.js`
**Acceptance Criteria:**
- [ ] POST /api/todos with body `{"title": "Buy groceries"}` creates a todo
- [ ] Returns 201 with the created todo object including generated id
- [ ] Missing title returns 400 with error message
- [ ] `npm start` runs without errors
**Dependencies:** US-001, US-002
**Notes:** Validate that title is a non-empty string

### US-004: Implement PATCH and DELETE endpoints [priority: 4]
**Description:** As a user, I want to update and delete todos so that I can manage my task list.
**Files:** `src/routes/todos.js`
**Acceptance Criteria:**
- [ ] PATCH /api/todos/:id updates title and/or completed fields
- [ ] DELETE /api/todos/:id removes the todo and returns 204
- [ ] Non-existent id returns 404 for both endpoints
- [ ] `npm start` runs without errors
**Dependencies:** US-001, US-002, US-003
**Notes:** PATCH should only update provided fields (partial update)
