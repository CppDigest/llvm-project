# CI Improvement Proposals

**Issue:** CppDigest/llvm-project#1
**Date:** 2026-02-24

Proposals ranked by ROI (impact / effort). Each includes expected impact, risk, required access, and rollout plan.

---

## Do Now (1-2 weeks)

### 1. Fork-Specific GitHub Actions CI [DONE]

**Status:** Implemented in this PR
**Impact:** HIGH - Enables CI feedback on fork PRs (was completely missing)
**Risk:** LOW - Isolated to fork, no upstream impact
**Files:** `.github/workflows/cppa-clang-ci.yml`, `.ci/build.sh`, `.ci/run-tests.sh`, `.ci/flaky-tests.txt`
**Validation:** PR #6 CI runs on Linux + Windows

### 2. Fix RWX CI Bugs [DONE]

**Status:** Implemented in this PR
**Impact:** MEDIUM - RWX pipeline no longer aborts on `grep` no-match or partial test failures
**Risk:** LOW - Defensive changes (set +e, || true)
**Files:** `.rwx/ci.yml` (performance-analysis + check-runtimes tasks)
**Validation:** Verified fix matches green run on `feature/issue-3` (RWX commit e483aaa)

### 3. Add sccache Stats to GitHub Step Summary [DONE]

**Status:** Implemented in this PR
**Impact:** LOW-MEDIUM - Enables cache hit rate monitoring directly in PR checks
**Risk:** LOW - Additive, || true guarded
**Files:** `.ci/utils.sh`
**Validation:** Shows in GitHub Actions step summary

### 4. Path-Based Project Selection for Fork CI

**Status:** Proposed
**Impact:** HIGH - Skip unnecessary builds. Clang-only change builds in ~15m instead of ~60m
**Risk:** LOW - Reuses upstream's battle-tested `compute_projects.py`
**Change:**
```yaml
# In cppa-clang-ci.yml, add before CMake Configure:
- name: Compute projects
  id: projects
  run: |
    source <(git diff HEAD~1...HEAD | python3 .ci/compute_projects.py linux)
    echo "projects=$PROJECTS" >> $GITHUB_OUTPUT
    echo "check_targets=$CHECK_TARGETS" >> $GITHUB_OUTPUT
```
**Expected Speedup:** 50-70% for targeted changes (e.g., clang-only PR skips check-llvm, check-lld)
**Effort:** 2-4 hours
**Rollout:** Add to cppa-clang-ci.yml, test on a small PR

### 5. Warm sccache with GitHub Actions Cache

