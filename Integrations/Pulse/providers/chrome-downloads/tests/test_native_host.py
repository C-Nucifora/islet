from __future__ import annotations

from datetime import datetime, timezone
import importlib.util
from pathlib import Path
import tempfile
import unittest
from unittest import mock
from urllib import error, request


MODULE_PATH = Path(__file__).resolve().parents[1] / "native_host.py"
SPEC = importlib.util.spec_from_file_location("chrome_native_host", MODULE_PATH)
assert SPEC and SPEC.loader
host = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(host)


class FakePulse:
    def __init__(self) -> None:
        self.commands: list[dict] = []
        self.ended: list[tuple[str, str]] = []

    def send(self, command: dict) -> dict:
        self.commands.append(command)
        return {"ok": True}

    def end(self, identifier: str, source: str) -> dict:
        self.ended.append((identifier, source))
        return {"ok": True}


class FakeReveal:
    def __init__(self) -> None:
        self.paths: list[Path] = []
        self.action_ids: list[str] = []
        self.expiries: list[float | None] = []
        self.removed: list[str] = []

    def action(
        self,
        path: Path,
        action_id: str = "reveal",
        expires_in: float | None = None,
    ) -> dict | None:
        self.paths.append(path)
        self.action_ids.append(action_id)
        self.expiries.append(expires_in)
        if not path.exists():
            return None
        return {
            "id": action_id,
            "title": "Reveal in Finder",
            "url": "http://127.0.0.1/x",
        }

    def clear(self) -> None:
        self.paths.clear()

    def remove(self, action_id: str) -> None:
        self.removed.append(action_id)

    def expire(self, _action_id: str, expires_in: float) -> bool:
        self.expiries.append(expires_in)
        return True

    def close(self) -> None:
        pass


