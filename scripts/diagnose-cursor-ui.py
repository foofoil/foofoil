#!/usr/bin/env python3
"""有界、只读的进程指标记录；不收集窗口标题、正文、按键或进程完整路径。"""
import argparse
import csv
from datetime import datetime
from pathlib import Path
import subprocess
import time


NAMES = {"foofoil", "CursorUIViewService", "WindowServer", "Squirrel"}
MAX_BYTES = 2 * 1024 * 1024


def append_rows(path, rows):
    # 最多保留当前文件和两份轮转文件，单次写入只含四类进程。
    if path.exists() and path.stat().st_size >= MAX_BYTES:
        previous = path.with_suffix(path.suffix + ".1")
        oldest = path.with_suffix(path.suffix + ".2")
        if previous.exists():
            previous.replace(oldest)
        path.replace(previous)
    new = not path.exists() or path.stat().st_size == 0
    with path.open("a", newline="") as stream:
        writer = csv.writer(stream)
        if new:
            writer.writerow(["time", "pid", "process", "ps_cpu_percent", "rss_kib", "status"])
        writer.writerows(rows)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--duration", type=float, default=3600, help="记录秒数，默认一小时，最多一天")
    parser.add_argument("--interval", type=float, default=5, help="间隔秒数，最少一秒")
    parser.add_argument("--output", type=Path, default=Path.home() / "Library/Logs/foofoil-cursor-ui/metrics.csv")
    args = parser.parse_args()
    if not 0 < args.duration <= 86400 or args.interval < 1:
        parser.error("duration 须在 (0, 86400] 内，interval 须 >= 1")
    args.output.parent.mkdir(parents=True, exist_ok=True)
    print(f"只读记录至 {args.output}；Ctrl+C 停止；最多约 6 MiB。", flush=True)
    deadline = time.monotonic() + args.duration
    try:
        while time.monotonic() < deadline:
            timestamp = datetime.now().astimezone().isoformat(timespec="seconds")
            rows = []
            try:
                result = subprocess.run(["ps", "-axo", "pid=,pcpu=,rss=,comm="],
                                        text=True, capture_output=True, check=True, timeout=5)
                for line in result.stdout.splitlines():
                    fields = line.strip().split(None, 3)
                    if len(fields) == 4 and Path(fields[3]).name in NAMES:
                        pid, cpu, rss, command = fields
                        rows.append([timestamp, pid, Path(command).name, cpu, rss, "ok"])
                if not rows:
                    rows.append([timestamp, "", "", "", "", "no_matching_process"])
            except (subprocess.SubprocessError, OSError) as error:
                # 失败显式记录；不把不可读指标伪装成零。
                rows.append([timestamp, "", "", "", "", type(error).__name__])
                print(f"{timestamp}: 指标读取失败：{type(error).__name__}", flush=True)
            append_rows(args.output, rows)
            time.sleep(max(0, min(args.interval, deadline - time.monotonic())))
    except KeyboardInterrupt:
        print("已停止。", flush=True)


if __name__ == "__main__":
    main()
