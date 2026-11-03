#!/usr/bin/env python3
"""Offline CLI contracts; no user installation or credentials are written."""
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile

cli = Path(sys.argv[1]).resolve() if len(sys.argv) > 1 else Path("build/Build/Products/Debug/foofoil.app/Contents/MacOS/foil").resolve()
with tempfile.TemporaryDirectory(prefix="foil-cli-contract-") as directory:
    credential = Path(directory) / "must-not-exist.json"
    env = dict(os.environ, FOIL_APP=str(Path(directory) / "absent.app"), FOIL_SESSION=str(credential))
    def call(*arguments, ok=True, code=None):
        result = subprocess.run([str(cli), *arguments], env=env, capture_output=True, text=True, timeout=5)
        assert (result.returncode == 0) == ok, (arguments, result.stdout, result.stderr)
        if code:
            assert json.loads(result.stdout)["error"] == code, result.stdout
        assert not credential.exists(), "Offline command created credentials"
        return result.stdout
    assert "foil [open] FILE" in call()
    call("--help")
    assert json.loads(call("--version"))["protocol_version"] == "1"
    schema = json.loads(call("schema"))
    assert schema["schema_version"] == 2
    for command in schema["commands"]:
        call("schema", command)
        call("help", command)
    for topic in ["start", "presentation", "reading", "windows", "media", "privacy", "config", "terminal", "integration", "troubleshooting"]:
        assert 0 < len(call("guide", topic)) < 8000
    call("doctor", "--json")
    call("media", "unknown", ok=False, code="UNKNOWN_COMMAND")
    # Both forms must pass the same parsing and reach the same absent-app error.
    for args in [["document.pdf"], ["--url", "https://example.com"], ["--directory", "./notes"], ["--clipboard"], ["--", "list"]]:
        implicit = json.loads(call(*args, ok=False))
        explicit = json.loads(call("open", *args, ok=False))
        assert implicit["error"] == explicit["error"], (args, implicit, explicit)
    call("list", "unexpected", ok=False, code="INVALID_ARGUMENTS")
    for arguments in [
        ["inspect", "id", "--incognito"],
        ["read", "id", "--limit", "3001"],
        ["read", "id", "--offset", "-1"],
        ["read", "id", "--limit", "0"],
        ["read", "id", "--limit", "2", "--limit", "3"],
        ["navigate", "id", "--page", "0", "--content-version", "v"],
        ["navigate", "id", "--page", "1", "--line", "2", "--content-version", "v"],
        ["media", "seek", "id", "--to", "1", "--by", "2"],
        ["open", "file", "--url", "https://example.com"],
        ["file", "--url", "https://example.com"],
        ["--unknown"],
        ["set", "id", "opacity", "nan"],
        ["set", "id", "opacity", "0.1"],
        ["export", "id", "--format", "original", "--output", "relative"],
        ["wait", "id", "--operation", "op"],
        ["wait", "id", "--timeout", "-1"],
        ["close", "id", "--force"],
    ]:
        call(*arguments, ok=False, code="INVALID_ARGUMENTS")
    call("skill", "install", ok=False, code="TARGET_REQUIRED")
    print(f"Passed: {len(schema['commands'])} schemas/help entries, 10 guides, offline version/doctor, and invalid argument matrix")
