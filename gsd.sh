#!/usr/bin/env bash
#
# gsd.sh — GSD Modular Pipeline Entry Point
#
# Chains: context → research → plan → execute → verify
# Each module can also be run independently.
#
# Usage:
#   # Full autonomous pipeline
#   ./gsd.sh --project ~/my-app --task "Add user authentication"
#
#   # Full pipeline with PRD file
#   ./gsd.sh --project ~/my-app --prd docs/feature.md
#
#   # Run individual modules
#   ./gsd.sh --project ~/my-app --only context --task "Add auth"
#   ./gsd.sh --project ~/my-app --only research --phase 1
#   ./gsd.sh --project ~/my-app --only plan --phase 1
#   ./gsd.sh --project ~/my-app --only execute --phase 1
#   ./gsd.sh --project ~/my-app --only verify --phase 1
#
#   # Multi-agent configuration
#   ./gsd.sh --project ~/my-app --task "Big feature" \
#     --planner claude --executor gemini,claude --reviewer codex \
#     --researcher gemini,claude,codex,gemini
#
#   # Resume from a specific phase
#   ./gsd.sh --project ~/my-app --phase 2
#
#   # With dashboard
#   ./gsd.sh --project ~/my-app --task "Feature" --dashboard
#

set -euo pipefail
shopt -s nullglob

# ─── Resolve paths ──────────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# Source all modules
source "${SCRIPT_DIR}/modules/common.sh"
source "${SCRIPT_DIR}/modules/context.sh"
source "${SCRIPT_DIR}/modules/research.sh"
source "${SCRIPT_DIR}/modules/plan.sh"
source "${SCRIPT_DIR}/modules/execute.sh"
source "${SCRIPT_DIR}/modules/verify.sh"

# ─── Defaults ───────────────────────────────────────────
PROJECT=""
TASK=""
PRD_FILE=""
PHASE=""                  # specific phase to run (or empty for auto)
ONLY=""                   # run only one module: context|research|plan|execute|verify
PLANNER="claude"
EXECUTOR="claude"
REVIEWER=""               # optional
RESEARCHER=""             # comma-separated 4 agents for research (default: planner x4)
CHECKER=""                # plan checker agent (default: same as planner)
VERIFIER=""               # verification agent (default: same as planner)
MAX_PHASES=20             # safety limit
MAX_FIX_ROUNDS=2          # max verify→fix→verify cycles
DASHBOARD=false
SKIP_RESEARCH=false
SKIP_VERIFY=false
MAP_CODEBASE=false
CONTEXT_FILES=""

# ─── Help ───────────────────────────────────────────────
_show_help() {
  cat <<'HELP'
GSD Pipeline — Autonomous Multi-Agent Development

USAGE:
  ./gsd.sh --project <dir> --task "description"   # Full pipeline from task
  ./gsd.sh --project <dir> --prd <file>            # Full pipeline from PRD
  ./gsd.sh --project <dir> --phase <N>             # Resume from phase N
  ./gsd.sh --project <dir> --only <module>         # Run single module

MODULES (--only):
  context    Auto-generate planning documents (PROJECT.md, ROADMAP.md, etc.)
  research   Parallel multi-agent research for a phase
  plan       Create structured plans with verification loop
  execute    Wave-based multi-agent execution
  verify     Verify deliverables and auto-generate fix plans

AGENT FLAGS:
  --planner <agent>      Planning agent (default: claude)
  --executor <agents>    Comma-separated executors (default: claude)
  --reviewer <agents>    Comma-separated reviewers (optional)
  --researcher <agents>  4 comma-separated research agents
  --checker <agent>      Plan verification agent
  --verifier <agent>     Post-execution verification agent
  --model <overrides>    Model per agent: agent:model[,agent:model]

OPTIONS:
  --skip-research        Skip research phase
  --skip-verify          Skip verification phase
  --map-codebase         Map existing codebase before context generation
  --dashboard            Start real-time monitoring dashboard
  --dry-run              Print prompts without executing
  --max-phases N         Maximum phases to execute (default: 20)
  --max-fix-rounds N     Maximum verify→fix cycles (default: 2)

EXAMPLES:
  # Simple autonomous run
  ./gsd.sh --project ~/app --task "Add JWT auth" --planner claude --executor gemini

  # Multi-agent power run
  ./gsd.sh --project ~/app --prd docs/prd.md \
    --planner claude --executor gemini,claude,codex \
    --reviewer codex --researcher gemini,claude,codex,gemini \
    --dashboard

  # Just plan phase 2
  ./gsd.sh --project ~/app --only plan --phase 2 --planner codex

  # Execute and verify phase 1
  ./gsd.sh --project ~/app --only execute --phase 1 --executor claude,gemini
  ./gsd.sh --project ~/app --only verify --phase 1 --verifier claude
HELP
}

