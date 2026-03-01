#!/usr/bin/env bash
#
# common.sh — Shared utilities for the GSD modular pipeline
#
# Provides: logging, agent dispatch, config loading, state management
# Source this file from any pipeline module.
#

# ─── Colors ─────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; CYAN='\033[0;36m'; MAGENTA='\033[0;35m'
BOLD='\033[1m'; DIM='\033[2m'; NC='\033[0m'

# ─── Prevent double-sourcing ────────────────────────────
[[ -n "${_COMMON_LOADED:-}" ]] && return 0
_COMMON_LOADED=1

# ─── Resolve script directory ───────────────────────────
MODULES_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CODESWARM_ROOT="$(cd "$MODULES_DIR/.." && pwd)"

# ─── GSD Paths (real GSD implementation) ─────────────────
GSD_ROOT="${GSD_ROOT:-${CODESWARM_ROOT}/gsd}"
GSD_TOOLS="${GSD_ROOT}/get-shit-done/bin/gsd-tools.cjs"

# Wrapper: call real GSD tools CLI
gsd_tools() {
  if [[ ! -f "$GSD_TOOLS" ]]; then
    error "GSD tools not found at $GSD_TOOLS"
    return 1
  fi
  node "$GSD_TOOLS" "$@"
}

# ─── Logging ─────────────────────────────────────────────
LOG_FILE="${LOG_FILE:-/dev/null}"

log()     { echo -e "${CYAN}[$(date +%H:%M:%S)] $1${NC}"; echo "[$(date +%H:%M:%S)] $1" >> "$LOG_FILE"; }
success() { echo -e "${GREEN}✓ $1${NC}"; echo "✓ $1" >> "$LOG_FILE"; }
warn()    { echo -e "${YELLOW}⚠ $1${NC}"; echo "⚠ $1" >> "$LOG_FILE"; }
error()   { echo -e "${RED}✗ $1${NC}"; echo "✗ $1" >> "$LOG_FILE"; }

banner() {
  local title="$1"
  echo ""
  echo -e "${BOLD}${MAGENTA}╔══════════════════════════════════════════════════════╗${NC}"
  echo -e "${BOLD}${MAGENTA}║  ${title}$(printf '%*s' $((50 - ${#title})) '')║${NC}"
  echo -e "${BOLD}${MAGENTA}╚══════════════════════════════════════════════════════╝${NC}"
  echo ""
}

step_banner() {
  local step="$1"
  local desc="$2"
  echo ""
  echo -e "${BOLD}${BLUE}━━━ ${step}: ${desc} ━━━${NC}"
}

# ─── Session Management ─────────────────────────────────
init_session() {
  local project="$1"
  ARTIFACTS="${project}/.codeswarm"
  TIMESTAMP=$(date +%Y%m%d_%H%M%S)
  SESSION_ID="session_${TIMESTAMP}"
  SESSION_DIR="${ARTIFACTS}/sessions/${SESSION_ID}"
  PLANNING_DIR="${ARTIFACTS}/planning"

  mkdir -p "$SESSION_DIR"
  mkdir -p "${SESSION_DIR}/directives"
  mkdir -p "${SESSION_DIR}/skills"
  mkdir -p "$PLANNING_DIR"
  mkdir -p "${PLANNING_DIR}/research"

  LOG_FILE="${SESSION_DIR}/pipeline.log"
  touch "$LOG_FILE"

  # Write session metadata
  cat > "${SESSION_DIR}/metadata.json" <<EOF
{
  "session_id": "${SESSION_ID}",
  "timestamp": "${TIMESTAMP}",
  "project": "${project}",
  "pipeline": "gsd-modular"
}
EOF
}

