#!/usr/bin/env python3
"""Real CLI verification; only incognito boards and this script's files are used."""
import json
import struct
from pathlib import Path
import subprocess
import sys
import tempfile
import time
import zlib


ROOT = Path(__file__).resolve().parents[1]
APP = Path(sys.argv[1]).resolve() if len(sys.argv) > 1 else ROOT / "build/Build/Products/Debug/foofoil.app"
CLI = APP / "Contents/MacOS/foil"


def main():
    measurements = []
    with tempfile.TemporaryDirectory(prefix="foil-cli-e2e-") as directory:
        root = Path(directory)
        session = root / "session.json"
        source = root / "report.md"
        source.write_text("# Reference\n\n![blocked](https://example.invalid/image.png)\n")

        def call(*arguments, expected=None, alternate=None):
            run = subprocess.run([str(alternate or CLI), *arguments, "--app", str(APP), "--session", str(session)],
                                 capture_output=True, text=True, timeout=45)
            result = json.loads(run.stdout)
            assert result.get("error") == expected, (arguments, result, run.stderr)
            assert run.returncode == (1 if expected else 0), (arguments, run.returncode)
            return result

        boards = []
        try:
            shown = call("show", str(source), "--incognito", "--request-id", "show-retry", "--json")
            board = shown["board_id"]
            boards.append(board)
            assert shown["revision"] == 1
            assert shown["warnings"] == ["MARKDOWN_RESOURCES_BLOCKED"]
            assert call("show", str(source), "--incognito", "--request-id", "show-retry")["board_id"] == board
            assert len(call("list")["boards"]) == 1
            source.write_text("# Updated\n\nContent at the same path.\n")
            assert call("update", board, str(source), "--expected-revision", "1")["revision"] == 2
            call("update", board, str(source), "--expected-revision", "1", expected="REVISION_CONFLICT")
            # 独立原生 CLI 进程反复交付同路径文件；记录本机样本，不推断通用性能。
            for index in range(60):
                source.write_text(f"# Reference {index}\n\n" + "bounded sample\n" * 70)
                start = time.monotonic()
                response = call("update", board, str(source))
                measurements.append({"sample": index, "bytes": source.stat().st_size,
                                     "milliseconds": round((time.monotonic() - start) * 1000, 2),
                                     "revision": response["revision"]})
                if index % 10 == 0:
                    processes = subprocess.check_output(["ps", "-axo", "pid=,command="], text=True)
                    executable = str(APP / "Contents/MacOS/foofoil")
                    for line in processes.splitlines():
                        parts = line.strip().split(None, 1)
                        if len(parts) == 2 and (parts[1] == executable or parts[1].startswith(executable + " ")):
                            measurements[-1]["rss_kib"] = int(subprocess.check_output(["ps", "-o", "rss=", "-p", parts[0]], text=True).strip())
                            break
            assert response["revision"] == 62
            # 另一凭证只可见自己的窗口。
            other = root / "other.json"
            run = subprocess.run([str(CLI), "list", "--app", str(APP), "--session", str(other)], capture_output=True, text=True, timeout=45)
            assert run.returncode == 0 and json.loads(run.stdout)["boards"] == []
            call("close", board)
            boards.remove(board)
            assert call("list")["boards"] == []
            assert call("show", str(source), "--incognito", "--request-id", "show-retry")["board_id"] == board
            assert call("list")["boards"] == []
            call("update", board, str(source), expected="BOARD_NOT_FOUND")
            svg = root / "diagram.svg"
            svg.write_text('<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 200 100"><rect width="200" height="100" fill="red"/></svg>')
            shown_svg = call("show", str(svg), "--incognito")
            svg_board = shown_svg["board_id"]
            boards.append(svg_board)
            assert call("update", svg_board, str(source))["revision"] == 2
            call("close", svg_board)
            boards.remove(svg_board)
            image = root / "image.png"
            def chunk(kind, data):
                return struct.pack("!I", len(data)) + kind + data + struct.pack("!I", zlib.crc32(kind + data))
            image.write_bytes(b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack("!IIBBBBB", 2, 2, 8, 6, 0, 0, 0))
                              + chunk(b"IDAT", zlib.compress((b"\0" + b"\xff\0\0\xff" * 2) * 2)) + chunk(b"IEND", b""))
            image_board = call("show", str(image), "--incognito")["board_id"]
            boards.append(image_board)
            call("close", image_board)
            boards.remove(image_board)
            unsupported = root / "page.html"
            unsupported.write_text("<html></html>")
            call("show", str(unsupported), "--incognito", expected="UNSUPPORTED_CONTENT")
            source.unlink()
            call("show", str(source), "--incognito", expected="CONTENT_UNREADABLE")
            install = root / "bin"
            call("install", "--directory", str(install))
            assert call("list", alternate=install / "foil")["boards"] == []
            call("install", "--directory", str(install))
            call("uninstall", "--directory", str(install))
            assert not (install / "foil").exists()
            third_party = install / "foil"
            third_party.write_text("third party command")
            call("install", "--directory", str(install), expected="INSTALL_CONFLICT")
            assert third_party.read_text() == "third party command"
        finally:
            for board in boards:
                call("close", board)
    report = ROOT / f"build/agent-cli-results-{int(time.time())}.json"
    report.write_text(json.dumps({"app": str(APP), "updates": measurements}, indent=2) + "\n")
    print(f"PASS real CLI: four commands, retry after close, revisions, same-path updates, warnings, isolation, install/upgrade/uninstall/conflict; {report}")


if __name__ == "__main__":
    main()
