#!/usr/bin/env bash
#
# orchestrate.sh — Multi-Agent Orchestration Script
# Coordinates Claude Code, Gemini CLI, and Codex CLI in Plan → Execute → Review pipeline.
#
# Usage:
#   ./orchestrate.sh --project <path> --task "description" [options]
#
# Options:
#   --project <path>       Target project directory (required)
#   --task <description>   Task description (required)
#   --planner <agent>      Agent for planning   (claude|gemini|codex)  default: from config.yaml
#   --executor <agent>     Agent for execution  (claude|gemini|codex)  default: from config.yaml
#   --reviewer <agent>     Agent for review     (claude|gemini|codex)  default: from config.yaml
#   --model <model>        Override model for planner (e.g. opus, sonnet, o3)
#   --browser-test         Enable browser testing after review
#   --test-url <url>       Base URL for browser tests
#   --skip-plan            Skip planning phase (use existing plan.md)
#   --skip-review          Skip review phase
#   --config <path>        Custom config file (default: ./config.yaml)
#   --verbose              Show full agent output
#   --dry-run              Print commands without executing

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE="${SCRIPT_DIR}/config.yaml"

# ─── Colors ─────────────────────────────────────────────
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

# ─── Defaults ───────────────────────────────────────────
PROJECT=""
TASK=""
PLANNER=""
EXECUTOR=""
REVIEWER=""
MODEL_OVERRIDE=""
BROWSER_TEST=false
TEST_URL=""
SKIP_PLAN=false
SKIP_REVIEW=false
VERBOSE=false
DRY_RUN=false

# ─── Parse Arguments ────────────────────────────────────
while [[ $# -gt 0 ]]; do
  case $1 in
    --project)     PROJECT="$2"; shift 2 ;;
    --task)        TASK="$2"; shift 2 ;;
    --planner)     PLANNER="$2"; shift 2 ;;
    --executor)    EXECUTOR="$2"; shift 2 ;;
    --reviewer)    REVIEWER="$2"; shift 2 ;;
    --model)       MODEL_OVERRIDE="$2"; shift 2 ;;
    --browser-test) BROWSER_TEST=true; shift ;;
    --test-url)    TEST_URL="$2"; shift 2 ;;
    --skip-plan)   SKIP_PLAN=true; shift ;;
    --skip-review) SKIP_REVIEW=true; shift ;;
    --config)      CONFIG_FILE="$2"; shift 2 ;;
    --verbose)     VERBOSE=true; shift ;;
    --dry-run)     DRY_RUN=true; shift ;;
    -h|--help)     head -20 "$0" | tail -18; exit 0 ;;
    *)             echo -e "${RED}Unknown option: $1${NC}"; exit 1 ;;
  esac
done

# ─── Validate ────────────────────────────────────────────
if [[ -z "$PROJECT" ]]; then
  echo -e "${RED}Error: --project is required${NC}"
  exit 1
fi
if [[ -z "$TASK" ]]; then
  echo -e "${RED}Error: --task is required${NC}"
  exit 1
fi
if [[ ! -d "$PROJECT" ]]; then
  echo -e "${RED}Error: Project directory not found: $PROJECT${NC}"
  exit 1
fi

# ─── Read Config (simple YAML parsing via grep/sed) ──────
read_config() {
  local key="$1"
  local default="$2"
  if [[ -f "$CONFIG_FILE" ]]; then
    local val
    val=$(grep -E "^\s+${key}:" "$CONFIG_FILE" 2>/dev/null | head -1 | sed 's/.*:\s*//' | sed 's/#.*//' | sed 's/"//g' | xargs)
    if [[ -n "$val" ]]; then
      echo "$val"
      return
    fi
  fi
  echo "$default"
}

# Apply config defaults where CLI flags not provided
[[ -z "$PLANNER" ]]  && PLANNER=$(read_config "planner" "claude")
[[ -z "$EXECUTOR" ]] && EXECUTOR=$(read_config "executor" "gemini")
[[ -z "$REVIEWER" ]] && REVIEWER=$(read_config "reviewer" "codex")

