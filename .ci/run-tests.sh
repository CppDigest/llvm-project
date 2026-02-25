#!/usr/bin/env bash
#===----------------------------------------------------------------------===##
# CppDigest/llvm-project — test runner with single retry for flaky tests
#
# Usage:
#   .ci/run-tests.sh check-clang
#   .ci/run-tests.sh check-clang check-llvm check-lld
#
# Environment variables:
#   BUILD_DIR        — build directory (default: ./build)
#   FLAKY_TESTS_FILE — path to flaky test list (default: .ci/flaky-tests.txt)
#===----------------------------------------------------------------------===##

set -uo pipefail

MONOREPO_ROOT="${MONOREPO_ROOT:-$(git rev-parse --show-toplevel)}"
BUILD_DIR="${BUILD_DIR:-${MONOREPO_ROOT}/build}"
FLAKY_TESTS_FILE="${FLAKY_TESTS_FILE:-${MONOREPO_ROOT}/.ci/flaky-tests.txt}"

TARGETS=("$@")
if [[ ${#TARGETS[@]} -eq 0 ]]; then
    echo "Usage: $0 <check-target> [check-target ...]" >&2
    exit 1
fi

OVERALL_RET=0

for target in "${TARGETS[@]}"; do
    echo ""
    echo "=== Running: ${target} ==="
    start=$(date +%s)

    ninja -C "${BUILD_DIR}" "${target}"
    ret=$?

    end=$(date +%s)
    echo "${target} completed in $((end - start))s (exit ${ret})"

    if [[ ${ret} -ne 0 ]]; then
        echo ""
        echo "--- ${target} FAILED (exit ${ret}), retrying once ---"
        ninja -C "${BUILD_DIR}" "${target}"
        ret=$?
        if [[ ${ret} -eq 0 ]]; then
            echo "${target} passed on retry (likely flaky)"
            if [[ -f "${FLAKY_TESTS_FILE}" ]]; then
                echo "  Hint: check ${FLAKY_TESTS_FILE} for known flaky tests"
            fi
        else
            echo "${target} failed on retry too"
            OVERALL_RET=1
        fi
    fi
done

echo ""
echo "=== Test Summary ==="
echo "Targets: ${TARGETS[*]}"
if [[ ${OVERALL_RET} -eq 0 ]]; then
    echo "Result: ALL PASSED"
else
    echo "Result: SOME FAILED"
fi

exit ${OVERALL_RET}
