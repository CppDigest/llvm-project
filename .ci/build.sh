#!/usr/bin/env bash
#===----------------------------------------------------------------------===##
# CppDigest/llvm-project — reusable build script
#
# Usage:
#   .ci/build.sh configure   # cmake configure only
#   .ci/build.sh build       # ninja build
#   .ci/build.sh all         # configure + build
#
# Environment variables:
#   PROJECTS      — semicolon-separated (default: clang;lld)
#   TARGETS       — build targets (default: all)
#   BUILD_DIR     — build directory (default: ./build)
#   SCCACHE_DIR   — sccache cache dir (optional)
#===----------------------------------------------------------------------===##

set -euo pipefail

MONOREPO_ROOT="${MONOREPO_ROOT:-$(git rev-parse --show-toplevel)}"
BUILD_DIR="${BUILD_DIR:-${MONOREPO_ROOT}/build}"
PROJECTS="${PROJECTS:-clang;lld}"
TARGETS="${TARGETS:-}"
CPUS="${CPUS:-$(nproc 2>/dev/null || echo 2)}"

do_configure() {
    echo "=== CMake Configure ==="
    echo "  Projects: ${PROJECTS}"
    echo "  Build dir: ${BUILD_DIR}"

    local extra_flags=()
    if command -v sccache &>/dev/null; then
        sccache --zero-stats
        extra_flags+=(
            -D CMAKE_C_COMPILER_LAUNCHER=sccache
            -D CMAKE_CXX_COMPILER_LAUNCHER=sccache
        )
    fi

    cmake -S "${MONOREPO_ROOT}/llvm" -B "${BUILD_DIR}" \
        -G Ninja \
        -D CMAKE_BUILD_TYPE=Release \
        -D LLVM_ENABLE_PROJECTS="${PROJECTS}" \
        -D LLVM_ENABLE_ASSERTIONS=ON \
        -D LLVM_BUILD_EXAMPLES=OFF \
        -D LLVM_TARGETS_TO_BUILD="X86" \
        -D LLVM_ENABLE_LLD=ON \
        -D CMAKE_CXX_FLAGS="-g1" \
        -D LLVM_LIT_ARGS="-v --xunit-xml-output ${BUILD_DIR}/test-results.xml --use-unique-output-file-name --timeout=600 --time-tests --succinct" \
        "${extra_flags[@]}"
}

do_build() {
    echo "=== Ninja Build (${CPUS} CPUs) ==="
    local start=$(date +%s)

    if [[ -n "${TARGETS}" ]]; then
        ninja -C "${BUILD_DIR}" -j"${CPUS}" -k 0 ${TARGETS}
    else
        ninja -C "${BUILD_DIR}" -j"${CPUS}" -k 0
    fi

    local end=$(date +%s)
    echo "Build completed in $((end - start))s"

    if command -v sccache &>/dev/null; then
        echo ""
        echo "=== Sccache Stats ==="
        sccache --show-stats
    fi
}

case "${1:-all}" in
    configure) do_configure ;;
    build)     do_build ;;
    all)       do_configure && do_build ;;
    *)
        echo "Usage: $0 {configure|build|all}" >&2
        exit 1
        ;;
esac