**Status:** Proposed
**Impact:** HIGH - Cold builds ~60m, warm builds ~10-20m
**Risk:** LOW - mozilla-actions/sccache-action already supports GHA cache backend
**Change:** Already using `mozilla-actions/sccache-action@v0.0.7` which stores in GitHub Actions cache. Monitor cache hit rate via step summary (proposal #3). If hits are low, consider:
- Setting `SCCACHE_GHA_ENABLED: "true"` explicitly
- Increasing cache size limits
**Expected Speedup:** 3-5x on repeat builds
**Effort:** 1-2 hours to tune
**Rollout:** Monitor current hit rate first, then optimize

### 6. Fix RWX Managed Triggers

**Status:** Proposed
**Impact:** MEDIUM - Restores full Linux monolithic build + 10 parallel check targets
**Risk:** LOW - Configuration change only
**Change:** RWX Mint webhook/trigger needs reconfiguration. Current org `cppdigest-test` has no webhooks or dispatch triggers defined. Need to:
1. Verify GitHub App installation on CppDigest/llvm-project
2. Configure webhook trigger for push + pull_request events
3. Test with a manual dispatch run
**Effort:** 1-2 hours (admin access required)
**Rollout:** Fix in RWX dashboard, push test commit to verify

---

## Do Next (1-2 months)

### 7. Flaky Test Detection and Auto-Retry

**Status:** Proposed
**Impact:** MEDIUM - Reduces false-positive CI failures
**Risk:** LOW - `.ci/run-tests.sh` already has single-retry logic
**Change:** Integrate `run-tests.sh` into `cppa-clang-ci.yml` instead of raw `ninja check-*` commands. Add flaky test reporting to step summary.
**Effort:** 4-8 hours
**Rollout:** Replace test steps with `.ci/run-tests.sh check-clang check-llvm check-lld`

### 8. CI Timing Dashboard

**Status:** Proposed
**Impact:** MEDIUM - Track build time trends, detect regressions
**Risk:** LOW - Read-only analytics
**Change:** Export timing data from CI runs to a tracking file or GitHub Pages dashboard. Use lit's `--time-tests` output + ninja logs.
**Metrics:**
- Configure time, build time, test time per target
- sccache hit rate over time
- Flaky test frequency
**Effort:** 1-2 days
**Rollout:** Start with CSV in artifacts, graduate to dashboard

### 9. Code Formatting Check for Fork

**Status:** Proposed
**Impact:** LOW-MEDIUM - Catches formatting issues before review
**Risk:** LOW - Non-blocking (continue-on-error)
**Change:** Add a lightweight clang-format check job to `cppa-clang-ci.yml` using upstream's `code-format-helper.py`
**Effort:** 2-4 hours
**Rollout:** Add as non-blocking job first, promote to blocking after validation

### 10. macOS CI Job

**Status:** Proposed
**Impact:** LOW - Cross-platform coverage
**Risk:** LOW - macOS runners are available (macos-14)
**Change:** Add macOS job to `cppa-clang-ci.yml` using ccache (upstream uses ccache on macOS, not sccache)
**Effort:** 4-8 hours
**Rollout:** Add as non-blocking job, monitor timing and cost (macOS runners are 10x cost)

---

## Later (On-Prem + Agentic UX)

### Local/On-Prem Runner Strategy

**Goal:** Run high-fidelity builds on local hardware while keeping GitHub-native UX
**Approach:**
1. Self-hosted GitHub Actions runners (cheapest, most integrated)
2. RWX Mint with local agents (already partially set up)
3. Buildbot workers connected to lab.llvm.org (upstream compatible)
**Key Requirements:** Fast NVMe storage, 16+ cores, 32GB+ RAM, sccache with shared cache

### Agentic Workflow Integration

**Goal:** AI agents assist with CI failure triage, minimal repro, patch iteration
**Phased Approach:**
1. **Assistant** (safe): Agent reads CI logs, suggests fix areas, links to relevant tests
2. **Copilot** (supervised): Agent creates fix PRs for known failure patterns (flaky tests, formatting)
3. **Autopilot** (well-defined): Agent handles bisection, test selection, and patch iteration for regression fixes

---

## Baseline Metrics & Targets

| Metric | Current Baseline | Target | How to Measure |
|--------|-----------------|--------|----------------|
| PR first meaningful signal | No CI (infinite) | <30 min | Time from PR open to first check result |
| Linux build (cold cache) | ~60 min | <20 min (warm) | GitHub Actions step timing |
| Windows build (cold cache) | ~90 min | <30 min (warm) | GitHub Actions step timing |
| sccache hit rate | 0% (new) | >60% | sccache stats in step summary |
| check-clang time | ~15 min | <15 min | lit --time-tests output |
| Flaky test rate | Unknown | <5% re-runs | Track retries in run-tests.sh |
| CI pass rate | 0% (new) | >90% | GitHub Actions run history |

---

## Summary

| # | Proposal | Impact | Effort | Priority |
|---|----------|--------|--------|----------|
| 1 | Fork CI workflow | HIGH | DONE | Do Now |
| 2 | Fix RWX CI bugs | MEDIUM | DONE | Do Now |
| 3 | sccache stats in summary | LOW-MED | DONE | Do Now |
| 4 | Path-based project selection | HIGH | 2-4h | Do Now |
| 5 | Warm sccache tuning | HIGH | 1-2h | Do Now |
| 6 | Fix RWX triggers | MEDIUM | 1-2h | Do Now |
| 7 | Flaky test auto-retry | MEDIUM | 4-8h | Do Next |
| 8 | CI timing dashboard | MEDIUM | 1-2d | Do Next |
| 9 | Code formatting check | LOW-MED | 2-4h | Do Next |
| 10 | macOS CI job | LOW | 4-8h | Do Next |