# ─── Artifacts & Logging ─────────────────────────────────
ARTIFACTS="${PROJECT}/.codeswarm"
SESSION_ID="run_$(date +%Y%m%d_%H%M%S)"
SESSION_DIR="${ARTIFACTS}/sessions/${SESSION_ID}"
PLAN_FILE="${SESSION_DIR}/plan.md"
EXEC_LOG="${SESSION_DIR}/execution.log"
REVIEW_FILE="${SESSION_DIR}/review.md"
SCREENSHOTS_DIR="${SESSION_DIR}/screenshots"
TIMESTAMP=$(date +"%Y-%m-%d_%H-%M-%S") # This variable is not used in the provided snippet, keeping it for consistency if used elsewhere.

mkdir -p "$SESSION_DIR" "$SCREENSHOTS_DIR"

# ─── Logging ─────────────────────────────────────────────
log() { echo -e "${CYAN}[$(date +%H:%M:%S)]${NC} $1"; }
success() { echo -e "${GREEN}✓${NC} $1"; }
warn() { echo -e "${YELLOW}⚠${NC} $1"; }
error() { echo -e "${RED}✗${NC} $1"; }
header() {
  echo ""
  echo -e "${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
  echo -e "${BOLD}  $1${NC}"
  echo -e "${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
}

# ─── Agent Command Builders ─────────────────────────────
run_agent() {
  local agent="$1"
  local prompt="$2"
  local working_dir="$3"
  local output_file="$4"
  local permission_mode="${5:-plan}"

  local cmd=""
  case "$agent" in
    claude)
      local model_flag=""
      if [[ -n "$MODEL_OVERRIDE" ]]; then
        model_flag="--model $MODEL_OVERRIDE"
      else
        local default_model
        default_model=$(read_config "claude" "opus")
        [[ -n "$default_model" ]] && model_flag="--model $default_model"
      fi
      cmd="cd '$working_dir' && claude -p $model_flag --permission-mode $permission_mode '$prompt'"
      ;;
    gemini)
      local model_flag=""
      local default_model
      default_model=$(read_config "gemini" "")
      [[ -n "$default_model" ]] && model_flag="--model $default_model"
      local approval_mode="default"
      [[ "$permission_mode" == "plan" ]] && approval_mode="plan"
      [[ "$permission_mode" == "auto_edit" ]] && approval_mode="auto_edit"
      [[ "$permission_mode" == "bypassPermissions" ]] && approval_mode="yolo"
      cmd="cd '$working_dir' && gemini -p '$prompt' $model_flag --approval-mode $approval_mode"
      ;;
    codex)
      local sandbox_flag="--sandbox read-only"
      [[ "$permission_mode" == "auto_edit" ]] && sandbox_flag=""
      cmd="cd '$working_dir' && codex exec $sandbox_flag '$prompt'"
      ;;
    *)
      error "Unknown agent: $agent"
      exit 1
      ;;
  esac

  if $DRY_RUN; then
    echo -e "${YELLOW}[DRY RUN]${NC} $cmd"
    echo "# Dry run — no output" > "$output_file"
    return 0
  fi

  log "Running ${BOLD}$agent${NC}..."
  if $VERBOSE; then
    eval "$cmd" 2>&1 | tee "$output_file"
  else
    eval "$cmd" > "$output_file" 2>&1
  fi
  local exit_code=$?

  if [[ $exit_code -ne 0 ]]; then
    warn "$agent exited with code $exit_code"
  else
    success "$agent completed successfully"
  fi
  return $exit_code
}

# ─── Banner ──────────────────────────────────────────────
echo ""
echo -e "${BOLD}${CYAN}"
echo "   ╔═══════════════════════════════════════════╗"
echo "   ║     🤖 AGENTIC ORCHESTRATOR v1.0          ║"
echo "   ╚═══════════════════════════════════════════╝"
echo -e "${NC}"
echo -e "  ${BOLD}Task:${NC}     $TASK"
echo -e "  ${BOLD}Project:${NC}  $PROJECT"
echo -e "  ${BOLD}Planner:${NC}  $PLANNER"
echo -e "  ${BOLD}Executor:${NC} $EXECUTOR"
echo -e "  ${BOLD}Reviewer:${NC} $REVIEWER"
echo -e "  ${BOLD}Browser:${NC}  $BROWSER_TEST"
echo ""

