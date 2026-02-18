# Part of the LLVM Project, under the Apache License v2.0 with LLVM Exceptions.
# See https://llvm.org/LICENSE.txt for license information.
# SPDX-License-Identifier: Apache-2.0 WITH LLVM-exception
"""Print job run times for a GitHub Actions workflow. Set GITHUB_TOKEN (or GH_TOKEN)."""

from __future__ import annotations

import argparse
import os
import sys
from collections import defaultdict
from datetime import timezone


def main() -> int:
    parser = argparse.ArgumentParser(
        description="Print job run times for a GitHub Actions workflow.",
    )
    parser.add_argument(
        "--repo",
        default="llvm/llvm-project",
        help="Repository owner/name (default: llvm/llvm-project)",
    )
    parser.add_argument(
        "--workflow",
        default="CI Checks",
        help="Workflow name to filter, e.g. 'CI Checks'",
    )
    parser.add_argument(
        "--runs",
        type=int,
        default=10,
        help="Max number of completed workflow runs to analyze (default: 10)",
    )
    parser.add_argument(
        "--event",
        default="pull_request",
        help="Event type: pull_request, push, etc.",
    )
    args = parser.parse_args()

    token = os.environ.get("GITHUB_TOKEN") or os.environ.get("GH_TOKEN")
    if not token:
        print("Set GITHUB_TOKEN or GH_TOKEN with Actions read permission.", file=sys.stderr)
        return 1

    try:
        from github import Github
    except ImportError:
        print("Install PyGithub: pip install PyGithub", file=sys.stderr)
        return 1

    gh = Github(token)
    repo = gh.get_repo(args.repo)

    # Find workflow by display name, then use its runs endpoint for
    # server-side filtering (avoids fetching all runs across the repo).
    target_workflow = None
    for wf in repo.get_workflows():
        if wf.name == args.workflow:
            target_workflow = wf
            break
    if target_workflow is None:
        print(f"Workflow '{args.workflow}' not found in {args.repo}.", file=sys.stderr)
        return 1

    runs_processed = 0
    job_seconds: dict[str, list[float]] = defaultdict(list)

    for run in target_workflow.get_runs(status="completed", event=args.event):
        if runs_processed >= args.runs:
            break

        for job in run.jobs():
            if job.status != "completed" or not job.completed_at or not job.started_at:
                continue
            started = job.started_at
            completed = job.completed_at
            if started.tzinfo is None:
                started = started.replace(tzinfo=timezone.utc)
            if completed.tzinfo is None:
                completed = completed.replace(tzinfo=timezone.utc)
            duration = (completed - started).total_seconds()
            if duration <= 0:
                continue
            job_seconds[job.name].append(duration)

        runs_processed += 1

    if runs_processed == 0:
        print(f"No completed runs found for workflow '{args.workflow}', event={args.event}.", file=sys.stderr)
        return 0

    job_total_seconds = {name: sum(durs) for name, durs in job_seconds.items()}
    total_seconds = sum(job_total_seconds.values())
    if total_seconds == 0:
        print("No job durations collected.", file=sys.stderr)
        return 0

    print(f"# Workflow bottleneck breakdown: {args.repo}")
    print(f"# Workflow: {args.workflow}  |  Event: {args.event}  |  Runs analyzed: {runs_processed}")
    print()
    print(" Job name                                      |  Total (min)  |  Share")
    print(" ----------------------------------------------+---------------+--------")

    for job_name in sorted(job_total_seconds.keys(), key=lambda k: -job_total_seconds[k]):
        secs = job_total_seconds[job_name]
        mins = secs / 60.0
        pct = 100.0 * secs / total_seconds
        label = (job_name[:46] + "..") if len(job_name) > 48 else job_name
        print(f" {label:<48} |  {mins:>10.1f}  |  {pct:>5.1f}%")

    print(" ----------------------------------------------+---------------+--------")
    print(f" {'TOTAL (sum of job wall times)':<48} |  {total_seconds/60:>10.1f}  |  100.0%")
    print()
    print("Note: Total sums job durations across runs; parallel jobs overlap in wall time.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
