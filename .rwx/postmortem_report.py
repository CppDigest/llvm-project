#!/usr/bin/env python3
# Summarize optimizer session logs. Run after .rwx/optimizer.sh.
# Usage: python3 postmortem_report.py [log_dir]. Set REPORT_OUTPUT to write to a file.

import os
import re
import sys
from pathlib import Path


def find_session_logs(log_dir: Path):
    """Find session_*.log and session_*_iter_*.log in log_dir."""
    if not log_dir.is_dir():
        return
    for p in sorted(log_dir.iterdir()):
        if not p.is_file():
            continue
        name = p.name
        if name.startswith("session_") and name.endswith(".log"):
            if "_iter_" in name:
                m = re.match(r"session_(\d+)_iter_(\d+)\.log", name)
                if m:
                    yield ("iter", int(m.group(1)), int(m.group(2)), p)
            else:
                m = re.match(r"session_(\d+)\.log", name)
                if m:
                    yield ("session", int(m.group(1)), 0, p)


def read_timing_from_run_meta(path: Path) -> dict:
    """Pull run_session/run_iteration from a run_meta-style line in the log."""
    out = {}
    text = path.read_text(errors="replace")
    for line in text.splitlines():
        if "run_session=" in line and "run_iteration=" in line:
            for part in line.split():
                if "=" in part:
                    k, v = part.split("=", 1)
                    out[k] = v
            break
    return out


def summarize_sessions(log_dir: Path) -> dict:
    """Count sessions and success/fail from log contents."""
    sessions = {}
    for kind, sid, iid, path in find_session_logs(log_dir):
        if kind == "session":
            content = path.read_text(errors="replace")
            success = "Result: SUCCESS" in content
            fail = "Result: FAIL" in content
            sessions[sid] = sessions.get(sid, {"iters": 0, "success": 0, "fail": 0, "path": str(path)})
            sessions[sid]["path"] = str(path)
            for line in content.splitlines():
                if "Result: SUCCESS" in line:
                    sessions[sid]["success"] = sessions[sid].get("success", 0) + 1
                if "Result: FAIL" in line:
                    sessions[sid]["fail"] = sessions[sid].get("fail", 0) + 1
        elif kind == "iter":
            sessions[sid] = sessions.get(sid, {"iters": 0, "success": 0, "fail": 0, "path": ""})
            sessions[sid]["iters"] = max(sessions[sid].get("iters", 0), iid)
    return sessions


def main():
    script_dir = Path(__file__).resolve().parent
    log_dir = Path(script_dir / "optimizer-logs")
    if len(sys.argv) >= 2:
        log_dir = Path(sys.argv[1])
    report_path = os.environ.get("REPORT_OUTPUT", "")

    out = []
    out.append("# RWX workflow optimizer — postmortem summary")
    out.append("")
    out.append(f"Log directory: `{log_dir}`")
    out.append("")

    if not log_dir.is_dir():
        out.append("No optimizer log directory found. Run `.rwx/optimizer.sh` first (e.g. `SESSION_ID=1 MAX_ITER=20 ./.rwx/optimizer.sh`).")
        report = "\n".join(out)
        print(report)
        if report_path:
            Path(report_path).write_text(report)
        return 0

    sessions = summarize_sessions(log_dir)
    if not sessions:
        out.append("No session logs found in the log directory.")
        report = "\n".join(out)
        print(report)
        if report_path:
            Path(report_path).write_text(report)
        return 0

    out.append("## Sessions")
    out.append("")
    for sid in sorted(sessions.keys()):
        s = sessions[sid]
        out.append(f"- **Session {sid}**: iters={s.get('iters', '?')} success={s.get('success', 0)} fail={s.get('fail', 0)} — `{s.get('path', '')}`")
    out.append("")
    out.append("## Next steps")
    out.append("")
    out.append("- Correlate with RWX run logs: `rwx runs list` then `rwx runs logs <run-id> <task-key>`.")
    out.append("- Correlate with `rwx runs logs` for full failure logs.")
    out.append("- When writing reports: check upstream llvm-project GitHub Actions history for reference: https://github.com/llvm/llvm-project/actions")
    out.append("")

    report = "\n".join(out)
    print(report)
    if report_path:
        Path(report_path).write_text(report)
    return 0


if __name__ == "__main__":
    sys.exit(main())
