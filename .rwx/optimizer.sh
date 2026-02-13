#!/usr/bin/env bash
#
# RWX CI Optimizer — iterative Claude Code optimization loop
#
# Runs the RWX workflow, extracts timing/failure data, feeds it to Claude Code,
# validates the changes, commits, and repeats. Stops on convergence or cap.
#
# Prerequisites:
#   - rwx CLI installed and authenticated
#   - claude CLI (Claude Code) installed
#   - git repo with .rwx/ci.yml committed
#
# Usage:
#   ./optimizer.sh                          # 1 session, 20 iterations
#   ./optimizer.sh --sessions 3             # 3 sessions of 20 iterations
#   ./optimizer.sh --max-iter 10            # override iterations per session
#   ./optimizer.sh --dry-run                # show what would be done
#   ./optimizer.sh --target-seconds 300     # stop optimizing once under 5 min
#
# References:
#   - Gist: https://gist.github.com/iTinkerBell/864cd6f1d4fcab339bb535d4b6462e7e
#   - RWX packages: https://github.com/rwx-cloud/packages
#   - Capy RWX CI: CppDigest/capy .rwx/ci.yml
#

set -euo pipefail

# ── config ──────────────────────────────────────────────────────────

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
WORKFLOW_FILE="$SCRIPT_DIR/ci.yml"
LOG_BASE_DIR="$SCRIPT_DIR/optimizer-logs"

MAX_ITERATIONS="${MAX_ITERATIONS:-20}"
MAX_SESSIONS="${MAX_SESSIONS:-1}"
DRY_RUN="${DRY_RUN:-false}"
TARGET_RUNTIME_SECONDS="${TARGET_RUNTIME_SECONDS:-300}"   # stop if total < this
LOG_AVAILABILITY_TIMEOUT="${LOG_AVAILABILITY_TIMEOUT:-90}" # seconds to wait for RWX logs
COMMIT_SHA="${COMMIT_SHA:-HEAD}"
CLONE_URL="${CLONE_URL:-https://github.com/CppDigest/llvm-project.git}"

BLOCKLIST_FILE="$LOG_BASE_DIR/blocklist.txt"

# ── parse args ──────────────────────────────────────────────────────

while [[ $# -gt 0 ]]; do
  case $1 in
    --sessions)          MAX_SESSIONS="$2";          shift 2 ;;
    --max-iter)          MAX_ITERATIONS="$2";        shift 2 ;;
    --dry-run)           DRY_RUN=true;               shift   ;;
    --target-seconds)    TARGET_RUNTIME_SECONDS="$2"; shift 2 ;;
    --commit-sha)        COMMIT_SHA="$2";            shift 2 ;;
    --clone-url)         CLONE_URL="$2";             shift 2 ;;
    --help)
      echo "Usage: $0 [--sessions N] [--max-iter N] [--target-seconds N] [--dry-run]"
      exit 0 ;;
    *) echo "Unknown option: $1"; exit 1 ;;
  esac
done

# ── pre-flight checks ──────────────────────────────────────────────

preflight() {
  local ok=true

  if [ ! -f "$WORKFLOW_FILE" ]; then
    echo "ERROR: $WORKFLOW_FILE not found"; ok=false
  fi

  if ! command -v rwx &>/dev/null; then
    echo "ERROR: rwx CLI not installed (https://www.rwx.com/docs/mint/cli)"; ok=false
  fi

  if ! command -v claude &>/dev/null; then
    echo "ERROR: claude CLI not installed"; ok=false
  fi

  if ! command -v git &>/dev/null; then
    echo "ERROR: git not installed"; ok=false
  fi

  if ! git -C "$REPO_ROOT" rev-parse --is-inside-work-tree &>/dev/null; then
    echo "ERROR: $REPO_ROOT is not a git repository"; ok=false
  fi

  if ! python3 -c "import yaml" &>/dev/null 2>&1; then
    echo "WARNING: python3 pyyaml not installed — YAML validation will be skipped"
  fi

  if [ "$ok" = false ]; then
    echo "Pre-flight failed. Fix the errors above."
    exit 1
  fi
}

