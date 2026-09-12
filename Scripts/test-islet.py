#!/usr/bin/env python3
"""Run app-hosted tests with an isolated identity and bounded process lifetime."""

import argparse
import fcntl
import math
import os
from pathlib import Path
import plistlib
import signal
import subprocess
import sys
import tempfile
import time

PRODUCTION_DOMAIN = "dev.islet"
TEST_DOMAIN = "dev.islet.tests"
OWNED_PROCESS_NAMES = {"Islet", "xcodebuild", "swift-frontend", "islet-xcode-pulse"}


def preference_domain(domain):
    result = subprocess.run(
        ["defaults", "export", domain, "-"], capture_output=True, timeout=10,
        env={**os.environ, "LC_ALL": "C"},
    )
    if result.returncode:
        if b"does not exist" in result.stderr:
            return None
        raise RuntimeError(f"Could not read preferences domain {domain}")
    return plistlib.loads(result.stdout)


def process_snapshot():
    result = subprocess.run(
        ["ps", "-axo", "pid=,stat=,comm="], capture_output=True, text=True,
        check=True, timeout=10,
    )
    return {
        int(parts[0]): parts[2]
        for line in result.stdout.splitlines()
        if len(parts := line.strip().split(None, 2)) == 3 and not parts[1].startswith("Z")
    }


def owned_processes(group, previous_pids, derived_data):
    owned = []
    for pid, executable in process_snapshot().items():
        if pid in previous_pids or Path(executable).name not in OWNED_PROCESS_NAMES:
            continue
        try:
            in_group = os.getpgid(pid) == group
        except ProcessLookupError:
            continue
        if in_group or executable.startswith(str(derived_data) + os.sep):
            owned.append(pid)
    return owned


def stop_owned_processes(group, previous_pids, derived_data):
    for sig in (signal.SIGTERM, signal.SIGKILL):
        for pid in owned_processes(group, previous_pids, derived_data):
            try:
                os.kill(pid, sig)
            except ProcessLookupError:
                pass
        deadline = time.monotonic() + 2
        while owned_processes(group, previous_pids, derived_data):
            if time.monotonic() >= deadline:
                break
            time.sleep(0.05)
        else:
            return
    raise RuntimeError("Owned test processes have not exited; do not relaunch Islet yet")


def wait_for_test_run(process, timeout, previous_pids, derived_data):
    try:
        return process.wait(timeout=timeout)
    except (subprocess.TimeoutExpired, KeyboardInterrupt):
        stop_owned_processes(process.pid, previous_pids, derived_data)
        process.wait(timeout=10)
        print("Test run stopped after cancellation or its hard timeout.", file=sys.stderr)
        return 124
    finally:
        # AppKit can launch the host outside xcodebuild's process group.
        if owned_processes(process.pid, previous_pids, derived_data):
            stop_owned_processes(process.pid, previous_pids, derived_data)


def run(args):
    root = Path(__file__).resolve().parent.parent
    derived_data = Path(args.derived_data or root / ".build/tests/DerivedData").resolve()
    extra = args.xcodebuild_args
    if extra[:1] == ["--"]:
        extra = extra[1:]
    for option in ("-project", "-workspace", "-scheme", "-configuration",
                   "-derivedDataPath", "-parallel-testing-enabled"):
        if option in extra:
            raise RuntimeError(f"The test runner manages {option}; remove that override")
    if not (root / "Islet.xcodeproj").is_dir():
        raise RuntimeError("Generate Islet.xcodeproj with xcodegen before running tests")

    lock_path = Path(tempfile.gettempdir()) / f"islet-app-hosted-tests-{os.getuid()}.lock"
    with lock_path.open("a") as lock:
        try:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError as error:
            raise RuntimeError("Another Islet test run holds the test lock") from error
        running = subprocess.run(["pgrep", "-x", "Islet"], capture_output=True, timeout=10)
        if running.returncode == 0:
            raise RuntimeError("Quit Islet and wait for other test hosts to exit before testing")
        if running.returncode != 1:
            raise RuntimeError("Could not verify whether Islet is running")

        production_before = preference_domain(PRODUCTION_DOMAIN)
        if preference_domain(TEST_DOMAIN):
            subprocess.run(
                ["defaults", "delete", TEST_DOMAIN], check=True, capture_output=True, timeout=10,
            )
        previous_pids = set(process_snapshot())
        command = [
            "xcodebuild", "-project", str(root / "Islet.xcodeproj"), "-scheme", "Islet",
            "-configuration", "Testing", "-destination", f"platform=macOS,arch={os.uname().machine}",
            "-derivedDataPath", str(derived_data), "-parallel-testing-enabled", "NO",
            "-onlyUsePackageVersionsFromResolvedFile", *extra, "test",
        ]
        process = subprocess.Popen(command, cwd=root, start_new_session=True)
        status = wait_for_test_run(process, args.timeout, previous_pids, derived_data)
        # Compare in memory. Preferences may contain private data; never print their contents.
        if preference_domain(PRODUCTION_DOMAIN) != production_before:
            raise RuntimeError("Production preferences changed during the test run")
        print("Production preferences unchanged.")
        return status


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--timeout", type=float, default=600, help="Hard timeout in seconds")
    parser.add_argument("--derived-data", help="Defaults to this worktree's .build/tests/DerivedData")
    parser.add_argument("xcodebuild_args", nargs=argparse.REMAINDER)
    args = parser.parse_args()
    if not math.isfinite(args.timeout) or args.timeout <= 0:
        parser.error("--timeout must be finite and positive")
    previous_handler = signal.signal(signal.SIGTERM, handle_termination)
    try:
        return run(args)
    except KeyboardInterrupt:
        return 130
    except (RuntimeError, subprocess.SubprocessError, OSError, plistlib.InvalidFileException) as error:
        print(f"Islet tests: {error}", file=sys.stderr)
        return 1
    finally:
        signal.signal(signal.SIGTERM, previous_handler)


def handle_termination(signum, frame):
    raise KeyboardInterrupt


if __name__ == "__main__":
    sys.exit(main())
