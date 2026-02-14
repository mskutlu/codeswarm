# Agent Tips & Configuration

## Claude Code

### Key Flags

```bash
claude -p "prompt"              # Headless mode (print & exit)
claude --model opus             # Use Claude Opus
claude --model sonnet           # Use Claude Sonnet (faster/cheaper)
claude --permission-mode plan   # Read-only mode (no edits)
claude --permission-mode auto_edit  # Auto-approve edits (no prompts)
claude --chrome                 # Enable Chrome browser control
claude --agents '{"name": {...}}'   # Define custom subagents
claude --add-dir /other/project     # Add additional directories
claude --mcp-config mcp.json       # Load MCP servers
```

### Claude Agent Teams (Experimental)

Define a team of specialized subagents:

```bash
claude --agents '{
  "architect": {
    "description": "Designs system architecture",
    "prompt": "You analyze requirements and design scalable architectures",
    "model": "opus"
  },
  "implementer": {
    "description": "Implements code changes",
    "prompt": "You write clean, tested code following team conventions",
    "model": "sonnet"
  },
  "qa": {
    "description": "Tests and validates changes",
    "prompt": "You test code for bugs, edge cases, and regressions",
    "model": "sonnet"
  }
}'
```

Or via `.claude/agents/` markdown files:

```markdown
---
name: architect
description: Designs system architecture
model: opus
allowedTools:
  - Read
  - Bash(find:*, grep:*, cat:*, tree:*)
---
You are an expert software architect. Analyze requirements and produce
detailed implementation plans with file paths, interfaces, and data models.
```

### Best Practices

- Use `opus` for planning (better reasoning, slower)
- Use `sonnet` for execution (fast, good at code generation)
- Use `--permission-mode plan` for reviewers (prevents accidental edits)
- Use `--add-dir` to give access to multiple related projects

---

## Gemini CLI

### Key Flags

```bash
gemini -p "prompt"              # Headless mode (prompt & exit)
gemini --model gemini-2.5-pro   # Specify model
gemini --approval-mode yolo     # Auto-approve everything
gemini --approval-mode auto_edit # Auto-approve edits only
gemini --approval-mode plan     # Read-only mode
gemini -y                       # YOLO mode (same as approval-mode yolo)
gemini --include-directories /other/project  # Add extra dirs
```

### Configuration Files

- `~/.gemini/settings.json` — Global settings and MCP servers
- `.gemini/settings.json` — Project-level settings
- `.gemini/AGENTS.md` — Custom agent instructions

### Project-Level Agent Instructions

Create `.gemini/AGENTS.md` in your project:

```markdown
# Project Agent Instructions

## Architecture
- This is a Spring Boot microservice using Hexagonal Architecture
- Entities go in domain/, services in application/, REST controllers in adapter/web/

## Code Conventions
- Use Lombok @Data for DTOs
- Use constructor injection
- All endpoints return ResultDTO
- Follow existing naming patterns
```

### Best Practices

- Gemini is excellent at file editing — ideal as executor
- Use `--approval-mode auto_edit` for automated execution
- YOLO mode (`-y`) is useful for fully automated pipelines
- Use `--include-directories` for multi-project tasks

---

## Codex CLI

### Key Flags

```bash
codex exec "prompt"             # Non-interactive execution
codex review                    # Code review mode
codex exec --sandbox read-only "prompt"  # Read-only sandbox
codex -m o3 "prompt"            # Use specific model
```

### Configuration

`~/.codex/config.toml`:

```toml
model = "o4-mini"

[sandbox_permissions]
disk-full-read-access = true
```

### Code Review

```bash
# Review uncommitted changes
codex review

# Review with specific focus
codex exec --sandbox read-only "Review the git diff for security issues, \
  performance problems, and adherence to SOLID principles. \
  Output a structured markdown report."
```

### Best Practices

- Codex excels at code review with `--sandbox read-only`
- Use `codex review` for the built-in review workflow
- Use `o3` or `o4-mini` models for reasoning-heavy reviews
- The sandbox prevents accidental modifications during review

---

## Windsurf

### Integration with Orchestrator

Windsurf (Cascade) can read the `.agentic/` directory:

1. Open your project in Windsurf
2. Ask Cascade: *"Read `.agentic/plan.md` and implement the changes"*
3. Or: *"Read `.agentic/review.md` and fix the issues mentioned"*

### When to Use Windsurf

- Complex refactoring that benefits from IDE context
- Debugging with breakpoints and step-through
- Visual feedback during development
- When you want an interactive conversation about the plan

---

## Antigravity

### Integration with Orchestrator

Antigravity has built-in browser capabilities:

1. Open your project in Antigravity
2. Ask: *"Read `.agentic/plan.md` and implement changes"*
3. For browser testing: *"Open http://localhost:4200 in the browser, login, and verify the dashboard"*
4. Design tasks: Use Pencil MCP for design-to-code workflows

### When to Use Antigravity

- Tasks involving UI design or visual prototyping
- Browser-based verification with built-in browser tools
- When you need Pencil MCP for design work

---

## Choosing the Right Agent

| Task Type | Recommended | Why |
|-----------|-------------|-----|
| Architecture planning | Claude (Opus) | Best reasoning and analysis |
| Code implementation | Gemini CLI | Fast, great at file editing |
| Code review | Codex CLI | Built-in review mode, sandbox |
| Complex debugging | Windsurf | IDE debugging tools |
| Frontend/Design | Antigravity | Browser + Pencil MCP |
| Quick prototyping | Gemini (YOLO) | Fastest iteration |
| Security audit | Codex (read-only) | Sandboxed analysis |
| Multi-repo tasks | Claude | Best at cross-project reasoning |
