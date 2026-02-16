#!/usr/bin/env bash
#
# coordinator.sh — Dynamic Multi-Agent Coordinator v7.0
#
# DESIGN:
#   Planner-driven loop. The PLANNER agent is the brain — it decides
#   what happens next by writing DIRECTIVE files. The coordinator reads
#   directives and dispatches work to executor/reviewer agents.
#
#   --prd  file.md   → Use PRD (auto-detects format, normalizes if needed)
#   --plan file.md   → Use existing plan (auto-detects PRD format too)
#   --task "..."     → Planner creates PRD from scratch
#
#   Planner writes directives: EXECUTE, REVIEW, APPROVE, SKIP, DONE
#   Coordinator dispatches, collects results, feeds back to planner.
#
#   PRD MODE: When input is a PRD (has user stories + acceptance criteria),
#   the planner references acceptance criteria in EXECUTE/REVIEW prompts,
#   and reviewers verify each criterion explicitly.
#

set -euo pipefail
shopt -s nullglob

# ─── Colors ─────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; CYAN='\033[0;36m'; MAGENTA='\033[0;35m'
BOLD='\033[1m'; DIM='\033[2m'; NC='\033[0m'

# ─── Defaults ───────────────────────────────────────────
PROJECT=""
TASK=""
PLAN_FILE=""           # --plan: use existing plan file
PRD_FILE=""            # --prd: use PRD (Product Requirements Document)
PRD_SOURCE="none"      # none, prd, plan, task — how we got the task file
PLANNER="codex"
EXECUTOR="claude"
REVIEWERS="gemini"     # comma-separated: "gemini,amp"
MAX_ROUNDS=30          # safety limit for planner loop
MAX_RETRIES=3          # retries per subtask before planner moves on
DRY_RUN=false
CONTEXT_FILES=""
SKILL_FILES=""
MODEL_OVERRIDES=""     # --model agent:model,agent:model:effort
REPLAN=false
SPLIT_VIEW=false          # --split: show agents in tmux split panes
USE_TMUX=false            # --tmux: use tmux sessions (default: direct bg processes)

# Frontend mode
FRONTEND=false
FRONTEND_DEV=""            # --frontend-dev: agent for frontend implementation
FRONTEND_REVIEWER=""       # --frontend-reviewer: agent(s) for frontend review (comma-separated)
BACKEND_CMD=""             # --backend-cmd: command to start backend (e.g. "mvn spring-boot:run")
FRONTEND_CMD=""            # --frontend-cmd: command to start frontend (e.g. "ng serve")
BACKEND_URL=""             # --backend-url: URL to check backend readiness (e.g. http://localhost:8096)
FRONTEND_URL=""            # --frontend-url: URL to check frontend readiness (e.g. http://localhost:4200)
DASHBOARD=false              # --dashboard: auto-start live monitoring dashboard
DASHBOARD_PORT=3777

# ─── Parse Arguments ────────────────────────────────────
while [[ $# -gt 0 ]]; do
  case $1 in
    --project)              PROJECT="$2"; shift 2 ;;
    --task)                 TASK="$2"; shift 2 ;;
    --plan)                 PLAN_FILE="$2"; shift 2 ;;
    --prd)                  PRD_FILE="$2"; shift 2 ;;
    --planner)              PLANNER="$2"; shift 2 ;;
    --executor)             EXECUTOR="$2"; shift 2 ;;
    --reviewer|--reviewers) REVIEWERS="$2"; shift 2 ;;
    --max-rounds)           MAX_ROUNDS="$2"; shift 2 ;;
    --max-retries)          MAX_RETRIES="$2"; shift 2 ;;
    --context)              CONTEXT_FILES="$2"; shift 2 ;;
    --skills)               SKILL_FILES="$2"; shift 2 ;;
    --model)                MODEL_OVERRIDES="$2"; shift 2 ;;
    --replan)               REPLAN=true; shift ;;
    --split)                SPLIT_VIEW=true; shift ;;
    --frontend)             FRONTEND=true; shift ;;
    --frontend-dev)         FRONTEND_DEV="$2"; FRONTEND=true; shift 2 ;;
    --frontend-reviewer|--frontend-reviewers) FRONTEND_REVIEWER="$2"; FRONTEND=true; shift 2 ;;
    --backend-cmd)          BACKEND_CMD="$2"; shift 2 ;;
    --frontend-cmd)         FRONTEND_CMD="$2"; shift 2 ;;
    --backend-url)          BACKEND_URL="$2"; shift 2 ;;
    --frontend-url)         FRONTEND_URL="$2"; shift 2 ;;
    --dashboard)             DASHBOARD=true; shift ;;
    --dashboard-port)        DASHBOARD=true; DASHBOARD_PORT="$2"; shift 2 ;;
    --tmux)                 USE_TMUX=true; shift ;;
    --dry-run)              DRY_RUN=true; shift ;;
    -h|--help)              head -16 "$0" | tail -14; exit 0 ;;
    *)                      echo -e "${RED}Unknown: $1${NC}"; exit 1 ;;
  esac
done

[[ -z "$PROJECT" ]] && { echo -e "${RED}--project required${NC}"; exit 1; }
[[ -z "$TASK" && -z "$PLAN_FILE" && -z "$PRD_FILE" ]] && { echo -e "${RED}Either --task, --plan, or --prd required${NC}"; exit 1; }
PROJECT=$(cd "$PROJECT" 2>/dev/null && pwd)

# ─── Session Setup ──────────────────────────────────────
ARTIFACTS="${PROJECT}/.codeswarm"
TIMESTAMP=$(date +%Y%m%d_%H%M%S)
SESSION_ID="session_${TIMESTAMP}"
SESSION_DIR="${ARTIFACTS}/sessions/${SESSION_ID}"
TASK_FILE="${ARTIFACTS}/task.md"
STATE_FILE="${SESSION_DIR}/state.md"
DIRECTIVES_DIR="${SESSION_DIR}/directives"

mkdir -p "$SESSION_DIR"
mkdir -p "$DIRECTIVES_DIR"
SKILLS_DIR="${SESSION_DIR}/skills"
mkdir -p "$SKILLS_DIR"

# ─── Tmux (opt-in only: --tmux flag) ─────────────────────
# tmux strips shell environment (PATH, conda, API keys) which breaks agents.
# Only enable with explicit --tmux flag. Default: direct background processes.
TMUX_SESSION="codeswarm-${TIMESTAMP}"
if $USE_TMUX && command -v tmux &>/dev/null; then
  tmux new-session -d -s "$TMUX_SESSION" -n "coord" -x 200 -y 50 2>/dev/null || true
else
  USE_TMUX=false
fi

# ─── Logging ──────────────────────────────────────────────
LOG_FILE="${SESSION_DIR}/coordinator.log"
log()     { echo -e "${CYAN}[$(date +%H:%M:%S)] $1${NC}"; echo "[$(date +%H:%M:%S)] $1" >> "$LOG_FILE"; }
success() { echo -e "${GREEN}✓ $1${NC}"; echo "✓ $1" >> "$LOG_FILE"; }
warn()    { echo -e "${YELLOW}⚠ $1${NC}"; echo "⚠ $1" >> "$LOG_FILE"; }
error()   { echo -e "${RED}✗ $1${NC}"; echo "✗ $1" >> "$LOG_FILE"; }

# ═══════════════════════════════════════════════════════════
# RETRY WRAPPER — embedded into generated agent scripts
# Handles transient API errors (e.g. "No messages returned")
# ═══════════════════════════════════════════════════════════
# This function body is injected into each generated .run_*.sh script
RETRY_FUNC='
_retry() {
  local max_retries="$1"; shift
  local retry_delay="$1"; shift
  local attempt=1
  local exit_code=0
  while [[ $attempt -le $max_retries ]]; do
    exit_code=0
    "$@" && return 0 || exit_code=$?
    if [[ $attempt -lt $max_retries ]]; then
      local wait_secs=$(( retry_delay * attempt ))
      echo ""
      echo "[codeswarm] ⚠️  Attempt ${attempt}/${max_retries} failed (exit ${exit_code}). Retrying in ${wait_secs}s..."
      echo ""
      sleep $wait_secs
    fi
    attempt=$((attempt + 1))
  done
  echo "[codeswarm] ✗ All ${max_retries} attempts failed (last exit ${exit_code})"
  return $exit_code
}
'

# ═══════════════════════════════════════════════════════════
# SEND PROMPT TO AGENT (with watchdog heartbeat)
# ═══════════════════════════════════════════════════════════
STALE_TIMEOUT=${STALE_TIMEOUT:-300}  # 5 min no output → kill
HEARTBEAT_INTERVAL=30

# ─── Model Resolution ────────────────────────────────────
# Resolve model for an agent from --model overrides
# Format: agent:model or agent:model:effort (codex)
get_model_for() {
  local agent="$1"
  local model=""
  if [[ -n "$MODEL_OVERRIDES" ]]; then
    IFS=',' read -ra pairs <<< "$MODEL_OVERRIDES"
    for pair in "${pairs[@]}"; do
      local key="${pair%%:*}"
      if [[ "$key" == "$agent" ]]; then
        local rest="${pair#*:}"  # everything after first colon
        # If rest has another colon (agent:model:effort), take only model part
        if [[ "$rest" == *:* ]]; then
          model="${rest%:*}"   # strip last segment (effort)
        else
          model="$rest"
        fi
        break
      fi
    done
  fi
  echo "$model"
}

# Extract reasoning effort for codex (third segment: agent:model:effort)
get_reasoning_effort() {
  local agent="$1"
  if [[ -n "$MODEL_OVERRIDES" ]]; then
    IFS=',' read -ra pairs <<< "$MODEL_OVERRIDES"
    for pair in "${pairs[@]}"; do
      local key="${pair%%:*}"
      if [[ "$key" == "$agent" ]]; then
        local rest="${pair#*:}"
        if [[ "$rest" == *:* ]]; then
          echo "${rest##*:}"  # last segment = effort
        fi
        break
      fi
    done
  fi
}

