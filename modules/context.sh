#!/usr/bin/env bash
#
# context.sh — Auto-Context Generation Module
#
# Replaces GSD's discuss-phase (which asks many questions) with
# autonomous context generation. The planner agent reads the PRD/task
# and codebase, then generates PROJECT.md + CONTEXT.md without
# asking the user anything.
#
# Usage:
#   source modules/common.sh
#   source modules/context.sh
#   generate_context "$PROJECT" "$TASK_OR_PRD" "$PLANNER_AGENT"
#
# Outputs:
#   .codeswarm/planning/PROJECT.md
#   .codeswarm/planning/CONTEXT.md
#   .codeswarm/planning/REQUIREMENTS.md
#   .codeswarm/planning/ROADMAP.md
#   .codeswarm/planning/STATE.md
#

set -euo pipefail

# ─── Prevent double-sourcing ────────────────────────────
[[ -n "${_CONTEXT_LOADED:-}" ]] && return 0
_CONTEXT_LOADED=1

# Ensure common.sh is loaded
MODULES_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${MODULES_DIR}/common.sh"

# ═══════════════════════════════════════════════════════════
# generate_context <project_dir> <task_or_prd_file> <planner_agent>
#
# Auto-generates all planning context without human interaction.
# The planner agent analyzes the codebase + requirements and produces
# the full GSD planning document set.
# ═══════════════════════════════════════════════════════════
generate_context() {
  local project="$1"
  local input="$2"       # task description string OR path to PRD file
  local planner="$3"
  local extra_context="${4:-}"

  banner "🧠 PHASE 0: AUTO-CONTEXT GENERATION"
  log "Planner: ${planner} | Project: ${project}"

  local planning_dir="${project}/.codeswarm/planning"
  mkdir -p "$planning_dir"
  mkdir -p "${planning_dir}/research"

  # Determine input type
  local input_type="task"
  local input_content="$input"
  if [[ -f "$input" ]]; then
    input_type="file"
    input_content="(see file reference below)"
    log "Input: file — ${input}"
  else
    log "Input: task description"
  fi

  # Check if context already exists (resume support)
  if [[ -f "${planning_dir}/PROJECT.md" ]] && [[ -f "${planning_dir}/ROADMAP.md" ]]; then
    local existing_phases=$(grep -c '^### Phase' "${planning_dir}/ROADMAP.md" 2>/dev/null || echo "0")
    if [[ $existing_phases -gt 0 ]]; then
      log "♻️  Existing planning context found (${existing_phases} phases). Reusing."
      success "Context loaded from previous session"
      return 0
    fi
  fi

  # Build the auto-context prompt
  local prompt="You are an autonomous project planner. Your job is to analyze a project and requirements, then produce complete planning documents — WITHOUT asking any questions.

PROJECT DIRECTORY: ${project}

TASK/REQUIREMENTS:
${input_content}
$(if [[ "$input_type" == "file" ]]; then echo "
READ THIS FILE FIRST: ${input}
"; fi)
${extra_context:+
ADDITIONAL CONTEXT:
${extra_context}
}

You MUST produce ALL of the following files. Read the project codebase first to understand existing patterns.

═══════════════════════════════════════════════════════
FILE 1: ${planning_dir}/PROJECT.md
═══════════════════════════════════════════════════════
Format:
\`\`\`markdown
# Project: <name>

## Vision
<2-3 sentences: what is this project and what problem does it solve>

## Tech Stack
- Language: <e.g. Java 21>
- Framework: <e.g. Spring Boot 3.x>
- Database: <e.g. PostgreSQL>
- Build: <e.g. Maven>
- Other: <relevant tools/libs>

## Architecture
<Brief architecture description — hexagonal, layered, etc.>

## Key Patterns
<Patterns found in existing code — naming conventions, package structure, etc.>

## Constraints
<Any constraints discovered from the codebase or requirements>
\`\`\`

═══════════════════════════════════════════════════════
FILE 2: ${planning_dir}/REQUIREMENTS.md
═══════════════════════════════════════════════════════
Format:
\`\`\`markdown
# Requirements

## V1 (Current Milestone)
- REQ-001: <requirement>
- REQ-002: <requirement>
...

## V2 (Future)
- <deferred items>

## Out of Scope
- <explicitly excluded>
\`\`\`

═══════════════════════════════════════════════════════
FILE 3: ${planning_dir}/ROADMAP.md
═══════════════════════════════════════════════════════
Format:
\`\`\`markdown
# Roadmap

## Milestone: V1

### Phase 1: <title>
**Goal:** <what this phase achieves>
**Requirements:** REQ-001, REQ-002
**Status:** not_started

### Phase 2: <title>
**Goal:** <what this phase achieves>
**Requirements:** REQ-003
**Dependencies:** Phase 1
**Status:** not_started

...
\`\`\`

Guidelines for phases:
- Each phase should be completable in 1-3 plans (small enough for fresh context)
- Order by dependency (foundations first, then features, then integration)
- Be specific: name the actual components, files, tables involved
- 3-8 phases per milestone is typical

═══════════════════════════════════════════════════════
FILE 4: ${planning_dir}/CONTEXT.md
═══════════════════════════════════════════════════════
Format:
\`\`\`markdown
# Implementation Context

## Decisions
<Key implementation decisions YOU are making autonomously>
- Decision 1: <what and why>
- Decision 2: <what and why>

## Patterns to Follow
<Patterns from existing codebase that new code should follow>
- Pattern: <description + file reference>

## Integration Points
<How new code connects to existing code>

## Deferred Ideas
<Things that could be done but are out of scope for V1>
\`\`\`

═══════════════════════════════════════════════════════
FILE 5: ${planning_dir}/STATE.md
═══════════════════════════════════════════════════════
Format:
\`\`\`markdown
# State

## Current Position
Phase: 1 (not started)
Status: Planning complete, ready for research

## Decisions Log
- <timestamp>: Auto-generated planning context

## Blockers
None
\`\`\`

CRITICAL RULES:
1. DO NOT ask any questions — make reasonable decisions and document them in CONTEXT.md
2. READ the existing codebase to understand patterns before making decisions
3. Be SPECIFIC — name files, classes, tables, endpoints
4. Each phase should produce something testable/verifiable
5. Write ALL 5 files listed above
6. When done, print: done"

  # Dispatch to planner
  local skills=$(get_skills_for "$planner")
  if [[ -n "$skills" ]]; then
    prompt+="
${skills}"
  fi

  step_banner "0.1" "Planner analyzing codebase + generating context"
  send_to_agent "$planner" "$prompt" "auto-context generation" "planner"

  # Verify outputs
  local generated=0
  local expected=5
  for doc in PROJECT.md REQUIREMENTS.md ROADMAP.md CONTEXT.md STATE.md; do
    if [[ -f "${planning_dir}/${doc}" ]] && [[ -s "${planning_dir}/${doc}" ]]; then
      generated=$((generated + 1))
      success "${doc} created"
    else
      warn "${doc} not generated"
    fi
  done

  if [[ $generated -lt 3 ]]; then
    error "Only ${generated}/${expected} planning docs generated. Context generation may have failed."
    return 1
  fi

  success "Auto-context complete: ${generated}/${expected} documents generated"
  return 0
}

# ═══════════════════════════════════════════════════════════
# update_state <project_dir> <phase_num> <status> <message>
#
# Updates STATE.md with progress information.
# ═══════════════════════════════════════════════════════════
update_state() {
  local project="$1"
  local phase="$2"
  local status="$3"
  local message="$4"
  local state_file="${project}/.codeswarm/planning/STATE.md"

  if [[ ! -f "$state_file" ]]; then
    return 0
  fi

  # Update current position
  sed -i '' "s/^Phase: .*/Phase: ${phase} (${status})/" "$state_file" 2>/dev/null || true
  sed -i '' "s/^Status: .*/Status: ${message}/" "$state_file" 2>/dev/null || true

  # Append to decisions log
  echo "- $(date '+%Y-%m-%d %H:%M'): Phase ${phase} — ${status}: ${message}" >> "$state_file"
}
