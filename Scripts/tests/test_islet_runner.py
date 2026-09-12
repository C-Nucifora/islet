import argparse
import importlib.util
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest.mock import patch

SCRIPT = Path(__file__).resolve().parents[1] / "test-islet.py"
spec = importlib.util.spec_from_file_location("islet_test_runner", SCRIPT)
runner = importlib.util.module_from_spec(spec)
spec.loader.exec_module(runner)


class TestRunnerTests(unittest.TestCase):
    def test_empty_test_domain_does_not_require_deletion(self):
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder)
            (root / "Islet.xcodeproj").mkdir()
            real_popen = subprocess.Popen

            def command_result(command, **kwargs):
                self.assertEqual(command, ["pgrep", "-x", "Islet"])
                return subprocess.CompletedProcess(command, 1, stdout=b"", stderr=b"")

            def start_fake_build(command, **kwargs):
                return real_popen(["/usr/bin/true"], start_new_session=True)

            with patch.object(runner, "__file__", str(root / "Scripts/test-islet.py")), \
                    patch.object(runner, "preference_domain", return_value={}), \
                    patch.object(runner, "process_snapshot", return_value={}), \
                    patch.object(runner.subprocess, "run", side_effect=command_result), \
                    patch.object(runner.subprocess, "Popen", side_effect=start_fake_build):
                status = runner.run(argparse.Namespace(
                    derived_data=None, xcodebuild_args=[], timeout=2))
            self.assertEqual(status, 0)

    def test_timeout_stops_owned_build_and_leaves_existing_process_alive(self):
        with tempfile.TemporaryDirectory() as folder:
            executable = Path(folder) / "xcodebuild"
            subprocess.run(
                ["xcrun", "clang", "-x", "c", "-o", str(executable), "-"],
                input=b"#include <unistd.h>\nint main(void) { sleep(30); return 0; }\n",
                check=True, capture_output=True, timeout=30)
            unrelated = subprocess.Popen([str(executable), "30"], start_new_session=True)
            owned = None
            try:
                previous_pids = set(runner.process_snapshot())
                owned = subprocess.Popen([str(executable), "30"], start_new_session=True)
                status = runner.wait_for_test_run(owned, 0.05, previous_pids, Path(folder) / "data")
                self.assertEqual(status, 124)
                self.assertIsNotNone(owned.poll())
                self.assertIsNone(unrelated.poll())
            finally:
                for process in (owned, unrelated):
                    if process is not None:
                        if process.poll() is None:
                            process.kill()
                        process.wait(timeout=5)

    def test_production_preference_change_fails_without_exposing_values(self):
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder)
            (root / "Islet.xcodeproj").mkdir()
            real_popen = subprocess.Popen
            snapshots = [{"private": "before"}, None, {"private": "do-not-print"}]
            with patch.object(runner, "__file__", str(root / "Scripts/test-islet.py")), \
                    patch.object(runner, "preference_domain", side_effect=snapshots), \
                    patch.object(runner, "process_snapshot", return_value={}), \
                    patch.object(runner.subprocess, "run", return_value=subprocess.CompletedProcess([], 1)), \
                    patch.object(runner.subprocess, "Popen", side_effect=lambda *a, **k: real_popen(
                        ["/usr/bin/true"], start_new_session=True)):
                with self.assertRaisesRegex(RuntimeError, "Production preferences changed") as error:
                    runner.run(argparse.Namespace(derived_data=None, xcodebuild_args=[], timeout=2))
            self.assertNotIn("do-not-print", str(error.exception))


if __name__ == "__main__":
    unittest.main()
