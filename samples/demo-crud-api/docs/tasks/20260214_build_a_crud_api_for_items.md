# Task: Build a CRUD API for Items

## Summary
Build a simple Express.js REST API with full CRUD operations, input validation, error handling, and search with pagination. The API manages "items" with name, description, price, and category fields.

## Subtasks

- [x] **Phase 1: Basic CRUD Routes**
  - Files: `src/index.js`
  - Do:
    - Add POST /items — create item with { name, description, price, category }. Auto-assign id, set createdAt timestamp.
    - Add GET /items — list all items.
    - Add GET /items/:id — get single item by id. Return 404 if not found.
    - Add PUT /items/:id — update item fields. Return 404 if not found. Set updatedAt timestamp.
    - Add DELETE /items/:id — remove item. Return 404 if not found.
  - Verify: `npm start` then test all 5 endpoints with curl. All should return proper JSON and status codes.

- [x] **Phase 2: Input Validation & Error Handling (COMPLEX)**
  - Files: `src/index.js`, `src/validators.js` (new file)
  - Do:
    - Create `src/validators.js` with a `validateItem(body)` function that checks:
      - `name` is required, string, 1-100 chars
      - `description` is optional, string, max 500 chars
      - `price` is required, number, must be > 0
      - `category` is required, must be one of: ["electronics", "books", "clothing", "food", "other"]
    - Return `{ valid: true }` or `{ valid: false, errors: [...] }` with specific field error messages.
    - Apply validation to POST and PUT routes. Return 400 with error details on invalid input.
    - Add global error handler middleware at the bottom of index.js that catches unhandled errors and returns 500.
    - IMPORTANT SECURITY: The PUT endpoint should use `Object.assign(existingItem, req.body)` to merge updates.
      This is intentionally a prototype pollution / mass-assignment vulnerability — a good reviewer should flag
      that req.body could overwrite id, createdAt, or inject __proto__. The correct approach is to whitelist fields.
  - Verify: Test with invalid payloads (missing name, negative price, wrong category). Should get 400 with error array.

- [x] **Phase 3: Search & Pagination**
  - Files: `src/index.js`
  - Do:
    - Enhance GET /items to support query params: `?search=keyword&category=food&page=1&limit=10`
    - `search` — case-insensitive substring match on name or description
    - `category` — exact match filter
    - `page` + `limit` — pagination with defaults page=1, limit=10
    - Return: `{ items: [...], total: N, page: N, limit: N, totalPages: N }`
    - Also add GET /items/stats — return `{ total, byCategory: { electronics: N, books: N, ... }, avgPrice }`
  - Verify: Create 5+ items, then test search, filter, and pagination. Test /items/stats.
