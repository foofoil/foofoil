#!/usr/bin/env python3
"""Verify build-plugin cache recovery without compiling Swift or signing bundles."""
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest


class PluginBuildTests(unittest.TestCase):
    def check_build(self, failure, retry_failure=False, configuration="debug"):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            shutil.copy2(Path(__file__).resolve().parents[1] / "build-plugin", root)
            (root / "scripts").mkdir()
            (root / "scripts/build-ffmpeg").write_text("#!/bin/sh\nexit 0\n")
            (root / "scripts/build-ffmpeg").chmod(0o755)
            (root / "Bundle").mkdir()
            (root / "ThirdParty").mkdir()
            (root / "Bundle/Info.plist").write_text("fixture")
            (root / "ExtensionManifest.json").write_text("{}")
            tools = root / "tools"
            tools.mkdir()
            swift = tools / "swift"
            swift.write_text('''#!/usr/bin/env python3
import os, sys
from pathlib import Path
root = Path(os.environ["FIXTURE_ROOT"])
args = sys.argv[1:]
with (root / "calls").open("a") as stream:
    stream.write(" ".join(args) + "\\n")
if args[0] == "package":
    sys.exit(0)
if "--show-bin-path" in args:
    print(root / "bin")
    sys.exit(0)
attempt = root / "attempt"
retry = attempt.exists()
attempt.touch()
if (not retry and os.environ["FAILURE"]) or (retry and os.environ["RETRY_FAILURE"]):
    print(os.environ["FAILURE"] if not retry else "retry failed")
    sys.exit(42)
(root / "bin").mkdir(exist_ok=True)
(root / "bin/libVideoExtensionRuntime.dylib").touch()
''')
            swift.chmod(0o755)
            for command in ("codesign", "plutil"):
                tool = tools / command
                tool.write_text("#!/bin/sh\nexit 0\n")
                tool.chmod(0o755)
            env = dict(os.environ, PATH=f"{tools}:{os.environ['PATH']}",
                       FIXTURE_ROOT=str(root), TMPDIR=str(root), FAILURE=failure,
                       RETRY_FAILURE="1" if retry_failure else "")
            result = subprocess.run([str(root / "build-plugin"), str(root / "output"),
                                     "-", configuration], env=env, capture_output=True, text=True)
            calls = (root / "calls").read_text().splitlines()
            return result, calls

    missing_context = "failed to deserialize Info.plist task context: No such file or directory (2)"

    def test_success_does_not_clean(self):
        result, calls = self.check_build("")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(len(calls), 2)
        self.assertFalse(any(call.startswith("package") for call in calls))

    def test_missing_context_retries_debug_and_release(self):
        for configuration in ("debug", "release"):
            with self.subTest(configuration=configuration):
                result, calls = self.check_build(self.missing_context, configuration=configuration)
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual(len(calls), 4)
                self.assertTrue(calls[1].startswith("package "))
                self.assertTrue(calls[1].endswith(" clean"))
                self.assertIn("--scratch-path", calls[1])
                self.assertEqual(calls[0], calls[2])
                self.assertIn(f"--configuration {configuration}", calls[2])
                self.assertIn(self.missing_context, result.stdout)

    def test_compile_error_does_not_retry(self):
        result, calls = self.check_build("error: ordinary compiler error")
        self.assertEqual(result.returncode, 42)
        self.assertEqual(len(calls), 1)
        self.assertIn("ordinary compiler error", result.stdout)

    def test_retry_failure_stops(self):
        result, calls = self.check_build(self.missing_context, retry_failure=True)
        self.assertEqual(result.returncode, 42)
        self.assertEqual(len(calls), 3)
        self.assertIn("retry failed", result.stdout)


if __name__ == "__main__":
    unittest.main()
