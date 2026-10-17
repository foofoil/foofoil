#!/usr/bin/env python3
"""Exercise the signed S07 probe. A failed acceptance check returns nonzero."""
import hashlib
import json
import os
from pathlib import Path
import subprocess
import tempfile
import time


ROOT = Path(__file__).resolve().parents[2]
OUTPUT = ROOT / "build/agent-terminal-prototype"
APP = OUTPUT / "AgentTerminalProbe.app"
CLIENT = OUTPUT / "probe-client"
results = []


def call(action, path=None):
    command = [str(CLIENT), str(APP), action]
    if path is not None:
        command.append(str(path))
    run = subprocess.run(command, capture_output=True, text=True, timeout=20)
    if not run.stdout.strip():
        raise RuntimeError(f"{action}: no response, exit={run.returncode}: {run.stderr.strip()}")
    reply = json.loads(run.stdout)
    assert run.returncode == (0 if reply["ok"] else 1), (action, run.returncode)
    results.append({"command": action, "response": reply})
    return reply


def check(name, condition):
    results.append({"check": name, "passed": bool(condition)})
    print(f"{'PASS' if condition else 'FAIL'} {name}", flush=True)


def wait_for_exit(pid):
    deadline = time.monotonic() + 5
    while time.monotonic() < deadline:
        try:
            os.kill(pid, 0)
        except ProcessLookupError:
            return
        time.sleep(0.05)
    raise RuntimeError("Probe did not terminate")


def digest(data):
    return hashlib.sha256(data).hexdigest()


def main():
    # 此目录只包含本脚本生成的原文件；不访问用户文档或产品容器。
    with tempfile.TemporaryDirectory(prefix="foil-source-", dir=OUTPUT) as directory:
        source = Path(directory) / "source.txt"
        first, second = b"first\n", b"updated at the same path\n"
        source.write_bytes(first)
        try:
            denied = call("path-only", source)
            check("cold start: a path alone grants no source access", not denied["ok"])
            acquired = call("acquire", source)
            check("explicit original file delivery and read", acquired.get("digest") == digest(first))
            check("security scoped bookmark created", acquired.get("bookmarkCreated") is True)
            source.write_bytes(second)
            check("same path in-place rewrite", call("read").get("digest") == digest(second))
            replacement = source.with_suffix(".replacement")
            replacement.write_bytes(first)
            replacement.replace(source)
            check("same path atomic replacement", call("read").get("digest") == digest(first))
            check("release accepted", call("release")["ok"])
            check("released source no longer held by probe", not call("read")["ok"])
            check("bookmark resolves again", call("restore").get("digest") == digest(first))
            stopped = call("quit")
            wait_for_exit(stopped["process"])
            restored = call("restore")
            check("bookmark resolves in a new process", restored.get("digest") == digest(first)
                  and restored["process"] != stopped["process"])
            call("hide")
            hidden = [call("status") for _ in range(3)]
            check("repeated calls preserve app hidden state", all(item.get("hiddenAfter") for item in hidden))
            source.unlink()
            check("deleted source cannot be reread", not call("read")["ok"])
            calls = [item["response"] for item in results if "response" in item]
            check("no probe windows created", all(item["windows"] == 0 for item in calls))
            check("frontmost app unchanged at observation points",
                  all(item["frontBefore"] == item["frontAfter"] for item in calls))
        finally:
            try:
                call("reset")
            finally:
                stopped = call("quit")
                wait_for_exit(stopped["process"])
    failed = sum(item.get("passed") is False for item in results)
    report = {"scope": "standalone optimized probe; not product Release acceptance",
              "results": results, "failed": failed}
    (OUTPUT / "results.json").write_text(json.dumps(report, indent=2) + "\n")
    print(f"Report: {OUTPUT / 'results.json'}")
    return 1 if failed else 0


if __name__ == "__main__":
    raise SystemExit(main())
