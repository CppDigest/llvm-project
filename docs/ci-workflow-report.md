# CI/Automation Workflow Report

**Issue:** CppDigest/llvm-project#1
**Date:** 2026-02-24
**Branch:** feature/issue-1-bug

## Executive Summary

CppDigest/llvm-project is a fork of llvm/llvm-project. The upstream CI (premerge.yaml) does **not** run on forks due to a `repository_owner == 'llvm'` guard. This report maps all CI/automation, identifies bottlenecks, and catalogs existing bots. A new fork-specific CI (`cppa-clang-ci.yml`) and supporting scripts have been created to fill this gap.

---

## 1. Workflow Diagram

```
PR opened/synced on CppDigest/llvm-project
    |
    +---> [SKIPPED] premerge.yaml          (guard: repository_owner == 'llvm')
    +---> [SKIPPED] CI Checks              (guard: repository_owner == 'llvm')
    +---> [SKIPPED] Check code formatting   (guard: repository_owner == 'llvm')
    +---> [SKIPPED] Check CI Scripts        (guard: repository_owner == 'llvm')
    +---> [ACTIVE]  Labelling new PRs       (greeter bot - runs on forks)
    +---> [ACTIVE]  CodeRabbit              (3rd-party review bot)
    +---> [BROKEN]  RWX: ci.yml             (trigger misconfigured since Feb 12)
    +---> [NEW]     CppDigest Clang CI      (our fork-specific workflow)
                        |
                        +--- linux-build (ubuntu-24.04, 120m timeout)
                        |     1. Checkout
                        |     2. Install deps (cmake, ninja, clang, lld, lit, psutil)
                        |     3. sccache setup
                        |     4. CMake Configure (clang+lld, X86, Release, Assertions)
                        |     5. Build (ninja -k 0)
                        |     6. Test: check-clang
                        |     7. Test: check-llvm
                        |     8. Test: check-lld (continue-on-error)
                        |     9. sccache stats + test report + artifacts
                        |
                        +--- windows-build (windows-2022, 150m timeout)
                              1. Checkout
                              2. Install psutil
                              3. sccache setup
                              4. CMake Configure (VS 2022 + ClangCL, X86, Release)
                              5. Build (cmake --parallel)
                              6. Test: check-clang
                              7. sccache stats
```

## 2. Where Time Goes

| Phase | Linux (est.) | Windows (est.) | Notes |
|-------|-------------|----------------|-------|
| Checkout | ~30s | ~30s | depth=2, fast |
| Install deps | ~60s | ~10s | Linux: apt-get + pip; Windows: pip only |
| sccache setup | ~10s | ~10s | mozilla-actions/sccache-action |
| CMake Configure | ~3-5m | ~5-8m | Ninja vs VS generator |
| Build | ~30-60m | ~60-90m | Cold cache; ~10-20m with warm sccache |
| check-clang | ~10-20m | ~15-25m | ~20k tests |
| check-llvm | ~10-15m | N/A | Linux only |
| check-lld | ~5-10m | N/A | Linux only |
| **Total** | **~60-110m** | **~80-130m** | **Cold cache** |

**Bottleneck:** The build phase dominates (50-70% of total time). With warm sccache, builds drop to ~10-20m, making tests the bottleneck instead.

## 3. What Is Flaky

Based on upstream data and RWX CI experience on `feature/issue-3`:

| Category | Examples | Frequency |
|----------|----------|-----------|
| LLDB tests | `TestExec.py`, `TestCommandScriptImmediateOutput.py` | Common |
| OpenMP tests | `libomp :: tasking/bug_nested_proxy_task.c` | Occasional |
| Sanitizer tests | `SanitizerCommon-asan-x86_64-Linux` | Occasional |
| Runtime tests | compiler-rt signal-related tests | Rare |

The `.ci/flaky-tests.txt` quarantine file is in place for tracking these.

## 4. Current Automation/Bots Inventory

| Bot/Tool | What It Does | Runs on Fork? |
|----------|-------------|---------------|
| **premerge.yaml** | Full build + test (Linux, Windows, macOS) | No |
| **compute_projects.py** | Path-based project selection (smart rebuild) | N/A (script) |
| **Greeter (new-prs.yml)** | Labels PRs, greets first-time contributors | Yes |
| **CODEOWNERS** | Auto-assigns reviewers by directory | Yes |
| **Labeler (new-prs-labeler.yml)** | Auto-labels by file path changes | Yes |
| **CodeRabbit** | AI code review on PRs | Yes |
| **RWX Mint (.rwx/ci.yml)** | Full monolithic Linux build + 10 parallel check targets | Broken |
| **Buildbot (.ci/buildbot/)** | Legacy CI on lab.llvm.org | No |
| **Renovate** | Weekly dependency updates | Yes |
| **pr-code-format.yml** | clang-format checking | No (guard) |
| **CppDigest Clang CI** | Fork-specific Linux + Windows CI | **Yes (new)** |

### Gaps Identified

1. **No CI on fork PRs** until our new workflow (upstream guard blocks everything)
2. **No path-based selection** in fork CI (upstream uses compute_projects.py)
3. **RWX trigger broken** since Feb 12 (org/webhook misconfiguration)
4. **No macOS CI** on the fork
5. **No code formatting check** on the fork (upstream guard)
6. **No flaky test retry** in GitHub Actions workflow (only in `.ci/run-tests.sh`)

---

## 5. Upstream CI Architecture (Reference)

### Key Files
- `.github/workflows/premerge.yaml` — Main CI, 3 platform jobs
- `.ci/compute_projects.py` — Maps changed files to projects/targets
- `.ci/monolithic-linux.sh` / `monolithic-windows.sh` — Build drivers
- `.ci/utils.sh` — Shared utilities, sccache reporting
- `.ci/generate_test_report_github.py` — JUnit XML to GitHub summary
- `.ci/cache_lit_timing_files.py` — Test timing optimization

### How Path-Based Selection Works
```
git diff HEAD~1...HEAD | python3 .ci/compute_projects.py
  -> PROJECTS="clang;lld"           (what to build)
  -> CHECK_TARGETS="check-clang check-lld"  (what to test)
  -> RUNTIMES=""                    (runtime tests needed)
```

Only changed projects + their dependents are built and tested. This is the single biggest CI speedup in upstream.