# ── logging ─────────────────────────────────────────────────────────

SESSION_ID=""
SESSION_DIR=""

init_session() {
  SESSION_ID="$(date +%Y%m%d-%H%M%S)-$$"
  SESSION_DIR="$LOG_BASE_DIR/session-$SESSION_ID"
  mkdir -p "$SESSION_DIR"

  cp "$WORKFLOW_FILE" "$SESSION_DIR/ci.yml.initial"

  log "session started | max_iter=$MAX_ITERATIONS target=${TARGET_RUNTIME_SECONDS}s"
}

init_iteration() {
  local iter=$1
  local pad; pad=$(printf '%03d' "$iter")
  cp "$WORKFLOW_FILE" "$SESSION_DIR/ci.yml.iter-${pad}.before"
  log "--- iteration $iter/$MAX_ITERATIONS ---"
}

log() {
  local ts; ts=$(date '+%H:%M:%S')
  echo "[$ts] $*" | tee -a "$SESSION_DIR/session.log"
}

# ── rwx run + metrics ──────────────────────────────────────────────

run_rwx() {
  local iter=$1
  local pad; pad=$(printf '%03d' "$iter")
  local output="$SESSION_DIR/rwx-output-${pad}.txt"
  local run_id_file="$SESSION_DIR/rwx-run-id-${pad}.txt"

  if [ "$DRY_RUN" = true ]; then
    log "[dry-run] would run: rwx run .rwx/ci.yml"
    echo "dry-run" > "$SESSION_DIR/rwx-status-${pad}.txt"
    return 0
  fi

  log "running rwx workflow..."
  cd "$REPO_ROOT"

  local start_ts; start_ts=$(date +%s)

  # Capture run ID from rwx output for log download
  if rwx run .rwx/ci.yml \
       --init "commit-sha=$COMMIT_SHA" \
       --init "clone-url=$CLONE_URL" \
       --init "branch=optimizer" \
       2>&1 | tee "$output"; then
    local end_ts; end_ts=$(date +%s)
    local wall=$((end_ts - start_ts))
    log "rwx PASSED (wall: ${wall}s)"
    echo "SUCCESS|${wall}" > "$SESSION_DIR/rwx-status-${pad}.txt"

    # Check if we hit the target
    if [ "$wall" -le "$TARGET_RUNTIME_SECONDS" ]; then
      log "target reached: ${wall}s <= ${TARGET_RUNTIME_SECONDS}s"
      return 2  # special code: target met
    fi
    return 0
  else
    local rc=$?
    local end_ts; end_ts=$(date +%s)
    local wall=$((end_ts - start_ts))
    log "rwx FAILED (exit=$rc, wall: ${wall}s)"
    echo "FAIL|${wall}|exit=$rc" > "$SESSION_DIR/rwx-status-${pad}.txt"
    return 1
  fi
}

extract_metrics() {
  local iter=$1
  local pad; pad=$(printf '%03d' "$iter")
  local output="$SESSION_DIR/rwx-output-${pad}.txt"
  local metrics="$SESSION_DIR/metrics-${pad}.txt"

  # Pull timing markers and errors from rwx output
  if [ -f "$output" ]; then
    grep -E "completed in|FAIL|ERROR|TASK:|sccache|Compile requests" \
      "$output" > "$metrics" 2>/dev/null || true
  fi

  # Append status
  if [ -f "$SESSION_DIR/rwx-status-${pad}.txt" ]; then
    echo "---" >> "$metrics"
    cat "$SESSION_DIR/rwx-status-${pad}.txt" >> "$metrics"
  fi

  log "metrics saved ($(wc -l < "$metrics") lines)"
}

