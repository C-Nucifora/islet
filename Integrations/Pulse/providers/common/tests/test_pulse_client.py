from __future__ import annotations

import base64
import importlib.util
import os
from pathlib import Path
import tempfile
import unittest
from unittest import mock
from urllib import error, request


MODULE_PATH = Path(__file__).resolve().parents[1] / "pulse_client.py"
SPEC = importlib.util.spec_from_file_location("pulse_client", MODULE_PATH)
assert SPEC and SPEC.loader
pulse_client = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(pulse_client)


class PulseTokenTests(unittest.TestCase):
    def test_reads_private_regular_token(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            support = Path(directory)
            token = base64.b64encode(os.urandom(32)).decode()
            token_path = support / "pulse-token"
            token_path.write_text(token, encoding="utf-8")
            token_path.chmod(0o600)

            self.assertEqual(pulse_client.PulseClient(support)._read_token(), token)

    def test_rejects_symlink_and_oversized_token(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            support = Path(directory)
            target = support / "target"
            target.write_text(
                base64.b64encode(os.urandom(32)).decode(), encoding="utf-8"
            )
            target.chmod(0o600)
            (support / "pulse-token").symlink_to(target)

            with self.assertRaises(pulse_client.PulseError):
                pulse_client.PulseClient(support)._read_token()

            (support / "pulse-token").unlink()
            (support / "pulse-token").write_text("A" * 129, encoding="utf-8")
            (support / "pulse-token").chmod(0o600)
            with self.assertRaises(pulse_client.PulseError):
                pulse_client.PulseClient(support)._read_token()


class RevealServerTests(unittest.TestCase):
    def test_oldest_action_is_evicted_at_capacity(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            paths = [root / f"item-{index}" for index in range(3)]
            for path in paths:
                path.write_text("test", encoding="utf-8")
            reveal = pulse_client.RevealServer(maximum_actions=2)
            try:
                actions = [
                    reveal.action(path, f"reveal-{index}")
                    for index, path in enumerate(paths)
                ]
                self.assertTrue(all(action is not None for action in actions))
                with self.assertRaises(error.HTTPError) as evicted:
                    request.urlopen(actions[0]["url"], timeout=2)
                self.assertEqual(evicted.exception.code, 404)
                with mock.patch.object(pulse_client.subprocess, "Popen") as launch:
                    with request.urlopen(actions[-1]["url"], timeout=2) as response:
                        self.assertEqual(response.status, 204)
                    launch.assert_called_once()
            finally:
                reveal.close()

    def test_remove_revokes_one_reveal_action(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "report.pdf"
            path.touch()
            server = pulse_client.RevealServer()
            try:
                action = server.action(path, "finished-transfer")
                self.assertIsNotNone(action)

                server.remove("finished-transfer")

                with self.assertRaises(error.HTTPError) as failure:
                    request.urlopen(action["url"], timeout=1)
                self.assertEqual(failure.exception.code, 404)
            finally:
                server.close()

    def test_reveal_reports_finder_launch_failure(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "report.pdf"
            path.touch()
            server = pulse_client.RevealServer()
            try:
                action = server.action(path, "failed-reveal")
                self.assertIsNotNone(action)

                with mock.patch.object(
                    pulse_client.subprocess, "Popen", side_effect=OSError
                ):
                    with self.assertRaises(error.HTTPError) as failure:
                        request.urlopen(action["url"], timeout=1)
                self.assertEqual(failure.exception.code, 500)
            finally:
                server.close()

    def test_expired_reveal_action_returns_not_found(self) -> None:
        now = [100.0]
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "report.pdf"
            path.touch()
            server = pulse_client.RevealServer(clock=lambda: now[0])
            try:
                action = server.action(path, "finished-transfer", expires_in=8)
                self.assertIsNotNone(action)

                now[0] += 8

                with self.assertRaises(error.HTTPError) as failure:
                    request.urlopen(action["url"], timeout=1)
                self.assertEqual(failure.exception.code, 404)
            finally:
                server.close()


if __name__ == "__main__":
    unittest.main()
