# PRD: CMMS Work Order Management API

## Overview
Build a RESTful API for managing maintenance work orders in a CMMS (Computerized Maintenance Management System). The API handles work order lifecycle from creation through completion, with assignment, priority management, and status tracking.

## Tech Stack
Java 21, Spring Boot 3.x, PostgreSQL, Liquibase, Maven

## User Stories

### US-001: Database Schema & Entity [priority: 1]
**Description:** Create the database schema and JPA entity for work orders. This is the foundation for all other stories.
**Files:** `src/main/resources/db/changelog/001-create-work-orders.xml`, `src/main/java/com/app/domain/model/WorkOrder.java`, `src/main/java/com/app/domain/model/WorkOrderStatus.java`, `src/main/java/com/app/domain/model/WorkOrderPriority.java`
**Acceptance Criteria:**
- [ ] Liquibase migration creates `work_orders` table with columns: id, title, description, status, priority, assigned_to, created_by, due_date, completed_at, created_at, updated_at
- [ ] WorkOrder JPA entity maps correctly with proper annotations (@Entity, @Table, @Id, @Version)
- [ ] WorkOrderStatus enum: OPEN, IN_PROGRESS, ON_HOLD, COMPLETED, CANCELLED
- [ ] WorkOrderPriority enum: CRITICAL, HIGH, MEDIUM, LOW
- [ ] `mvn compile` passes with no errors
**Dependencies:** none
**Notes:** Follow hexagonal architecture. Use `@GeneratedValue(strategy = GenerationType.SEQUENCE)` with a dedicated sequence.

### US-002: Repository & Basic Service [priority: 2]
**Description:** Create the repository interface and service layer with basic CRUD operations.
**Files:** `src/main/java/com/app/infrastructure/adapter/out/persistence/WorkOrderRepository.java`, `src/main/java/com/app/domain/service/WorkOrderService.java`, `src/main/java/com/app/application/dto/WorkOrderDto.java`, `src/main/java/com/app/application/dto/CreateWorkOrderRequest.java`
**Acceptance Criteria:**
- [ ] JpaRepository with custom query: findByStatus, findByAssignedTo, findByPriority
- [ ] WorkOrderService implements: create, findById, findAll, update, delete
- [ ] CreateWorkOrderRequest DTO with Jakarta validation annotations (@NotBlank, @NotNull)
- [ ] WorkOrderDto as a Java record for responses
- [ ] Service uses constructor injection (no @Autowired on fields)
- [ ] `mvn compile` passes
**Dependencies:** US-001
**Notes:** Use MapStruct for entity-DTO mapping if the project already uses it, otherwise manual mapping.

### US-003: REST Controller [priority: 3]
**Description:** Create REST endpoints for work order CRUD operations with proper HTTP status codes and error handling.
**Files:** `src/main/java/com/app/infrastructure/adapter/in/web/WorkOrderController.java`, `src/main/java/com/app/shared/exception/ResourceNotFoundException.java`
**Acceptance Criteria:**
- [ ] POST /api/work-orders — creates work order, returns 201 with Location header
- [ ] GET /api/work-orders — lists all work orders with pagination (Pageable)
- [ ] GET /api/work-orders/{id} — returns single work order or 404
- [ ] PUT /api/work-orders/{id} — updates work order or 404
- [ ] DELETE /api/work-orders/{id} — soft-delete or 404
- [ ] @Valid on request bodies triggers 400 with field-level error messages
- [ ] Global exception handler returns consistent error JSON: { timestamp, status, message, path }
- [ ] `mvn compile` passes
**Dependencies:** US-002
**Notes:** Use @RestController with @RequestMapping("/api/work-orders"). Follow existing controller patterns in the project.

### US-004: Status Transitions & Business Rules [priority: 4]
**Description:** Implement work order status transition logic with validation. Not all transitions are valid (e.g., CANCELLED → IN_PROGRESS is not allowed).
**Files:** `src/main/java/com/app/domain/service/WorkOrderService.java`, `src/main/java/com/app/domain/model/WorkOrder.java`, `src/main/java/com/app/shared/exception/InvalidStatusTransitionException.java`
**Acceptance Criteria:**
- [ ] Valid transitions: OPEN→IN_PROGRESS, OPEN→CANCELLED, IN_PROGRESS→ON_HOLD, IN_PROGRESS→COMPLETED, IN_PROGRESS→CANCELLED, ON_HOLD→IN_PROGRESS, ON_HOLD→CANCELLED
- [ ] Invalid transitions throw InvalidStatusTransitionException (returns 409 Conflict)
- [ ] PATCH /api/work-orders/{id}/status endpoint accepts { "status": "IN_PROGRESS" }
- [ ] completed_at is automatically set when transitioning to COMPLETED
- [ ] assigned_to is required before transitioning to IN_PROGRESS
- [ ] `mvn compile` passes
**Dependencies:** US-003
**Notes:** Consider using a state machine pattern or a simple Map<Status, Set<Status>> for allowed transitions.

### US-005: Search & Filtering [priority: 5]
**Description:** Add search and filtering capabilities to the work orders list endpoint.
**Files:** `src/main/java/com/app/infrastructure/adapter/in/web/WorkOrderController.java`, `src/main/java/com/app/infrastructure/adapter/out/persistence/WorkOrderRepository.java`, `src/main/java/com/app/application/dto/WorkOrderFilterRequest.java`
**Acceptance Criteria:**
- [ ] GET /api/work-orders?status=OPEN&priority=HIGH — filter by status and/or priority
- [ ] GET /api/work-orders?search=pump — case-insensitive search in title and description
- [ ] GET /api/work-orders?assignedTo=user123 — filter by assignee
- [ ] GET /api/work-orders?dueBefore=2025-01-01 — filter by due date
- [ ] Filters are combinable (AND logic)
- [ ] Pagination still works with filters (page, size, sort parameters)
- [ ] `mvn compile` passes
**Dependencies:** US-003
**Notes:** Use Spring Data JPA Specifications or @Query with dynamic parameters. Do NOT use Criteria API directly.

---

## Non-Functional Requirements
- All endpoints require authentication (existing Spring Security config handles this)
- Use SLF4J Logger, not System.out.println
- Follow existing naming conventions in the project
- Database columns use snake_case, Java fields use camelCase

## Out of Scope
- File attachments on work orders
- Work order comments/notes
- Email notifications
- Audit log integration