# ─── Parse Arguments ────────────────────────────────────
while [[ $# -gt 0 ]]; do
  case $1 in
    --project)        PROJECT="$2"; shift 2 ;;
    --task)           TASK="$2"; shift 2 ;;
    --prd)            PRD_FILE="$2"; shift 2 ;;
    --phase)          PHASE="$2"; shift 2 ;;
    --only)           ONLY="$2"; shift 2 ;;
    --planner)        PLANNER="$2"; shift 2 ;;
    --executor)       EXECUTOR="$2"; shift 2 ;;
    --reviewer)       REVIEWER="$2"; shift 2 ;;
    --researcher)     RESEARCHER="$2"; shift 2 ;;
    --checker)        CHECKER="$2"; shift 2 ;;
    --verifier)       VERIFIER="$2"; shift 2 ;;
    --model)          MODEL_OVERRIDES="$2"; shift 2 ;;
    --max-phases)     MAX_PHASES="$2"; shift 2 ;;
    --max-fix-rounds) MAX_FIX_ROUNDS="$2"; shift 2 ;;
    --dashboard)      DASHBOARD=true; shift ;;
    --dashboard-port) DASHBOARD=true; DASHBOARD_PORT="$2"; shift 2 ;;
    --skip-research)  SKIP_RESEARCH=true; shift ;;
    --skip-verify)    SKIP_VERIFY=true; shift ;;
    --map-codebase)   MAP_CODEBASE=true; shift ;;
    --context)        CONTEXT_FILES="$2"; shift 2 ;;
    --dry-run)        DRY_RUN=true; shift ;;
    -h|--help)        _show_help; exit 0 ;;
    *)                echo -e "${RED}Unknown: $1${NC}"; exit 1 ;;
  esac
done

# ─── Validate ───────────────────────────────────────────
[[ -z "$PROJECT" ]] && { error "--project required"; exit 1; }
PROJECT=$(cd "$PROJECT" 2>/dev/null && pwd)

if [[ -z "$TASK" && -z "$PRD_FILE" && -z "$PHASE" && -z "$ONLY" ]]; then
  error "Provide --task, --prd, --phase, or --only"
  exit 1
fi

# Resolve defaults
[[ -z "$CHECKER" ]] && CHECKER="$PLANNER"
[[ -z "$VERIFIER" ]] && VERIFIER="$PLANNER"
[[ -z "$RESEARCHER" ]] && RESEARCHER="${PLANNER},${PLANNER},${PLANNER},${PLANNER}"

# Export PROJECT for modules
export PROJECT

# ─── Initialize Session ─────────────────────────────────
init_session "$PROJECT"

