from __future__ import annotations

from contextlib import redirect_stderr
import importlib.util
import io
from pathlib import Path
import tempfile
import unittest


MODULE_PATH = Path(__file__).resolve().parents[1] / "rclone_provider.py"
SPEC = importlib.util.spec_from_file_location("rclone_provider", MODULE_PATH)
assert SPEC and SPEC.loader
rclone = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(rclone)


class FakeRC:
    def __init__(self, responses: dict[tuple[str, str | None], dict]) -> None:
        self.responses = responses
        self.calls: list[tuple[str, str | None]] = []

    def call(self, method: str, parameters: dict | None = None) -> dict:
        group = parameters.get("group") if parameters else None
        self.calls.append((method, group))
        return self.responses.get((method, group), {})


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
        self.active: set[str] = set()
        self.removed: list[str] = []

    def action(self, path: Path, action_id: str = "reveal") -> dict | None:
        if not path.exists():
            return None
        self.active.add(action_id)
        return {
            "id": action_id,
            "title": "Reveal in Finder",
            "url": "http://127.0.0.1/x",
        }

    def clear(self) -> None:
        self.active.clear()

    def remove(self, action_id: str) -> None:
        self.active.discard(action_id)
        self.removed.append(action_id)

    def close(self) -> None:
        pass


def fixture(transferring: list[dict], transferred: list[dict] | None = None) -> FakeRC:
    return FakeRC(
        {
            ("job/list", None): {
                "executeId": "instance-a",
                "jobids": [7, 99],
                "running_ids": [7],
                "finished_ids": [99],
            },
            ("core/stats", "job/7"): {"transferring": transferring},
            ("core/transferred", "job/7"): {"transferred": transferred or []},
        }
    )