MSG_SEQ=0
send_to_agent() {
  local agent_name="$1"
  local prompt="$2"
  local label="${3:-}"

  MSG_SEQ=$((MSG_SEQ + 1))
  local seq=$(printf '%03d' $MSG_SEQ)
  local prompt_file="${SESSION_DIR}/prompt_${seq}_${agent_name}.md"
  local log_file="${SESSION_DIR}/log_${seq}_${agent_name}.md"
  local exitcode_file="${SESSION_DIR}/.exitcode_${seq}"
  local done_flag="${SESSION_DIR}/.done_${seq}"

  echo "$prompt" > "$prompt_file"
  touch "$log_file"
  log "🚀 ${BOLD}${agent_name}${NC} ${label:+— ${label}}"

  if $DRY_RUN; then
    echo "# Dry run — prompt at: ${prompt_file}" > "$log_file"
    return 0
  fi

  # ── Build agent command ──────────────────────────────
  # Short CLI prompt telling agent to read the prompt file (agents use their own tools to read)
  # NO stdout redirect — output goes to terminal; pipe-pane captures it to log_file
  local short="Read ALL instructions from the file ${prompt_file} and execute them completely. When done, print: done"
  local agent_cmd=""
  local agent_retries=${AGENT_RETRY_COUNT:-3}
  local agent_retry_delay=${AGENT_RETRY_DELAY:-5}

  # Resolve model for this agent
  local model=$(get_model_for "$agent_name")
  local effort=$(get_reasoning_effort "$agent_name")
  [[ -n "$model" ]] && log "  📦 Model: ${model}${effort:+ (effort: ${effort})}"

  case "$agent_name" in
    claude)
      agent_cmd="_retry ${agent_retries} ${agent_retry_delay} claude ${model:+--model $model} --dangerously-skip-permissions --verbose -p '${short}'; echo \$? > '${exitcode_file}'"
      ;;
    gemini)
      agent_cmd="_retry ${agent_retries} ${agent_retry_delay} gemini ${model:+--model $model} -p '${short}' --approval-mode yolo; echo \$? > '${exitcode_file}'"
      ;;
    codex)
      agent_cmd="_retry ${agent_retries} ${agent_retry_delay} codex exec ${model:+--model $model} ${effort:+--reasoning-effort $effort} --yolo '${short}'; echo \$? > '${exitcode_file}'"
      ;;
    amp)
      agent_cmd="_retry ${agent_retries} ${agent_retry_delay} amp --dangerously-allow-all -x '${short}'; echo \$? > '${exitcode_file}'"
      ;;
    opencode)
      agent_cmd="_retry ${agent_retries} ${agent_retry_delay} env OPENCODE_PERMISSION='{\"*\":\"allow\"}' opencode run ${model:+--model $model} '${short}'; echo \$? > '${exitcode_file}'"
      ;;
    *)
      error "Unknown agent: $agent_name (supported: claude, gemini, codex, amp, opencode)"; return 1 ;;
  esac

  # ── Execute with watchdog heartbeat ──────────────────
  local start_time=$(date +%s)
  local last_size=0
  local stale_since=$start_time

  if $USE_TMUX; then
    # Each agent gets its own tmux session for isolation
    local agent_session="${TMUX_SESSION}-${agent_name}-${seq}"
    tmux new-session -d -s "$agent_session" -x 200 -y 50 2>/dev/null || true

    # Write command to a script file to avoid tmux send-keys garbling long commands
    # Embeds _retry function so it works in isolated tmux sessions
    local cmd_script="${SESSION_DIR}/.run_${seq}_${agent_name}.sh"
    cat > "$cmd_script" <<CMDEOF
#!/usr/bin/env bash
${RETRY_FUNC}
cd '${PROJECT}'
${agent_cmd}
touch '${done_flag}'
CMDEOF
    chmod +x "$cmd_script"

    echo -e "  ${CYAN}📺 tmux attach -t ${agent_session}${NC}"

    # If --split, create a tail pane in the coordinator session
    if $SPLIT_VIEW; then
      tmux split-window -t "${TMUX_SESSION}:coord" -v -l 15 \
        "echo '─── ${agent_name} (${label:-}) ───'; tail -f '${log_file}'" 2>/dev/null || true
    fi

    # pipe-pane captures terminal output to log file
    tmux pipe-pane -o -t "$agent_session" "cat >> '${log_file}'"
    tmux send-keys -t "$agent_session" "bash '${cmd_script}'" Enter

    while [[ ! -f "$done_flag" ]]; do
      sleep $HEARTBEAT_INTERVAL

      local elapsed=$(( $(date +%s) - start_time ))
      local mins=$(( elapsed / 60 ))
      local secs=$(( elapsed % 60 ))
      local current_size=$(wc -c < "$log_file" 2>/dev/null | tr -d ' ' || echo "0")

      # Check if agent process is still alive in tmux (some agents buffer output)
      local agent_proc_alive=false
      if tmux list-sessions 2>/dev/null | grep -q "$agent_session"; then
        agent_proc_alive=true
      fi

      if [[ "$current_size" -gt "$last_size" ]]; then
        stale_since=$(date +%s)
        last_size=$current_size
        echo -e "${DIM}  💚 ${agent_name} alive — ${mins}m${secs}s, ${current_size} bytes${NC}"
      elif $agent_proc_alive; then
        # Process alive but no output — agent is thinking (claude --print buffers)
        echo -e "${DIM}  🧠 ${agent_name} working — ${mins}m${secs}s (process alive, waiting for output)${NC}"
        # Only kill if total elapsed exceeds 15 min (hard timeout)
        if [[ $elapsed -ge 900 ]]; then
          warn "${agent_name} hard timeout — ${mins}m elapsed. Killing..."
          tmux send-keys -t "$agent_session" C-c 2>/dev/null || true
          sleep 2
          tmux kill-session -t "$agent_session" 2>/dev/null || true
          echo "WATCHDOG_KILLED" > "$exitcode_file"
          break
        fi
      else
        local stale_duration=$(( $(date +%s) - stale_since ))
        local stale_mins=$(( stale_duration / 60 ))

        if [[ $stale_duration -ge $STALE_TIMEOUT ]]; then
          warn "${agent_name} stuck — no output for ${stale_mins}m. Killing..."
          tmux send-keys -t "$agent_session" C-c 2>/dev/null || true
          sleep 2
          tmux kill-session -t "$agent_session" 2>/dev/null || true
          echo "WATCHDOG_KILLED" > "$exitcode_file"
          break
        else
          echo -e "${YELLOW}  ⚠️ ${agent_name} stale — ${stale_mins}m no output (kill at $((STALE_TIMEOUT / 60))m)${NC}"
        fi
      fi
    done
    rm -f "$done_flag"
    # Clean up agent session
    tmux kill-session -t "$agent_session" 2>/dev/null || true
  else
    # Foreground (no tmux): write script file + run as background process
    local cmd_script="${SESSION_DIR}/.run_${seq}_${agent_name}.sh"
    cat > "$cmd_script" <<CMDEOF
#!/usr/bin/env bash
${RETRY_FUNC}
cd '${PROJECT}'
${agent_cmd}
CMDEOF
    chmod +x "$cmd_script"
    # Use script(1) to allocate a PTY — agents like claude need a terminal to work
    script -q "$log_file" bash "$cmd_script" &
    local agent_pid=$!

    while kill -0 $agent_pid 2>/dev/null; do
      sleep $HEARTBEAT_INTERVAL
      local elapsed=$(( $(date +%s) - start_time ))
      local current_size=$(wc -c < "$log_file" 2>/dev/null | tr -d ' ' || echo "0")
      if [[ "$current_size" -gt "$last_size" ]]; then
        stale_since=$(date +%s)
        last_size=$current_size
        echo -e "${DIM}  💚 ${agent_name} alive — $((elapsed/60))m$((elapsed%60))s, ${current_size} bytes${NC}"
      else
        local stale_duration=$(( $(date +%s) - stale_since ))
        if [[ $stale_duration -ge $STALE_TIMEOUT ]]; then
          warn "${agent_name} stuck — killing..."
          kill $agent_pid 2>/dev/null || true; sleep 2; kill -9 $agent_pid 2>/dev/null || true
          echo "WATCHDOG_KILLED" > "$exitcode_file"
          break
        fi
      fi
    done
    wait $agent_pid 2>/dev/null || true
  fi

  local elapsed=$(( $(date +%s) - start_time ))
  log "${agent_name} finished in $((elapsed / 60))m$((elapsed % 60))s"

  local exit_code=0
  if [[ -f "$exitcode_file" ]]; then
    exit_code=$(cat "$exitcode_file" | tr -d '[:space:]')
    rm -f "$exitcode_file"
  fi
  if [[ "$exit_code" == "WATCHDOG_KILLED" ]]; then
    error "${agent_name} killed by watchdog"
    echo "--- WATCHDOG KILLED ---" >> "$log_file"
    return 1
  fi
  [[ "$exit_code" =~ ^[0-9]+$ ]] || { [[ -s "$log_file" ]] && exit_code=0 || exit_code=1; }

  # Post-execution: detect transient errors even with exit 0 (e.g. claude "No messages returned")
  if [[ $exit_code -eq 0 ]] && grep -qE "No messages returned|ECONNRESET|ETIMEDOUT" "$log_file" 2>/dev/null; then
    local post_retries=${AGENT_RETRY_COUNT:-3}
    local post_delay=${AGENT_RETRY_DELAY:-5}
    for (( _pr=1; _pr<post_retries; _pr++ )); do
      local wait_secs=$(( post_delay * _pr ))
      warn "${agent_name} transient error detected in output. Retry ${_pr}/$((post_retries-1)) in ${wait_secs}s..."
      sleep $wait_secs
      # Re-run via the same script file
      local cmd_script="${SESSION_DIR}/.run_${seq}_${agent_name}.sh"
      if [[ -f "$cmd_script" ]]; then
        > "$log_file"  # truncate log for fresh attempt
        if $USE_TMUX; then
          local agent_session="${TMUX_SESSION}-${agent_name}-${seq}-r${_pr}"
          tmux new-session -d -s "$agent_session" -x 200 -y 50 2>/dev/null || true
          tmux pipe-pane -o -t "$agent_session" "cat >> '${log_file}'"
          tmux send-keys -t "$agent_session" "bash '${cmd_script}'" Enter
          while [[ ! -f "$done_flag" ]]; do sleep $HEARTBEAT_INTERVAL; done
          rm -f "$done_flag"
          tmux kill-session -t "$agent_session" 2>/dev/null || true
        else
          script -q "$log_file" bash "$cmd_script" &
          local retry_pid=$!
          wait $retry_pid 2>/dev/null || true
        fi
        # Check if retry succeeded
        if ! grep -qE "No messages returned|ECONNRESET|ETIMEDOUT" "$log_file" 2>/dev/null; then
          log "${agent_name} retry ${_pr} succeeded"
          exit_code=0
          break
        fi
      fi
    done
  fi

  if [[ $exit_code -ne 0 ]]; then
    warn "${agent_name} exited ${exit_code} — check: ${log_file}"
  else
    success "${agent_name} done"
  fi
  return $exit_code
}