# ─── Config Loading ──────────────────────────────────────
load_config() {
  local config_file="${CODESWARM_ROOT}/config.yaml"
  if [[ ! -f "$config_file" ]]; then
    warn "No config.yaml found, using defaults"
    return 0
  fi
  # Simple YAML extraction (no dependency on yq)
  _yaml_val() {
    grep "^  $1:" "$config_file" 2>/dev/null | head -1 | sed "s/^  $1: *//" | sed 's/#.*//' | xargs
  }
  CONFIG_PLANNER=$(_yaml_val "planner")
  CONFIG_EXECUTOR=$(_yaml_val "executor")
  CONFIG_REVIEWER=$(_yaml_val "reviewer")
}

# ─── Model Resolution ────────────────────────────────────
MODEL_OVERRIDES=""

get_model_for() {
  local agent="$1"
  local model=""
  if [[ -n "$MODEL_OVERRIDES" ]]; then
    IFS=',' read -ra pairs <<< "$MODEL_OVERRIDES"
    for pair in "${pairs[@]}"; do
      local key="${pair%%:*}"
      if [[ "$key" == "$agent" ]]; then
        local rest="${pair#*:}"
        if [[ "$rest" == *:* ]]; then
          model="${rest%:*}"
        else
          model="$rest"
        fi
        break
      fi
    done
  fi
  echo "$model"
}

get_reasoning_effort() {
  local agent="$1"
  if [[ -n "$MODEL_OVERRIDES" ]]; then
    IFS=',' read -ra pairs <<< "$MODEL_OVERRIDES"
    for pair in "${pairs[@]}"; do
      local key="${pair%%:*}"
      if [[ "$key" == "$agent" ]]; then
        local rest="${pair#*:}"
        if [[ "$rest" == *:* ]]; then
          echo "${rest##*:}"
        fi
        break
      fi
    done
  fi
}

# ─── Retry wrapper (embedded into agent scripts) ─────────
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
      echo "[codeswarm] ⚠️  Attempt ${attempt}/${max_retries} failed (exit ${exit_code}). Retrying in ${wait_secs}s..."
      sleep $wait_secs
    fi
    attempt=$((attempt + 1))
  done
  echo "[codeswarm] ✗ All ${max_retries} attempts failed (last exit ${exit_code})"
  return $exit_code
}
'

# ─── Agent Dispatch ──────────────────────────────────────
# Globals for message sequencing
MSG_SEQ=${MSG_SEQ:-0}
STALE_TIMEOUT=${STALE_TIMEOUT:-300}
HEARTBEAT_INTERVAL=${HEARTBEAT_INTERVAL:-30}
DRY_RUN=${DRY_RUN:-false}
AGENT_RETRY_COUNT=${AGENT_RETRY_COUNT:-3}
AGENT_RETRY_DELAY=${AGENT_RETRY_DELAY:-5}

