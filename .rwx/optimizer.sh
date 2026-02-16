#!/usr/bin/env bash
# Run N iterations of "optimize .rwx/ci.yml" and optionally rwx run; logs go to .rwx/optimizer-logs.
# e.g. MAX_ITER=20 SESSION_ID=1 ./.rwx/optimizer.sh
# Needs rwx in PATH to actually run the workflow; SKIP_RWX_RUN=1 to skip and just log.

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
LOG_DIR="${OPTIMIZER_LOG_DIR:-$REPO_ROOT/.rwx/optimizer-logs}"
SESSION_ID="${SESSION_ID:-1}"
MAX_ITER="${MAX_ITER:-20}"
SKIP_RWX_RUN="${SKIP_RWX_RUN:-0}"

mkdir -p "$LOG_DIR"
SESSION_LOG="$LOG_DIR/session_${SESSION_ID}.log"
RUNS_INDEX="$LOG_DIR/session_${SESSION_ID}_runs.txt"

echo "=== RWX workflow optimizer ===" | tee -a "$SESSION_LOG"
echo "  SESSION_ID=$SESSION_ID MAX_ITER=$MAX_ITER LOG_DIR=$LOG_DIR" | tee -a "$SESSION_LOG"
echo "  Started: $(date -u +%Y-%m-%dT%H:%M:%SZ)" | tee -a "$SESSION_LOG"
echo "" | tee -a "$SESSION_LOG"

for iter in $(seq 1 "$MAX_ITER"); do
  echo "--- iteration $iter ---" | tee -a "$SESSION_LOG"
  ITER_LOG="$LOG_DIR/session_${SESSION_ID}_iter_${iter}.log"
  {
    echo "iteration=$iter session=$SESSION_ID timestamp=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    echo "Prompt (for Claude/Cursor):"
    echo "  Optimize or fix .rwx/ci.yml (RWX Mint workflow) for this repo. Keep all matrix items and steps (Linux-only). Preserve caching behavior; refer to RWX docs: https://www.rwx.com/docs/mint/caching and https://github.com/rwx-cloud/packages. Log changes briefly. If the workflow is already optimal, suggest one small improvement or document current state."
    echo ""
  } | tee -a "$ITER_LOG" >> "$SESSION_LOG"

  if [ "$SKIP_RWX_RUN" = "1" ]; then
    echo "  (SKIP_RWX_RUN=1: not running rwx)" | tee -a "$ITER_LOG" >> "$SESSION_LOG"
    continue
  fi

  if command -v rwx >/dev/null 2>&1; then
    BRANCH="${BRANCH:-$(git -C "$REPO_ROOT" branch --show-current 2>/dev/null || echo main)}"
    CLONE_URL="${CLONE_URL:-$(git -C "$REPO_ROOT" config --get remote.origin.url 2>/dev/null || echo '')}"
    RUN_CMD="rwx run $SCRIPT_DIR/ci.yml --init commit-sha=HEAD --init clone-url=$CLONE_URL --init branch=$BRANCH --init run_session=$SESSION_ID --init run_iteration=$iter"
    echo "  Run: $RUN_CMD" | tee -a "$ITER_LOG" >> "$SESSION_LOG"
    if (cd "$REPO_ROOT" && rwx run "$SCRIPT_DIR/ci.yml" --init commit-sha=HEAD --init clone-url="$CLONE_URL" --init branch="$BRANCH" --init run_session="$SESSION_ID" --init run_iteration="$iter") 2>&1 | tee -a "$ITER_LOG" >> "$SESSION_LOG"; then
      echo "  Result: SUCCESS" | tee -a "$ITER_LOG" >> "$SESSION_LOG"
    else
      echo "  Result: FAIL" | tee -a "$ITER_LOG" >> "$SESSION_LOG"
      echo "  To fetch logs: rwx runs list  # then rwx runs logs <run-id> <task-key>" | tee -a "$ITER_LOG" >> "$SESSION_LOG"
    fi
  else
    echo "  rwx CLI not found; install for run + log retrieval (rwx runs list, rwx runs logs <run-id> <task-key>)." | tee -a "$ITER_LOG" >> "$SESSION_LOG"
  fi
  echo "" | tee -a "$SESSION_LOG"
done

echo "=== session $SESSION_ID finished: $(date -u +%Y-%m-%dT%H:%M:%SZ) ===" | tee -a "$SESSION_LOG"
echo "Logs: $SESSION_LOG and $LOG_DIR/session_${SESSION_ID}_iter_*.log"
echo "Generate report: python3 \"$SCRIPT_DIR/postmortem_report.py\" \"$LOG_DIR\""
