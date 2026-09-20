import argparse
from contextlib import contextmanager
import fcntl
import importlib.util
from pathlib import Path
import plistlib
import subprocess
import tempfile
import unittest
from unittest.mock import Mock, patch

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
                    patch.object(runner.tempfile, "gettempdir", return_value=folder), \
                    patch.object(runner, "preference_domain", return_value={}), \
                    patch.object(runner, "process_snapshot", return_value={}), \
                    patch.object(runner.subprocess, "run", side_effect=command_result), \
                    patch.object(runner.subprocess, "Popen", side_effect=start_fake_build):
                status = runner.run(argparse.Namespace(
                    derived_data=None, xcodebuild_args=[], timeout=2))
            self.assertEqual(status, 0)

    def test_concurrent_run_stops_before_reading_preferences_or_starting_build(self):
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder)
            (root / "Islet.xcodeproj").mkdir()
            lock_path = root / f"islet-app-hosted-tests-{runner.os.getuid()}.lock"
            with lock_path.open("a") as existing_run:
                fcntl.flock(existing_run, fcntl.LOCK_EX | fcntl.LOCK_NB)
                with patch.object(runner, "__file__", str(root / "Scripts/test-islet.py")), \
                        patch.object(runner.tempfile, "gettempdir", return_value=folder), \
                        patch.object(runner, "preference_domain") as preferences, \
                        patch.object(runner.subprocess, "run") as command, \
                        patch.object(runner.subprocess, "Popen") as build:
                    for coexist_pid in (None, 42):
                        with self.assertRaisesRegex(RuntimeError, "Another Islet test run"):
                            runner.run(argparse.Namespace(
                                derived_data=None, xcodebuild_args=[], timeout=2,
                                coexist_with_pid=coexist_pid))
                preferences.assert_not_called()
                command.assert_not_called()
                build.assert_not_called()

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
                    patch.object(runner.tempfile, "gettempdir", return_value=folder), \
                    patch.object(runner, "preference_domain", side_effect=snapshots), \
                    patch.object(runner, "process_snapshot", return_value={}), \
                    patch.object(runner.subprocess, "run", return_value=subprocess.CompletedProcess([], 1)), \
                    patch.object(runner.subprocess, "Popen", side_effect=lambda *a, **k: real_popen(
                        ["/usr/bin/true"], start_new_session=True)):
                with self.assertRaisesRegex(RuntimeError, "Production preferences changed") as error:
                    runner.run(argparse.Namespace(derived_data=None, xcodebuild_args=[], timeout=2))
            self.assertNotIn("do-not-print", str(error.exception))