# send_to_agent <agent_name> <prompt> [label] [role]
# Runs an AI agent CLI with the given prompt. Blocks until done.
# Returns 0 on success, 1 on failure.
# Output captured to $SESSION_DIR/log_NNN_agent.md
send_to_agent() {
  local agent_name="$1"
  local prompt="$2"
  local label="${3:-}"
  local role="${4:-executor}"
  local project="${PROJECT:-$(pwd)}"

  MSG_SEQ=$((MSG_SEQ + 1))
  local seq=$(printf '%03d' $MSG_SEQ)
  local prompt_file="${SESSION_DIR}/prompt_${seq}_${agent_name}.md"
  local log_file="${SESSION_DIR}/log_${seq}_${agent_name}.md"
  local exitcode_file="${SESSION_DIR}/.exitcode_${seq}"

  echo "$prompt" > "$prompt_file"
  touch "$log_file"
  log "🚀 ${BOLD}${agent_name}${NC} ${label:+— ${label}} ${role:+(${role})}"

  if $DRY_RUN; then
    echo "# Dry run — prompt at: ${prompt_file}" > "$log_file"
    return 0
  fi

  # Build agent command
  local short="Read ALL instructions from the file ${prompt_file} and execute them completely. When done, print: done"
  local agent_cmd=""
  local agent_retries=${AGENT_RETRY_COUNT}
  local agent_retry_delay=${AGENT_RETRY_DELAY}

  local model=$(get_model_for "$agent_name")
  local effort=$(get_reasoning_effort "$agent_name")
  [[ -n "$model" ]] && log "  📦 Model: ${model}${effort:+ (effort: ${effort})}"

  case "$agent_name" in
    claude)
      agent_cmd="_retry ${agent_retries} ${agent_retry_delay} claude ${model:+--model $model} --dangerously-skip-permissions --verbose -p '${short}'; echo \$? > '${exitcode_file}'"
      ;;
    gemini)
      if [[ "$role" == "planner" ]]; then
        agent_cmd="_retry ${agent_retries} ${agent_retry_delay} gemini ${model:+--model $model} -p '${short}' --approval-mode plan; echo \$? > '${exitcode_file}'"
      else
        agent_cmd="_retry ${agent_retries} ${agent_retry_delay} gemini ${model:+--model $model} -p '${short}' --approval-mode yolo; echo \$? > '${exitcode_file}'"
      fi
      ;;
    codex)
      if [[ "$role" == "planner" ]]; then
        agent_cmd="_retry ${agent_retries} ${agent_retry_delay} codex exec ${model:+--model $model} ${effort:+--reasoning-effort $effort} '${short}'; echo \$? > '${exitcode_file}'"
      else
        agent_cmd="_retry ${agent_retries} ${agent_retry_delay} codex exec ${model:+--model $model} ${effort:+--reasoning-effort $effort} --yolo '${short}'; echo \$? > '${exitcode_file}'"
      fi
      ;;
    amp)
      agent_cmd="_retry ${agent_retries} ${agent_retry_delay} amp --dangerously-allow-all -x '${short}'; echo \$? > '${exitcode_file}'"
      ;;
    opencode)
      if [[ "$role" == "planner" ]]; then
        agent_cmd="_retry ${agent_retries} ${agent_retry_delay} opencode run ${model:+--model $model} '${short}'; echo \$? > '${exitcode_file}'"
      else
        agent_cmd="_retry ${agent_retries} ${agent_retry_delay} env OPENCODE_PERMISSION='{\"*\":\"allow\"}' opencode run ${model:+--model $model} '${short}'; echo \$? > '${exitcode_file}'"
      fi
      ;;
    *)
      error "Unknown agent: $agent_name"; return 1
      ;;
  esac

  # Execute with watchdog heartbeat
  local start_time=$(date +%s)
  local last_size=0
  local stale_since=$start_time

  local cmd_script="${SESSION_DIR}/.run_${seq}_${agent_name}.sh"
  cat > "$cmd_script" <<CMDEOF
#!/usr/bin/env bash
${RETRY_FUNC}
cd '${project}'
${agent_cmd}
CMDEOF
  chmod +x "$cmd_script"

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

  local elapsed=$(( $(date +%s) - start_time ))
  log "${agent_name} finished in $((elapsed / 60))m$((elapsed % 60))s"

  local exit_code=0
  if [[ -f "$exitcode_file" ]]; then
    exit_code=$(cat "$exitcode_file" | tr -d '[:space:]')
    rm -f "$exitcode_file"
  fi

  if [[ "$exit_code" == "WATCHDOG_KILLED" ]]; then
    error "${agent_name} killed by watchdog"
    return 1
  fi
  [[ "$exit_code" =~ ^[0-9]+$ ]] || { [[ -s "$log_file" ]] && exit_code=0 || exit_code=1; }

  if [[ $exit_code -ne 0 ]]; then
    warn "${agent_name} exited ${exit_code} — check: ${log_file}"
  else
    success "${agent_name} done"
  fi

  # Export the log file path for callers
  LAST_LOG_FILE="$log_file"
  return $exit_code
}

# send_to_agent_bg — Same as send_to_agent but runs in background
# Usage: send_to_agent_bg <agent_name> <prompt> [label] [role]
# After calling, use wait_for_agents to collect results.
AGENT_PIDS=()
AGENT_LOG_FILES=()

