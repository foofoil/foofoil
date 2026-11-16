#!/usr/bin/env python3
"""查找并清理 /Applications 之外的 foofoil 应用副本。"""

import argparse
import os
from pathlib import Path
import plistlib
import shutil
import sys
import time

BUNDLE_ID = "com.markonce.foofoil"
PROTECTED = Path("/Applications")


def main():
    parser = argparse.ArgumentParser(
        description="查找 foofoil 应用副本；默认仅预览，--delete 才会删除。"
    )
    parser.add_argument("roots", nargs="*", type=Path, help="搜索目录（默认：项目 build 和 Xcode 中 foofoil 的 DerivedData）")
    parser.add_argument("--delete", action="store_true", help="永久删除找到的副本")
    args = parser.parse_args()
    home = Path.home()
    roots = args.roots or [
        Path(__file__).resolve().parent.parent / 'build',
        *(home / 'Library/Developer/Xcode/DerivedData').glob('foofoil-*'),
    ]
    protected = PROTECTED.resolve()
    seen = set()
    matches = []
    errors = []
    last_progress = 0.0
    scanned = 0

    def onerror(error):
        errors.append(str(error))

    for root in roots:
        root = root.expanduser()
        if not root.exists():
            if args.roots:
                errors.append(f"搜索目录不存在或无法访问：{root}")
            continue
        if not root.is_dir() or root.is_symlink():
            errors.append(f"搜索目录必须是非符号链接目录：{root}")
            continue
        print(f"正在搜索：{root}", flush=True)
        for directory, dirs, _ in os.walk(root, topdown=True, followlinks=False, onerror=onerror):
            path = Path(directory)
            scanned += 1
            now = time.monotonic()
            if now - last_progress >= 2:
                print(f"已扫描 {scanned} 个目录，当前：{path}", flush=True)
                last_progress = now
            resolved = path.resolve()
            if resolved in seen or resolved == protected or protected in resolved.parents:
                dirs[:] = []
                continue
            seen.add(resolved)
            if path.suffix.lower() != '.app':
                continue
            try:
                with (path / 'Contents' / 'Info.plist').open('rb') as file:
                    info = plistlib.load(file)
            except FileNotFoundError:
                continue
            except (OSError, plistlib.InvalidFileException, ValueError) as error:
                errors.append(f"无法读取 {path}：{error}")
                continue
            if isinstance(info, dict) and info.get('CFBundleIdentifier') == BUNDLE_ID:
                matches.append(path)
                print(f"发现副本：{path}", flush=True)
                dirs[:] = []

    for path in matches:
        if args.delete:
            try:
                shutil.rmtree(path)
                print(f"已删除：{path}")
            except OSError as error:
                errors.append(f"无法删除 {path}：{error}")
        else:
            print(f"待删除：{path}")
    print(f"{'找到' if not args.delete else '处理'} {len(matches)} 个副本。")
    if not args.delete and matches:
        print("预览模式：加 --delete 才会永久删除以上副本。")
    for error in errors:
        print(f"警告：{error}", file=sys.stderr)
    return 1 if errors else 0


if __name__ == '__main__':
    sys.exit(main())
