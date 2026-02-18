#!/usr/bin/env bash
# Usage: bash .ci/run-tests.sh [--retry]
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
BUILD_DIR="$(cd "$SCRIPT_DIR/.." && pwd)/build"

run_tests() {
    ninja -C "${BUILD_DIR}" check-clang check-llvm
}

set +e
run_tests
EXIT_CODE=$?
set -e

if [[ $EXIT_CODE -eq 0 ]]; then
    exit 0
fi

if [[ "${1:-}" == "--retry" ]]; then
    echo "Tests failed (exit $EXIT_CODE), retrying once..."
    set +e
    run_tests
    RETRY_CODE=$?
    set -e
    if [[ $RETRY_CODE -eq 0 ]]; then
        echo "Passed on retry — likely flaky. Check .ci/flaky-tests.txt"
        exit 0
    fi
    EXIT_CODE=$RETRY_CODE
fi

exit ${EXIT_CODE}
