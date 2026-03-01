#!/usr/bin/env bash
#
# execute.sh — Wave-Based Multi-Agent Execution Module
#
# Executes plans in dependency-aware waves. Within each wave, plans
# run in parallel across different AI agents. Each agent gets a
# fresh context window with only the plan + relevant project files.
#
# Usage:
#   source modules/common.sh
#   source modules/plan.sh
#   source modules/execute.sh
#   run_execution "$PROJECT" "$PHASE_NUM" "claude,gemini,codex"
#
# Outputs:
#   .codeswarm/planning/{phase}-{N}-SUMMARY.md per plan
#   Git commits per completed task
#

set -euo pipefail

[[ -n "${_EXECUTE_LOADED:-}" ]] && return 0
_EXECUTE_LOADED=1

MODULES_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${MODULES_DIR}/common.sh"
source "${MODULES_DIR}/plan.sh"

MAX_TASK_RETRIES=${MAX_TASK_RETRIES:-2}

# ═══════════════════════════════════════════════════════════
# run_execution <project_dir> <phase_num> <executor_agents> [reviewer_agents]
#
# executor_agents: comma-separated list of agents for execution
#   Plans are round-robin assigned to executors.
#   e.g. "claude,gemini" → plan 1→claude, plan 2→gemini, plan 3→claude
#
# reviewer_agents: comma-separated list of agents for post-execution review
#   Optional. If provided, each plan gets reviewed after execution.
# ═══════════════════════════════════════════════════════════
run_execution() {
  local project="$1"
  local phase_num="$2"
  local executor_list="$3"
  local reviewer_list="${4:-}"

  banner "⚡ PHASE 3: WAVE EXECUTION"

  local planning_dir="${project}/.codeswarm/planning"

  # Parse executors
  IFS=',' read -ra EXECUTORS <<< "$executor_list"
  [[ ${#EXECUTORS[@]} -eq 0 ]] && { error "No executors specified"; return 1; }

  # Parse reviewers
  local REVIEWERS=()
  if [[ -n "$reviewer_list" ]]; then
    IFS=',' read -ra REVIEWERS <<< "$reviewer_list"
  fi

  # Get wave assignments
  local wave_data
  wave_data=$(get_plan_waves "$project" "$phase_num")

  if [[ -z "$wave_data" ]]; then
    error "No plans found for phase ${phase_num}"
    return 1
  fi

  local max_wave
  max_wave=$(echo "$wave_data" | cut -d: -f1 | sort -rn | head -1)
  [[ -z "$max_wave" ]] && max_wave=1

  log "Execution plan:"
  log "  Executors: ${EXECUTORS[*]}"
  [[ ${#REVIEWERS[@]} -gt 0 ]] && log "  Reviewers: ${REVIEWERS[*]}"
  log "  Waves: ${max_wave}"
  log "  Plans: $(echo "$wave_data" | wc -l | tr -d ' ')"

  # Load context for executor prompts
  local project_md=$(get_project_md)
  local context_md=$(get_context_md)

  local total_plans=0
  local completed_plans=0
  local failed_plans=0

  # Execute wave by wave
  for ((wave=1; wave<=max_wave; wave++)); do
    step_banner "3.w${wave}" "Wave ${wave}/${max_wave}"

    # Get plans for this wave
    local wave_plans=()
    while IFS= read -r line; do
      local w="${line%%:*}"
      local pf="${line#*:}"
      [[ "$w" -eq "$wave" ]] && wave_plans+=("$pf")
    done <<< "$wave_data"

    if [[ ${#wave_plans[@]} -eq 0 ]]; then
      log "No plans in wave ${wave} — skipping"
      continue
    fi

    log "Wave ${wave}: ${#wave_plans[@]} plan(s) to execute in parallel"

    # Launch plans in parallel, round-robin across executors
    local plan_pids=()
    local plan_files=()
    local plan_executors=()

    for ((pi=0; pi<${#wave_plans[@]}; pi++)); do
      local plan_file="${wave_plans[$pi]}"
      local executor_idx=$((pi % ${#EXECUTORS[@]}))
      local executor="${EXECUTORS[$executor_idx]}"
      local plan_name=$(basename "$plan_file" .md)
      local summary_file="${planning_dir}/${plan_name}-SUMMARY.md"

      total_plans=$((total_plans + 1))

      # Skip already-completed plans
      if [[ -f "$summary_file" ]] && grep -qi 'STATUS:.*complete' "$summary_file" 2>/dev/null; then
        log "  ♻️  ${plan_name} already completed — skipping"
        completed_plans=$((completed_plans + 1))
        continue
      fi

      local plan_content=$(cat "$plan_file")

      log "  🚀 ${plan_name} → ${executor}"

      # Build executor prompt — fresh context, only what's needed
      local exec_prompt="You are an executor. Implement the following plan in project ${project}.

READ THE PLAN CAREFULLY. Execute every task in order. Commit after each task.

${project_md:+
PROJECT CONTEXT (brief):
$(echo "$project_md" | head -40)
}
${context_md:+
IMPLEMENTATION DECISIONS (follow these):
$(echo "$context_md" | head -30)
}

═══════════════════════════════════════════════════════
PLAN TO EXECUTE:
═══════════════════════════════════════════════════════
${plan_content}

═══════════════════════════════════════════════════════
EXECUTION RULES:
═══════════════════════════════════════════════════════
1. Read the project files referenced in the plan's Context section FIRST
2. For each <task>:
   a. Implement exactly what the <action> says
   b. Run the <verify> step to confirm it works
   c. If verify fails, fix and retry (max ${MAX_TASK_RETRIES} retries)
   d. Git commit with message: \"feat(${phase_num}-${plan_name}): <task name>\"
3. After ALL tasks: run the Success Criteria checks
4. Write a summary to: ${summary_file}

SUMMARY FORMAT:
\`\`\`markdown
# Summary: ${plan_name}

## Status: complete | partial | failed

## Tasks
- [x] Task 1: <title> — <commit hash>
- [x] Task 2: <title> — <commit hash>
- [ ] Task 3: <title> — <reason for failure>

## Deviations
<any changes from the plan + reasoning>

## Verification
<results of success criteria checks>
\`\`\`

5. Do NOT modify any files in .codeswarm/planning/ (except the summary file above)
6. Do NOT skip tasks — implement ALL of them
7. When done, print: done"

      local skills=$(get_skills_for "$executor")
      [[ -n "$skills" ]] && exec_prompt+="
${skills}"

      # Launch in background
      send_to_agent "$executor" "$exec_prompt" "execute ${plan_name}" "executor" &
      plan_pids+=($!)
      plan_files+=("$plan_file")
      plan_executors+=("$executor")
    done

    # Wait for all plans in this wave
    if [[ ${#plan_pids[@]} -gt 0 ]]; then
      log "⏳ Waiting for wave ${wave} (${#plan_pids[@]} agents)..."

      for ((pi=0; pi<${#plan_pids[@]}; pi++)); do
        local pid="${plan_pids[$pi]}"
        local pf="${plan_files[$pi]}"
        local plan_name=$(basename "$pf" .md)
        local summary_file="${planning_dir}/${plan_name}-SUMMARY.md"

        if wait "$pid" 2>/dev/null; then
          if [[ -f "$summary_file" ]]; then
            if grep -qi 'STATUS:.*complete' "$summary_file" 2>/dev/null; then
              completed_plans=$((completed_plans + 1))
              success "${plan_name} completed ✓"
            elif grep -qi 'STATUS:.*partial' "$summary_file" 2>/dev/null; then
              completed_plans=$((completed_plans + 1))
              warn "${plan_name} partially completed"
            else
              failed_plans=$((failed_plans + 1))
              warn "${plan_name} may have issues — check summary"
            fi
          else
            # No summary but agent exited OK — optimistic
            completed_plans=$((completed_plans + 1))
            warn "${plan_name} finished (no summary file)"
          fi
        else
          failed_plans=$((failed_plans + 1))
          error "${plan_name} execution FAILED"
        fi
      done
    fi

    success "Wave ${wave} complete"

    # ─── Optional: Review after wave ────────────────────
    if [[ ${#REVIEWERS[@]} -gt 0 ]]; then
      _review_wave "$project" "$phase_num" "$wave" "${wave_plans[*]}"
    fi
  done

  # ─── Execution Summary ────────────────────────────────
  echo ""
  log "📊 Execution Results:"
  log "  Total plans:     ${total_plans}"
  log "  Completed:       ${completed_plans}"
  [[ $failed_plans -gt 0 ]] && log "  Failed:          ${failed_plans}"

  if [[ $failed_plans -gt 0 ]]; then
    warn "${failed_plans} plan(s) failed — verify module will create fix plans"
    return 1
  fi

  success "Phase ${phase_num} execution complete: ${completed_plans}/${total_plans} plans"
  return 0
}

# ═══════════════════════════════════════════════════════════
# _review_wave <project> <phase> <wave> <plan_files>
#
# Internal: Review plans after execution. Reviewers run in parallel.
# Results are saved for the verify module.
# ═══════════════════════════════════════════════════════════
_review_wave() {
  local project="$1"
  local phase_num="$2"
  local wave="$3"
  local plan_files_str="$4"
  local planning_dir="${project}/.codeswarm/planning"

  step_banner "3.r${wave}" "Reviewing Wave ${wave} → ${REVIEWERS[*]}"

  # Get changed files since wave started
  local changed_files=""
  if command -v git &>/dev/null && git -C "$project" rev-parse --is-inside-work-tree &>/dev/null 2>&1; then
    changed_files=$(cd "$project" && git diff --name-only HEAD~5 2>/dev/null | head -30 || echo "(no git changes)")
  fi

  local review_pids=()

  for plan_file in $plan_files_str; do
    [[ -f "$plan_file" ]] || continue
    local plan_name=$(basename "$plan_file" .md)
    local plan_content=$(cat "$plan_file")
    local summary_file="${planning_dir}/${plan_name}-SUMMARY.md"
    local summary_content=""
    [[ -f "$summary_file" ]] && summary_content=$(cat "$summary_file")

    # Round-robin reviewers across plans
    for ((ri=0; ri<${#REVIEWERS[@]}; ri++)); do
      local reviewer="${REVIEWERS[$ri]}"
      local review_file="${planning_dir}/${plan_name}-REVIEW-${reviewer}.md"

      send_to_agent "$reviewer" "You are a code reviewer. Review the implementation of plan ${plan_name} in project ${project}.

PLAN (what was supposed to be built):
${plan_content}

${summary_content:+
EXECUTION SUMMARY:
${summary_content}
}

CHANGED FILES:
${changed_files}

YOUR TASK:
1. Read the changed files in the project
2. Verify each task in the plan was implemented correctly
3. Check for bugs, missing edge cases, code quality issues
4. Verify the build passes

Write your review to: ${review_file}

FORMAT:
\`\`\`markdown
# Review: ${plan_name}

## Build Status: Pass | Fail
## Code Quality: Good | Acceptable | Needs Work

## Task Verification
- [x] Task 1: <implemented correctly>
- [ ] Task 2: <issue description>

## Issues
- <specific issue with file:line reference>

## Assessment
<1-2 sentence summary>
\`\`\`

RULES:
- You provide FEEDBACK only — do not modify code
- Be specific — reference files, lines, methods
- Focus on correctness over style
- When done, print: done" \
        "review ${plan_name}" "executor" &
      review_pids+=($!)
    done
  done

  # Wait for all reviewers
  for rpid in "${review_pids[@]}"; do
    wait "$rpid" 2>/dev/null || true
  done

  success "Wave ${wave} reviews complete"
}

# ═══════════════════════════════════════════════════════════
# run_single_plan <project_dir> <plan_file> <executor_agent>
#
# Execute a single plan file (useful for fix plans or re-execution).
# ═══════════════════════════════════════════════════════════
run_single_plan() {
  local project="$1"
  local plan_file="$2"
  local executor="$3"
  local planning_dir="${project}/.codeswarm/planning"
  local plan_name=$(basename "$plan_file" .md)
  local summary_file="${planning_dir}/${plan_name}-SUMMARY.md"

  local plan_content=$(cat "$plan_file")
  local project_md=$(get_project_md)

  log "🔨 Executing single plan: ${plan_name} → ${executor}"

  send_to_agent "$executor" "You are an executor. Implement the following plan in project ${project}.

${project_md:+
PROJECT CONTEXT (brief):
$(echo "$project_md" | head -30)
}

PLAN:
${plan_content}

RULES:
1. Read referenced files first
2. Implement each task, verify, commit
3. Write summary to: ${summary_file}
4. When done, print: done" \
    "execute ${plan_name}" "executor"

  if [[ -f "$summary_file" ]] && grep -qi 'STATUS:.*complete' "$summary_file" 2>/dev/null; then
    success "${plan_name} completed"
    return 0
  else
    warn "${plan_name} may not be fully complete"
    return 1
  fi
}
