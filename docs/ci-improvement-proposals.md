# 10x-100x Productivity: Bottleneck Analysis & Improvement Proposals

**Issue:** CppDigest/llvm-project#1
**Date:** 2026-02-24
**Context:** CppDigest is scaling LLVM contributions using a fork + AI-assisted human agentic workflow.

## Executive Summary

An LLVM contribution goes through 7 stages: issue understanding, patch authoring, local testing, CI validation, code review, merge, and ongoing fork maintenance. Today, a single contribution takes **2-5 days end-to-end**, with the dominant bottlenecks being the feedback loop (build + test + CI = 60-90 min per iteration) and code review wait time (days-weeks). For AI-assisted parallel development, these bottlenecks are even more severe: agent throughput is gated by CI turnaround, and human review becomes the queue.

The proposals below target each bottleneck in the contribution cycle, aiming for **10x** (single-contributor velocity) and **100x** (parallel AI-augmented throughput).

---

## 1. Contribution Cycle Bottleneck Map

| Stage | Activity | Current Time | Bottleneck | Who Feels It |
|-------|----------|-------------|------------|-------------|
| 1. Understand | Read code, find relevant files, learn patterns | Hours-days | 30M+ LOC, fragmented docs, LLVM-specific idioms | Human + AI |
| 2. Author | Write patch + tests, format code | Hours | Coding standards, test framework (lit/FileCheck), TableGen | Human + AI |
| 3. Local Test | Build & run check targets | 30-90 min | Full build hours; incremental 5-15 min; linking is bottleneck | Human + AI |
| 4. CI Feedback | Push, wait for green | 45-90 min | 2-core runners, cold sccache, no path filtering, Windows slow | AI (blocks agent) |
| 5. Review | Find reviewer, get LGTM, iterate | Days-weeks | Finding right reviewer, 1-week ping norm, multiple rounds | Human |
| 6. Merge | Rebase, land, monitor buildbots | Hours-days | Fast-moving trunk, post-commit reverts | Human |
| 7. Maintain | Sync fork, resolve conflicts | Ongoing | Upstream moves ~1000 commits/week | Human + AI |

**Key insight:** For a human contributor, stages 1-2 dominate (intellectual work). For AI-assisted workflows, stages 3-4 dominate (waiting for machines) and stage 5 becomes the throughput ceiling (human review queue).

---

## 2. Bottleneck: Feedback Loop (Stages 3+4)

*Current: 60-90 min per iteration. Target: <10 min.*

This is the critical path for AI agent productivity. Every iteration (code change -> test result) costs 60-90 minutes on our fork vs 7-15 minutes on upstream.

### 2.1 Path-Based Project Selection [CRITICAL]

**Bottleneck:** Every PR builds full clang regardless of what changed.
**Fix:** Use upstream's `compute_projects.py` to build/test only affected projects.

```yaml
- name: Compute affected projects
  run: |
    source <(git diff ${{ github.event.pull_request.base.sha }}..HEAD \
      | python3 .ci/compute_projects.py linux)
    echo "projects=$PROJECTS" >> $GITHUB_OUTPUT
    echo "check_targets=$CHECK_TARGETS" >> $GITHUB_OUTPUT
```

A change to `clang/lib/Sema/` only needs `check-clang`, not full `check-all`. A change to `llvm/lib/Target/X86/` needs `check-llvm` + dependent projects. This alone cuts 50-70% of build time for targeted changes.

**Effort:** 2-4h | **Impact:** 60m -> 15-20m | **Status:** Done (implemented in `cppa-clang-ci.yml`, infra-only PRs skip build in <2 min)

### 2.2 Warm sccache [CRITICAL]

**Bottleneck:** Cold cache means every object file compiles from scratch.
**Fix:** Tune cache key strategy for cross-PR reuse. Monitor hit rate via step summary (already wired in `utils.sh`).

- Use `restore-keys` to share cache across branches
- Set `SCCACHE_GHA_CACHE_TO` / `SCCACHE_GHA_CACHE_FROM` for fine-grained control
- Target >60% hit rate (upstream achieves >80% on GCS)