download_failure_logs() {
  local iter=$1
  local pad; pad=$(printf '%03d' "$iter")
  local output="$SESSION_DIR/rwx-output-${pad}.txt"
  local failure="$SESSION_DIR/failure-${pad}.txt"

  : > "$failure"

  # Try rwx CLI for structured failure info
  if command -v rwx &>/dev/null; then
    # Extract task IDs from output (UUIDs in RWX output)
    local task_ids
    task_ids=$(grep -oP '[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}' \
      "$output" 2>/dev/null | sort -u || true)

    for tid in $task_ids; do
      log "downloading logs for task $tid..."
      local waited=0
      while [ "$waited" -lt "$LOG_AVAILABILITY_TIMEOUT" ]; do
        if rwx tasks logs "$tid" >> "$failure" 2>/dev/null; then
          break
        fi
        sleep 5
        waited=$((waited + 5))
      done
    done
  fi

  # Also grab error context from raw output
  if [ -f "$output" ]; then
    grep -A 10 -E "^error:|^FAIL|fatal:" "$output" >> "$failure" 2>/dev/null || true
  fi

  if [ -s "$failure" ]; then
    log "failure logs saved ($(wc -l < "$failure") lines)"
  fi
}

# ── validation ──────────────────────────────────────────────────────

validate_yaml() {
  # Syntax check
  if command -v python3 &>/dev/null && python3 -c "import yaml" &>/dev/null 2>&1; then
    if ! python3 -c "
import yaml, sys
with open(sys.argv[1]) as f:
    yaml.safe_load(f)
" "$WORKFLOW_FILE" 2>&1; then
      log "YAML syntax invalid"
      return 1
    fi
  fi

  # Known-bad patterns
  local bad_patterns=(
    "depinst.py --jobs"
    "git submodule.*--single-branch"
    "ubuntu:25.04"
  )
  for pat in "${bad_patterns[@]}"; do
    if grep -qP "$pat" "$WORKFLOW_FILE"; then
      log "found known-bad pattern: $pat"
      return 1
    fi
  done

  # Sanity: make sure key tasks still exist
  local required_keys=(clone-repo cmake-configure build-llvm-core check-llvm check-clang)
  for key in "${required_keys[@]}"; do
    if ! grep -q "key: $key" "$WORKFLOW_FILE"; then
      log "required task '$key' missing from workflow"
      return 1
    fi
  done

  log "validation passed"
  return 0
}

check_oscillation() {
  local iter=$1
  [ "$iter" -lt 3 ] && return 0

  local cur="$SESSION_DIR/ci.yml.iter-$(printf '%03d' "$iter").before"
  local prev2="$SESSION_DIR/ci.yml.iter-$(printf '%03d' $((iter - 2))).before"

  if [ -f "$cur" ] && [ -f "$prev2" ] && diff -q "$cur" "$prev2" &>/dev/null; then
    log "oscillation: current matches iter $((iter - 2))"
    return 1
  fi
  return 0
}

# ── claude invocation ───────────────────────────────────────────────