# ─── Read context files ─────────────────────────────────
CONTEXT_CONTENT=""
if [[ -n "$CONTEXT_FILES" ]]; then
  IFS=',' read -ra CFILES <<< "$CONTEXT_FILES"
  for cf in "${CFILES[@]}"; do
    cf=$(echo "$cf" | xargs)
    local_path=""
    [[ -f "$PROJECT/$cf" ]] && local_path="$PROJECT/$cf"
    [[ -f "$cf" ]] && local_path="$cf"
    if [[ -n "$local_path" ]]; then
      CONTEXT_CONTENT="${CONTEXT_CONTENT}
=== FILE: ${cf} ===
$(cat "$local_path")
=== END ==="
    fi
  done
fi

# ─── Skill Discovery (file-based, bash 3.2 compatible) ──
load_skill_file() {
  local path="$1"
  local label="$2"
  if [[ -f "$path" ]] && [[ -s "$path" ]]; then
    echo "
=== SKILL: ${label} (${path}) ===
$(cat "$path")
=== END SKILL ==="
  fi
}

discover_skills() {
  local agent_name="$1"
  local agent_upper=$(echo "$agent_name" | tr '[:lower:]' '[:upper:]')
  local content=""

  content+=$(load_skill_file "${PROJECT}/AGENTS.md" "project/AGENTS.md")
  content+=$(load_skill_file "${PROJECT}/${agent_upper}.md" "project/${agent_upper}.md")

  if [[ -d "${PROJECT}/.codeswarm/skills" ]]; then
    for sf in "${PROJECT}/.codeswarm/skills/"*.md; do
      content+=$(load_skill_file "$sf" ".codeswarm/skills/$(basename "$sf")")
    done
  fi

  local home_dirs=(
    "${HOME}/.claude"
    "${HOME}/.gemini"
    "${HOME}/.codex"
    "${HOME}/.config/amp"
  )
  for hd in "${home_dirs[@]}"; do
    if [[ -d "$hd" ]]; then
      local agent_base=$(basename "$hd")
      local agent_base_upper=$(echo "$agent_base" | tr '[:lower:]' '[:upper:]')
      if [[ "$agent_upper" == "$agent_base_upper" ]]; then
        content+=$(load_skill_file "${hd}/${agent_base_upper}.md" "global/${agent_base_upper}.md")
        content+=$(load_skill_file "${hd}/instructions.md" "global/${agent_base}/instructions.md")
      fi
    fi
  done

  if [[ -n "$SKILL_FILES" ]]; then
    IFS=',' read -ra SFILES <<< "$SKILL_FILES"
    for sf in "${SFILES[@]}"; do
      sf=$(echo "$sf" | xargs)
      [[ -f "$PROJECT/$sf" ]] && sf="$PROJECT/$sf"
      content+=$(load_skill_file "$sf" "explicit/$(basename "$sf")")
    done
  fi

  echo "$content" > "${SKILLS_DIR}/${agent_name}.txt"
}

get_skills_for() {
  local agent_name="$1"
  local skill_file="${SKILLS_DIR}/${agent_name}.txt"
  if [[ ! -f "$skill_file" ]]; then
    discover_skills "$agent_name"
  fi
  local content=""
  if [[ -f "$skill_file" ]]; then
    content=$(cat "$skill_file")
  fi
  if [[ -n "$content" ]]; then
    echo "
SKILLS & INSTRUCTIONS:
${content}"
  fi
}

# ─── Parse reviewers ────────────────────────────────────
IFS=',' read -ra REVIEWER_LIST <<< "$REVIEWERS"
for idx in "${!REVIEWER_LIST[@]}"; do
  REVIEWER_LIST[$idx]=$(echo "${REVIEWER_LIST[$idx]}" | xargs)
done

# ─── Parse frontend reviewers ──────────────────────────
FRONTEND_REVIEWER_LIST=()
if [[ -n "$FRONTEND_REVIEWER" ]]; then
  IFS=',' read -ra FRONTEND_REVIEWER_LIST <<< "$FRONTEND_REVIEWER"
  for idx in "${!FRONTEND_REVIEWER_LIST[@]}"; do
    FRONTEND_REVIEWER_LIST[$idx]=$(echo "${FRONTEND_REVIEWER_LIST[$idx]}" | xargs)
  done
fi

# Pre-discover skills
discover_skills "$PLANNER"
discover_skills "$EXECUTOR"
for _rev in "${REVIEWER_LIST[@]}"; do
  discover_skills "$_rev"
done
if [[ -n "$FRONTEND_DEV" ]]; then
  discover_skills "$FRONTEND_DEV"