send_to_agent_bg() {
  local agent_name="$1"
  local prompt="$2"
  local label="${3:-}"
  local role="${4:-executor}"

  send_to_agent "$agent_name" "$prompt" "$label" "$role" &
  AGENT_PIDS+=($!)
  # Pre-calculate what the log file will be
  local seq=$(printf '%03d' $((MSG_SEQ)))
  AGENT_LOG_FILES+=("${SESSION_DIR}/log_${seq}_${agent_name}.md")
}

wait_for_agents() {
  local all_ok=true
  for pid in "${AGENT_PIDS[@]}"; do
    wait "$pid" 2>/dev/null || all_ok=false
  done
  AGENT_PIDS=()
  $all_ok
}

# ─── Skill Discovery ─────────────────────────────────────
load_skill_file() {
  local path="$1"
  local label="$2"
  if [[ -f "$path" ]] && [[ -s "$path" ]]; then
    echo "
=== SKILL: ${label} ===
$(cat "$path")
=== END SKILL ==="
  fi
}

get_skills_for() {
  local agent_name="$1"
  local project="${PROJECT:-$(pwd)}"
  local content=""

  content+=$(load_skill_file "${project}/AGENTS.md" "project/AGENTS.md")

  if [[ -d "${project}/.codeswarm/skills" ]]; then
    for sf in "${project}/.codeswarm/skills/"*.md; do
      content+=$(load_skill_file "$sf" ".codeswarm/skills/$(basename "$sf")")
    done
  fi

  # Load GSD-style skills from pipeline templates
  if [[ -d "${CODESWARM_ROOT}/templates/skills" ]]; then
    for sf in "${CODESWARM_ROOT}/templates/skills/"*.md; do
      content+=$(load_skill_file "$sf" "pipeline/$(basename "$sf")")
    done
  fi

  if [[ -n "$content" ]]; then
    echo "
SKILLS & INSTRUCTIONS:
${content}"
  fi
}

# ─── File Helpers ─────────────────────────────────────────
read_file_safe() {
  local path="$1"
  if [[ -f "$path" ]]; then
    cat "$path"
  else
    echo ""
  fi
}

# Read planning artifacts
get_project_md()      { read_file_safe "${PLANNING_DIR}/PROJECT.md"; }
get_requirements_md() { read_file_safe "${PLANNING_DIR}/REQUIREMENTS.md"; }
get_roadmap_md()      { read_file_safe "${PLANNING_DIR}/ROADMAP.md"; }
get_context_md()      { read_file_safe "${PLANNING_DIR}/CONTEXT.md"; }
get_research_md()     { read_file_safe "${PLANNING_DIR}/RESEARCH.md"; }
get_state_md()        { read_file_safe "${PLANNING_DIR}/STATE.md"; }

# ─── Dashboard Integration ───────────────────────────────
DASHBOARD_PID=""
DASHBOARD_PORT=${DASHBOARD_PORT:-3777}

start_dashboard() {
  local project="$1"
  local dashboard_script="${CODESWARM_ROOT}/dashboard/server.js"
  if [[ -f "$dashboard_script" ]]; then
    lsof -ti:"$DASHBOARD_PORT" | xargs kill -9 2>/dev/null || true
    sleep 0.5
    node "$dashboard_script" --project "$project" --port "$DASHBOARD_PORT" &
    DASHBOARD_PID=$!
    log "📊 Dashboard: http://localhost:${DASHBOARD_PORT}"
    if command -v open &>/dev/null; then
      open "http://localhost:${DASHBOARD_PORT}" 2>/dev/null || true
    fi
  else
    warn "Dashboard not found — run: cd dashboard && npm install"
  fi
}

stop_dashboard() {
  if [[ -n "$DASHBOARD_PID" ]]; then
    kill "$DASHBOARD_PID" 2>/dev/null || true
    DASHBOARD_PID=""
  fi
}