class RcloneProviderTests(unittest.TestCase):
    def provider(
        self,
        rc: FakeRC,
        state: dict | None = None,
        reveal_root: Path | None = None,
        clock=None,
    ) -> tuple[rclone.RcloneProvider, FakePulse]:
        pulse = FakePulse()
        return (
            rclone.RcloneProvider(
                rc,
                pulse,
                FakeReveal(),
                reveal_root,
                state or {"completedAfter": 0},
                clock=clock,
            ),
            pulse,
        )

    def test_duplicate_file_names_in_different_paths_have_independent_ids(self) -> None:
        rc = fixture(
            [
                {"name": "one/report.pdf", "bytes": 10, "size": 100, "percentage": 10},
                {"name": "two/report.pdf", "bytes": 20, "size": 100, "percentage": 20},
            ]
        )
        provider, pulse = self.provider(rc)
        provider.observe()
        identifiers = [command["activity"]["id"] for command in pulse.commands]
        self.assertEqual(len(set(identifiers)), 2)
        self.assertTrue(
            all(
                "report.pdf" in command["activity"]["title"]
                for command in pulse.commands
            )
        )

    def test_top_level_cli_transfer_uses_global_stats_without_an_async_job(self) -> None:
        rc = FakeRC(
            {
                ("job/list", None): {"executeId": "instance-a", "jobids": []},
                ("core/stats", "global_stats"): {
                    "transferring": [
                        {
                            "name": "archive/top-level.bin",
                            "bytes": 25,
                            "size": 100,
                            "percentage": 25,
                        }
                    ]
                },
                ("core/transferred", None): {"transferred": []},
            }
        )
        provider, pulse = self.provider(rc)

        provider.observe()

        self.assertEqual(len(pulse.commands), 1)
        self.assertEqual(pulse.commands[0]["activity"]["progress"], 0.25)
        self.assertIn(("core/stats", "global_stats"), rc.calls)

    def test_same_name_global_and_async_job_transfers_have_independent_ids(self) -> None:
        rc = FakeRC(
            {
                ("job/list", None): {
                    "executeId": "instance-a",
                    "runningIds": [7],
                },
                ("core/stats", "job/7"): {
                    "transferring": [
                        {"name": "same.bin", "bytes": 10, "size": 100}
                    ]
                },
                ("core/transferred", "job/7"): {"transferred": []},
                ("core/stats", "global_stats"): {
                    "transferring": [
                        {"name": "same.bin", "bytes": 70, "size": 100}
                    ]
                },
                # rclone's aggregate transfer map is keyed by name, so one of the two
                # same-name rows is absent here. Group-specific queries retain both.
                ("core/stats", None): {
                    "transferring": [
                        {
                            "name": "same.bin",
                            "bytes": 10,
                            "size": 100,
                            "group": "job/7",
                        }
                    ]
                },
                ("core/transferred", None): {"transferred": []},
            }
        )
        provider, pulse = self.provider(rc)

        provider.observe()

        identifiers = [command["activity"]["id"] for command in pulse.commands]
        self.assertEqual(len(set(identifiers)), 2)
        self.assertEqual(
            {command["activity"]["progress"] for command in pulse.commands},
            {0.1, 0.7},
        )

    def test_finished_rc_housekeeping_jobs_are_not_polled_as_transfers(self) -> None:
        provider, _ = self.provider(
            fixture([{"name": "live.bin", "bytes": 1, "size": 2}])
        )

        provider.observe()

        self.assertNotIn(("core/stats", "job/99"), provider.rc.calls)
        self.assertNotIn(("core/transferred", "job/99"), provider.rc.calls)

    def test_progress_budget_rotates_across_large_transfer_sets(self) -> None:
        transfers = [
            {"name": f"batch/file-{index}.bin", "bytes": 1, "size": 2}
            for index in range(20)
        ]
        provider, pulse = self.provider(fixture(transfers))
        provider.observe()
        self.assertEqual(len(pulse.commands), 12)
        provider.observe()
        self.assertEqual(len(pulse.commands), 20)

    def test_unchanged_active_transfer_refreshes_before_expiry(self) -> None:
        now = [1_000.0]
        provider, pulse = self.provider(
            fixture([{"name": "live.bin", "bytes": 1, "size": 2}]),
            clock=lambda: now[0],
        )

        provider.observe()
        now[0] += 29
        provider.observe()
        now[0] += 1
        provider.observe()

        self.assertEqual(len(pulse.commands), 2)
        self.assertIn("expiresAt", pulse.commands[-1]["activity"])

    def test_restart_recovery_republishes_active_and_ends_missing_cached_id(
        self,
    ) -> None:
        missing = rclone.opaque_id("old-instance", 2, "gone.bin")
        rc = fixture([{"name": "live.bin", "bytes": 4, "size": 8}])
        provider, pulse = self.provider(
            rc, {"published": [missing], "completedAfter": 0}
        )
        provider.observe()
        self.assertEqual(pulse.ended, [(missing, rclone.SOURCE)])
        self.assertEqual(pulse.commands[0]["activity"]["progress"], 0.5)

    def test_failed_transfer_publishes_expiring_failure_without_error_details(
        self,
    ) -> None:
        record = {
            "name": "private/failure.bin",
            "bytes": 3,
            "size": 9,
            "timestamp": 1000,
            "error": "/Users/private/path: permission denied",
            "jobid": 7,
        }
        provider, pulse = self.provider(fixture([], [record]))
        provider.observe()
        command = pulse.commands[0]
        self.assertEqual(command["operation"], "event")
        self.assertEqual(command["activity"]["state"], "failed")
        self.assertNotIn("/Users/private", str(command))

    def test_current_rclone_completion_uses_completed_at_and_group(self) -> None:
        record = {
            "bytes": 8_388_608,
            "checked": False,
            "completed_at": "2026-08-31T07:57:17.8845+10:00",
            "error": "",
            "group": "job/7",
            "name": "review.bin",
            "size": 8_388_608,
            "started_at": "2026-08-31T07:57:17.868719+10:00",
            "what": "transferring",
        }
        rc = FakeRC(
            {
                ("job/list", None): {
                    "executeId": "instance-a",
                    "finishedIds": [7],
                    "runningIds": [],
                },
                ("core/stats", "global_stats"): {},
                ("core/transferred", None): {"transferred": [record]},
            }
        )
        provider, pulse = self.provider(rc)

        provider.observe()

        self.assertEqual(len(pulse.commands), 1)
        self.assertEqual(pulse.commands[0]["operation"], "event")
        self.assertEqual(pulse.commands[0]["activity"]["state"], "succeeded")
        self.assertEqual(
            pulse.commands[0]["activity"]["id"],
            rclone.opaque_id("instance-a", 7, "review.bin"),
        )
        self.assertEqual(provider.completed_after, 1_788_127_037_884)

    def test_restart_recovery_deduplicates_current_rclone_completion(self) -> None:
        record = {
            "bytes": 3,
            "checked": False,
            "completed_at": "2026-08-31T07:57:17.884500+10:00",
            "error": "permission denied",
            "group": "job/7",
            "name": "failure.bin",
            "size": 9,
            "started_at": "2026-08-31T07:57:16+10:00",
            "what": "transferring",
        }
        responses = {
            ("job/list", None): {
                "executeId": "instance-a",
                "finishedIds": [7],
                "runningIds": [],
            },
            ("core/stats", "global_stats"): {},
            ("core/transferred", None): {"transferred": [record]},
        }
        provider, pulse = self.provider(
            FakeRC(responses), {"completedAfter": 1_788_127_037_883}
        )

        provider.observe()
        recovered_state = provider.persisted(True)
        restarted, restarted_pulse = self.provider(FakeRC(responses), recovered_state)
        restarted.observe()

        self.assertEqual(len(pulse.commands), 1)
        self.assertEqual(pulse.commands[0]["activity"]["state"], "failed")
        self.assertEqual(restarted_pulse.commands, [])

    def test_cancelled_or_removed_active_transfer_is_ended(self) -> None:
        identifier = rclone.opaque_id("instance-a", 7, "cancelled.bin")
        provider, pulse = self.provider(
            fixture([]), {"published": [identifier], "completedAfter": 0}
        )
        provider.observe()
        self.assertEqual(pulse.ended, [(identifier, rclone.SOURCE)])

    def test_inaccessible_or_escaping_reveal_paths_get_no_action(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            rc = fixture(
                [
                    {"name": "missing.bin", "bytes": 1, "size": 2},
                    {"name": "../escape.bin", "bytes": 1, "size": 2},
                ]
            )
            provider, pulse = self.provider(rc, reveal_root=root)
            provider.observe()
        self.assertTrue(
            all("actions" not in command["activity"] for command in pulse.commands)
        )

    def test_terminal_reveal_mapping_expires_with_the_pulse_event(self) -> None:
        now = [1_000.0]
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / "finished.bin").touch()
            record = {
                "name": "finished.bin",
                "timestamp": 1_000,
                "error": "",
                "jobid": 7,
            }
            provider, _ = self.provider(
                fixture([], [record]), reveal_root=root, clock=lambda: now[0]
            )

            provider.observe()
            reveal = provider.reveal
            self.assertEqual(len(reveal.active), 1)
            action_id = next(iter(reveal.active))
            now[0] += 8
            provider.observe()

        self.assertEqual(reveal.active, set())
        self.assertEqual(reveal.removed, [action_id])

    def test_removed_active_transfer_revokes_only_its_reveal_mapping(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / "active.bin").touch()
            rc = fixture([{"name": "active.bin", "bytes": 1, "size": 2}])
            provider, _ = self.provider(rc, reveal_root=root)

            provider.observe()
            reveal = provider.reveal
            self.assertEqual(len(reveal.active), 1)
            action_id = next(iter(reveal.active))
            rc.responses[("core/stats", "job/7")] = {"transferring": []}
            provider.observe()

        self.assertEqual(reveal.active, set())
        self.assertEqual(reveal.removed, [action_id])

    def test_disable_ends_items_without_observing_rclone(self) -> None:
        identifier = rclone.opaque_id("instance-a", 7, "active.bin")
        rc = fixture([])
        provider, pulse = self.provider(
            rc, {"published": [identifier], "completedAfter": 0}
        )
        provider.disable()
        self.assertEqual(rc.calls, [])
        self.assertEqual(pulse.ended, [(identifier, rclone.SOURCE)])

    def test_concurrent_disable_stops_before_the_next_rc_request(self) -> None:
        enabled = [True]

        class DisablingRC(FakeRC):
            def call(self, method: str, parameters: dict | None = None) -> dict:
                response = super().call(method, parameters)
                if method == "job/list":
                    enabled[0] = False
                return response

        rc = DisablingRC(
            {
                ("job/list", None): {
                    "executeId": "instance-a",
                    "runningIds": [7],
                }
            }
        )
        provider, pulse = self.provider(rc)
        provider.is_enabled = lambda: enabled[0]

        with self.assertRaisesRegex(RuntimeError, "observation disabled"):
            provider.observe()

        self.assertEqual(rc.calls, [("job/list", None)])
        self.assertEqual(pulse.commands, [])

    def test_concurrent_disable_stops_before_publishing_a_completed_poll(self) -> None:
        enabled = [True]

        class DisablingRC(FakeRC):
            def call(self, method: str, parameters: dict | None = None) -> dict:
                response = super().call(method, parameters)
                if method == "core/transferred" and parameters is None:
                    enabled[0] = False
                return response

        rc = DisablingRC(
            {
                ("job/list", None): {
                    "executeId": "instance-a",
                    "runningIds": [],
                },
                ("core/stats", "global_stats"): {
                    "transferring": [
                        {"name": "live.bin", "bytes": 1, "size": 2}
                    ]
                },
                ("core/transferred", None): {"transferred": []},
            }
        )
        provider, pulse = self.provider(rc)
        provider.is_enabled = lambda: enabled[0]

        with self.assertRaisesRegex(RuntimeError, "observation disabled"):
            provider.observe()

        self.assertEqual(pulse.commands, [])


class RcloneClientTests(unittest.TestCase):
    def test_rejects_remote_and_credential_bearing_urls(self) -> None:
        with self.assertRaises(ValueError):
            rclone.RcloneClient("http://example.com:5572")
        with self.assertRaises(ValueError):
            rclone.RcloneClient("http://localhost:5572")
        with self.assertRaises(ValueError):
            rclone.RcloneClient("http://user:secret@127.0.0.1:5572")

    def test_interval_cannot_exceed_the_active_heartbeat_window(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            state_file = Path(directory) / "state.json"
            accepted = rclone.main(
                [
                    "--disable",
                    "--interval",
                    "30",
                    "--state-file",
                    str(state_file),
                ]
            )
            self.assertEqual(accepted, 0)

            for invalid in ("30.001", "nan", "inf"):
                with self.subTest(invalid=invalid), redirect_stderr(io.StringIO()):
                    with self.assertRaises(SystemExit):
                        rclone.main(
                            [
                                "--disable",
                                "--interval",
                                invalid,
                                "--state-file",
                                str(state_file),
                            ]
                        )


if __name__ == "__main__":
    unittest.main()
