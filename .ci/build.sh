#!/usr/bin/env bash
# Usage: bash .ci/build.sh [configure|build|all]
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
BUILD_DIR="${REPO_ROOT}/build"

configure() {
    cmake -G Ninja -B "${BUILD_DIR}" -S "${REPO_ROOT}/llvm" \
        -DCMAKE_BUILD_TYPE=Release \
        -DLLVM_ENABLE_PROJECTS=clang \
        -DLLVM_TARGETS_TO_BUILD="X86;AArch64" \
        -DCMAKE_C_COMPILER_LAUNCHER=sccache \
        -DCMAKE_CXX_COMPILER_LAUNCHER=sccache
}

build() {
    ninja -C "${BUILD_DIR}" -j"$(nproc)"
}

case "${1:-all}" in
    configure) configure ;;
    build)     build ;;
    all)       configure && build ;;
    *)
        echo "Usage: $0 [configure|build|all]"
        exit 1
        ;;
esac