# ─── PHASE 1: PLANNING ──────────────────────────────────
if ! $SKIP_PLAN; then
  header "📋 Phase 1: Planning ($PLANNER)"

  PLAN_PROMPT="You are the PLANNER agent in a multi-agent development team.

TASK: $TASK

PROJECT DIRECTORY: $PROJECT

Your job is to analyze the task and produce a detailed implementation plan.

OUTPUT FORMAT (write as markdown):
# Implementation Plan

## Task Summary
<One-paragraph summary of what needs to be done>

## File Changes
For each file to modify/create/delete:
### [MODIFY|NEW|DELETE] <filepath>
- What to change and why

## Testing Strategy
- How to verify the changes work
- What to test manually
- What automated tests to add

## Risk Assessment
- Potential issues or breaking changes
- Dependencies to be aware of

## Estimated Complexity
Rate 1-10 and explain why.

IMPORTANT:
- Be specific about file paths relative to the project root
- Include code snippets where helpful
- Consider the existing codebase patterns
- Think about edge cases"

  PLANNER_PERMISSION=$(read_config "planner" "plan")
  run_agent "$PLANNER" "$PLAN_PROMPT" "$PROJECT" "$PLAN_FILE" "$PLANNER_PERMISSION"

  log "Plan saved to: $PLAN_FILE"
  echo ""
  echo -e "${YELLOW}─── Plan Preview ──────────────────────────────────${NC}"
  head -30 "$PLAN_FILE"
  echo -e "${YELLOW}───────────────────────────────────────────────────${NC}"
  echo ""

  # Optional: pause for human review
  if [[ -t 0 ]]; then
    read -p "$(echo -e ${BOLD})Review plan and press Enter to continue (or Ctrl+C to abort)...$(echo -e ${NC}) "
  fi
else
  log "Skipping planning phase (using existing plan)"
  if [[ ! -f "$PLAN_FILE" ]]; then
    error "No existing plan found at $PLAN_FILE"
    exit 1
  fi
fi

# ─── PHASE 2: EXECUTION ─────────────────────────────────
header "⚡ Phase 2: Execution ($EXECUTOR)"

PLAN_CONTENT=$(cat "$PLAN_FILE")

EXEC_PROMPT="You are the EXECUTOR agent in a multi-agent development team.

TASK: $TASK

You must implement the following plan EXACTLY. Do not deviate from the plan unless you encounter a blocker.

=== PLAN ===
$PLAN_CONTENT
=== END PLAN ===

INSTRUCTIONS:
1. Read the relevant files first to understand current state
2. Make the changes described in the plan
3. After making changes, run any build/compile commands to verify
4. If you encounter issues, fix them and document what you changed

IMPORTANT:
- Follow the plan precisely
- Create new files where specified
- Modify existing files as described
- Run tests if the plan includes a testing strategy
- Log any deviations from the plan"

EXECUTOR_PERMISSION=$(read_config "executor" "auto_edit")
run_agent "$EXECUTOR" "$EXEC_PROMPT" "$PROJECT" "$EXEC_LOG" "$EXECUTOR_PERMISSION"

log "Execution log saved to: $EXEC_LOG"

# ─── PHASE 3: REVIEW ────────────────────────────────────
if ! $SKIP_REVIEW; then
  header "🔍 Phase 3: Review ($REVIEWER)"

  # Capture git diff for the reviewer
  DIFF_OUTPUT=""
  if command -v git &>/dev/null && git -C "$PROJECT" rev-parse --is-inside-work-tree &>/dev/null; then
    DIFF_OUTPUT=$(git -C "$PROJECT" diff --stat 2>/dev/null || echo "No git diff available")
    DIFF_DETAIL=$(git -C "$PROJECT" diff 2>/dev/null | head -500 || echo "")
  fi

  REVIEW_PROMPT="You are the REVIEWER agent in a multi-agent development team.

TASK: $TASK

You must review the changes made by the executor agent.

=== ORIGINAL PLAN ===
$PLAN_CONTENT
=== END PLAN ===

=== GIT DIFF SUMMARY ===
$DIFF_OUTPUT
=== END DIFF SUMMARY ===

=== DIFF DETAIL (first 500 lines) ===
$DIFF_DETAIL
=== END DIFF ===

