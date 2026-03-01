#!/usr/bin/env bash
#
# plan.sh — Structured Planning Module with Verification Loop
#
# Creates GSD-style XML plans from research + context, then verifies
# them with a plan-checker agent. Iterates until plans pass.
#
# Usage:
#   source modules/common.sh
#   source modules/plan.sh
#   run_planning "$PROJECT" "$PHASE_NUM" "$PLANNER_AGENT" "$CHECKER_AGENT"
#
# Outputs:
#   .codeswarm/planning/{phase}-{N}-PLAN.md (1 or more plan files)
#

set -euo pipefail

[[ -n "${_PLAN_LOADED:-}" ]] && return 0
_PLAN_LOADED=1

MODULES_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${MODULES_DIR}/common.sh"

MAX_PLAN_ITERATIONS=${MAX_PLAN_ITERATIONS:-3}

# ═══════════════════════════════════════════════════════════
# run_planning <project_dir> <phase_num> <planner_agent> [checker_agent]
#
# Creates structured plans with verification loop.
# checker_agent defaults to planner_agent if not specified.
# ═══════════════════════════════════════════════════════════
run_planning() {
  local project="$1"
  local phase_num="$2"
  local planner="$3"
  local checker="${4:-$planner}"

  banner "📋 PHASE 2: STRUCTURED PLANNING"

  local planning_dir="${project}/.codeswarm/planning"
  mkdir -p "$planning_dir"

  # Check for existing plans
  local existing_plans=()
  for pf in "${planning_dir}/${phase_num}"-*-PLAN.md; do
    [[ -f "$pf" ]] && existing_plans+=("$pf")
  done

  if [[ ${#existing_plans[@]} -gt 0 ]]; then
    log "♻️  ${#existing_plans[@]} existing plan(s) found for phase ${phase_num}."
    for ep in "${existing_plans[@]}"; do
      log "  📄 $(basename "$ep")"
    done
    success "Plans loaded from previous session"
    return 0
  fi

  # Gather context
  local project_md=$(get_project_md)
  local roadmap_md=$(get_roadmap_md)
  local context_md=$(get_context_md)
  local research_md=""

  # Try phase-specific research first, then general
  if [[ -f "${planning_dir}/${phase_num}-RESEARCH.md" ]]; then
    research_md=$(cat "${planning_dir}/${phase_num}-RESEARCH.md")
  elif [[ -f "${planning_dir}/RESEARCH.md" ]]; then
    research_md=$(cat "${planning_dir}/RESEARCH.md")
  fi

  # Extract phase description from roadmap
  local phase_desc=""
  if [[ -n "$roadmap_md" ]]; then
    phase_desc=$(echo "$roadmap_md" | sed -n "/### Phase ${phase_num}:/,/### Phase/p" | head -30)
  fi

  local plan_iteration=0
  local plans_accepted=false

  while [[ $plan_iteration -lt $MAX_PLAN_ITERATIONS ]] && ! $plans_accepted; do
    plan_iteration=$((plan_iteration + 1))

    step_banner "2.${plan_iteration}" "Planning Iteration ${plan_iteration}/${MAX_PLAN_ITERATIONS} → ${planner}"

    # Build planning prompt
    local checker_feedback=""
    if [[ -f "${planning_dir}/${phase_num}-CHECKER-FEEDBACK.md" ]]; then
      checker_feedback=$(cat "${planning_dir}/${phase_num}-CHECKER-FEEDBACK.md")
    fi

    local plan_prompt="You are a planner. Create executable implementation plans for Phase ${phase_num}.

PROJECT: ${project}
${project_md:+
PROJECT CONTEXT:
${project_md}
}
${context_md:+
IMPLEMENTATION DECISIONS:
${context_md}
}
${research_md:+
RESEARCH FINDINGS:
${research_md}
}
PHASE ${phase_num}:
${phase_desc}
$(if [[ -n "$checker_feedback" ]]; then echo "
CHECKER FEEDBACK (from previous iteration — FIX THESE ISSUES):
${checker_feedback}
"; fi)

═══════════════════════════════════════════════════════
YOUR OUTPUT: Create 1-3 plan files
═══════════════════════════════════════════════════════

For each plan, write to: ${planning_dir}/${phase_num}-{N}-PLAN.md
where {N} is 01, 02, 03...

PLAN FORMAT (each file):
\`\`\`markdown
---
phase: ${phase_num}
plan: {N}
type: implementation
autonomous: true
wave: {wave_number}
depends_on: []
---

# Plan ${phase_num}-{N}: <title>

## Objective
<what this plan achieves and why>

## Context
Read these files before starting:
- \`path/to/relevant/file.java\`
- \`path/to/another/file.java\`

## Tasks

<task type=\"auto\">
  <name>Task title</name>
  <files>path/to/file1.java, path/to/file2.java</files>
  <action>
    Specific implementation instructions.
    Reference existing patterns: \"Follow the pattern in ExistingClass.java\"
    Name exact classes, methods, fields to create.
    Include exact annotations, imports, configurations.
  </action>
  <verify>How to verify this task (e.g., 'mvn compile passes', 'endpoint responds')</verify>
  <done>What \"done\" looks like for this task</done>
</task>

<task type=\"auto\">
  <name>Next task</name>
  ...
</task>

## Success Criteria
- [ ] <measurable criterion 1>
- [ ] <measurable criterion 2>
- [ ] Build passes (mvn compile / npm run build)
\`\`\`

PLANNING RULES:
1. Each plan should have 2-4 tasks (small enough for one fresh context window)
2. Tasks are atomic — each can be committed independently
3. Use XML task format — it's optimized for AI execution
4. Be SPECIFIC: name files, classes, methods, annotations, table names
5. Reference existing code: \"Follow pattern in XxxService.java\"
6. Include build verification in every plan's success criteria
7. Group independent plans into the same wave (parallel execution)
8. Dependent plans go in later waves
9. Total plans per phase: 1-3 (keep it focused)

WAVE ASSIGNMENT:
- wave: 1 → Plans that can run in parallel (no dependencies)
- wave: 2 → Plans that depend on wave 1 results
- depends_on: [\"${phase_num}-01\"] → Specific plan dependencies

When done, print: done"

    local skills=$(get_skills_for "$planner")
    [[ -n "$skills" ]] && plan_prompt+="
${skills}"

    send_to_agent "$planner" "$plan_prompt" "planning iteration ${plan_iteration}" "planner"

    # Collect generated plans
    local plans=()
    for pf in "${planning_dir}/${phase_num}"-*-PLAN.md; do
      [[ -f "$pf" ]] && plans+=("$pf")
    done

    if [[ ${#plans[@]} -eq 0 ]]; then
      warn "No plans generated in iteration ${plan_iteration}"
      continue
    fi

    log "📄 ${#plans[@]} plan(s) generated"
    for p in "${plans[@]}"; do
      log "  → $(basename "$p")"
    done

    # ─── Verify Plans with Checker ──────────────────────
    if [[ "$checker" == "$planner" ]] && [[ $plan_iteration -ge $MAX_PLAN_ITERATIONS ]]; then
      # Skip checker on last iteration if same agent (avoid infinite loop)
      log "Last iteration — accepting plans without checker"
      plans_accepted=true
      break
    fi

    step_banner "2.${plan_iteration}c" "Plan Verification → ${checker}"

    local all_plans_content=""
    for pf in "${plans[@]}"; do
      all_plans_content+="
=== $(basename "$pf") ===
$(cat "$pf")
=== END ===
"
    done

    local checker_output="${planning_dir}/${phase_num}-CHECKER-FEEDBACK.md"

    send_to_agent "$checker" "You are a plan checker. Verify that these plans will achieve the phase goals.

PROJECT: ${project}
${project_md:+
PROJECT CONTEXT:
${project_md}
}
PHASE ${phase_num}:
${phase_desc}

${context_md:+
IMPLEMENTATION DECISIONS (plans MUST honor these):
${context_md}
}

PLANS TO VERIFY:
${all_plans_content}

VERIFICATION CHECKLIST:
1. [ ] Every phase goal has a plan task implementing it
2. [ ] File paths and class names are correct (READ the project to check)
3. [ ] Dependencies between plans are correct (wave ordering)
4. [ ] Each task is specific enough to implement without interpretation
5. [ ] Build verification is included in success criteria
6. [ ] No task is too large (>15 min of AI work)
7. [ ] Implementation decisions from CONTEXT.md are honored

Write your verdict to: ${checker_output}

FORMAT:
\`\`\`
VERDICT: PASS | FAIL

## Issues (if FAIL)
- Issue 1: <specific problem + how to fix>
- Issue 2: <specific problem + how to fix>

## Checklist Results
- [x] or [ ] for each item above

## Suggestions (optional, even if PASS)
- <improvement ideas>
\`\`\`

RULES:
- READ the actual project files to verify paths and patterns
- Be specific about issues — vague feedback wastes iterations
- PASS if plans are good enough to execute (minor suggestions OK)
- FAIL only for real problems that would cause execution failure
- When done, print: done" \
      "plan checking" "planner"

    # Parse verdict
    if [[ -f "$checker_output" ]]; then
      if grep -qi 'VERDICT:.*PASS' "$checker_output" 2>/dev/null; then
        plans_accepted=true
        success "Plans PASSED verification ✓"
      else
        warn "Plans FAILED verification — iterating..."
        # Plans will be regenerated next iteration (checker feedback is read)
        # Delete old plans so planner creates fresh ones
        for pf in "${plans[@]}"; do
          rm -f "$pf"
        done
      fi
    else
      # No checker output — accept plans
      plans_accepted=true
      log "No checker output — accepting plans"
    fi
  done

  # Final plan count
  local final_plans=()
  for pf in "${planning_dir}/${phase_num}"-*-PLAN.md; do
    [[ -f "$pf" ]] && final_plans+=("$pf")
  done

  if [[ ${#final_plans[@]} -eq 0 ]]; then
    error "No plans produced after ${plan_iteration} iterations"
    return 1
  fi

  success "Planning complete: ${#final_plans[@]} plan(s) for phase ${phase_num}"
  return 0
}

# ═══════════════════════════════════════════════════════════
# get_plan_waves <project_dir> <phase_num>
#
# Reads plan files and groups them by wave number.
# Outputs wave assignments as: wave_num:plan_file (one per line)
# ═══════════════════════════════════════════════════════════
get_plan_waves() {
  local project="$1"
  local phase_num="$2"
  local planning_dir="${project}/.codeswarm/planning"

  for pf in "${planning_dir}/${phase_num}"-*-PLAN.md; do
    [[ -f "$pf" ]] || continue
    local wave=$(grep '^wave:' "$pf" 2>/dev/null | head -1 | sed 's/wave: *//' | tr -dc '0-9')
    [[ -z "$wave" ]] && wave=1
    echo "${wave}:${pf}"
  done | sort -t: -k1 -n
}

# ═══════════════════════════════════════════════════════════
# get_max_wave <project_dir> <phase_num>
#
# Returns the highest wave number across all plans.
# ═══════════════════════════════════════════════════════════
get_max_wave() {
  local project="$1"
  local phase_num="$2"
  get_plan_waves "$project" "$phase_num" | cut -d: -f1 | sort -rn | head -1
}