class CoexistenceTests(unittest.TestCase):
    @contextmanager
    def fixture(self, pid=42, running_pids=b"42\n", domain="dev.islet"):
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder)
            (root / "Islet.xcodeproj").mkdir()
            contents = root / "Installed Islet.app/Contents"
            (contents / "MacOS").mkdir(parents=True)
            executable = str(contents / "MacOS/Islet")
            with (contents / "Info.plist").open("wb") as source:
                plistlib.dump({"CFBundleIdentifier": domain, "CFBundleExecutable": "Islet"}, source)

            def command_result(command, **kwargs):
                if command == ["pgrep", "-x", "Islet"]:
                    return subprocess.CompletedProcess(command, 0 if running_pids else 1,
                                                       stdout=running_pids)
                if command == ["ps", "-p", "42", "-o", "lstart="]:
                    return subprocess.CompletedProcess(command, 0, stdout="Sat Sep 19 12:00:00 2026\n")
                if command == ["defaults", "delete", runner.TEST_DOMAIN]:
                    return subprocess.CompletedProcess(command, 0)
                self.fail(f"Unexpected command: {command}")

            with patch.object(runner, "__file__", str(root / "Scripts/test-islet.py")), \
                    patch.object(runner.tempfile, "gettempdir", return_value=folder), \
                    patch.object(runner, "preference_domain", return_value={}) as preferences, \
                    patch.object(runner, "process_snapshot", return_value={42: executable}), \
                    patch.object(runner.subprocess, "run", side_effect=command_result) as command, \
                    patch.object(runner.subprocess, "Popen", return_value=Mock(pid=43)) as build, \
                    patch.object(runner, "wait_for_test_run", return_value=0) as wait:
                args = argparse.Namespace(derived_data=None, xcodebuild_args=[], timeout=2,
                                          coexist_with_pid=pid)
                yield args, preferences, build, wait, command, executable

    def test_default_still_rejects_running_app_before_preferences_or_build(self):
        with self.fixture(pid=None) as (args, preferences, build, _, _, _):
            with self.assertRaisesRegex(RuntimeError, "Quit Islet"):
                runner.run(args)
            preferences.assert_not_called()
            build.assert_not_called()

    def test_opt_in_preserves_runner_configuration_cleanup_and_previous_pid(self):
        with self.fixture() as (args, preferences, build, wait, command, _):
            preferences.side_effect = [{}, {"old-test-setting": True}, {}]
            self.assertEqual(runner.run(args), 0)
            invocation = build.call_args.args[0]
            self.assertEqual(invocation[invocation.index("-configuration") + 1], "Testing")
            self.assertEqual(invocation[invocation.index("-parallel-testing-enabled") + 1], "NO")
            self.assertTrue(build.call_args.kwargs["start_new_session"])
            self.assertEqual(wait.call_args.args[1], 2)
            self.assertEqual(wait.call_args.args[2], {42})
            command.assert_any_call(["defaults", "delete", runner.TEST_DOMAIN], check=True,
                                    capture_output=True, timeout=10)
            self.assertEqual([call.args[0] for call in preferences.call_args_list],
                             [runner.PRODUCTION_DOMAIN, runner.TEST_DOMAIN, runner.PRODUCTION_DOMAIN])

    def test_missing_unapproved_or_additional_process_is_rejected(self):
        for running_pids in (b"", b"43\n", b"42\n43\n"):
            with self.subTest(running_pids=running_pids), self.fixture(running_pids=running_pids) as fixture:
                args, preferences, build, _, _, _ = fixture
                with self.assertRaisesRegex(RuntimeError, "exactly the approved Islet PID"):
                    runner.run(args)
                preferences.assert_not_called()
                build.assert_not_called()

    def test_test_host_cannot_be_approved_as_production(self):
        with self.fixture(domain="dev.islet.tests") as (args, preferences, build, _, _, _):
            with self.assertRaisesRegex(RuntimeError, "production application identity"):
                runner.run(args)
            preferences.assert_not_called()
            build.assert_not_called()

    def test_app_inside_test_output_cannot_be_approved(self):
        with self.fixture() as (args, preferences, build, _, _, executable):
            args.derived_data = str(Path(executable).parents[3])
            with self.assertRaisesRegex(RuntimeError, "outside test DerivedData"):
                runner.run(args)
            preferences.assert_not_called()
            build.assert_not_called()

    def test_preference_changes_still_fail_without_exposing_values(self):
        with self.fixture() as (args, preferences, _, _, _, _):
            preferences.side_effect = [{"private": "before"}, {}, {"private": "do-not-print"}]
            with self.assertRaisesRegex(RuntimeError, "Production preferences changed") as error:
                runner.run(args)
            self.assertNotIn("do-not-print", str(error.exception))

    def test_restarted_original_is_not_reported_as_success(self):
        with self.fixture() as (args, _, _, _, _, executable):
            with patch.object(runner, "coexistence_identity", side_effect=[
                (executable, "before"), (executable, "before"), (executable, "after"),
            ]):
                with self.assertRaisesRegex(RuntimeError, "process changed during testing"):
                    runner.run(args)

    def test_preexisting_islet_is_excluded_from_cleanup_even_in_owned_group(self):
        processes = {42: "/test/DerivedData/Islet", 43: "/test/DerivedData/Islet"}
        with patch.object(runner, "process_snapshot", return_value=processes), \
                patch.object(runner.os, "getpgid", return_value=7) as group:
            self.assertEqual(runner.owned_processes(7, {42}, Path("/test/DerivedData")), [43])
            group.assert_called_once_with(43)


if __name__ == "__main__":
    unittest.main()