**Effort:** 1-2h | **Impact:** 3-5x speedup once warm | **Status:** Wired (sccache stats in step summary; hit rate visible per run; cross-branch restore-keys not yet configured)

### 2.3 Upgrade Runners

**Bottleneck:** 2-core GHA runners serialize compilation.
**Fix:** Use larger runners (4/8-core GHA or 16-core self-hosted).

| Runner | Cores | Build Time | Monthly Cost (200 builds) |
|--------|-------|-----------|--------------------------|
| `ubuntu-24.04` (current) | 2 | ~60m | Free |
| `ubuntu-latest-8-cores` | 8 | ~20m | $384 |
| Self-hosted 16-core | 16 | ~10m | ~$100 |

**Effort:** 1h (config change) | **Impact:** 2-4x speedup | **Status:** Not started

### 2.4 Distributed Build Cache (GCS/S3)

**Bottleneck:** GHA cache is 10 GB per-repo limit, not shared across CI systems.
**Fix:** Use cloud storage backend for sccache (like upstream's GCS bucket).

Shared cache across all PRs, runners, and CI systems. Hit rate >80%.

**Effort:** 4-8h | **Impact:** Persistent warm cache | **Status:** Not started

### 2.5 Test Sharding

**Bottleneck:** `check-clang` runs ~20k tests sequentially on one runner.
**Fix:** Use lit's `--shard-count` / `--shard-index` across parallel runners.

4 shards = 4x test speedup (15m -> 4m).

**Effort:** 4-8h | **Impact:** 4x test speedup | **Status:** Not started

### Combined Feedback Loop Impact

| Optimization | Time Saved | Cumulative |
|-------------|-----------|-----------|
| Baseline (current) | -- | 60 min |
| + Path filtering | -30m | 30 min |
| + Warm sccache | -15m | 15 min |
| + 8-core runners | -7m | 8 min |
| + Test sharding | -3m | 5 min |

**10x achieved: 60 min -> 5-8 min.**

---

## 3. Bottleneck: Wasted Iterations (Stages 2+3)

*Current: 20-40% of CI runs fail on preventable issues. Target: <5%.*

Every failed CI run is a wasted feedback loop. Catching issues earlier saves the entire round-trip.

### 3.1 Code Formatting Pre-Check

**Bottleneck:** Formatting issues discovered in CI or review, wasting an iteration.
**Fix:** Add `clang-format` check as first CI step (fast, fails early). Upstream's `pr-code-format.yml` is blocked by owner guard on our fork.

**Effort:** 2-4h | **Impact:** Eliminates formatting round-trips | **Status:** Not started

### 3.2 Local Pre-Flight Script

**Bottleneck:** Developers/agents push without local validation, wasting CI time.
**Fix:** Provide a `scripts/pre-flight.sh` that runs: format check, targeted build, fast smoke test. Agents run this before pushing.

```bash
#!/bin/bash
# Quick local validation before pushing
git clang-format --diff HEAD~1 --extensions cpp,h || exit 1
ninja -C build -j$(nproc) clang || exit 1
llvm-lit -sv --no-progress-bar build/tools/clang/test/Sema/ || exit 1
```

**Effort:** 2-4h | **Impact:** Catches 80% of issues before CI | **Status:** Not started

### 3.3 Flaky Test Retry [DONE]

**Status:** `.ci/run-tests.sh` integrated with single-retry for known flaky tests. Flaky test list maintained in `.ci/flaky-tests.txt`.

### 3.4 RWX Managed Triggers [DONE]

**Status:** VCS integration connected, cmake-configure filter widened to `llvm-project/**`.

---

## 4. Bottleneck: Code Review Queue (Stage 5)

*Current: Days-weeks per review. Target: Hours for routine changes.*

For AI-assisted parallel development, human review is the throughput ceiling. 10 agents producing 10 PRs/day means 10 reviews/day.

### 4.1 AI Pre-Review (Automated First Pass)

**Bottleneck:** Human reviewers spend time on mechanical checks (style, patterns, test coverage).
**Fix:** AI agent reviews every PR before human review:
- LLVM coding pattern violations
- Missing test coverage for new code paths
- API misuse (e.g., `dyn_cast` vs `cast` vs `isa`)
- Concise change summary for human reviewer

Reduces human review time per PR and catches issues that would require another round-trip.

**Effort:** 2-4 weeks | **Impact:** 2-3x review throughput | **Status:** Design phase

### 4.2 Reviewer Auto-Assignment

**Bottleneck:** Finding the right reviewer requires tribal knowledge.
**Fix:** Parse `Maintainers.md` / CODEOWNERS files + git blame to auto-suggest reviewers for changed files. Add as PR comment or assignee.

**Effort:** 1-2 days | **Impact:** Removes review discovery friction | **Status:** Not started

### 4.3 Change Classification & Review Templates

**Bottleneck:** All PRs look the same regardless of complexity.
**Fix:** Classify changes automatically (NFC/refactor, bug fix, new feature, API change) and apply appropriate review templates. NFC changes need lighter review.

**Effort:** 1 day | **Impact:** Speeds up routine reviews | **Status:** Not started

---

## 5. Bottleneck: Codebase Understanding (Stage 1)

*Current: Hours-days to understand relevant code. Target: Minutes with AI assistance.*

LLVM has 30M+ lines of code with fragmented documentation. Finding the right file, understanding the pattern, and knowing which tests to write is a major friction for both humans and AI agents.

### 5.1 Codebase Index for AI Agents

**Bottleneck:** AI agents spend tokens navigating the codebase, often going down wrong paths.
**Fix:** Build a structured index of LLVM subsystems: key files, patterns, test locations, common pitfalls. Agents consult this before exploring.

Example entries:
- `clang/lib/Sema/` = semantic analysis, tests in `clang/test/Sema/`, uses `Diag()` for errors
- `llvm/lib/Target/X86/` = x86 backend, tests in `llvm/test/CodeGen/X86/`, uses TableGen

**Effort:** 2-3 days | **Impact:** 2-5x faster agent task start | **Status:** Not started

### 5.2 Patch Templates by Area

**Bottleneck:** Every patch requires figuring out the same boilerplate (test structure, includes, build rules).
**Fix:** Provide templates for common change types:
- "Add a new Clang diagnostic" (diagnostic def, Sema check, test, docs)
- "Add an X86 instruction pattern" (TableGen, test, scheduling info)
- "Fix a CodeGen bug" (regression test pattern, IR example)

**Effort:** 1-2 days | **Impact:** Faster authoring, fewer mistakes | **Status:** Not started

---

## 6. Bottleneck: Parallel Agent Throughput (100x)

*Current: 1-2 PRs/day. Target: 20-100 PRs/day with AI agents.*

Once the feedback loop is fast (Tier 1) and review is streamlined (Tier 2), the architecture can support multiple AI agents working in parallel.

### 6.1 Agentic CI Failure Triage

**Bottleneck:** CI failures require human debugging, blocking the agent's next iteration.
**Fix:** AI agent reads CI logs, classifies root cause, suggests fix. Phased rollout:
1. **Reader**: Parse logs, identify failure pattern, link to code
2. **Advisor**: Create draft fix for known patterns (missing include, test expectation)
3. **Autopilot**: Handle bisection and patch iteration for regressions

Upstream precedent: `.ci/premerge_advisor_explain.py` does basic failure analysis.

**Effort:** 2-4 weeks | **Impact:** Removes human from failure triage | **Status:** Not started

### 6.2 Parallel Development Streams

**Bottleneck:** Agents work sequentially; CI is shared and slow.
**Fix:** N agents -> N branches -> N CI pipelines -> human review queue.

```
Issue Backlog --> Agent Orchestrator --> N parallel agents
                                             |
                                             v
                                    N branches + N CI pipelines
                                             |
                                             v
                                    Human review queue (prioritized)
```

**Key enabler:** Cheap, fast CI from sections 2-3 makes this economically viable.

**Effort:** 1-3 months | **Impact:** 10-50x throughput | **Status:** Future

### 6.3 Fork Sync Automation

**Bottleneck:** Manual rebase against upstream (~1000 commits/week), conflict resolution.
**Fix:** Automated daily rebase with conflict detection. AI agent resolves mechanical conflicts; human handles semantic ones.

**Effort:** 1 week | **Impact:** Eliminates maintenance burden | **Status:** Not started

---

## Metrics & Targets

| Metric | Current | 10x Target | 100x Target |
|--------|---------|-----------|-------------|
| **Feedback loop** (push to result) | 60-90 min | <10 min | <5 min |
| **Wasted iterations** (preventable failures) | ~20-40% | <10% | <5% |
| **Review turnaround** | Days-weeks | <1 day | Hours |
| **Time to first PR** (new issue) | Days | Hours | Minutes (agent) |
| **PRs per day** (human) | 1-2 | 3-5 | 5-10 |
| **PRs per day** (AI-assisted) | 0 | 2-5 | 20-100 |
| **sccache hit rate** | ~0% | >60% | >90% |
| **Monthly CI cost** | $61 | <$200 | <$2000 |

### Baseline metrics (definition of done — Issue #1 measurability)

We define the following baseline metrics and targets for the **critical workflow** (CppDigest Clang CI, `cppa-clang-ci.yml`):

| Metric | Definition | Current (baseline) | Target |
|--------|------------|--------------------|--------|
| **First meaningful signal** | Time from workflow start to first job completion that gives pass/fail for the commit (e.g. Linux job done). | ~60–90 min | &lt;25 min |
| **Total wall time** | End-to-end duration of the critical workflow (all required jobs). | ~60–120 min (Linux+Windows) | &lt;90 min |
| **Cache hit rate** | sccache: (hits) / (hits + misses). From `sccache --show-stats` in step summary. | ~0% (cold) | &gt;60% |
| **Flake rate** | Fraction of workflow runs that were re-run (same ref) and then passed. Lower is better. | Unknown (track manually) | &lt;5% |

*How to measure:* First meaningful signal and total wall time from GitHub Actions run timestamps (or API). Cache hit rate from the "Cache (sccache)" block in the job step summary. Flake rate from counting re-runs that later passed vs total runs over a window.

---

## Implementation Priority

| # | Proposal | Bottleneck | Impact | Effort | Status |
|---|----------|-----------|--------|--------|--------|
| 2.1 | Path-based project selection | Feedback loop | Very High | 2-4h | **Done** |
| 2.2 | Warm sccache | Feedback loop | Very High | 1-2h | Wired (needs restore-keys) |
| 2.3 | Upgrade runners | Feedback loop | High | 1h | Do Now |
| 3.1 | Code formatting pre-check | Wasted iterations | Medium | 2-4h | Do Now |
| 3.2 | Local pre-flight script | Wasted iterations | High | 2-4h | Do Now |
| 3.3 | Flaky test retry | Wasted iterations | Medium | -- | Done |
| 3.4 | RWX managed triggers | Feedback loop | Medium | -- | Done |
| 2.4 | Distributed build cache | Feedback loop | High | 4-8h | Do Next |
| 2.5 | Test sharding | Feedback loop | Med-High | 4-8h | Do Next |
| 4.1 | AI pre-review | Review queue | High | 2-4w | Do Next |
| 4.2 | Reviewer auto-assignment | Review queue | Medium | 1-2d | Do Next |
| 4.3 | Change classification | Review queue | Medium | 1d | Do Next |
| 5.1 | Codebase index for agents | Understanding | High | 2-3d | Do Next |
| 5.2 | Patch templates | Authoring | Medium | 1-2d | Do Next |
| 6.1 | Agentic failure triage | Agent autonomy | Very High | 2-4w | Later |
| 6.2 | Parallel dev streams | Throughput | Transformative | 1-3mo | Later |
| 6.3 | Fork sync automation | Maintenance | High | 1w | Later |

---

## Phased roadmap (Issue #1: short-term → medium-term → long-term)

This roadmap explicitly connects the three phases required by Issue #1.

### Phase 1: Short-term CI speedups (1–2 weeks)

**Goal:** Shorter feedback loop and measurable baseline without changing upstream policy.

| Step | Deliverable | Outcome | Status |
|------|-------------|--------|--------|
| 1.1 | Path-based project selection in fork CI | Build/test only what changed; skip when no projects. | **Done** |
| 1.2 | sccache stats in step summary | Cache hit rate visible every run (baseline for measurability). | **Done** |
| 1.3 | Baseline metrics defined | First meaningful signal, total wall time, cache hit rate, flake rate (see table above). | **Done** |
| 1.4 | Improvement proposals + workflow report | Clarity and actionability (≥3 implementable items). | **Done** |

**Exit:** At least 3 improvement items are implementable; baseline metrics and targets are defined. **Phase 1 complete.**

### Phase 2: Medium-term runner strategy (1–2 months)

**Goal:** Run high-fidelity builds/tests off GitHub-hosted runners while keeping a GitHub-native developer experience.

| Step | Deliverable | Outcome |
|------|-------------|--------|
| 2.1 | Requirements doc | Runner specs, cache (sccache/GCS or shared cache), networking, secrets. |
| 2.2 | Pilot: larger or self-hosted runners | One heavy job (e.g. Linux build) on 8-core or self-hosted; same workflow YAML, different `runs-on`. |
| 2.3 | Rollout | Migrate remaining heavy jobs; keep GitHub as source of truth and PR checks. |

**Exit:** Critical path no longer limited by 2-core GHA runners; cache and capacity improved.

### Phase 3: Long-term agentic local-dev via GitHub web chat

**Goal:** AI-assisted agents do triage, minimal repro, bisection, and patch suggestion loops; humans focus on decisions. Delivered via a GitHub-native web interface that collaborates with coding agents via chat.

| Step | Deliverable | Outcome |
|------|-------------|--------|
| 3.1 | Agentic failure triage | Agent reads CI logs, classifies root cause, suggests fix (assistant role). |
| 3.2 | Chat + re-runs + patch suggestions | Agent can trigger re-runs, propose patches (branch or suggestion); human reviews and merges. |
| 3.3 | Optional: local/on-prem runs from same UI | High-fidelity builds from same "single pane"; results reflected in GitHub. |

**Exit:** Single workflow from "open PR" to "see failure → get suggestion → approve → merge" with minimal context switching; agents in safe "assistant" then "autopilot" steps.

**Dependencies:** Phase 1 is independent. Phase 2 can overlap with Phase 1. Phase 3 depends on Phase 1 (visibility + triage) and benefits from Phase 2 (runner capacity).

---

## Prototype / Proof of Value

The issue requires at least one measurable CI speedup or scripted workflow analyzer.

### Implemented: Path-Based Project Selection

**Before (GHA run #15):** 3h 25m 48s — full clang build on infrastructure-only PR.
**After (GHA run #18):** 1m 52s — `compute_projects.py` detects no buildable files, skips build entirely.

**Speedup: 110x** for infrastructure-only changes (docs, CI scripts, workflow files).

### Implemented: sccache Stats in Step Summary

Every GHA run now prints sccache hit/miss stats to the Job Step Summary. This gives per-run cache hit rate visibility without needing external tooling. Current baseline: ~0% (cold cache on new fork). Target: >60% after 2-3 builds on `main`.

### Implemented: RWX Monolithic Build Pipeline

Fork-specific RWX CI (`.rwx/ci.yml`) provides a second CI system with:
- Monolithic LLVM build (all subprojects, X86 target)
- Parallel check tasks (check-llvm, check-clang, check-lld, check-mlir, ...)
- Performance analysis report (task timing, sccache stats)
- Per-second billing (~$0.008/min vs GHA's per-minute billing)