build_prompt() {
  local iter=$1
  local rwx_status=$2
  local pad; pad=$(printf '%03d' "$iter")
  local prompt="$SESSION_DIR/prompt-${pad}.md"

  cat > "$prompt" << 'HEADER'
You are optimizing an RWX CI workflow for the LLVM project.
Only modify .rwx/ci.yml. Keep all existing check-* tasks. Preserve the DAG structure.

RWX task fields: key, use, after, run, call, with, cache, filter, env, timeout, agent, if.
Docs: https://www.rwx.com/docs/mint  Packages: https://github.com/rwx-cloud/packages

Rules:
- sccache dir (tmp/sccache/**) MUST be in filter: for any task using sccache
- timeout must be set on every task (default 10m is too short for LLVM)
- agent specs must match task needs (build: 16 CPU/64GB, checks: 4-8 CPU)
- Do NOT add flags that don't exist (e.g. depinst.py --jobs)
- Do NOT use ubuntu:25.04 (unsupported by rwx/base)
- Explain changes in a short comment at the top of your diff
HEADER

  echo "" >> "$prompt"
  echo "## Iteration $iter — Status: $rwx_status" >> "$prompt"

  # Metrics
  local mf="$SESSION_DIR/metrics-${pad}.txt"
  if [ -f "$mf" ] && [ -s "$mf" ]; then
    echo "" >> "$prompt"
    echo "## Metrics" >> "$prompt"
    echo '```' >> "$prompt"
    head -80 "$mf" >> "$prompt"
    echo '```' >> "$prompt"
  fi

  # Failure logs
  local ff="$SESSION_DIR/failure-${pad}.txt"
  if [ -f "$ff" ] && [ -s "$ff" ]; then
    echo "" >> "$prompt"
    echo "## Failure logs (truncated)" >> "$prompt"
    echo '```' >> "$prompt"
    head -150 "$ff" >> "$prompt"
    echo '```' >> "$prompt"
  fi

  # Blocklist
  if [ -f "$BLOCKLIST_FILE" ] && [ -s "$BLOCKLIST_FILE" ]; then
    echo "" >> "$prompt"
    echo "## Do NOT modify these areas" >> "$prompt"
    cat "$BLOCKLIST_FILE" >> "$prompt"
  fi

  # Current workflow
  echo "" >> "$prompt"
  echo "## Current .rwx/ci.yml" >> "$prompt"
  echo '```yaml' >> "$prompt"
  cat "$WORKFLOW_FILE" >> "$prompt"
  echo '```' >> "$prompt"

  # Task
  echo "" >> "$prompt"
  if [ "$rwx_status" = "SUCCESS" ]; then
    echo "The workflow passed. Optimize the slowest tasks for speed." >> "$prompt"
    echo "Target: total wall-clock under ${TARGET_RUNTIME_SECONDS}s." >> "$prompt"
  else
    echo "The workflow failed. Fix the root cause." >> "$prompt"
  fi

  echo "$prompt"
}

invoke_claude() {
  local iter=$1
  local prompt_file=$2
  local pad; pad=$(printf '%03d' "$iter")
  local output="$SESSION_DIR/claude-output-${pad}.txt"

  if [ "$DRY_RUN" = true ]; then
    log "[dry-run] would invoke: claude -p < $prompt_file"
    return 1  # no changes in dry-run
  fi

  log "invoking claude..."
  cd "$REPO_ROOT"

  if claude -p < "$prompt_file" > "$output" 2>&1; then
    log "claude responded"
  else
    log "claude failed (exit=$?)"
    return 1
  fi

  # Did it actually change the file?
  if git diff --quiet "$WORKFLOW_FILE" 2>/dev/null; then
    log "claude made no changes"
    return 1
  fi

  log "claude modified ci.yml"
  return 0
}

# ── git ─────────────────────────────────────────────────────────────

commit_changes() {
  local iter=$1
  local session_num=$2

  if [ "$DRY_RUN" = true ]; then return 0; fi

  cd "$REPO_ROOT"
  git diff --quiet "$WORKFLOW_FILE" 2>/dev/null && return 1

  git add "$WORKFLOW_FILE"
  git commit -m "rwx-optimizer: s${session_num} i${iter}

Session: $SESSION_ID
Iteration: $iter/$MAX_ITERATIONS"
  log "committed"
}

revert() {
  if [ "$DRY_RUN" = true ]; then return 0; fi

  cd "$REPO_ROOT"
  if git diff --quiet "$WORKFLOW_FILE" 2>/dev/null; then
    git revert --no-edit HEAD 2>/dev/null || git checkout HEAD~1 -- "$WORKFLOW_FILE"
  else
    git checkout -- "$WORKFLOW_FILE"
  fi
  log "reverted"
}

# ── main loop ───────────────────────────────────────────────────────

run_session() {
  local session_num=$1
  init_session

  local no_change_streak=0
  local fail_streak=0

  for ((iter=1; iter<=MAX_ITERATIONS; iter++)); do
    init_iteration "$iter"

    # Oscillation guard
    if ! check_oscillation "$iter"; then
      log "stopping: oscillation detected"
      break
    fi

    # Run workflow
    local rwx_status="SUCCESS"
    local rwx_rc=0
    run_rwx "$iter" || rwx_rc=$?

    if [ "$rwx_rc" -eq 2 ]; then
      log "target met — done"
      break
    elif [ "$rwx_rc" -ne 0 ]; then
      rwx_status="FAIL"
      download_failure_logs "$iter"
      fail_streak=$((fail_streak + 1))
    else
      fail_streak=0
    fi

    extract_metrics "$iter"

    # Build prompt, invoke claude
    local prompt_file
    prompt_file=$(build_prompt "$iter" "$rwx_status")

    if ! invoke_claude "$iter" "$prompt_file"; then
      no_change_streak=$((no_change_streak + 1))
      if [ "$no_change_streak" -ge 3 ]; then
        log "stopping: 3 iterations with no changes"
        break
      fi
      continue
    fi
    no_change_streak=0

    # Validate
    if ! validate_yaml; then
      log "validation failed — reverting"
      revert
      continue
    fi

    # Commit
    commit_changes "$iter" "$session_num" || true

    # Safety cap
    if [ "$fail_streak" -ge 5 ]; then
      log "stopping: 5 consecutive failures"
      break
    fi
  done

  cp "$WORKFLOW_FILE" "$SESSION_DIR/ci.yml.final"
  generate_report "$session_num"
  log "session done"
}

# ── report ──────────────────────────────────────────────────────────

generate_report() {
  local session_num=$1
  local report="$SESSION_DIR/report.md"

  cat > "$report" << EOF
# Optimizer Report — Session $SESSION_ID

**Repo:** CppDigest/llvm-project
**Session:** $session_num / $MAX_SESSIONS
**Target:** ${TARGET_RUNTIME_SECONDS}s

| Iter | RWX | Wall | Changed | Committed |
|------|-----|------|---------|-----------|
EOF

  for f in "$SESSION_DIR"/rwx-status-*.txt; do
    [ -f "$f" ] || continue
    local pad; pad=$(basename "$f" | grep -oP '\d{3}')
    local num=$((10#$pad))
    local status; status=$(cut -d'|' -f1 < "$f")
    local wall; wall=$(cut -d'|' -f2 < "$f" 2>/dev/null || echo "-")

    local changed="no"
    local committed="no"
    local before="$SESSION_DIR/ci.yml.iter-${pad}.before"
    local next_pad; next_pad=$(printf '%03d' $((num + 1)))
    local after_file="$SESSION_DIR/ci.yml.iter-${next_pad}.before"
    if [ -f "$before" ] && [ -f "$after_file" ]; then
      diff -q "$before" "$after_file" &>/dev/null || { changed="yes"; committed="yes"; }
    fi

    echo "| $num | $status | ${wall}s | $changed | $committed |" >> "$report"
  done

  echo "" >> "$report"
  echo "Logs: \`$SESSION_DIR/\`" >> "$report"

  log "report: $report"
}

# ── entry ───────────────────────────────────────────────────────────

main() {
  echo ""
  echo "RWX CI Optimizer — CppDigest/llvm-project"
  echo "sessions=$MAX_SESSIONS  iter/session=$MAX_ITERATIONS  target=${TARGET_RUNTIME_SECONDS}s  dry=$DRY_RUN"
  echo ""

  preflight

  mkdir -p "$LOG_BASE_DIR"
  touch "$BLOCKLIST_FILE"

  for ((s=1; s<=MAX_SESSIONS; s++)); do
    echo ""
    echo "=== Session $s / $MAX_SESSIONS ==="
    run_session "$s"
  done

  echo ""
  echo "Done. Logs: $LOG_BASE_DIR"
}

main "$@"