# ─── Banner ──────────────────────────────────────────────
echo ""
echo -e "${BOLD}${MAGENTA}"
echo "   ╔═══════════════════════════════════════════════════════╗"
echo "   ║   🚀 GSD PIPELINE — Autonomous Multi-Agent Dev       ║"
echo "   ╚═══════════════════════════════════════════════════════╝"
echo -e "${NC}"
echo -e "  ${BOLD}Project:${NC}     $PROJECT"
[[ -n "$TASK" ]] && echo -e "  ${BOLD}Task:${NC}        ${TASK:0:80}"
[[ -n "$PRD_FILE" ]] && echo -e "  ${BOLD}PRD:${NC}         $PRD_FILE"
echo -e "  ${BOLD}Planner:${NC}     $PLANNER"
echo -e "  ${BOLD}Executor(s):${NC} $EXECUTOR"
[[ -n "$REVIEWER" ]] && echo -e "  ${BOLD}Reviewer(s):${NC} $REVIEWER"
echo -e "  ${BOLD}Researcher:${NC}  $RESEARCHER"
echo -e "  ${BOLD}Checker:${NC}     $CHECKER"
echo -e "  ${BOLD}Verifier:${NC}    $VERIFIER"
[[ -n "$ONLY" ]] && echo -e "  ${BOLD}Module:${NC}      ${ONLY} only"
[[ -n "$PHASE" ]] && echo -e "  ${BOLD}Phase:${NC}       ${PHASE}"
$DASHBOARD && echo -e "  ${BOLD}Dashboard:${NC}   http://localhost:${DASHBOARD_PORT}"
echo -e "  ${BOLD}Session:${NC}     ${SESSION_ID}"
echo ""

# ─── Start Dashboard ────────────────────────────────────
if $DASHBOARD; then
  start_dashboard "$PROJECT"
fi

# ─── Read extra context files ───────────────────────────
EXTRA_CONTEXT=""
if [[ -n "$CONTEXT_FILES" ]]; then
  IFS=',' read -ra CFILES <<< "$CONTEXT_FILES"
  for cf in "${CFILES[@]}"; do
    cf=$(echo "$cf" | xargs)
    local_path=""
    [[ -f "$PROJECT/$cf" ]] && local_path="$PROJECT/$cf"
    [[ -f "$cf" ]] && local_path="$cf"
    if [[ -n "$local_path" ]]; then
      EXTRA_CONTEXT+="
=== FILE: ${cf} ===
$(cat "$local_path")
=== END ===
"
    fi
  done
fi

# Resolve PRD input
INPUT=""
if [[ -n "$PRD_FILE" ]]; then
  [[ ! -f "$PRD_FILE" ]] && [[ -f "$PROJECT/$PRD_FILE" ]] && PRD_FILE="$PROJECT/$PRD_FILE"
  [[ ! -f "$PRD_FILE" ]] && { error "PRD file not found: $PRD_FILE"; exit 1; }
  INPUT="$PRD_FILE"
elif [[ -n "$TASK" ]]; then
  INPUT="$TASK"
fi

# ═══════════════════════════════════════════════════════════
# SINGLE MODULE MODE (--only)
# ═══════════════════════════════════════════════════════════
if [[ -n "$ONLY" ]]; then
  case "$ONLY" in
    context)
      [[ -z "$INPUT" ]] && { error "--task or --prd required for context module"; exit 1; }
      generate_context "$PROJECT" "$INPUT" "$PLANNER" "$EXTRA_CONTEXT"
      ;;
    research)
      [[ -z "$PHASE" ]] && { error "--phase required for research module"; exit 1; }
      run_research "$PROJECT" "$PHASE" "$RESEARCHER"
      ;;
    plan)
      [[ -z "$PHASE" ]] && { error "--phase required for plan module"; exit 1; }
      run_planning "$PROJECT" "$PHASE" "$PLANNER" "$CHECKER"
      ;;
    execute)
      [[ -z "$PHASE" ]] && { error "--phase required for execute module"; exit 1; }
      run_execution "$PROJECT" "$PHASE" "$EXECUTOR" "$REVIEWER"
      ;;
    verify)
      [[ -z "$PHASE" ]] && { error "--phase required for verify module"; exit 1; }
      run_verification "$PROJECT" "$PHASE" "$VERIFIER"
      ;;
    *)
      error "Unknown module: $ONLY (expected: context|research|plan|execute|verify)"
      exit 1
      ;;
  esac
  stop_dashboard
  exit $?
fi