REVIEW CHECKLIST:
1. ✅ Does the implementation match the plan?
2. ✅ Are there any bugs or logic errors?
3. ✅ Code quality: naming, structure, patterns
4. ✅ Are edge cases handled?
5. ✅ Security considerations
6. ✅ Performance concerns
7. ✅ Missing tests or documentation
8. ✅ Breaking changes

OUTPUT FORMAT (markdown):
# Code Review Report

## Summary
<Overall assessment: APPROVED | NEEDS_CHANGES | REJECTED>

## Findings
### Critical Issues
- ...

### Warnings
- ...

### Suggestions
- ...

## Plan Adherence
<Did the executor follow the plan? Any deviations?>

## Verdict
<Final recommendation with reasoning>"

  REVIEWER_PERMISSION=$(read_config "reviewer" "plan")
  run_agent "$REVIEWER" "$REVIEW_PROMPT" "$PROJECT" "$REVIEW_FILE" "$REVIEWER_PERMISSION"

  log "Review saved to: $REVIEW_FILE"
fi

# ─── PHASE 4: BROWSER TESTING ───────────────────────────
if $BROWSER_TEST; then
  header "🌐 Phase 4: Browser Testing (Playwright MCP)"

  if [[ -z "$TEST_URL" ]]; then
    TEST_URL=$(read_config "base_url" "http://localhost:4200")
  fi

  BROWSER_PROMPT="You are a QA agent performing browser-based testing.

TASK: Test the changes made for: $TASK

TEST URL: $TEST_URL

INSTRUCTIONS:
1. Navigate to $TEST_URL
2. Login with test credentials if required
3. Navigate to the relevant pages affected by the task
4. Click buttons, fill forms, and interact with the UI
5. Take a screenshot at EACH significant step
6. Verify that the expected behavior matches the plan
7. Report any visual glitches, broken layouts, or errors

OUTPUT FORMAT (markdown):
# Browser Test Report

## Test Environment
- URL: $TEST_URL
- Browser: Chromium
- Date: $TIMESTAMP

## Test Steps
### Step 1: [Description]
- Action: ...
- Expected: ...
- Actual: ...
- Screenshot: [filename]
- Status: PASS | FAIL

## Summary
- Total steps: N
- Passed: N
- Failed: N
- Screenshots: [list]"

  # Use Claude with --chrome or Playwright MCP for browser testing
  BROWSER_AGENT="${PLANNER}"  # default to planner agent for browser tests
  TEST_REPORT="${AGENTIC_DIR}/test-report.md"

  run_agent "$BROWSER_AGENT" "$BROWSER_PROMPT" "$PROJECT" "$TEST_REPORT" "default"

  log "Test report saved to: $TEST_REPORT"
fi

# ─── FINAL REPORT ────────────────────────────────────────
header "📊 Final Summary"

REPORT_FILE="${AGENTIC_DIR}/report-${TIMESTAMP}.md"
cat > "$REPORT_FILE" <<EOF
# Orchestration Report

**Date:** $TIMESTAMP
**Task:** $TASK
**Project:** $PROJECT

## Agent Assignments
| Role | Agent |
|------|-------|
| Planner | $PLANNER |
| Executor | $EXECUTOR |
| Reviewer | $REVIEWER |

## Artifacts
- Plan: [plan.md](./plan.md)
- Execution Log: [execution.log](./execution.log)
- Review: [review.md](./review.md)
$(if $BROWSER_TEST; then echo "- Test Report: [test-report.md](./test-report.md)"; fi)

## Quick Links
- \`cat ${PLAN_FILE}\`
- \`cat ${REVIEW_FILE}\`
EOF

success "Report saved to: $REPORT_FILE"
echo ""
echo -e "${GREEN}${BOLD}All phases complete!${NC}"
echo -e "  📋 Plan:    ${PLAN_FILE}"
echo -e "  ⚡ Log:     ${EXEC_LOG}"
echo -e "  🔍 Review:  ${REVIEW_FILE}"
if $BROWSER_TEST; then
  echo -e "  🌐 Tests:   ${AGENTIC_DIR}/test-report.md"
fi
echo -e "  📊 Report:  ${REPORT_FILE}"
echo ""
