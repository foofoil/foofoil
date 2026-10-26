#!/usr/bin/env python3
"""Restore OpenCode v2's leader+m binding without removing custom model keys."""
import argparse
import json
import os
from pathlib import Path
import shutil
import tempfile


def restore(path):
    original = path.read_text()
    config = json.loads(original)
    keys = config.setdefault("keybinds", {})
    current = keys.get("model.list")
    if current is None or current is False or current == "none":
        bindings = []
    else:
        bindings = list(current) if isinstance(current, list) else [current]
    if "<leader>m" in bindings:
        return False
    keys["model.list"] = [*bindings, "<leader>m"]
    # 保留原始配置供回退；同目录原子替换，避免中断时写出半份 JSON。
    backup = path.with_name(path.name + ".before-model-shortcut.bak")
    if not backup.exists():
        shutil.copy2(path, backup)
    fd, temporary = tempfile.mkstemp(prefix=path.name + ".", dir=path.parent)
    try:
        with os.fdopen(fd, "w") as output:
            output.write(json.dumps(config, ensure_ascii=False, indent=2) + "\n")
        shutil.copymode(path, temporary)
        os.replace(temporary, path)
    finally:
        if os.path.exists(temporary):
            os.unlink(temporary)
    return True


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--config", type=Path,
                        default=Path.home() / ".config/opencode/cli.json")
    args = parser.parse_args()
    changed = restore(args.config)
    print("Restored leader+m; existing bindings retained. Restart OpenCode."
          if changed else "leader+m is already configured.")
