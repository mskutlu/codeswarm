#!/usr/bin/env bash
#
# verify.sh — Post-Execution Verification Module
#
# Verifies that phase deliverables match requirements.
# If failures found, auto-generates fix plans for re-execution.
#
# Usage:
#   source modules/common.sh
#   source modules/verify.sh
#   run_verification "$PROJECT" "$PHASE_NUM" "$VERIFIER_AGENT"
#
# Outputs:
#   .codeswarm/planning/{phase}-VERIFICATION.md
#   .codeswarm/planning/{phase}-FIX-{N}-PLAN.md (if issues found)
#

set -euo pipefail

[[ -n "${_VERIFY_LOADED:-}" ]] && return 0
_VERIFY_LOADED=1

MODULES_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${MODULES_DIR}/common.sh"

# ═══════════════════════════════════════════════════════════
# run_verification <project_dir> <phase_num> <verifier_agent> [fix_planner_agent]
#
# Verifies phase deliverables against requirements and plans.
# If issues found, creates fix plans that can be re-executed.
# ═══════════════════════════════════════════════════════════
run_verification() {
  local project="$1"
  local phase_num="$2"
  local verifier="$3"
  local fix_planner="${4:-$verifier}"

  banner "✅ PHASE 4: VERIFICATION"

  local planning_dir="${project}/.codeswarm/planning"
  local verification_file="${planning_dir}/${phase_num}-VERIFICATION.md"

  # Gather all plan summaries and reviews
  local summaries=""
  local reviews=""
  local plans=""

  for sf in "${planning_dir}/${phase_num}"-*-SUMMARY.md; do
    [[ -f "$sf" ]] && summaries+="
=== $(basename "$sf") ===
$(cat "$sf")
=== END ===
"
  done

  for rf in "${planning_dir}/${phase_num}"-*-REVIEW-*.md; do
    [[ -f "$rf" ]] && reviews+="
=== $(basename "$rf") ===
$(cat "$rf")
=== END ===
"
  done

  for pf in "${planning_dir}/${phase_num}"-*-PLAN.md; do
    [[ -f "$pf" ]] && plans+="
=== $(basename "$pf") ===
$(cat "$pf")
=== END ===
"
  done

  # Load planning context
  local project_md=$(get_project_md)
  local requirements_md=$(get_requirements_md)
  local roadmap_md=$(get_roadmap_md)
  local context_md=$(get_context_md)

  local phase_desc=""
  if [[ -n "$roadmap_md" ]]; then
    phase_desc=$(echo "$roadmap_md" | sed -n "/### Phase ${phase_num}:/,/### Phase/p" | head -30)
  fi

  step_banner "4.1" "Verifying Phase ${phase_num} → ${verifier}"

  send_to_agent "$verifier" "You are a verifier. Check that Phase ${phase_num} deliverables are complete and correct.

PROJECT: ${project}

PHASE ${phase_num} GOALS:
${phase_desc}

${requirements_md:+
REQUIREMENTS (check these are met):
$(echo "$requirements_md" | head -60)
}

${context_md:+
IMPLEMENTATION DECISIONS (verify these were followed):
$(echo "$context_md" | head -40)
}

ORIGINAL PLANS:
${plans}

EXECUTION SUMMARIES:
${summaries}

${reviews:+
REVIEW REPORTS:
${reviews}
}

═══════════════════════════════════════════════════════
YOUR VERIFICATION PROCESS:
═══════════════════════════════════════════════════════

1. Read the project code to verify implementations
2. Run the build (mvn compile, npm run build, etc.)
3. Check each plan's success criteria
4. Check each requirement mapped to this phase
5. Look for integration issues between plans
6. Run tests if available

Write your verification report to: ${verification_file}

FORMAT:
\`\`\`markdown
# Verification Report — Phase ${phase_num}

## Overall Status: PASS | FAIL

## Build Status: Pass | Fail
<build output summary>

## Plan Verification
### ${phase_num}-01-PLAN
- [x] Success criterion 1
- [ ] Success criterion 2 — <what's wrong>

### ${phase_num}-02-PLAN
- [x] Success criterion 1
...

## Requirements Check
- [x] REQ-001: <verified how>
- [ ] REQ-003: <what's missing>

## Integration Check
<do the plans work together correctly?>

## Issues Found
1. <specific issue with file reference>
2. <specific issue>

## Fix Recommendations
<for each issue, describe what needs to be fixed>
\`\`\`

RULES:
- Actually READ the code and RUN the build — don't guess
- Be specific about failures — file paths, expected vs actual
- A plan PASSES if all success criteria are met
- The phase PASSES if all plans pass AND requirements are met
- Minor issues (code style, comments) don't cause FAIL
- When done, print: done" \
    "verification" "planner"

  if [[ ! -f "$verification_file" ]]; then
    warn "Verification file not generated"
    return 1
  fi

  # Parse overall status
  local status="UNKNOWN"
  if grep -qi 'Overall Status:.*PASS' "$verification_file" 2>/dev/null; then
    status="PASS"
  elif grep -qi 'Overall Status:.*FAIL' "$verification_file" 2>/dev/null; then
    status="FAIL"
  fi

  if [[ "$status" == "PASS" ]]; then
    success "Phase ${phase_num} VERIFIED ✓"
    _finalize_phase "$project" "$phase_num"
    return 0
  fi

  # ─── Generate Fix Plans ─────────────────────────────
  warn "Phase ${phase_num} verification FAILED — generating fix plans"
  step_banner "4.2" "Fix Planning → ${fix_planner}"

  local verification_content=$(cat "$verification_file")

  send_to_agent "$fix_planner" "You are a planner. Create fix plans based on verification failures.

PROJECT: ${project}

VERIFICATION REPORT:
${verification_content}

Create fix plans ONLY for the specific issues found. Each fix plan should be small and focused.

Write fix plans to: ${planning_dir}/${phase_num}-FIX-{N}-PLAN.md
where {N} is 01, 02, etc.

Use the same plan format as regular plans (XML tasks, success criteria).
Set wave: 1 for all fix plans (they should be independent fixes).

Focus on:
- Build failures → fix compilation errors
- Missing implementations → implement the missing pieces
- Integration issues → fix the connections between components
- Test failures → fix the failing tests

Do NOT re-implement things that already work.
When done, print: done" \
    "fix planning" "planner"

  # Count fix plans
  local fix_count=0
  for fp in "${planning_dir}/${phase_num}"-FIX-*-PLAN.md; do
    [[ -f "$fp" ]] && fix_count=$((fix_count + 1))
  done

  if [[ $fix_count -gt 0 ]]; then
    success "${fix_count} fix plan(s) created — ready for re-execution"
  else
    warn "No fix plans generated — manual intervention may be needed"
  fi

  return 1
}

# ═══════════════════════════════════════════════════════════
# run_fix_execution <project_dir> <phase_num> <executor_agents>
#
# Executes fix plans generated by verification.
# Then re-verifies.
# ═══════════════════════════════════════════════════════════
run_fix_execution() {
  local project="$1"
  local phase_num="$2"
  local executor_list="$3"
  local verifier="${4:-}"
  local planning_dir="${project}/.codeswarm/planning"

  local fix_plans=()
  for fp in "${planning_dir}/${phase_num}"-FIX-*-PLAN.md; do
    [[ -f "$fp" ]] && fix_plans+=("$fp")
  done

  if [[ ${#fix_plans[@]} -eq 0 ]]; then
    log "No fix plans to execute"
    return 0
  fi

  step_banner "4.3" "Executing ${#fix_plans[@]} Fix Plan(s)"

  IFS=',' read -ra EXECUTORS <<< "$executor_list"
  local fix_pids=()

  for ((fi=0; fi<${#fix_plans[@]}; fi++)); do
    local fp="${fix_plans[$fi]}"
    local executor="${EXECUTORS[$((fi % ${#EXECUTORS[@]}))]}"
    local plan_name=$(basename "$fp" .md)
    local plan_content=$(cat "$fp")
    local summary_file="${planning_dir}/${plan_name}-SUMMARY.md"

    log "  🔧 ${plan_name} → ${executor}"

    send_to_agent "$executor" "You are an executor. Fix the issues described in this plan.

PROJECT: ${project}

FIX PLAN:
${plan_content}

RULES:
1. Read the files, understand the issue
2. Make the minimal fix needed
3. Verify the fix works (build passes, tests pass)
4. Git commit: \"fix(${phase_num}): <description>\"
5. Write summary to: ${summary_file}
6. When done, print: done" \
      "fix ${plan_name}" "executor" &
    fix_pids+=($!)
  done

  for pid in "${fix_pids[@]}"; do
    wait "$pid" 2>/dev/null || true
  done

  success "Fix execution complete"

  # Re-verify if verifier specified
  if [[ -n "$verifier" ]]; then
    # Remove old verification to force re-check
    rm -f "${planning_dir}/${phase_num}-VERIFICATION.md"
    run_verification "$project" "$phase_num" "$verifier"
    return $?
  fi

  return 0
}

# ═══════════════════════════════════════════════════════════
# _finalize_phase <project_dir> <phase_num>
#
# Internal: Mark phase as complete, update state and roadmap.
# ═══════════════════════════════════════════════════════════
_finalize_phase() {
  local project="$1"
  local phase_num="$2"
  local planning_dir="${project}/.codeswarm/planning"

  # Update roadmap status
  local roadmap="${planning_dir}/ROADMAP.md"
  if [[ -f "$roadmap" ]]; then
    # Find the phase section and update status
    sed -i '' "/### Phase ${phase_num}:/,/### Phase/{s/Status: .*/Status: complete/;}" "$roadmap" 2>/dev/null || true
  fi

  # Update state
  local state="${planning_dir}/STATE.md"
  if [[ -f "$state" ]]; then
    local next_phase=$((phase_num + 1))
    sed -i '' "s/^Phase: .*/Phase: ${next_phase} (not started)/" "$state" 2>/dev/null || true
    echo "- $(date '+%Y-%m-%d %H:%M'): Phase ${phase_num} COMPLETE" >> "$state"
  fi

  # Git tag
  if command -v git &>/dev/null && git -C "$project" rev-parse --is-inside-work-tree &>/dev/null 2>&1; then
    (cd "$project" && git tag "phase-${phase_num}-complete" 2>/dev/null) || true
  fi

  success "Phase ${phase_num} finalized and tagged"
}
