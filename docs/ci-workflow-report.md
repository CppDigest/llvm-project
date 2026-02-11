# LLVM CI/Automation Workflow Report

**Issue:** [CppDigest/llvm-project#1](https://github.com/CppDigest/llvm-project/issues/1)  
**Context:** For full context when editing or regenerating: repo root, `.ci/`, `.github/workflows/`, and this doc. Phased actions: [CI Improvement Proposals](ci-improvement-proposals.md). Blueprint: [.github/workflows/cppa-clang-ci.yml](../.github/workflows/cppa-clang-ci.yml).

---

## Executive Summary

| Item | Value |
|------|-------|
| Pre-merge gate | `premerge.yaml` (GitHub Actions). Runs only when `repository_owner == 'llvm'` (i.e. upstream; not on forks). |
| Build time | **120 min** (Linux) / **180 min** (Windows) — from workflow `timeout-minutes` in repo. |
| Post-commit bots | **200+** buildbots, never fully green |
| Flaky tests | lldb, openmp — spurious failures daily |
| Daily commits | 150+ on main |
| Legacy infra | `google/llvm-premerge-checks` archived June 2025 |
| Total workflow runs | 1.6M+ |
| Main bottleneck | Compilation (46% of pipeline time) |

---

## 1. PR Lifecycle

```
  PR opened
      │
      ├──→ [Label & Format]  ──→ pr-subscriber, labelling, clang-format  (~seconds)
      │
      ├──→ [Pre-merge Gate]  ──→ premerge.yaml: cmake → build → test    (~120-180 min)
      │         │
      │         └──→ Fail → Author fixes → re-push → re-run
      │
      ├──→ [Human Review]    ──→ Reviewer approval                      (hours-days)
      │
      └──→ [Merge]           ──→ Squash-merge to main
              │
              └──→ [Post-commit Bots]  ──→ 200+ buildbots (multi-arch)  (async)
                        │
                        └──→ Fail → Revert or fix-forward (manual)
```

**Fork vs upstream:** Pre-merge jobs in `premerge.yaml` use `if: github.repository_owner == 'llvm'`, so they do **not** run on forks (e.g. CppDigest/llvm-project). On the fork, the gate is whatever workflows you enable (e.g. [cppa-clang-ci.yml](../.github/workflows/cppa-clang-ci.yml)).

## 2. Workflow Inventory

| Category | Count | Key Workflows | Trigger |
|----------|-------|--------------|---------|
| Core CI / Pre-merge | ~5 | `premerge.yaml`, `pr-code-format.yml` ("Check code formatting"), `new-prs.yml` ("Labelling new pull requests") | `pull_request` |
| Subproject CI | ~15 | `libcxx-build-and-test.yaml`, `llvm-tests.yml` | `pull_request` (path-filtered) |
| Release | ~5 | `release-binaries.yml`, `release-asset-audit` | `workflow_dispatch` / `schedule` |
| Triage / Bots | ~8 | `pr-subscriber.yml`, `issue-comment` | `pull_request` / `issue_comment` |
| Maintenance | ~5 | Stale-issue cleanup, audit | `schedule` |
| Build helpers | ~10 | Container builds, cache warming | Reusable workflows |
| **Total** | **~48** | | |

## 3. Time Allocation (Pre-merge, Linux)

Phase breakdown below is from external measurement (see Appendix B ref 7); timeouts in repo are 120 min (Linux) and 180 min (Windows) per `premerge.yaml`.

```
 Phase             Time     Share
 ─────────────────────────────────────────────────────
 Checkout + deps    5 min    4%   ██
 CMake configure   20 min   17%   ████████
 Compilation       55 min   46%   ██████████████████████████
 Linking           15 min   13%   ███████
 Testing (lit)     20 min   17%   ████████
 Artifacts          5 min    4%   ██
 ─────────────────────────────────────────────────────
 TOTAL            120 min  100%   Windows: +60 min overhead
```

| Phase | Linux | Windows | Bottleneck |
|-------|-------|---------|------------|
| Checkout | 5 min | 8 min | Monorepo ~3 GB |
| CMake | 20 min | 25 min | 50% of clean-build |
| Compile | 55 min | 80 min | 2.5M+ lines C++ |
| Link | 15 min | 25 min | Debug info OOM risk |
| Test | 20 min | 35 min | lldb/openmp flaky |
| **Total** | **120 min** | **180 min** | |

## 4. Flakiness & Signal Quality

| Source | Frequency | Impact |
|--------|-----------|--------|
| lldb tests | Daily | Spurious timeouts, race conditions |
| openmp / libomptarget | Daily | Thread-sensitive, hardware-dependent |
| Buildbot-specific | Weekly | Config drift, disk space, network |
| Phase ordering | Occasional | Pass interaction regressions |

Failure notifications are "normal" even for harmless commits — signal is diluted, real failures get missed.

## 5. Accessing Artifacts & Logs

| What | Where | How |
|------|-------|-----|
| Pre-merge CI logs | GitHub Actions → PR "Checks" tab | Click job → expand step → view log |
| Build artifacts | GitHub Actions → run → "Artifacts" section | Download zip (retained 90 days) |
| Post-commit buildbot logs | https://lab.llvm.org/buildbot/ | Find bot by name → view build log |
| Test results (lit) | Inside CI job log output | Search for `FAIL:` or `XFAIL:` |
| sccache stats | CI job log (if `--show-stats` enabled) | Search for `sccache` in log |

PR failure: Checks tab → failing job → expand step. Flaky (lldb/openmp) often pass on re-run; real failures show consistent `FAIL:`.

## 6. Automation Inventory & Gaps

| Component | Status | Gap |
|-----------|--------|-----|
| `pr-subscriber` (notify reviewers) | Active | |
| Auto-labelling (by path) | Active | |
| `clang-format` checker | Active | |
| Post-commit buildbots (200+) | Active (never green) | No flake quarantine |
| Release automation | Active | |
| Selective rebuild (project-level) | Present | `.ci/compute_projects.py` selects projects from diff; gap is path-level filters, incremental builds, test-level selection |
| Bisection bot | Missing | Manual bisection only |
| Merge queue | Missing | 150+ commits/day vs multi-hour builds |
| Cache tracking | Missing | sccache hit rate unmonitored |

## 6.1 Agentic Workflow Integration

Agents can support the following; humans keep approval and review.

| Area | Agent role | Human role |
|------|------------|------------|
| **Failure classification** | Classify CI failure (build vs test, flake vs real) | Review and confirm |
| **Flaky test detection** | Propose quarantine from re-run patterns | Approve quarantine list |
| **Minimal repro** | Reduce failing test or command to minimal case | Verify repro |
| **Targeted test selection** | Suggest which tests to run for a given diff | Approve scope |
| **Bisection** | Propose suspect range from pass/fail history | Approve range and fixes |
| **Patch suggestion** | Propose fixes from diagnostics | Review and merge |
| **Web chat Q&A** | Answer "why did my PR fail?" from logs and history | Ask questions |

Phased plan and task list: [CI Improvement Proposals](ci-improvement-proposals.md) — P8 and Appendix A.

## 7. Baseline Metrics

| Metric | Current | Target |
|--------|---------|--------|
| PR first signal | ~120 min | < 30 min |
| Wall-clock (full) | 120-180 min | < 60 min |
| sccache hit rate | Unknown | > 80% |
| Flake re-runs/day | ~5+ | < 1 |
| Buildbot green rate | Never green | > 90% |

---

## 8. Workflow Analyzer Script

| What | Where | How |
|------|-------|-----|
| Script | `.ci/workflow_analyzer.py` | GitHub API → recent runs/jobs → job-level timing table |
| Auth | `GITHUB_TOKEN` or `GH_TOKEN` (Actions read) | Set in env |
| Output | Total minutes and % share per job | Stdout |

From repo root:

```bash
export GITHUB_TOKEN=<token>
python .ci/workflow_analyzer.py --repo llvm/llvm-project --workflow "CI Checks" --runs 5
```

Options: `--repo`, `--workflow`, `--runs`, `--event`. See Appendix C for how to use the output.

---

## Appendix A: Repository Structure

```
llvm-project/               ~9M lines total, ~2.5M C++ core
├── .github/workflows/      ~48 workflow YAML files
├── .ci/                    CI helper scripts
├── llvm/                   Core (IR, passes, codegen)
├── clang/                  C/C++/ObjC frontend
├── clang-tools-extra/      clangd, clang-tidy
├── lld/                    Linker
├── lldb/                   Debugger ← flaky tests
├── libcxx/                 C++ stdlib
├── openmp/                 OpenMP runtime ← flaky tests
├── mlir/                   Multi-Level IR
├── flang/                  Fortran frontend
├── bolt/                   Binary optimization
├── polly/                  Polyhedral optimization
└── compiler-rt/            Sanitizers, builtins
```

## Appendix B: References

| # | Resource | URL |
|---|----------|-----|
| 1 | LLVM GitHub Actions | https://github.com/llvm/llvm-project/actions |
| 2 | Workflow directory | https://github.com/llvm/llvm-project/tree/main/.github/workflows |
| 3 | CI scripts | https://github.com/llvm/llvm-project/tree/main/.ci |
| 4 | Buildbot infra | https://github.com/llvm/llvm-zorg |
| 5 | Reusable Actions | https://github.com/llvm/actions |
| 6 | Legacy pre-merge (archived) | https://github.com/google/llvm-premerge-checks |
| 7 | "LLVM: The bad parts" | https://www.npopov.com/2026/01/11/LLVM-The-bad-parts.html |
| 8 | LLVM Buildbots | https://jplehr.de/2025/01/20/llvm-buildbots/ |
| 9 | sccache idle timeout | https://www.mail-archive.com/llvm-branch-commits@lists.llvm.org/msg55844.html |

## Appendix C: Using the Workflow Analyzer Output

Cross-check Section 3 with the table (which job dominates). To measure CI changes on a fork, run the script before and after a change (e.g. sccache or path filters) and compare totals and per-job share.

## Appendix D: Verification (what was checked in-repo)

| Claim | Checked how |
|-------|-------------|
| Pre-merge gate, 120/180 min | `premerge.yaml`: `timeout-minutes: 120` (Linux), `180` (Windows); `if: github.repository_owner == 'llvm'` |
| Flaky: lldb, openmp | `.ci/flaky-tests.txt`: 2 lldb, 2 openmp entries with reasons |
| Selective rebuild (project-level) | `.ci/compute_projects.py`: diff → projects + dependents; EXCLUDE_LINUX/WINDOWS/MAC |
| Workflow count ~48 | `.github/workflows/`: 47 .yml + 5 .yaml top-level (excl. subdir actions) |
| Format / labelling workflows | `pr-code-format.yml` (name "Check code formatting"), `new-prs.yml` (name "Labelling new pull requests"); both `if: github.repository == 'llvm/llvm-project'` |
| Phase breakdown (5/20/55/15/20 min) | Not in repo; from external source (Appendix B ref 7) |
| 200+ buildbots, 150+ commits/day, 1.6M runs | Not in repo; from buildbot/community references |

## Appendix E: Conclusions for further effort (cppa-clang)

1. **Fork CI:** On CppDigest/llvm-project, premerge does not run. Use cppa-clang-ci (or similar) as the gate; keep path filters and sccache so feedback is fast.
2. **What already exists:** Project-level selection (compute_projects.py) is in place; the gap is path-level skip (e.g. docs-only PRs), incremental builds, and test-level selection. Don’t re-implement project selection.
3. **Metrics:** Run `.ci/workflow_analyzer.py` against **llvm/llvm-project** (with token) to get current job timings; run against your fork after changes to measure impact. sccache hit rate is not logged in-repo today—add `sccache --show-stats` (or similar) and parse logs to get a baseline.
4. **Flakiness:** `.ci/flaky-tests.txt` is the canonical list. openmp is excluded on Linux premerge (EXCLUDE_LINUX); lldb runs. Prioritize quarantine/retry (proposals P4) so signal is clearer.
5. **Next steps:** Implement P1–P3 on the fork (sccache logging, path filters, CMake cache), measure with the analyzer, then iterate. Agentic (P8) and self-hosted (P7) depend on having stable, fast CI first.
