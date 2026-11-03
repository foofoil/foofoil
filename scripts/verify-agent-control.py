#!/usr/bin/env python3
"""Focused live smoke test; uses only new incognito windows and temporary files."""
import json
from pathlib import Path
import subprocess
import sys
import tempfile

app = Path(sys.argv[1]).resolve() if len(sys.argv) > 1 else Path("build/Build/Products/Debug/foofoil.app").resolve()
cli = app / "Contents/MacOS/foil"
with tempfile.TemporaryDirectory(prefix="foil-control-") as directory:
    root = Path(directory)
    windows = []
    def call(*args, error=None):
        result = subprocess.run([str(cli), *args, "--app", str(app), "--session", str(root / "session.json")], capture_output=True, text=True, timeout=40)
        value = json.loads(result.stdout)
        assert value.get("error") == error, (args, value, result.stderr)
        assert result.returncode == (1 if error else 0), (args, result.returncode)
        return value
    def opened(path):
        result = call("open", str(path), "--incognito")
        window = result["window"]["id"]
        windows.append(window)
        assert result["status"] == "accepted"
        assert call("wait", "--operation", result["operation"]["id"], "--timeout", "10")["operation"]["status"] == "ready"
        return window
    try:
        source = root / "reference.txt"
        source.write_text("甲😀乙\n第二行甲😀丙", encoding="utf-8")
        window = opened(source)
        assert call("inspect", window)["window"]["incognito"]
        assert call("read", window, "--limit", "2")["text_page"]["text"] == "甲😀"
        search = call("search", window, "😀", "--limit", "1")["search"]
        assert search["matches"][0]["offset"] == 1
        next_page = call("search", window, "😀", "--limit", "1", "--offset", str(search["next_offset"]), "--content-version", search["content_version"])["search"]
        assert next_page["matches"][0]["line"] == 2
        assert call("set", window, "opacity", "0.7")["window"]["opacity"] == 0.7
        assert not call("hide", window)["window"]["visible"]
        assert call("reveal", window)["window"]["visible"]
        screen = call("screens")["screens"][0]
        frame = call("window", "frame", window, "--screen", screen["id"], "--x", "-10", "--y", "20", "--width", "500", "--height", "300")["window"]["frame"]
        assert frame["x"] >= 0 and frame["y"] >= 0
        export = root / "export.txt"
        call("export", window, "--format", "original", "--output", str(export))
        assert export.read_text() == source.read_text()
        call("export", window, "--format", "original", "--output", str(export), error="OUTPUT_EXISTS")
        call("media", "status", window, error="CAPABILITY_UNAVAILABLE")
        assert call("capabilities", window)["availability"]
        assert call("config", "list")["configuration"]
        assert call("permissions", "status")["permissions"]
        html = root / "page.html"
        html.write_text('<html><head><meta charset="utf-8"></head><body><h1>参考</h1><p>甲😀乙</p></body></html>')
        web = opened(html)
        assert "甲😀乙" in call("read", web, "--source", "rendered")["text_page"]["text"]
        archived = root / "page.webarchive"
        call("export", web, "--format", "original", "--output", str(archived))
        assert archived.stat().st_size > 0
        bad = call("open", "--url", "http://127.0.0.1:9/", "--incognito")
        windows.append(bad["window"]["id"])
        call("wait", "--operation", bad["operation"]["id"], "--timeout", "10", error="CONTENT_LOAD_FAILED")
        print("Passed: live incognito open/wait/read/search/window/frame/export/WebKit/failure/capability/config/permission checks")
    finally:
        for window in windows:
            call("close", window, "--scope", "all")
