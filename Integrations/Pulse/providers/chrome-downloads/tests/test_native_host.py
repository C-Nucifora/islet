from __future__ import annotations

from datetime import datetime, timezone
import importlib.util
from pathlib import Path
import tempfile
import unittest


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

    def action(self, path: Path, action_id: str = "reveal") -> dict | None:
        self.paths.append(path)
        if not path.exists():
            return None
        return {
            "id": action_id,
            "title": "Reveal in Finder",
            "url": "http://127.0.0.1/x",
        }

    def clear(self) -> None:
        self.paths.clear()

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
        provider, pulse, _ = self.provider()
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


if __name__ == "__main__":
    unittest.main()