class ChromeNativeHostTests(unittest.TestCase):
    profile = "12345678-1234-4123-8123-123456789abc"

    def provider(self) -> tuple[host.ChromeDownloadProvider, FakePulse, FakeReveal]:
        pulse = FakePulse()
        reveal = FakeReveal()
        return host.ChromeDownloadProvider(pulse, reveal), pulse, reveal

    def message(self, identifier: int, **changes: object) -> dict:
        item = {
            "id": identifier,
            "filename": "/not/accessible/report.pdf",
            "bytesReceived": 25,
            "totalBytes": 100,
            "state": "in_progress",
            "error": "",
            "exists": True,
        }
        item.update(changes)
        return {"kind": "upsert", "profileID": self.profile, "item": item}

    def test_duplicate_names_produce_independent_pulse_identifiers(self) -> None:
        provider, pulse, _ = self.provider()
        provider.command_for(self.message(1, filename="/one/report.pdf"))
        provider.command_for(self.message(2, filename="/two/report.pdf"))
        identifiers = [command["activity"]["id"] for command in pulse.commands]
        self.assertEqual(len(set(identifiers)), 2)
        self.assertTrue(
            all(
                command["activity"]["title"] == "Downloading report.pdf"
                for command in pulse.commands
            )
        )

    def test_failure_is_a_high_priority_expiring_event(self) -> None:
        provider, pulse, _ = self.provider()
        provider.command_for(
            self.message(3, state="interrupted", error="NETWORK_FAILED")
        )
        command = pulse.commands[0]
        self.assertEqual(command["operation"], "event")
        self.assertEqual(command["activity"]["state"], "failed")
        self.assertEqual(command["activity"]["priority"], "high")

    def test_cancellation_ends_without_publishing_failure(self) -> None:
        provider, pulse, _ = self.provider()
        provider.command_for(
            self.message(4, state="interrupted", error="USER_CANCELED")
        )
        self.assertEqual(pulse.commands, [])
        self.assertEqual(pulse.ended[0][1], host.SOURCE)

    def test_cancellation_revokes_its_reveal_action(self) -> None:
        provider, _, reveal = self.provider()
        with tempfile.NamedTemporaryFile() as temporary:
            provider.command_for(self.message(8, filename=temporary.name))
            action_id = reveal.action_ids[-1]

            provider.command_for(
                self.message(
                    8,
                    filename=temporary.name,
                    state="interrupted",
                    error="USER_CANCELED",
                )
            )

        self.assertEqual(reveal.removed, [action_id])

    def test_missing_active_file_revokes_its_previous_reveal_action(self) -> None:
        provider, _, reveal = self.provider()
        with tempfile.NamedTemporaryFile() as temporary:
            provider.command_for(self.message(9, filename=temporary.name))
            action_id = reveal.action_ids[-1]

            provider.command_for(
                self.message(9, filename=temporary.name, exists=False)
            )

        self.assertEqual(reveal.removed, [action_id])

    def test_inaccessible_file_omits_reveal_action(self) -> None:
        provider, pulse, reveal = self.provider()
        provider.command_for(self.message(5))
        self.assertNotIn("actions", pulse.commands[0]["activity"])
        self.assertEqual(reveal.paths, [Path("/not/accessible/report.pdf")])

    def test_active_download_has_a_bounded_expiry_for_crash_cleanup(self) -> None:
        provider, pulse, _ = self.provider()

        provider.command_for(self.message(7))

        expires_at = pulse.commands[0]["activity"]["expiresAt"]
        expiry = datetime.fromisoformat(expires_at.replace("Z", "+00:00"))
        remaining = (expiry - datetime.now(timezone.utc)).total_seconds()
        self.assertGreater(remaining, 80)
        self.assertLessEqual(remaining, 90)

    def test_existing_file_gets_loopback_reveal_action(self) -> None:
        provider, pulse, reveal = self.provider()
        with tempfile.NamedTemporaryFile() as temporary:
            provider.command_for(
                self.message(6, filename=temporary.name, state="complete")
            )
        command = pulse.commands[0]
        self.assertEqual(command["operation"], "event")
        self.assertEqual(command["activity"]["state"], "succeeded")
        self.assertEqual(command["activity"]["progress"], 1.0)
        action = command["activity"]["actions"][0]
        self.assertTrue(action["url"].startswith("http://127.0.0.1/"))
        self.assertEqual(reveal.expiries[-1], 8)

    def test_terminal_reveal_remains_available_for_full_delayed_event(self) -> None:
        now = [100.0]

        class DelayedPulse(FakePulse):
            received_at: float | None = None

            def send(self, command: dict) -> dict:
                now[0] += 2
                self.received_at = now[0]
                return super().send(command)

        def reveal_is_available(url: str) -> bool:
            try:
                with request.urlopen(url, timeout=1) as response:
                    return response.status == 204
            except error.HTTPError as failure:
                failure.close()
                return False

        pulse = DelayedPulse()
        reveal = host.RevealServer(clock=lambda: now[0])
        provider = host.ChromeDownloadProvider(pulse, reveal)
        try:
            with tempfile.NamedTemporaryFile() as temporary:
                command = provider.command_for(
                    self.message(10, filename=temporary.name, state="complete")
                )
                self.assertIsNotNone(command)
                action_url = command["activity"]["actions"][0]["url"]
                self.assertIsNotNone(pulse.received_at)
                with mock.patch(f"{host.RevealServer.__module__}.subprocess.Popen"):
                    now[0] = pulse.received_at + 7
                    self.assertTrue(reveal_is_available(action_url))
                    now[0] += 1
                    self.assertFalse(reveal_is_available(action_url))
        finally:
            reveal.close()

    def test_rejected_terminal_delivery_revokes_its_reveal_mapping(self) -> None:
        class RejectingPulse(FakePulse):
            def send(self, command: dict) -> dict:
                super().send(command)
                raise host.PulseError("rejected")

        pulse = RejectingPulse()
        reveal = host.RevealServer()
        provider = host.ChromeDownloadProvider(pulse, reveal)
        try:
            with tempfile.NamedTemporaryFile() as temporary:
                with self.assertRaisesRegex(host.PulseError, "rejected"):
                    provider.command_for(
                        self.message(11, filename=temporary.name, state="complete")
                    )
                action_url = pulse.commands[0]["activity"]["actions"][0]["url"]
                with mock.patch(f"{host.RevealServer.__module__}.subprocess.Popen"):
                    with self.assertRaises(error.HTTPError) as failure:
                        request.urlopen(action_url, timeout=1)
                self.assertEqual(failure.exception.code, 404)
                failure.exception.close()
        finally:
            reveal.close()


if __name__ == "__main__":
    unittest.main()
