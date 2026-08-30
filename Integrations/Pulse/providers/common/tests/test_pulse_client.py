from __future__ import annotations

import base64
import importlib.util
import os
from pathlib import Path
import tempfile
import unittest


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


if __name__ == "__main__":
    unittest.main()