# ═══════════════════════════════════════════════════════════
# FULL PIPELINE MODE
# ═══════════════════════════════════════════════════════════
PIPELINE_START=$(date +%s)

# ─── Step 0: Codebase Mapping (optional) ─────────────────
if $MAP_CODEBASE; then
  run_codebase_map "$PROJECT" "$PLANNER"
fi

# ─── Step 1: Auto-Context Generation ─────────────────────
if [[ -n "$INPUT" ]]; then
  generate_context "$PROJECT" "$INPUT" "$PLANNER" "$EXTRA_CONTEXT" || {
    error "Context generation failed"
    stop_dashboard
    exit 1
  }
fi

# ─── Step 2+: Phase Loop ─────────────────────────────────
# Determine phases from roadmap
PLANNING_DIR="${PROJECT}/.codeswarm/planning"
ROADMAP_FILE="${PLANNING_DIR}/ROADMAP.md"

if [[ ! -f "$ROADMAP_FILE" ]]; then
  error "No ROADMAP.md found — context generation may have failed"
  stop_dashboard
  exit 1
fi

# Extract phase numbers from roadmap
PHASES=()
while IFS= read -r line; do
  if [[ "$line" =~ ^###\ Phase\ ([0-9]+): ]]; then
    PHASES+=("${BASH_REMATCH[1]}")
  fi
done < "$ROADMAP_FILE"

if [[ ${#PHASES[@]} -eq 0 ]]; then
  error "No phases found in ROADMAP.md"
  stop_dashboard
  exit 1
fi

log "Found ${#PHASES[@]} phase(s) in roadmap: ${PHASES[*]}"

# If --phase specified, start from that phase
START_PHASE=0
if [[ -n "$PHASE" ]]; then
  for ((pi=0; pi<${#PHASES[@]}; pi++)); do
    [[ "${PHASES[$pi]}" == "$PHASE" ]] && { START_PHASE=$pi; break; }
  done
fi

# Execute phases
PHASES_COMPLETED=0
PHASES_FAILED=0

for ((pi=START_PHASE; pi<${#PHASES[@]} && pi<MAX_PHASES; pi++)); do
  CURRENT_PHASE="${PHASES[$pi]}"

  # Check if phase already complete
  if grep -q "### Phase ${CURRENT_PHASE}:.*complete" "$ROADMAP_FILE" 2>/dev/null ||
     grep -q "Status: complete" <(sed -n "/### Phase ${CURRENT_PHASE}:/,/### Phase/p" "$ROADMAP_FILE") 2>/dev/null; then
    log "♻️  Phase ${CURRENT_PHASE} already complete — skipping"
    PHASES_COMPLETED=$((PHASES_COMPLETED + 1))
    continue
  fi

  echo ""
  echo -e "${BOLD}${MAGENTA}╔══════════════════════════════════════════════════════╗${NC}"
  echo -e "${BOLD}${MAGENTA}║  📦 PHASE ${CURRENT_PHASE}                                            ║${NC}"
  echo -e "${BOLD}${MAGENTA}╚══════════════════════════════════════════════════════╝${NC}"

  update_state "$PROJECT" "$CURRENT_PHASE" "in_progress" "Starting phase ${CURRENT_PHASE}"

  # ─── Research ────────────────────────────────────────
  if ! $SKIP_RESEARCH; then
    run_research "$PROJECT" "$CURRENT_PHASE" "$RESEARCHER" "$PLANNER" || {
      warn "Research had issues — continuing with available data"
    }
  else
    log "⏩ Skipping research (--skip-research)"
  fi

  # ─── Plan ────────────────────────────────────────────
  run_planning "$PROJECT" "$CURRENT_PHASE" "$PLANNER" "$CHECKER" || {
    error "Planning failed for phase ${CURRENT_PHASE}"
    PHASES_FAILED=$((PHASES_FAILED + 1))
    update_state "$PROJECT" "$CURRENT_PHASE" "failed" "Planning failed"
    continue
  }

  # ─── Execute ─────────────────────────────────────────
  run_execution "$PROJECT" "$CURRENT_PHASE" "$EXECUTOR" "$REVIEWER"
  local exec_result=$?

  # ─── Verify ──────────────────────────────────────────
  if ! $SKIP_VERIFY; then
    local fix_round=0
    local phase_verified=false

    while [[ $fix_round -lt $MAX_FIX_ROUNDS ]] && ! $phase_verified; do
      if run_verification "$PROJECT" "$CURRENT_PHASE" "$VERIFIER" "$PLANNER"; then
        phase_verified=true
      else
        fix_round=$((fix_round + 1))
        if [[ $fix_round -lt $MAX_FIX_ROUNDS ]]; then
          log "🔧 Fix round ${fix_round}/${MAX_FIX_ROUNDS}..."
          run_fix_execution "$PROJECT" "$CURRENT_PHASE" "$EXECUTOR" "$VERIFIER" || true
        fi
      fi
    done

    if $phase_verified; then
      PHASES_COMPLETED=$((PHASES_COMPLETED + 1))
      update_state "$PROJECT" "$CURRENT_PHASE" "complete" "Phase verified and complete"
    else
      PHASES_FAILED=$((PHASES_FAILED + 1))
      update_state "$PROJECT" "$CURRENT_PHASE" "failed" "Verification failed after ${fix_round} fix rounds"
      warn "Phase ${CURRENT_PHASE} could not be fully verified — continuing"
    fi
  else
    log "⏩ Skipping verification (--skip-verify)"
    PHASES_COMPLETED=$((PHASES_COMPLETED + 1))
    update_state "$PROJECT" "$CURRENT_PHASE" "complete" "Completed (verification skipped)"
    _finalize_phase "$PROJECT" "$CURRENT_PHASE"
  fi
done

# ═══════════════════════════════════════════════════════════
# FINAL REPORT
# ═══════════════════════════════════════════════════════════
PIPELINE_END=$(date +%s)
PIPELINE_DURATION=$(( PIPELINE_END - PIPELINE_START ))
PIPELINE_MINS=$(( PIPELINE_DURATION / 60 ))
PIPELINE_SECS=$(( PIPELINE_DURATION % 60 ))

echo ""
echo -e "${BOLD}${MAGENTA}╔══════════════════════════════════════════════════════╗${NC}"
echo -e "${BOLD}${MAGENTA}║  📊 PIPELINE COMPLETE                                ║${NC}"
echo -e "${BOLD}${MAGENTA}╚══════════════════════════════════════════════════════╝${NC}"
echo ""
echo -e "  ${BOLD}Duration:${NC}       ${PIPELINE_MINS}m ${PIPELINE_SECS}s"
echo -e "  ${BOLD}Total Phases:${NC}   ${#PHASES[@]}"
echo -e "  ${GREEN}Completed:${NC}      ${PHASES_COMPLETED}"
[[ $PHASES_FAILED -gt 0 ]] && echo -e "  ${RED}Failed:${NC}         ${PHASES_FAILED}"
echo -e "  ${BOLD}Session:${NC}        ${SESSION_DIR}"
echo ""

# Show phase status from roadmap
if [[ -f "$ROADMAP_FILE" ]]; then
  while IFS= read -r line; do
    if [[ "$line" =~ ^###\ Phase ]]; then
      if echo "$line" | grep -q "complete" 2>/dev/null; then
        echo -e "  ${GREEN}✓ ${line}${NC}"
      else
        echo -e "  ${YELLOW}○ ${line}${NC}"
      fi
    fi
  done < "$ROADMAP_FILE"
fi

echo ""
if [[ $PHASES_FAILED -eq 0 ]]; then
  echo -e "${GREEN}${BOLD}✓ All phases completed successfully!${NC}"
else
  echo -e "${YELLOW}${BOLD}⚠ ${PHASES_COMPLETED}/${#PHASES[@]} phases completed. ${PHASES_FAILED} need attention.${NC}"
fi
echo ""

# ─── Cleanup ────────────────────────────────────────────
stop_dashboard