fi
if [[ ${#FRONTEND_REVIEWER_LIST[@]} -gt 0 ]]; then
  for _frev in "${FRONTEND_REVIEWER_LIST[@]}"; do
    discover_skills "$_frev"
  done
fi

# ─── Service management (frontend mode) ────────────────
BACKEND_SESSION=""
FRONTEND_SESSION=""

wait_for_url() {
  local url="$1"
  local name="$2"
  local timeout="${3:-120}"
  local start=$(date +%s)
  echo -ne "  ⏳ Waiting for ${name} at ${url}"
  while true; do
    if curl -sf -o /dev/null --max-time 3 "$url" 2>/dev/null; then
      echo -e " ${GREEN}✓${NC}"
      return 0
    fi
    local elapsed=$(( $(date +%s) - start ))
    if [[ $elapsed -ge $timeout ]]; then
      echo -e " ${RED}✗ timeout after ${timeout}s${NC}"
      return 1
    fi
    echo -n "."
    sleep 3
  done
}

start_services() {
  if [[ -z "$BACKEND_CMD" && -z "$FRONTEND_CMD" ]]; then
    return 0
  fi

  log "🖥️  Starting services for frontend testing..."

  if [[ -n "$BACKEND_CMD" ]]; then
    BACKEND_SESSION="${TMUX_SESSION}-backend"
    tmux new-session -d -s "$BACKEND_SESSION" -x 200 -y 50 2>/dev/null || true
    tmux pipe-pane -o -t "$BACKEND_SESSION" "cat >> '${SESSION_DIR}/backend.log'"
    tmux send-keys -t "$BACKEND_SESSION" "cd '${PROJECT}' && ${BACKEND_CMD}" Enter
    echo -e "  ${CYAN}📺 tmux attach -t ${BACKEND_SESSION}${NC}"

    if [[ -n "$BACKEND_URL" ]]; then
      wait_for_url "$BACKEND_URL" "backend" 180 || { error "Backend failed to start"; return 1; }
    else
      log "No --backend-url, waiting 30s for backend startup..."
      sleep 30
    fi
  fi

  if [[ -n "$FRONTEND_CMD" ]]; then
    FRONTEND_SESSION="${TMUX_SESSION}-frontend"
    tmux new-session -d -s "$FRONTEND_SESSION" -x 200 -y 50 2>/dev/null || true
    tmux pipe-pane -o -t "$FRONTEND_SESSION" "cat >> '${SESSION_DIR}/frontend.log'"
    tmux send-keys -t "$FRONTEND_SESSION" "cd '${PROJECT}' && ${FRONTEND_CMD}" Enter
    echo -e "  ${CYAN}📺 tmux attach -t ${FRONTEND_SESSION}${NC}"

    if [[ -n "$FRONTEND_URL" ]]; then
      wait_for_url "$FRONTEND_URL" "frontend" 120 || { error "Frontend failed to start"; return 1; }
    else
      log "No --frontend-url, waiting 20s for frontend startup..."
      sleep 20
    fi
  fi

  success "Services running"
}

stop_services() {
  [[ -n "$BACKEND_SESSION" ]] && tmux kill-session -t "$BACKEND_SESSION" 2>/dev/null || true
  [[ -n "$FRONTEND_SESSION" ]] && tmux kill-session -t "$FRONTEND_SESSION" 2>/dev/null || true
}

# ─── Banner ──────────────────────────────────────────────
echo ""
echo -e "${BOLD}${MAGENTA}"
echo "   ╔═══════════════════════════════════════════════════════╗"
echo "   ║   🧠 DYNAMIC MULTI-AGENT COORDINATOR v7.0            ║"
echo "   ╚═══════════════════════════════════════════════════════╝"
echo -e "${NC}"
echo -e "  ${BOLD}Task:${NC}      ${TASK:-'(from plan file)'}"
echo -e "  ${BOLD}Project:${NC}   $PROJECT"
echo -e "  ${BOLD}Planner:${NC}   ${PLANNER} ${BOLD}(brain — decides everything)${NC}"
echo -e "  ${BOLD}Executor:${NC}  ${EXECUTOR} (backend implements)"
echo -e "  ${BOLD}Reviewers:${NC} ${REVIEWER_LIST[*]} (backend review)"
if $FRONTEND; then
  [[ -n "$FRONTEND_DEV" ]] && echo -e "  ${BOLD}FE Dev:${NC}    ${FRONTEND_DEV} (frontend implements)"
  [[ ${#FRONTEND_REVIEWER_LIST[@]} -gt 0 ]] && echo -e "  ${BOLD}FE Review:${NC} ${FRONTEND_REVIEWER_LIST[*]} (frontend review)"
  [[ -n "$BACKEND_CMD" ]] && echo -e "  ${BOLD}Backend:${NC}   ${BACKEND_CMD}"
  [[ -n "$FRONTEND_CMD" ]] && echo -e "  ${BOLD}Frontend:${NC}  ${FRONTEND_CMD}"
fi
[[ -n "$PLAN_FILE" ]] && echo -e "  ${BOLD}Plan:${NC}      ${PLAN_FILE}"
$USE_TMUX && echo -e "  ${BOLD}Tmux:${NC}     tmux attach -t ${TMUX_SESSION}"
$SPLIT_VIEW && echo -e "  ${BOLD}Split:${NC}    agent output visible in coordinator tmux"
$DASHBOARD && echo -e "  ${BOLD}Dashboard:${NC} http://localhost:${DASHBOARD_PORT}"
echo ""

# Write session metadata for dashboard
FRL_JSON="[]"
if [[ ${#FRONTEND_REVIEWER_LIST[@]} -gt 0 ]]; then
  FRL_JSON=$(printf '"%s",' "${FRONTEND_REVIEWER_LIST[@]}" | sed 's/,$//')
  FRL_JSON="[${FRL_JSON}]"
fi
REV_JSON=$(printf '"%s",' "${REVIEWER_LIST[@]}" | sed 's/,$//')
cat > "${SESSION_DIR}/metadata.json" <<METAEOF
{
  "planner": "${PLANNER}",
  "executor": "${EXECUTOR}",
  "reviewers": [${REV_JSON}],
  "frontendDev": "${FRONTEND_DEV:-}",
  "frontendReviewers": ${FRL_JSON},
  "project": "${PROJECT}",
  "timestamp": "${TIMESTAMP}",
  "frontend": $($FRONTEND && echo true || echo false)
}
METAEOF

# ═══════════════════════════════════════════════════════════
# START DASHBOARD (if enabled)
# ═══════════════════════════════════════════════════════════
DASHBOARD_PID=""
if $DASHBOARD; then
  DASHBOARD_SCRIPT="$(cd "$(dirname "$0")" && pwd)/dashboard/server.js"
  if [[ -f "$DASHBOARD_SCRIPT" ]]; then
    # Kill any existing process on the dashboard port
    lsof -ti:"$DASHBOARD_PORT" | xargs kill -9 2>/dev/null || true
    sleep 0.5
    node "$DASHBOARD_SCRIPT" --project "$PROJECT" --port "$DASHBOARD_PORT" &
    DASHBOARD_PID=$!
    log "📊 Dashboard started at http://localhost:${DASHBOARD_PORT} (PID: ${DASHBOARD_PID})"
    # Try to open in browser
    if command -v open &>/dev/null; then
      open "http://localhost:${DASHBOARD_PORT}" 2>/dev/null || true
    fi
  else
    warn "Dashboard not found at ${DASHBOARD_SCRIPT} — run: cd dashboard && npm install"
  fi
fi

# ═══════════════════════════════════════════════════════════
# PRD HELPERS
# ═══════════════════════════════════════════════════════════

# Detect if a file is in PRD format (has user stories with acceptance criteria)
is_prd_format() {
  local file="$1"
  [[ ! -f "$file" ]] && return 1
  # PRD format: has "### US-" user story headers with acceptance criteria
  if grep -q '^### US-[0-9]' "$file" 2>/dev/null && grep -q 'Acceptance Criteria' "$file" 2>/dev/null; then
    return 0
  fi
  return 1
}

# Detect if a file is a JSON PRD (ralph-style prd.json)
is_json_prd() {
  local file="$1"
  [[ ! -f "$file" ]] && return 1
  # Check file extension is .json AND contains userStories key
  if [[ "$file" == *.json ]] && grep -q '"userStories"' "$file" 2>/dev/null; then
    return 0
  fi
  return 1
}

# Convert a JSON PRD (ralph-style prd.json) to markdown PRD, then to task.md
prd_from_json() {
  local json_file="$1"
  local output_file="$2"
  local md_prd="${SESSION_DIR}/json_to_md_prd.md"

  # Check for jq
  if ! command -v jq &>/dev/null; then
    error "jq is required for JSON PRD parsing. Install: brew install jq"
    return 1
  fi

  local project_name
  project_name=$(jq -r '.project // "Project"' "$json_file")
  local description
  description=$(jq -r '.description // ""' "$json_file")

  {
    echo "# PRD: ${project_name}"
    echo ""
    echo "## Overview"
    echo "${description}"
    echo ""
    echo "## User Stories"
    echo ""

    # Iterate over each user story
    local count
    count=$(jq '.userStories | length' "$json_file")
    for ((si=0; si<count; si++)); do
      local id title desc priority notes passes
      id=$(jq -r ".userStories[$si].id" "$json_file")
      title=$(jq -r ".userStories[$si].title" "$json_file")
      desc=$(jq -r ".userStories[$si].description // \"\"" "$json_file")
      priority=$(jq -r ".userStories[$si].priority // $((si+1))" "$json_file")
      notes=$(jq -r ".userStories[$si].notes // \"\"" "$json_file")
      passes=$(jq -r ".userStories[$si].passes // false" "$json_file")

      echo "### ${id}: ${title} [priority: ${priority}]"
      [[ -n "$desc" ]] && echo "**Description:** ${desc}"
      echo "**Acceptance Criteria:**"

      # Iterate acceptance criteria
      local ac_count
      ac_count=$(jq ".userStories[$si].acceptanceCriteria | length" "$json_file")
      for ((ci=0; ci<ac_count; ci++)); do
        local criterion
        criterion=$(jq -r ".userStories[$si].acceptanceCriteria[$ci]" "$json_file")
        if [[ "$passes" == "true" ]]; then
          echo "- [x] ${criterion}"
        else
          echo "- [ ] ${criterion}"
        fi
      done

      [[ -n "$notes" && "$notes" != "" ]] && echo "**Notes:** ${notes}"
      echo ""
    done
  } > "$md_prd"

  # Now convert the generated markdown PRD to task.md
  prd_to_task_md "$md_prd" "$output_file"
}

# Load PRD skill template if available
load_prd_skill() {
  local skill_file="${PROJECT}/.codeswarm/skills/prd_template.md"
  if [[ -f "$skill_file" ]]; then
    echo "
=== PRD GENERATION SKILL ===
$(cat "$skill_file")
=== END PRD SKILL ==="
  fi
}

# Convert a PRD file into the standardized task.md format
# Extracts user stories as subtasks, preserves acceptance criteria inline
prd_to_task_md() {
  local prd_file="$1"
  local output_file="$2"

  # Extract title from first H1
  local title
  title=$(grep -m1 '^# ' "$prd_file" | sed 's/^# //' | sed 's/^PRD: //')

  # Extract overview
  local overview=""
  overview=$(sed -n '/^## Overview/,/^## /{ /^## Overview/d; /^## /d; p; }' "$prd_file" | head -5 | sed '/^$/d')

  # Build task.md
  {
    echo "# Task: ${title}"
    echo ""
    echo "## Summary"
    echo "${overview}"
    echo ""
    echo "## Subtasks"
    echo ""

    # Parse each user story into a subtask
    local story_num=0
    local in_story=false
    local story_id="" story_title="" story_desc="" story_files="" story_deps="" story_notes=""
    local in_ac=false
    local ac_lines=""

    while IFS= read -r line; do
      # New user story header: ### US-001: Title [priority: N]
      if [[ "$line" =~ ^###\ US-([0-9]+):\ (.+) ]]; then
        # Flush previous story
        if [[ $story_num -gt 0 ]]; then
          echo "- [ ] **[${story_id}] ${story_title}**"
          [[ -n "$story_files" ]] && echo "  - Files: ${story_files}"
          [[ -n "$story_desc" ]] && echo "  - Do: ${story_desc}"
          if [[ -n "$ac_lines" ]]; then
            echo "  - Acceptance Criteria:"
            echo "$ac_lines" | while IFS= read -r acl; do
              [[ -n "$acl" ]] && echo "    ${acl}"
            done
          fi
          echo "  - Verify: Check all acceptance criteria pass"
          [[ -n "$story_deps" ]] && echo "  - Dependencies: ${story_deps}"
          [[ -n "$story_notes" ]] && echo "  - Notes: ${story_notes}"
          echo ""
        fi

        story_num=$((story_num + 1))
        # Extract title (strip [priority: N] and [status: ...] suffixes)
        story_title=$(echo "$line" | sed 's/^### US-[0-9]*: //' | sed 's/ \[priority:.*//; s/ \[status:.*//')
        story_id=$(echo "$line" | grep -o 'US-[0-9]*')
        story_desc="" story_files="" story_deps="" story_notes=""
        in_ac=false ac_lines=""
        in_story=true
        continue
      fi

      # Stop at section breaks
      if [[ "$line" =~ ^---$ ]] || [[ "$line" =~ ^##\  && ! "$line" =~ ^###\  ]]; then
        in_story=false
      fi

      if $in_story; then
        if [[ "$line" =~ ^\*\*Description:\*\* ]]; then
          story_desc=$(echo "$line" | sed 's/^\*\*Description:\*\* //')
          in_ac=false
        elif [[ "$line" =~ ^\*\*Files:\*\* ]]; then
          story_files=$(echo "$line" | sed 's/^\*\*Files:\*\* //')
          in_ac=false
        elif [[ "$line" =~ ^\*\*Dependencies:\*\* ]]; then
          story_deps=$(echo "$line" | sed 's/^\*\*Dependencies:\*\* //')
          in_ac=false
        elif [[ "$line" =~ ^\*\*Notes:\*\* ]]; then
          story_notes=$(echo "$line" | sed 's/^\*\*Notes:\*\* //')
          in_ac=false
        elif [[ "$line" =~ ^\*\*Acceptance\ Criteria:\*\* ]]; then
          in_ac=true
        elif $in_ac && [[ "$line" =~ ^-\ \[.\] ]]; then
          ac_lines+="${line}
"
        fi
      fi
    done < "$prd_file"

    # Flush last story
    if [[ $story_num -gt 0 ]]; then
      echo "- [ ] **[${story_id}] ${story_title}**"
      [[ -n "$story_files" ]] && echo "  - Files: ${story_files}"
      [[ -n "$story_desc" ]] && echo "  - Do: ${story_desc}"
      if [[ -n "$ac_lines" ]]; then
        echo "  - Acceptance Criteria:"
        echo "$ac_lines" | while IFS= read -r acl; do
          [[ -n "$acl" ]] && echo "    ${acl}"
        done
      fi
      echo "  - Verify: Check all acceptance criteria pass"
      [[ -n "$story_deps" ]] && echo "  - Dependencies: ${story_deps}"
      [[ -n "$story_notes" ]] && echo "  - Notes: ${story_notes}"
      echo ""
    fi

    echo ""
    echo "---"
    echo ""
    echo "# Original PRD"
    echo ""
    cat "$prd_file"
  } > "$output_file"
}

# ═══════════════════════════════════════════════════════════
# PHASE 1: LOAD OR CREATE PLAN (supports --prd, --plan, --task)
# ═══════════════════════════════════════════════════════════

if [[ -n "$PRD_FILE" ]]; then
  # ── PRD mode: load and normalize PRD ─────────────────
  if [[ ! -f "$PRD_FILE" ]]; then
    [[ -f "$PROJECT/$PRD_FILE" ]] && PRD_FILE="$PROJECT/$PRD_FILE"
  fi
  if [[ ! -f "$PRD_FILE" ]]; then
    error "PRD file not found: $PRD_FILE"
    exit 1
  fi

  PRD_SOURCE="prd"
  # Copy original PRD to session for reference
  cp "$PRD_FILE" "${SESSION_DIR}/original_prd.$(echo "$PRD_FILE" | sed 's/.*\.//')" 2>/dev/null || true

  if is_json_prd "$PRD_FILE"; then
    # JSON PRD format (ralph-style prd.json) → convert to task.md
    log "📋 JSON PRD detected — converting user stories to subtasks..."
    prd_from_json "$PRD_FILE" "$TASK_FILE"
    success "JSON PRD converted to task.md ($(grep -c '^\- \[ \]' "$TASK_FILE" 2>/dev/null || echo 0) subtasks)"
  elif is_prd_format "$PRD_FILE"; then
    # Already in markdown PRD format → convert directly to task.md
    log "📋 Markdown PRD detected — converting user stories to subtasks..."
    prd_to_task_md "$PRD_FILE" "$TASK_FILE"
    success "PRD converted to task.md ($(grep -c '^\- \[ \]' "$TASK_FILE" 2>/dev/null || echo 0) subtasks)"
  else
    # Not in PRD format → planner normalizes it to PRD, then to task.md
    log "📋 Input is not in PRD format — planner will normalize..."
    PLANNER_SKILLS=$(get_skills_for "$PLANNER")

    send_to_agent "$PLANNER" "You are a planner. Convert the following document into a structured PRD (Product Requirements Document).

Read the project at ${PROJECT} to understand the codebase, then read the input document.
${PLANNER_SKILLS}
${CONTEXT_CONTENT:+
CONTEXT:
${CONTEXT_CONTENT}
}
INPUT DOCUMENT: ${PRD_FILE}
(Read this file first to understand the requirements)

IMPORTANT: Write the normalized PRD to this exact file: ${SESSION_DIR}/normalized_prd.md

The PRD MUST use this exact format:

# PRD: <Project Title>

## Overview
<2-3 sentence description>

## Tech Stack
<language, framework, database>

## User Stories

### US-001: <Title> [priority: 1]
**Description:** <what and why>
**Files:** \`path/to/file1\`, \`path/to/file2\`
**Acceptance Criteria:**
- [ ] <specific, testable criterion — e.g. 'mvn compile passes'>
- [ ] <specific, testable criterion>
**Dependencies:** none | US-XXX
**Notes:** <patterns to follow, gotchas>

### US-002: <Title> [priority: 2]
...

Guidelines:
- Read existing code first to understand patterns and conventions
- Each user story should be completable by one agent in ~10 minutes
- Order by dependency (schema first, then entities, services, controllers)
- Be specific: name files, classes, methods, table names
- Include 'mvn compile passes' (or equivalent build check) in every story's acceptance criteria
- Reference existing implementations as patterns to follow
- When done, print: done" \
      "normalizing input → PRD format"

    NORM_PRD="${SESSION_DIR}/normalized_prd.md"
    if [[ -f "$NORM_PRD" ]] && [[ -s "$NORM_PRD" ]]; then
      prd_to_task_md "$NORM_PRD" "$TASK_FILE"
      success "PRD normalized and converted to task.md ($(grep -c '^\- \[ \]' "$TASK_FILE" 2>/dev/null || echo 0) subtasks)"
    else
      # Fallback: planner may have written directly to task.md or the file itself was usable
      warn "Planner did not produce normalized PRD — falling back to direct plan creation"
      PRD_SOURCE="task"
      # Let the planner create a standard plan from the input
      send_to_agent "$PLANNER" "You are a planner. Read the project at ${PROJECT} and the requirements in ${PRD_FILE}. Create a structured implementation plan.
${PLANNER_SKILLS}

IMPORTANT: Write the plan to this exact file: ${TASK_FILE}

The plan MUST use this exact markdown format:
# Task: <one-line title>

## Summary
<2-3 sentence overview>

## Subtasks

- [ ] **SUBTASK 1: <title>**
  - Files: <specific file paths to create or modify>
  - Do: <concrete steps>
  - Verify: <how to confirm it works>

- [ ] **SUBTASK 2: <title>**
  ...

When done, print: done" \
        "creating plan from PRD → task.md"
    fi
  fi

elif [[ -n "$PLAN_FILE" ]]; then
  # ── Use existing plan file ──────────────────────────
  if [[ ! -f "$PLAN_FILE" ]]; then
    [[ -f "$PROJECT/$PLAN_FILE" ]] && PLAN_FILE="$PROJECT/$PLAN_FILE"
  fi
  if [[ ! -f "$PLAN_FILE" ]]; then
    error "Plan file not found: $PLAN_FILE"
    exit 1
  fi

  PRD_SOURCE="plan"
  # Check if the "plan" is actually a PRD
  if is_prd_format "$PLAN_FILE"; then
    log "📋 Plan file is in PRD format — converting user stories to subtasks..."
    cp "$PLAN_FILE" "${SESSION_DIR}/original_prd.md"
    prd_to_task_md "$PLAN_FILE" "$TASK_FILE"
    PRD_SOURCE="prd"
    success "PRD converted to task.md ($(grep -c '^\- \[ \]' "$TASK_FILE" 2>/dev/null || echo 0) subtasks)"
  else
    cp "$PLAN_FILE" "$TASK_FILE"
    success "Plan loaded from: $PLAN_FILE"
  fi

elif [[ -f "$TASK_FILE" ]] && [[ -s "$TASK_FILE" ]] && ! $REPLAN; then
  # ── Resume existing plan ─────────────────────────────
  PRD_SOURCE="plan"
  log "Existing task.md found — resuming"

else
  # ── Planner creates plan from task description ──────
  PRD_SOURCE="task"
  log "📋 Sending task to planner — generating PRD first..."
  PLANNER_SKILLS=$(get_skills_for "$PLANNER")
  PRD_SKILL=$(load_prd_skill)

  send_to_agent "$PLANNER" "You are a planner. Read the project at ${PROJECT} and create a structured PRD (Product Requirements Document).
${PLANNER_SKILLS}
${PRD_SKILL}
${CONTEXT_CONTENT:+
CONTEXT:
${CONTEXT_CONTENT}
}
GOAL: ${TASK}

IMPORTANT: Write the PRD to this exact file: ${SESSION_DIR}/generated_prd.md

The PRD MUST use this exact format:

# PRD: <Project Title>

## Overview
<2-3 sentence description>

## Tech Stack
<language, framework, database>

## User Stories

### US-001: <Title> [priority: 1]
**Description:** <what and why>
**Files:** \`path/to/file1\`, \`path/to/file2\`
**Acceptance Criteria:**
- [ ] <specific, testable criterion — e.g. 'mvn compile passes'>
- [ ] <specific, testable criterion>
**Dependencies:** none | US-XXX
**Notes:** <patterns to follow, gotchas>

### US-002: <Title> [priority: 2]
...

Guidelines:
- Read existing code first to understand patterns and conventions
- Each user story should be completable by one agent in ~10 minutes
- Order by dependency (schema first, then entities, services, controllers)
- Be specific: name files, classes, methods, table names
- Include 'build passes' in every story's acceptance criteria
- Reference existing implementations as patterns to follow
- When done, print: done" \
    "creating PRD from task description"

  GEN_PRD="${SESSION_DIR}/generated_prd.md"
  if [[ -f "$GEN_PRD" ]] && [[ -s "$GEN_PRD" ]]; then
    prd_to_task_md "$GEN_PRD" "$TASK_FILE"
    PRD_SOURCE="prd"
    success "PRD created and converted to task.md ($(grep -c '^\- \[ \]' "$TASK_FILE" 2>/dev/null || echo 0) subtasks)"
  else
    # Fallback: check if planner wrote directly to task.md
    if [[ -f "$TASK_FILE" ]] && [[ -s "$TASK_FILE" ]]; then
      success "task.md created (planner wrote directly)"
    else
      error "Planner did not create task.md or PRD!"
      exit 1
    fi
  fi
fi

# Ensure task.md exists at this point
if [[ ! -f "$TASK_FILE" ]] || [[ ! -s "$TASK_FILE" ]]; then
  error "No task.md found after Phase 1 — cannot proceed"
  exit 1
fi

# ═══════════════════════════════════════════════════════════
# START SERVICES (if frontend mode)
# ═══════════════════════════════════════════════════════════
if $FRONTEND; then
  start_services || { error "Service startup failed — aborting"; exit 1; }
fi

# ═══════════════════════════════════════════════════════════
# INITIALIZE SESSION STATE
# ═══════════════════════════════════════════════════════════

# Parse subtasks — supports multiple plan formats
ALL_LINES=()

# Format 1: checkbox items  - [ ] or - [x] or - [/]
while IFS= read -r line; do
  ALL_LINES+=("$line")
done < <(grep -n '\- \[.\]' "$TASK_FILE" 2>/dev/null || true)

# Format 2: if no checkboxes, look for section headers and convert
if [[ ${#ALL_LINES[@]} -eq 0 ]]; then
  log "No checkbox subtasks found — scanning for section headers..."

  # Try patterns in order of specificity
  SECTION_PATTERN=""
  if grep -q '^### \(Phase\|Step\|Part\|Stage\|Task\) [0-9]' "$TASK_FILE" 2>/dev/null; then
    SECTION_PATTERN='^### \(Phase\|Step\|Part\|Stage\|Task\) [0-9]'
  elif grep -q '^## [0-9][0-9]*\.' "$TASK_FILE" 2>/dev/null; then
    SECTION_PATTERN='^## [0-9][0-9]*\.'
  elif grep -q '^### [0-9][0-9]*\.' "$TASK_FILE" 2>/dev/null; then
    SECTION_PATTERN='^### [0-9][0-9]*\.'
  fi

  if [[ -n "$SECTION_PATTERN" ]]; then
    # Build a new task.md: checkbox index at top + original plan below
    ORIG_CONTENT=$(cat "$TASK_FILE")

    # Write header
    {
      echo "## Subtasks"
      echo ""
      # Write each checkbox on its own line
      while IFS= read -r hdr; do
        title=$(echo "$hdr" | sed 's/^#\{2,3\} //')
        echo "- [ ] **${title}**"
      done < <(grep "$SECTION_PATTERN" <<< "$ORIG_CONTENT")
      echo ""
      echo "---"
      echo ""
      echo "$ORIG_CONTENT"
    } > "$TASK_FILE"

    # Re-parse
    while IFS= read -r line; do
      ALL_LINES+=("$line")
    done < <(grep -n '\- \[.\]' "$TASK_FILE" 2>/dev/null || true)
    log "Converted ${#ALL_LINES[@]} section headers into subtasks"
  fi
fi

TOTAL=${#ALL_LINES[@]}

[[ $TOTAL -eq 0 ]] && { error "No subtasks found in plan — expected '- [ ]' checkboxes or '### Phase N:' sections"; exit 1; }
log "Found ${BOLD}${TOTAL}${NC} subtasks"

# Helpers
get_subtask_status() {
  local info="${ALL_LINES[$1]}"
  if [[ "${info#*:}" == *"[x]"* ]]; then echo "done"
  elif [[ "${info#*:}" == *"[/]"* ]]; then echo "in_progress"
  else echo "pending"; fi
}

get_block() {
  local idx=$1
  local start="${ALL_LINES[$idx]%%:*}"
  local end=""
  if [[ $((idx + 1)) -lt $TOTAL ]]; then
    end="${ALL_LINES[$((idx + 1))]%%:*}"
    end=$((end - 1))
  else
    end=$(wc -l < "$TASK_FILE" | tr -d ' ')
  fi
  sed -n "${start},${end}p" "$TASK_FILE"
}

get_title() {
  echo "$1" | head -1 | sed 's/^- \[.\] \*\*//' | sed 's/\*\*.*//' | xargs
}

# Build initial state
build_state() {
  local state="# Session State\n"
  state+="Updated: $(date '+%Y-%m-%d %H:%M:%S')\n\n"
  state+="## Subtask Status\n"
  for ((j=0; j<TOTAL; j++)); do
    local num=$((j + 1))
    local status=$(get_subtask_status $j)
    local block=$(get_block $j)
    local title=$(get_title "$block")
    local mark="[ ]"
    [[ "$status" == "done" ]] && mark="[x]"
    [[ "$status" == "in_progress" ]] && mark="[/]"
    state+="- [${mark:1:1}] Subtask ${num}: ${title} (${status})\n"
  done
  state+="\n## History\n"
  echo -e "$state"
}

echo -e "$(build_state)" > "$STATE_FILE"

# ═══════════════════════════════════════════════════════════
# PHASE 2: PLANNER-DRIVEN DYNAMIC LOOP
# ═══════════════════════════════════════════════════════════
# The planner decides what to do next by writing DIRECTIVES.
# Coordinator reads directive, dispatches, feeds result back.
#
ROUND=0
COMPLETED=0
FAILED=0

# Count already-done subtasks
for ((i=0; i<TOTAL; i++)); do
  [[ "$(get_subtask_status $i)" == "done" ]] && COMPLETED=$((COMPLETED + 1))
done
[[ $COMPLETED -gt 0 ]] && log "${COMPLETED} subtask(s) already done — resuming"

while [[ $ROUND -lt $MAX_ROUNDS ]] && [[ $COMPLETED -lt $TOTAL ]]; do
  ROUND=$((ROUND + 1))
  DIRECTIVE_FILE="${DIRECTIVES_DIR}/directive_$(printf '%03d' $ROUND).md"

  echo ""
  echo -e "${BOLD}${BLUE}╔══════════════════════════════════════════╗${NC}"
  echo -e "${BOLD}${BLUE}║  🔄 ROUND ${ROUND} — Planner deciding...       ║${NC}"
  echo -e "${BOLD}${BLUE}╚══════════════════════════════════════════╝${NC}"

  # ─── Refresh state ────────────────────────────────
  # Re-parse task.md (may have been edited by agents)
  ALL_LINES=()
  while IFS= read -r line; do
    ALL_LINES+=("$line")
  done < <(grep -n '\- \[.\]' "$TASK_FILE" 2>/dev/null || true)
  TOTAL=${#ALL_LINES[@]}

  # Truncate state history to last 10 rounds to prevent unbounded growth
  state_lines=$(wc -l < "$STATE_FILE" 2>/dev/null | tr -d ' ' || echo "0")
  if [[ $state_lines -gt 60 ]]; then
    # Keep header (first 15 lines) + last 30 lines of history
    { head -15 "$STATE_FILE"; echo "... (earlier rounds truncated) ..."; tail -30 "$STATE_FILE"; } > "${STATE_FILE}.tmp"
    mv "${STATE_FILE}.tmp" "$STATE_FILE"
  fi
  CURRENT_STATE=$(cat "$STATE_FILE")

  # Gather recent results (safe: check files exist before ls to avoid nullglob listing cwd)
  RECENT_LOGS=""
  LOG_FILES=("${SESSION_DIR}"/log_*.md)
  if [[ ${#LOG_FILES[@]} -gt 0 ]] && [[ -f "${LOG_FILES[0]}" ]]; then
    for recent in $(ls -t "${LOG_FILES[@]}" 2>/dev/null | head -3); do
      RECENT_LOGS+="
=== $(basename "$recent") ===
$(tail -30 "$recent" 2>/dev/null)
=== END ==="
    done
  fi

  # Build subtask summary for planner
  SUBTASK_SUMMARY=""
  for ((j=0; j<TOTAL; j++)); do
    local_num=$((j + 1))
    local_status=$(get_subtask_status $j)
    local_block=$(get_block $j)
    local_title=$(get_title "$local_block")
    case "$local_status" in
      done)        SUBTASK_SUMMARY+="  ✅ ${local_num}. ${local_title}\n" ;;
      in_progress) SUBTASK_SUMMARY+="  🔄 ${local_num}. ${local_title}\n" ;;
      pending)     SUBTASK_SUMMARY+="  ⬜ ${local_num}. ${local_title}\n" ;;
    esac
  done

  # ─── Ask planner what to do next ──────────────────
  PLANNER_SKILLS=$(get_skills_for "$PLANNER")

  send_to_agent "$PLANNER" "You are the planner. Decide what happens next. Round ${ROUND}/${MAX_ROUNDS}.

PROJECT: ${PROJECT}
PLAN: ${TASK_FILE}
${PLANNER_SKILLS}

PROGRESS (${COMPLETED}/${TOTAL} done):
$(echo -e "$SUBTASK_SUMMARY")
${RECENT_LOGS:+
RECENT RESULTS (last 3 agent outputs — check for errors/success):
${RECENT_LOGS}
}
Read ${TASK_FILE} for full subtask details. Read recent logs above to understand what happened.

Write your decision to: ${DIRECTIVE_FILE}

FORMAT (first line MUST start with ACTION:):
ACTION: EXECUTE|REVIEW|APPROVE|SKIP|DONE|FRONTEND_EXECUTE|FRONTEND_REVIEW
SUBTASK: <number>
INSTRUCTIONS: <specific instructions for the agent — cite files, patterns, classes>
REASON: <why this action>

AVAILABLE AGENTS:
- Backend executor: ${EXECUTOR} — implements backend code (Java/Spring Boot)
- Backend reviewers: ${REVIEWER_LIST[*]} — reviews backend code$(
if $FRONTEND; then
  echo "
- Frontend dev: ${FRONTEND_DEV:-not assigned} — implements frontend code (Angular)
- Frontend reviewers: $(if [[ ${#FRONTEND_REVIEWER_LIST[@]} -gt 0 ]]; then echo "${FRONTEND_REVIEWER_LIST[*]}"; else echo 'not assigned'; fi) — reviews frontend in browser
- Services: backend=${BACKEND_URL:-not running}, frontend=${FRONTEND_URL:-not running}"
fi)

ACTIONS:
- EXECUTE N: Send subtask to executor (${EXECUTOR}). Include SPECIFIC instructions.
- REVIEW N: Send to reviewers (${REVIEWER_LIST[*]}). They provide feedback only — they do NOT approve/reject.$(
if $FRONTEND; then
  echo "
- FRONTEND_EXECUTE N: Send subtask to frontend dev (${FRONTEND_DEV:-?}). For Angular/UI work.
- FRONTEND_REVIEW N: Send to frontend reviewers. They provide feedback only."
fi)
- APPROVE N: YOU decide to mark subtask done.
- SKIP N: YOU decide to skip a subtask.
- DONE: YOU decide all work is complete.

YOU ARE THE BRAIN — all decisions are yours:
- After EVERY action (execute or review), results come back to YOU.
- YOU read ALL feedback (execution logs, reviewer reports) and decide what to do next.
- When reviewers disagree (one says OK, another says NOT OK), YOU are the arbiter.
  Analyze both reports, decide if the concern is valid, and act accordingly.
- YOU decide when something is good enough to APPROVE — not the reviewers.
- YOU decide when to re-execute with specific fix instructions based on feedback.
- YOU decide when to SKIP if stuck after multiple attempts.
- ONLY write DONE when ALL ${TOTAL}/${TOTAL} subtasks are completed. Currently ${COMPLETED}/${TOTAL} done.$(
if [[ "$PRD_SOURCE" == "prd" ]]; then
  echo "

PRD MODE — Each subtask has Acceptance Criteria.
- When writing EXECUTE: reference acceptance criteria, tell executor to verify each one.
- When writing REVIEW: tell reviewers to check each criterion and report findings.
- YOU decide if criteria are met based on the feedback."
fi)$(
if $FRONTEND; then
  echo "
- For UI/Angular subtasks: use FRONTEND_EXECUTE instead of EXECUTE
- After FRONTEND_EXECUTE: use FRONTEND_REVIEW to get browser feedback
- Backend subtasks FIRST, then frontend subtasks that depend on backend APIs"
fi)

Write the directive to ${DIRECTIVE_FILE}, then print: done" \
    "planner round ${ROUND}"

  # ─── Parse directive ────────────────────────────────
  # Strategy: check directive file first, then fall back to extracting from agent log output
  if [[ ! -f "$DIRECTIVE_FILE" ]] || [[ ! -s "$DIRECTIVE_FILE" ]]; then
    PLANNER_LOG="${SESSION_DIR}/log_$(printf '%03d' $MSG_SEQ)_${PLANNER}.md"
    if [[ -f "$PLANNER_LOG" ]]; then
      # Strip ANSI escape codes from pipe-pane output before searching
      clean_log=$(sed 's/\x1b\[[0-9;]*[a-zA-Z]//g' "$PLANNER_LOG" 2>/dev/null)

      # Extract directive from log output — skip the FORMAT template line (contains |)
      # Look for ACTION: with a single valid action (no pipes)
      if echo "$clean_log" | grep -q '^ACTION: [A-Z_]*$' 2>/dev/null; then
        # Found a clean ACTION line — grab it and the next few lines
        echo "$clean_log" | grep -A 5 '^ACTION: [A-Z_]*$' | head -6 > "$DIRECTIVE_FILE" 2>/dev/null || true
      fi

      # Fallback: extract from ```md code blocks (codex often wraps output in code blocks)
      if [[ ! -s "$DIRECTIVE_FILE" ]]; then
        block_content=$(echo "$clean_log" | sed -n '/^```/,/^```/p' | sed '1d;$d')
        if echo "$block_content" | grep -q '^ACTION:' 2>/dev/null; then
          echo "$block_content" > "$DIRECTIVE_FILE" 2>/dev/null || true
        fi
      fi

      # Last resort: find any ACTION: line that doesn't contain | (template)
      if [[ ! -s "$DIRECTIVE_FILE" ]]; then
        echo "$clean_log" | grep 'ACTION:' | grep -v '|' | head -1 > "$DIRECTIVE_FILE" 2>/dev/null || true
        if [[ -s "$DIRECTIVE_FILE" ]]; then
          # Also grab SUBTASK/INSTRUCTIONS/REASON lines nearby
          action_line=$(echo "$clean_log" | grep -n 'ACTION:' | grep -v '|' | head -1 | cut -d: -f1)
          if [[ -n "$action_line" ]]; then
            echo "$clean_log" | tail -n +"$action_line" | head -10 > "$DIRECTIVE_FILE" 2>/dev/null || true
          fi
        fi
      fi
    fi
  fi

  if [[ ! -f "$DIRECTIVE_FILE" ]] || [[ ! -s "$DIRECTIVE_FILE" ]]; then
    warn "Planner didn't write directive file. Asking again..."
    continue
  fi

  # Strip ANSI codes from directive file (in case extracted from pipe-pane log)
  sed -i '' 's/\x1b\[[0-9;]*[a-zA-Z]//g' "$DIRECTIVE_FILE" 2>/dev/null || true

  # Extract fields
  ACTION=$(grep -m1 'ACTION:' "$DIRECTIVE_FILE" 2>/dev/null | sed 's/.*ACTION: *//' | xargs || echo "")
  SUBTASK_NUM=$(grep -m1 'SUBTASK:' "$DIRECTIVE_FILE" 2>/dev/null | sed 's/.*SUBTASK: *//' | tr -dc '0-9' || echo "")
  DIRECTIVE_AGENT=$(grep -m1 'AGENT:' "$DIRECTIVE_FILE" 2>/dev/null | sed 's/.*AGENT: *//' | xargs || echo "")
  DIRECTIVE_INSTRUCTIONS=$(sed -n '/INSTRUCTIONS:/,/^---$\|^$/p' "$DIRECTIVE_FILE" 2>/dev/null | sed '1s/.*INSTRUCTIONS: *//' | head -20 || echo "")
  DIRECTIVE_REASON=$(grep -m1 'REASON:' "$DIRECTIVE_FILE" 2>/dev/null | sed 's/.*REASON: *//' | xargs || echo "")

  log "📋 Directive: ${BOLD}${ACTION}${NC}${SUBTASK_NUM:+ subtask #${SUBTASK_NUM}}"

  # Append to state history
  echo "- Round ${ROUND}: ${ACTION}${SUBTASK_NUM:+ subtask #${SUBTASK_NUM}} ${DIRECTIVE_REASON:+— ${DIRECTIVE_REASON}}" >> "$STATE_FILE"

  # ─── Dispatch directive ─────────────────────────────
  case "$ACTION" in

    EXECUTE)
      [[ -z "$SUBTASK_NUM" ]] && { warn "EXECUTE needs SUBTASK number"; continue; }
      IDX=$((SUBTASK_NUM - 1))
      BLOCK=$(get_block $IDX)
      TITLE=$(get_title "$BLOCK")
      EXEC_AGENT="${DIRECTIVE_AGENT:-$EXECUTOR}"
      EXEC_SKILLS=$(get_skills_for "$EXEC_AGENT")

      echo -e "${BOLD}━━━ 🔨 EXECUTE subtask #${SUBTASK_NUM}: ${TITLE} ━━━${NC}"

      send_to_agent "$EXEC_AGENT" "You are an executor. Implement the following subtask in project ${PROJECT}.
${EXEC_SKILLS}

SUBTASK #${SUBTASK_NUM}: ${TITLE}

${BLOCK}
${DIRECTIVE_INSTRUCTIONS:+
PLANNER INSTRUCTIONS:
${DIRECTIVE_INSTRUCTIONS}
}
Steps:
1. Read existing project code to understand patterns and conventions
2. Implement exactly what the spec says
3. Run the build command (e.g. mvn compile, npm run build) to verify no errors$(
if [[ "$PRD_SOURCE" == "prd" ]]; then
  echo "
4. Verify EACH acceptance criterion listed above — the subtask is NOT done until all criteria pass
5. Do NOT edit task.md or any .codeswarm/ files
6. When done, print: done"
else
  echo "
4. Do NOT edit task.md or any .codeswarm/ files
5. When done, print: done"
fi)" \
        "execute subtask #${SUBTASK_NUM}"

      # Mark in-progress
      LINE_NUM="${ALL_LINES[$IDX]%%:*}"
      sed -i '' "${LINE_NUM}s/- \[ \]/- [\/]/" "$TASK_FILE" 2>/dev/null || true
      ;;

    REVIEW)
      [[ -z "$SUBTASK_NUM" ]] && { warn "REVIEW needs SUBTASK number"; continue; }
      IDX=$((SUBTASK_NUM - 1))
      BLOCK=$(get_block $IDX)
      TITLE=$(get_title "$BLOCK")

      echo -e "${BOLD}━━━ 🔍 REVIEW subtask #${SUBTASK_NUM}: ${TITLE} ━━━${NC}"

      # Get changed files for context
      CHANGED_FILES=$(cd "$PROJECT" && git diff --name-only HEAD 2>/dev/null | head -20 || echo "(git not available)")

      log "📝 Sending to ${#REVIEWER_LIST[@]} reviewer(s) in parallel..."

      REVIEW_REPORTS=()
      REVIEW_PIDS=()
      for rev_agent in "${REVIEWER_LIST[@]}"; do
        REVIEW_REPORT="${SESSION_DIR}/review_r${ROUND}_${SUBTASK_NUM}_${rev_agent}.md"
        REV_SKILLS=$(get_skills_for "$rev_agent")

        send_to_agent "$rev_agent" "You are a code reviewer. Review subtask #${SUBTASK_NUM} in project ${PROJECT}.
${REV_SKILLS}

SUBTASK: ${TITLE}

EXPECTED:
${BLOCK}

CHANGED FILES: ${CHANGED_FILES}
${DIRECTIVE_INSTRUCTIONS:+
FOCUS: ${DIRECTIVE_INSTRUCTIONS}
}
Write your review report to: ${REVIEW_REPORT}

Report format:
BUILD_STATUS: Pass/Fail (run the build command to check)
ISSUES: <specific problems with file:line references, or 'None'>$(
if [[ "$PRD_SOURCE" == "prd" ]]; then
  echo "
ACCEPTANCE_CRITERIA:
- [ ] or [x] <criterion 1> — <pass/fail with reason>
- [ ] or [x] <criterion 2> — <pass/fail with reason>
..."
fi)
ASSESSMENT: <1-2 sentence quality summary>$(
if [[ "$PRD_SOURCE" == "prd" ]]; then
  echo "

IMPORTANT: This subtask has Acceptance Criteria (see EXPECTED block above).
You MUST verify EACH acceptance criterion explicitly and report pass/fail for each one.
A subtask only passes review if ALL acceptance criteria are met."
fi)

Rules:
- You provide FEEDBACK only. The PLANNER makes all decisions.
- Report what you found — issues, concerns, quality assessment.
- Do NOT approve or reject. Do NOT edit task.md.
- When done, print: done" \
          "review #${SUBTASK_NUM} by ${rev_agent}" &
        REVIEW_PIDS+=($!)

        REVIEW_REPORTS+=("$REVIEW_REPORT")
      done

      for rpid in "${REVIEW_PIDS[@]}"; do wait "$rpid" 2>/dev/null || true; done
      log "All reviewers finished"

      # Consolidate reviews into state
      REVIEWS_SUMMARY=""
      for rr in "${REVIEW_REPORTS[@]}"; do
        rev_name=$(basename "$rr" .md)
        if [[ -f "$rr" ]] && [[ -s "$rr" ]]; then
          REVIEWS_SUMMARY+="
=== ${rev_name} ===
$(cat "$rr")
=== END ==="
        fi
      done

      # Append reviews to state for planner's next round
      echo -e "\n### Reviews for subtask #${SUBTASK_NUM} (round ${ROUND}):\n${REVIEWS_SUMMARY}" >> "$STATE_FILE"
      ;;

    FRONTEND_EXECUTE)
      [[ -z "$SUBTASK_NUM" ]] && { warn "FRONTEND_EXECUTE needs SUBTASK number"; continue; }
      [[ -z "$FRONTEND_DEV" ]] && { warn "No --frontend-dev agent assigned"; continue; }
      IDX=$((SUBTASK_NUM - 1))
      BLOCK=$(get_block $IDX)
      TITLE=$(get_title "$BLOCK")
      FE_SKILLS=$(get_skills_for "$FRONTEND_DEV")

      echo -e "${BOLD}━━━ 🎨 FRONTEND_EXECUTE subtask #${SUBTASK_NUM}: ${TITLE} ━━━${NC}"

      send_to_agent "$FRONTEND_DEV" "You are a frontend developer. Implement the following subtask in project ${PROJECT}.
${FE_SKILLS}

SUBTASK #${SUBTASK_NUM}: ${TITLE}

${BLOCK}
${DIRECTIVE_INSTRUCTIONS:+
PLANNER INSTRUCTIONS:
${DIRECTIVE_INSTRUCTIONS}
}
ENVIRONMENT:
- Backend API: ${BACKEND_URL:-http://localhost:8080}
- Frontend: ${FRONTEND_URL:-http://localhost:4200}
- Both services are already running.

Steps:
1. Read existing Angular code to understand patterns, component structure, and services
2. Implement the Angular components, services, routes, and templates as specified
3. After code changes, the frontend will hot-reload automatically
4. Use chrome-devtools-mcp to verify your work:
   a. navigate_page to ${FRONTEND_URL:-http://localhost:4200}/your-route
   b. list_console_messages — check for errors
   c. list_network_requests — verify API calls succeed
   d. take_screenshot — visual confirmation
   e. fill_form / click — test interactive elements
5. Do NOT edit task.md or any .codeswarm/ files
6. When done, print: done" \
        "frontend execute subtask #${SUBTASK_NUM}"

      # Mark in-progress
      LINE_NUM="${ALL_LINES[$IDX]%%:*}"
      sed -i '' "${LINE_NUM}s/- \[ \]/- [\/]/" "$TASK_FILE" 2>/dev/null || true
      ;;

    FRONTEND_REVIEW)
      [[ -z "$SUBTASK_NUM" ]] && { warn "FRONTEND_REVIEW needs SUBTASK number"; continue; }
      IDX=$((SUBTASK_NUM - 1))
      BLOCK=$(get_block $IDX)
      TITLE=$(get_title "$BLOCK")

      echo -e "${BOLD}━━━ 🔍🎨 FRONTEND_REVIEW subtask #${SUBTASK_NUM}: ${TITLE} ━━━${NC}"

      CHANGED_FILES=$(cd "$PROJECT" && git diff --name-only HEAD 2>/dev/null | head -20 || echo "(git not available)")

      # Use frontend reviewers if available, otherwise fall back to backend reviewers
      FE_REV_LIST=()
      if [[ ${#FRONTEND_REVIEWER_LIST[@]} -gt 0 ]]; then
        FE_REV_LIST=("${FRONTEND_REVIEWER_LIST[@]}")
      fi
      [[ ${#FE_REV_LIST[@]} -eq 0 ]] && FE_REV_LIST=("${REVIEWER_LIST[@]}")

      log "🎨 Sending to ${#FE_REV_LIST[@]} frontend reviewer(s) in parallel..."

      REVIEW_REPORTS=()
      FE_REVIEW_PIDS=()
      for rev_agent in "${FE_REV_LIST[@]}"; do
        REVIEW_REPORT="${SESSION_DIR}/fe_review_r${ROUND}_${SUBTASK_NUM}_${rev_agent}.md"
        REV_SKILLS=$(get_skills_for "$rev_agent")

        send_to_agent "$rev_agent" "You are a frontend reviewer. Review subtask #${SUBTASK_NUM} in project ${PROJECT}.
${REV_SKILLS}

SUBTASK: ${TITLE}

EXPECTED:
${BLOCK}

CHANGED FILES: ${CHANGED_FILES}
${DIRECTIVE_INSTRUCTIONS:+
FOCUS: ${DIRECTIVE_INSTRUCTIONS}
}
ENVIRONMENT:
- Frontend running at: ${FRONTEND_URL:-http://localhost:4200}
- Backend running at: ${BACKEND_URL:-http://localhost:8080}

Your review process (use chrome-devtools-mcp):
1. navigate_page to the relevant page
2. list_console_messages — report ANY errors or warnings
3. list_network_requests — check API calls (status codes, failed requests)
4. take_screenshot — capture the current state of the page
5. Test interactions: fill_form, click buttons, verify behavior
6. Check the Angular code: component structure, services, templates

Write your review report to: ${REVIEW_REPORT}

Report format:
CONSOLE_ERRORS: <list of console errors, or 'None'>
NETWORK_ISSUES: <failed API calls or unexpected responses, or 'None'>
UI_STATUS: <does it render correctly? form validation? responsive?>
CODE_QUALITY: <Angular best practices, component structure>
SCREENSHOT: <describe what the page looks like>
ASSESSMENT: <1-2 sentence overall quality summary>

Rules:
- You provide FEEDBACK only. The PLANNER makes all decisions.
- Report what you found — console errors, network issues, UI state, quality.
- Do NOT approve or reject. Do NOT edit task.md.
- When done, print: done" \
          "frontend review #${SUBTASK_NUM} by ${rev_agent}" &
        FE_REVIEW_PIDS+=($!)

        REVIEW_REPORTS+=("$REVIEW_REPORT")
      done

      for rpid in "${FE_REVIEW_PIDS[@]}"; do wait "$rpid" 2>/dev/null || true; done
      log "All frontend reviewers finished"

      # Consolidate frontend reviews into state
      REVIEWS_SUMMARY=""
      for rr in "${REVIEW_REPORTS[@]}"; do
        rev_name=$(basename "$rr" .md)
        if [[ -f "$rr" ]] && [[ -s "$rr" ]]; then
          REVIEWS_SUMMARY+="
=== ${rev_name} ===
$(cat "$rr")
=== END ==="
        fi
      done

      echo -e "\n### Frontend Reviews for subtask #${SUBTASK_NUM} (round ${ROUND}):\n${REVIEWS_SUMMARY}" >> "$STATE_FILE"
      ;;

    APPROVE)
      [[ -z "$SUBTASK_NUM" ]] && { warn "APPROVE needs SUBTASK number"; continue; }
      IDX=$((SUBTASK_NUM - 1))
      BLOCK=$(get_block $IDX)
      TITLE=$(get_title "$BLOCK")

      # Mark done in task.md
      LINE_NUM="${ALL_LINES[$IDX]%%:*}"
      sed -i '' "${LINE_NUM}s/- \[.\]/- [x]/" "$TASK_FILE" 2>/dev/null || true

      COMPLETED=$((COMPLETED + 1))
      success "Subtask #${SUBTASK_NUM} APPROVED ✓ (${COMPLETED}/${TOTAL})"

      # Git commit
      if command -v git &>/dev/null && git -C "$PROJECT" rev-parse --is-inside-work-tree &>/dev/null 2>&1; then
        (cd "$PROJECT" && git add -A && git commit -m "feat: ${TITLE}" --no-verify 2>/dev/null) || true
      fi
      ;;

    SKIP)
      [[ -z "$SUBTASK_NUM" ]] && { warn "SKIP needs SUBTASK number"; continue; }
      IDX=$((SUBTASK_NUM - 1))

      # Mark as done (skipped)
      LINE_NUM="${ALL_LINES[$IDX]%%:*}"
      sed -i '' "${LINE_NUM}s/- \[.\]/- [x]/" "$TASK_FILE" 2>/dev/null || true

      COMPLETED=$((COMPLETED + 1))
      warn "Subtask #${SUBTASK_NUM} SKIPPED — ${DIRECTIVE_REASON:-no reason given}"
      ;;

    DONE)
      success "Planner says: ALL DONE — ${DIRECTIVE_REASON:-all subtasks completed}"
      break
      ;;

    *)
      warn "Unknown action: '${ACTION}' — asking planner again..."
      echo "- Round ${ROUND}: ERROR — unknown action '${ACTION}'" >> "$STATE_FILE"
      ;;
  esac
done

if [[ $ROUND -ge $MAX_ROUNDS ]] && [[ $COMPLETED -lt $TOTAL ]]; then
  warn "Max rounds (${MAX_ROUNDS}) reached with ${COMPLETED}/${TOTAL} done"
fi

# ═══════════════════════════════════════════════════════════
# CLEANUP SERVICES & DASHBOARD
# ═══════════════════════════════════════════════════════════
if $FRONTEND; then
  log "Stopping services..."
  stop_services
fi
if [[ -n "$DASHBOARD_PID" ]]; then
  log "Stopping dashboard (PID: ${DASHBOARD_PID})..."
  kill "$DASHBOARD_PID" 2>/dev/null || true
fi

# ═══════════════════════════════════════════════════════════
# FINAL REPORT
# ═══════════════════════════════════════════════════════════
echo ""
echo -e "${BOLD}${MAGENTA}┌───────────────────────────────────────┐${NC}"
echo -e "${BOLD}${MAGENTA}│          📊 FINAL REPORT              │${NC}"
echo -e "${BOLD}${MAGENTA}└───────────────────────────────────────┘${NC}"
echo -e "  ${GREEN}Completed:${NC} ${COMPLETED}/${TOTAL}"
echo -e "  ${CYAN}Rounds:${NC}    ${ROUND}"
[[ $FAILED -gt 0 ]] && echo -e "  ${RED}Failed:${NC}    ${FAILED}"
echo -e "  ${DIM}Session: ${SESSION_DIR}${NC}"
echo ""

# Show task.md status
grep '\- \[' "$TASK_FILE" 2>/dev/null | while IFS= read -r line; do
  if echo "$line" | grep -q '\[x\]'; then
    echo -e "  ${GREEN}${line}${NC}"
  else
    echo -e "  ${RED}${line}${NC}"
  fi
done
echo ""

# ─── Archive completed plans ────────────────────────────
if [[ $COMPLETED -eq $TOTAL ]]; then
  echo -e "${GREEN}${BOLD}✓ All ${TOTAL} subtasks completed!${NC}"

  TASKS_DIR="${PROJECT}/docs/tasks"
  mkdir -p "$TASKS_DIR"

  TASK_TITLE=$(grep -m1 '^# Task:' "$TASK_FILE" 2>/dev/null | sed 's/^# Task: *//' | xargs)
  [[ -z "$TASK_TITLE" ]] && TASK_TITLE="${TASK:-task}"

  SLUG=$(echo "$TASK_TITLE" \
    | tr '[:upper:]' '[:lower:]' \
    | sed 's/[^a-z0-9 _-]//g' \
    | sed 's/  */ /g' \
    | sed 's/ /_/g' \
    | cut -c1-60)
  [[ -z "$SLUG" ]] && SLUG="task"

  ARCHIVE_NAME="$(date +%Y%m%d)_${SLUG}.md"
  ARCHIVE_PATH="${TASKS_DIR}/${ARCHIVE_NAME}"

  if [[ -f "$ARCHIVE_PATH" ]]; then
    COUNTER=2
    while [[ -f "${TASKS_DIR}/$(date +%Y%m%d)_${SLUG}_${COUNTER}.md" ]]; do
      COUNTER=$((COUNTER + 1))
    done
    ARCHIVE_NAME="$(date +%Y%m%d)_${SLUG}_${COUNTER}.md"
    ARCHIVE_PATH="${TASKS_DIR}/${ARCHIVE_NAME}"
  fi

  mv "$TASK_FILE" "$ARCHIVE_PATH"
  success "Archived → docs/tasks/${ARCHIVE_NAME}"
else
  echo -e "${YELLOW}${BOLD}⚠ ${COMPLETED}/${TOTAL} done. Re-run to continue.${NC}"
  echo -e "  ${DIM}task.md kept for resume. Use --replan to start fresh.${NC}"
fi
echo ""
