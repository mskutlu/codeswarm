#!/usr/bin/env bash
#
# research.sh — Parallel Multi-Agent Research Module
#
# Runs 4 research agents in parallel (any AI provider) to investigate:
#   1. Stack & Dependencies
#   2. Feature Implementation Patterns
#   3. Architecture & Integration
#   4. Pitfalls & Edge Cases
#
# Results are synthesized into RESEARCH.md
#
# Usage:
#   source modules/common.sh
#   source modules/research.sh
#   run_research "$PROJECT" "$PHASE_NUM" "claude,gemini,codex,claude"
#

set -euo pipefail

[[ -n "${_RESEARCH_LOADED:-}" ]] && return 0
_RESEARCH_LOADED=1

MODULES_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${MODULES_DIR}/common.sh"

# ═══════════════════════════════════════════════════════════
# run_research <project_dir> <phase_num> <agent_list> [synthesizer_agent]
#
# agent_list: comma-separated list of 4 agents for parallel research
#   e.g. "gemini,claude,codex,gemini"
# synthesizer_agent: agent to combine results (default: first in list)
# ═══════════════════════════════════════════════════════════
run_research() {
  local project="$1"
  local phase_num="$2"
  local agent_list="$3"
  local synthesizer="${4:-}"

  banner "🔬 PHASE 1: PARALLEL RESEARCH"

  local planning_dir="${project}/.codeswarm/planning"
  local research_dir="${planning_dir}/research"
  mkdir -p "$research_dir"

  # Check if research already exists for this phase
  local research_file="${planning_dir}/${phase_num}-RESEARCH.md"
  if [[ -f "$research_file" ]] && [[ -s "$research_file" ]]; then
    log "♻️  Research already exists for phase ${phase_num}. Reusing."
    success "Research loaded from: ${research_file}"
    return 0
  fi

  # Parse agent list
  IFS=',' read -ra RESEARCH_AGENTS <<< "$agent_list"
  # Pad to 4 agents if fewer provided
  while [[ ${#RESEARCH_AGENTS[@]} -lt 4 ]]; do
    RESEARCH_AGENTS+=("${RESEARCH_AGENTS[0]}")
  done

  [[ -z "$synthesizer" ]] && synthesizer="${RESEARCH_AGENTS[0]}"

  # Load planning context
  local project_md=$(get_project_md)
  local roadmap_md=$(get_roadmap_md)
  local context_md=$(get_context_md)

  # Extract phase description from roadmap
  local phase_desc=""
  if [[ -n "$roadmap_md" ]]; then
    phase_desc=$(echo "$roadmap_md" | sed -n "/### Phase ${phase_num}:/,/### Phase/p" | head -20)
  fi

  log "Dispatching 4 research agents in parallel..."
  log "  Stack:        ${RESEARCH_AGENTS[0]}"
  log "  Features:     ${RESEARCH_AGENTS[1]}"
  log "  Architecture: ${RESEARCH_AGENTS[2]}"
  log "  Pitfalls:     ${RESEARCH_AGENTS[3]}"

  # ─── Research Agent 1: Stack & Dependencies ────────────
  local stack_output="${research_dir}/${phase_num}-stack.md"
  step_banner "1.1" "Stack Research → ${RESEARCH_AGENTS[0]}"

  send_to_agent "${RESEARCH_AGENTS[0]}" "You are a stack researcher. Investigate the technology stack for this project phase.

PROJECT: ${project}
${project_md:+
PROJECT CONTEXT:
${project_md}
}
PHASE ${phase_num}:
${phase_desc}

YOUR TASK:
1. Read the project's build files (pom.xml, package.json, build.gradle, etc.)
2. Identify ALL relevant dependencies, their versions, and compatibility
3. Research any new libraries or frameworks needed for this phase
4. Check for version conflicts or deprecated APIs

Write your findings to: ${stack_output}

Format:
# Stack Research — Phase ${phase_num}

## Current Dependencies
<list relevant dependencies with versions>

## New Dependencies Needed
<libraries/frameworks needed for this phase>

## Version Compatibility
<any conflicts or concerns>

## Recommendations
<specific version recommendations>

When done, print: done" \
    "stack research" "executor" &
  local pid1=$!

  # ─── Research Agent 2: Feature Implementation Patterns ──
  local feature_output="${research_dir}/${phase_num}-features.md"
  step_banner "1.2" "Feature Research → ${RESEARCH_AGENTS[1]}"

  send_to_agent "${RESEARCH_AGENTS[1]}" "You are a feature researcher. Investigate how to implement the features in this phase.

PROJECT: ${project}
${project_md:+
PROJECT CONTEXT:
${project_md}
}
${context_md:+
IMPLEMENTATION CONTEXT:
${context_md}
}
PHASE ${phase_num}:
${phase_desc}

YOUR TASK:
1. Read existing code to find similar implementations in the project
2. Identify reusable patterns, services, and components
3. Research best practices for the specific features
4. Find concrete examples in the codebase to follow

Write your findings to: ${feature_output}

Format:
# Feature Research — Phase ${phase_num}

## Existing Patterns
<patterns found in codebase with file references>

## Reusable Components
<existing code that can be reused or extended>

## Implementation Approach
<recommended approach for each feature>

## Best Practices
<relevant best practices>

When done, print: done" \
    "feature research" "executor" &
  local pid2=$!

  # ─── Research Agent 3: Architecture & Integration ───────
  local arch_output="${research_dir}/${phase_num}-architecture.md"
  step_banner "1.3" "Architecture Research → ${RESEARCH_AGENTS[2]}"

  send_to_agent "${RESEARCH_AGENTS[2]}" "You are an architecture researcher. Investigate the architectural implications of this phase.

PROJECT: ${project}
${project_md:+
PROJECT CONTEXT:
${project_md}
}
PHASE ${phase_num}:
${phase_desc}

YOUR TASK:
1. Read the project structure and architecture
2. Map integration points — where new code connects to existing code
3. Identify API contracts, database schema changes, event flows
4. Check for architectural concerns (circular deps, coupling, etc.)

Write your findings to: ${arch_output}

Format:
# Architecture Research — Phase ${phase_num}

## Project Structure
<relevant directory/package structure>

## Integration Points
<where new code connects to existing code>

## Schema Changes
<database tables, columns, migrations needed>

## API Contracts
<endpoints, DTOs, request/response formats>

## Concerns
<architectural risks or concerns>

When done, print: done" \
    "architecture research" "executor" &
  local pid3=$!

  # ─── Research Agent 4: Pitfalls & Edge Cases ────────────
  local pitfall_output="${research_dir}/${phase_num}-pitfalls.md"
  step_banner "1.4" "Pitfall Research → ${RESEARCH_AGENTS[3]}"

  send_to_agent "${RESEARCH_AGENTS[3]}" "You are a pitfall researcher. Investigate potential issues and edge cases for this phase.

PROJECT: ${project}
${project_md:+
PROJECT CONTEXT:
${project_md}
}
PHASE ${phase_num}:
${phase_desc}

YOUR TASK:
1. Read existing code to find past bug patterns or workarounds
2. Identify edge cases for the features in this phase
3. Check for common pitfalls with the tech stack
4. Look for transaction boundaries, null handling, concurrency issues

Write your findings to: ${pitfall_output}

Format:
# Pitfall Research — Phase ${phase_num}

## Known Patterns
<existing workarounds or patterns that suggest past issues>

## Edge Cases
<specific edge cases to handle>

## Common Pitfalls
<tech-stack-specific pitfalls>

## Testing Focus
<what tests should cover based on risk areas>

When done, print: done" \
    "pitfall research" "executor" &
  local pid4=$!

  # Wait for all research agents
  log "⏳ Waiting for all 4 research agents..."
  local all_ok=true
  wait $pid1 2>/dev/null || { warn "Stack researcher failed"; all_ok=false; }
  wait $pid2 2>/dev/null || { warn "Feature researcher failed"; all_ok=false; }
  wait $pid3 2>/dev/null || { warn "Architecture researcher failed"; all_ok=false; }
  wait $pid4 2>/dev/null || { warn "Pitfall researcher failed"; all_ok=false; }

  # ─── Synthesize Results ─────────────────────────────────
  step_banner "1.5" "Synthesizing Research → ${synthesizer}"

  # Collect all research outputs
  local all_research=""
  for rf in "$stack_output" "$feature_output" "$arch_output" "$pitfall_output"; do
    if [[ -f "$rf" ]] && [[ -s "$rf" ]]; then
      all_research+="
$(cat "$rf")

---
"
    fi
  done

  if [[ -z "$all_research" ]]; then
    warn "No research outputs collected — skipping synthesis"
    # Create minimal research file
    echo "# Research — Phase ${phase_num}

No research data collected. Proceeding with available context.
" > "$research_file"
    return 0
  fi

  send_to_agent "$synthesizer" "You are a research synthesizer. Combine the following research reports into a single, actionable document.

RESEARCH REPORTS:
${all_research}

Write the synthesized research to: ${research_file}

Format:
# Research Summary — Phase ${phase_num}

## Key Findings
<most important findings across all research>

## Implementation Guide
<concrete implementation guidance synthesized from all reports>

## Dependencies & Setup
<what needs to be added/configured>

## Risk Areas
<combined risks and mitigation strategies>

## Testing Strategy
<what to test based on research findings>

RULES:
- Merge duplicate findings
- Prioritize actionable insights over general advice
- Resolve conflicting recommendations (pick the one that fits the codebase)
- Keep it concise — this will be read by planning and execution agents
- When done, print: done" \
    "research synthesis" "planner"

  if [[ -f "$research_file" ]] && [[ -s "$research_file" ]]; then
    success "Research complete: ${research_file}"
  else
    warn "Research synthesis may have failed — check agent logs"
  fi

  return 0
}

# ═══════════════════════════════════════════════════════════
# run_codebase_map <project_dir> <agent>
#
# Maps the existing codebase (like GSD's map-codebase).
# Creates a CODEBASE.md that provides project understanding.
# ═══════════════════════════════════════════════════════════
run_codebase_map() {
  local project="$1"
  local agent="$2"
  local planning_dir="${project}/.codeswarm/planning"
  local output="${planning_dir}/CODEBASE.md"

  if [[ -f "$output" ]] && [[ -s "$output" ]]; then
    log "♻️  Codebase map already exists. Reusing."
    return 0
  fi

  step_banner "0.0" "Mapping Codebase → ${agent}"

  send_to_agent "$agent" "You are a codebase analyst. Map the project at ${project}.

Analyze:
1. Directory structure and package organization
2. Key files: build config, main classes, entry points
3. Architecture pattern (hexagonal, layered, MVC, etc.)
4. Database: entities, repositories, migrations
5. API: controllers, endpoints, DTOs
6. Tests: structure, frameworks, coverage patterns
7. Configuration: profiles, properties, env-specific settings

Write your analysis to: ${output}

Format:
# Codebase Map

## Structure
<directory tree of important paths>

## Architecture
<pattern name + how it's implemented>

## Key Components
<most important classes/modules with their roles>

## Data Layer
<entities, tables, ORM patterns>

## API Layer
<controllers, endpoints, auth>

## Build & Config
<how to build, run, test>

## Conventions
<naming, coding style, patterns to follow>

Keep it factual and reference-heavy (file paths, class names).
When done, print: done" \
    "codebase mapping" "planner"

  if [[ -f "$output" ]] && [[ -s "$output" ]]; then
    success "Codebase mapped: ${output}"
  else
    warn "Codebase mapping may have failed"
  fi
}
