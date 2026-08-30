#!/usr/bin/env python3
"""Observe rclone's loopback remote-control API and publish transfer state to Pulse."""

from __future__ import annotations

import argparse
import base64
from datetime import datetime, timedelta, timezone
import hashlib
import ipaddress
import json
import math
import os
from pathlib import Path, PurePosixPath
import re
import signal
import sys
import tempfile
import time
from typing import Any, Callable
from urllib.error import HTTPError, URLError
from urllib.parse import urlparse
from urllib.request import HTTPRedirectHandler, ProxyHandler, Request, build_opener

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "common"))
from pulse_client import PulseClient, PulseError, RevealServer, safe_child  # noqa: E402


SOURCE = "rclone"
MAX_RC_RESPONSE = 1024 * 1024
ACTIVE_EXPIRY_SECONDS = 90
ACTIVE_HEARTBEAT_SECONDS = 30
MAX_INTERVAL_SECONDS = ACTIVE_HEARTBEAT_SECONDS
TERMINAL_REVEAL_SECONDS = 8
NANOSECONDS_PER_MILLISECOND = 1_000_000
PUBLIC_OBSERVATION_METHODS = frozenset(
    {"core/stats", "core/transferred", "job/list", "job/status"}
)
_RFC3339 = re.compile(
    r"^(\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2})(?:\.(\d{1,9}))?(Z|[+-]\d{2}:\d{2})$"
)


def active_expiry() -> str:
    expiry = datetime.now(timezone.utc) + timedelta(seconds=ACTIVE_EXPIRY_SECONDS)
    return expiry.replace(microsecond=0).isoformat().replace("+00:00", "Z")


def opaque_id(execute_id: str, scope: int | str, name: str) -> str:
    digest = hashlib.sha256(f"{execute_id}\0{scope}\0{name}".encode()).hexdigest()[:32]
    return f"rclone:{digest}"


def event_id(
    execute_id: str,
    scope: int | str,
    timestamp: int,
    record: dict[str, Any],
) -> str:
    basis = (
        f"{execute_id}\0{scope}\0{record.get('name')}\0{timestamp}\0{record.get('error')}"
    )
    return hashlib.sha256(basis.encode()).hexdigest()


def completion_nanoseconds(record: dict[str, Any]) -> int | None:
    legacy = record.get("timestamp")
    if isinstance(legacy, int) and not isinstance(legacy, bool):
        return legacy * NANOSECONDS_PER_MILLISECOND
    current = record.get("completed_at")
    if not isinstance(current, str):
        return None
    match = _RFC3339.fullmatch(current)
    if match is None:
        return None
    base, fraction, zone = match.groups()
    nanoseconds = int(((fraction or "") + "000000000")[:9])
    normalized = f"{base}{'+00:00' if zone == 'Z' else zone}"
    try:
        completed = datetime.fromisoformat(normalized).astimezone(timezone.utc)
    except ValueError:
        return None
    elapsed = completed - datetime(1970, 1, 1, tzinfo=timezone.utc)
    return (
        (elapsed.days * 86_400 + elapsed.seconds) * 1_000_000_000
        + nanoseconds
    )


def transfer_scope(record: dict[str, Any], fallback: int | str) -> int | str:
    legacy = record.get("jobid")
    if isinstance(legacy, int) and not isinstance(legacy, bool):
        return legacy
    group = record.get("group")
    if not isinstance(group, str) or not group:
        return fallback
    if group == "global_stats":
        return 0
    match = re.fullmatch(r"job/(\d+)", group)
    if match:
        return int(match.group(1))
    return group


def display_name(value: object) -> str:
    if not isinstance(value, str) or not value:
        return "transfer"
    return (PurePosixPath(value).name or "transfer")[:140]


class RcloneClient:
    def __init__(
        self, url: str, user: str | None = None, password: str | None = None
    ) -> None:
        parsed = urlparse(url)
        try:
            is_loopback = ipaddress.ip_address(parsed.hostname or "").is_loopback
        except ValueError:
            is_loopback = False
        if parsed.scheme not in {"http", "https"} or not is_loopback:
            raise ValueError("rclone RC URL must use HTTP(S) on loopback")
        if parsed.username or parsed.password or parsed.query or parsed.fragment:
            raise ValueError(
                "rclone RC URL cannot contain credentials, query, or fragment"
            )
        self.url = url.rstrip("/")
        self.opener = build_opener(ProxyHandler({}), _RejectRedirects)
        self.authorization = None
        if user is not None or password is not None:
            encoded = base64.b64encode(
                f"{user or ''}:{password or ''}".encode()
            ).decode()
            self.authorization = f"Basic {encoded}"

    def call(
        self, method: str, parameters: dict[str, Any] | None = None
    ) -> dict[str, Any]:
        body = json.dumps(parameters or {}, separators=(",", ":")).encode()
        request = Request(
            f"{self.url}/{method}",
            body,
            {"Content-Type": "application/json"},
            method="POST",
        )
        if self.authorization and method not in PUBLIC_OBSERVATION_METHODS:
            request.add_header("Authorization", self.authorization)
        try:
            with self.opener.open(request, timeout=5) as response:
                payload = response.read(MAX_RC_RESPONSE + 1)
        except (HTTPError, URLError, TimeoutError, OSError) as error:
            raise RuntimeError(
                f"rclone RC request failed: {type(error).__name__}"
            ) from error
        if len(payload) > MAX_RC_RESPONSE:
            raise RuntimeError("rclone RC response exceeds 1 MiB")
        try:
            value = json.loads(payload)
        except json.JSONDecodeError as error:
            raise RuntimeError("rclone RC returned invalid JSON") from error
        if not isinstance(value, dict):
            raise RuntimeError("rclone RC response must be an object")
        return value


class _RejectRedirects(HTTPRedirectHandler):
    """Keep loopback RC requests and credentials from following redirects."""

    def redirect_request(
        self,
        request: Request,
        file_pointer: object,
        code: int,
        message: str,
        headers: object,
        new_url: str,
    ) -> None:
        return None


class ObservationDisabled(RuntimeError):
    pass


class StateStore:
    def __init__(self, path: Path) -> None:
        self.path = path
        self.disabled_path = path.with_name(path.name + ".disabled")

    def load(self) -> dict[str, Any]:
        try:
            value = json.loads(self.path.read_text(encoding="utf-8"))
        except (OSError, json.JSONDecodeError):
            now = time.time_ns()
            return {
                "enabled": not self.disabled_path.exists(),
                "published": [],
                "seen": [],
                "completedAfter": now // NANOSECONDS_PER_MILLISECOND,
                "completedAfterNanoseconds": now,
                "completedAtKeys": [],
            }
        if not isinstance(value, dict):
            now = time.time_ns()
            return {
                "enabled": not self.disabled_path.exists(),
                "published": [],
                "seen": [],
                "completedAfter": now // NANOSECONDS_PER_MILLISECOND,
                "completedAfterNanoseconds": now,
                "completedAtKeys": [],
            }
        legacy_watermark = value.get("completedAfter", 0)
        if not isinstance(legacy_watermark, int) or isinstance(legacy_watermark, bool):
            legacy_watermark = 0
        exact_watermark = value.get("completedAfterNanoseconds")
        if not isinstance(exact_watermark, int) or isinstance(exact_watermark, bool):
            exact_watermark = legacy_watermark * NANOSECONDS_PER_MILLISECOND
        return {
            "enabled": not self.disabled_path.exists(),
            "published": [
                item for item in value.get("published", []) if isinstance(item, str)
            ],
            "seen": [item for item in value.get("seen", []) if isinstance(item, str)][
                -512:
            ],
            "completedAfter": legacy_watermark,
            "completedAfterNanoseconds": exact_watermark,
            "completedAtKeys": [
                item
                for item in value.get("completedAtKeys", [])
                if isinstance(item, str)
            ][-512:],
        }

    def save(self, value: dict[str, Any]) -> None:
        value = dict(value)
        value["enabled"] = not self.disabled_path.exists()
        self._ensure_parent()
        descriptor, temporary = tempfile.mkstemp(
            prefix=".rclone-", dir=self.path.parent
        )
        try:
            with os.fdopen(descriptor, "w", encoding="utf-8") as output:
                json.dump(value, output, separators=(",", ":"))
                output.write("\n")
            os.chmod(temporary, 0o600)
            os.replace(temporary, self.path)
        finally:
            try:
                os.unlink(temporary)
            except FileNotFoundError:
                pass

    def set_enabled(self, enabled: bool) -> dict[str, Any]:
        self._ensure_parent()
        if enabled:
            try:
                self.disabled_path.unlink()
            except FileNotFoundError:
                pass
        else:
            self.disabled_path.touch(mode=0o600, exist_ok=True)
            os.chmod(self.disabled_path, 0o600)
        state = self.load()
        self.save(state)
        return state

    def _ensure_parent(self) -> None:
        try:
            self.path.parent.mkdir(mode=0o700, parents=True)
        except FileExistsError:
            pass

    def save_runtime(self, value: dict[str, Any]) -> bool:
        """Update observation state without overwriting a concurrent enable or disable command."""
        enabled = self.load()["enabled"]
        next_value = dict(value)
        next_value["enabled"] = enabled
        self.save(next_value)
        return enabled


class RcloneProvider:
    def __init__(
        self,
        rc: RcloneClient,
        pulse: PulseClient | None = None,
        reveal: RevealServer | None = None,
        reveal_root: Path | None = None,
        state: dict[str, Any] | None = None,
        clock: Callable[[], float] | None = None,
        is_enabled: Callable[[], bool] | None = None,
    ) -> None:
        self.rc = rc
        self.pulse = pulse or PulseClient()
        self.reveal = reveal or RevealServer()
        self.reveal_root = reveal_root
        self.published = set((state or {}).get("published", []))
        self.seen = set((state or {}).get("seen", []))
        state_value = state or {}
        exact_watermark = state_value.get("completedAfterNanoseconds")
        if not isinstance(exact_watermark, int) or isinstance(exact_watermark, bool):
            legacy_watermark = state_value.get("completedAfter", 0)
            if not isinstance(legacy_watermark, int) or isinstance(
                legacy_watermark, bool
            ):
                legacy_watermark = 0
            exact_watermark = legacy_watermark * NANOSECONDS_PER_MILLISECOND
        self.completed_after_nanoseconds = exact_watermark
        self.completed_at_keys = set(state_value.get("completedAtKeys", []))
        self.fingerprints: dict[str, str] = {}
        self.last_published_at: dict[str, float] = {}
        self.reveal_deadlines: dict[str, float] = {}
        self.clock = clock or time.monotonic
        self.is_enabled = is_enabled or (lambda: True)
        self.active_command_budget = 12
        self.rotation = 0

    def observe(self) -> None:
        self._expire_reveals()
        self.active_command_budget = 12
        jobs = self._call("job/list")
        execute_id = jobs.get("executeId")
        if not isinstance(execute_id, str) or not execute_id:
            raise RuntimeError("rclone job/list omitted executeId")
        running_job_ids = jobs.get("running_ids", jobs.get("runningIds", []))
        if not isinstance(running_job_ids, list):
            raise RuntimeError("rclone job/list returned invalid running job IDs")

        active: set[str] = set()
        active_candidates: list[tuple[str, int | str, dict[str, Any]]] = []
        terminal: set[str] = set()
        max_timestamp = self.completed_after_nanoseconds
        keys_at_max_timestamp = set(self.completed_at_keys)

        def consume_completed(records: object, fallback_scope: int | str) -> None:
            nonlocal keys_at_max_timestamp, max_timestamp
            if not isinstance(records, list):
                return
            for record in records:
                if not isinstance(record, dict) or record.get("checked") is True:
                    continue
                timestamp = completion_nanoseconds(record)
                if timestamp is None:
                    continue
                scope = transfer_scope(record, fallback_scope)
                key = event_id(execute_id, scope, timestamp, record)
                if timestamp > max_timestamp:
                    max_timestamp = timestamp
                    keys_at_max_timestamp = {key}
                elif timestamp == max_timestamp:
                    keys_at_max_timestamp.add(key)
                if timestamp < self.completed_after_nanoseconds or (
                    timestamp == self.completed_after_nanoseconds
                    and key in self.completed_at_keys
                ):
                    continue
                if key in self.seen:
                    continue
                identifier = self._publish_terminal(execute_id, scope, record)
                self.seen.add(key)
                if identifier:
                    terminal.add(identifier)

        for raw_job_id in running_job_ids:
            if not isinstance(raw_job_id, int) or isinstance(raw_job_id, bool):
                continue
            status = self._call("job/status", {"jobid": raw_job_id})
            if status.get("finished") is not False:
                continue
            reported_group = status.get("group")
            group_name = (
                reported_group
                if isinstance(reported_group, str) and reported_group
                else f"job/{raw_job_id}"
            )
            group = {"group": group_name}
            scope = transfer_scope({"group": group_name}, raw_job_id)
            stats = self._call("core/stats", group)
            transfers = stats.get("transferring", [])
            if isinstance(transfers, list):
                for transfer in transfers:
                    if (
                        isinstance(transfer, dict)
                        and isinstance(transfer.get("name"), str)
                        and transfer["name"]
                    ):
                        active.add(opaque_id(execute_id, scope, transfer["name"]))
                        active_candidates.append((execute_id, scope, transfer))

            completed = self._call("core/transferred", group).get("transferred", [])
            consume_completed(completed, scope)

        # The aggregate transfer map is keyed by name and can collapse same-name rows from
        # different groups. Query the persistent process's top-level group directly instead.
        global_stats = self._call("core/stats", {"group": "global_stats"})
        global_transfers = global_stats.get("transferring", [])
        if isinstance(global_transfers, list):
            for transfer in global_transfers:
                if (
                    not isinstance(transfer, dict)
                    or not isinstance(transfer.get("name"), str)
                    or not transfer["name"]
                ):
                    continue
                active.add(opaque_id(execute_id, 0, transfer["name"]))
                active_candidates.append((execute_id, 0, transfer))

        global_completed = self._call("core/transferred").get("transferred", [])
        consume_completed(global_completed, 0)

        active_candidates.sort(
            key=lambda candidate: opaque_id(
                candidate[0], candidate[1], candidate[2]["name"]
            )
        )
        if active_candidates:
            start = self.rotation % len(active_candidates)
            ordered = active_candidates[start:] + active_candidates[:start]
            for candidate in ordered:
                self._publish_active(*candidate)
            self.rotation = (start + 12) % len(active_candidates)

        for identifier in self.published - active - terminal:
            self._end(identifier)
        self.published.intersection_update(active)
        self.completed_after_nanoseconds = max_timestamp
        self.completed_at_keys = set(sorted(keys_at_max_timestamp)[-512:])
        if len(self.seen) > 512:
            self.seen = set(sorted(self.seen)[-512:])

    def _publish_active(
        self, execute_id: str, scope: int | str, transfer: dict[str, Any]
    ) -> str | None:
        self._ensure_enabled()
        name = transfer.get("name")
        if not isinstance(name, str) or not name:
            return None
        identifier = opaque_id(execute_id, scope, name)
        progress = self._progress(transfer)
        fingerprint = hashlib.sha256(
            json.dumps(
                [
                    transfer.get("bytes"),
                    transfer.get("size"),
                    transfer.get("percentage"),
                ],
                separators=(",", ":"),
            ).encode()
        ).hexdigest()
        now = self.clock()
        if (
            self.fingerprints.get(identifier) == fingerprint
            and now - self.last_published_at.get(identifier, float("-inf"))
            < ACTIVE_HEARTBEAT_SECONDS
        ):
            return identifier
        if self.active_command_budget == 0:
            return identifier
        activity: dict[str, Any] = {
            "id": identifier,
            "source": SOURCE,
            "title": f"Transferring {display_name(name)}",
            "symbol": "arrow.up.arrow.down.circle.fill",
            "state": "progress",
            "priority": "normal",
            "expiresAt": active_expiry(),
        }
        if progress is not None:
            activity["progress"] = progress
            activity["subtitle"] = f"{round(progress * 100)}%"
        reveal_action_id = self._add_reveal(activity, name, identifier)
        if reveal_action_id:
            self.reveal_deadlines.pop(reveal_action_id, None)
        self.pulse.send({"operation": "update", "activity": activity})
        self.active_command_budget -= 1
        self.fingerprints[identifier] = fingerprint
        self.last_published_at[identifier] = now
        self.published.add(identifier)
        return identifier

    def _publish_terminal(
        self, execute_id: str, scope: int | str, record: dict[str, Any]
    ) -> str | None:
        self._ensure_enabled()
        name = record.get("name")
        if not isinstance(name, str) or not name:
            return None
        identifier = opaque_id(execute_id, scope, name)
        failed = bool(record.get("error"))
        activity: dict[str, Any] = {
            "id": identifier,
            "source": SOURCE,
            "title": f"Transfer {'failed' if failed else 'complete'}: {display_name(name)}",
            "subtitle": "rclone reported an error" if failed else "Complete",
            "symbol": "exclamationmark.circle.fill"
            if failed
            else "checkmark.circle.fill",
            "state": "failed" if failed else "succeeded",
            "priority": "high" if failed else "normal",
        }
        if not failed:
            activity["progress"] = 1.0
        reveal_action_id = self._add_reveal(activity, name, identifier)
        if reveal_action_id:
            self.reveal_deadlines[reveal_action_id] = (
                self.clock() + TERMINAL_REVEAL_SECONDS
            )
        self.pulse.send({"operation": "event", "activity": activity})
        if reveal_action_id:
            self.reveal_deadlines[reveal_action_id] = (
                self.clock() + TERMINAL_REVEAL_SECONDS
            )
        self.fingerprints.pop(identifier, None)
        self.last_published_at.pop(identifier, None)
        self.published.discard(identifier)
        return identifier

    def _call(
        self, method: str, parameters: dict[str, Any] | None = None
    ) -> dict[str, Any]:
        self._ensure_enabled()
        return self.rc.call(method, parameters)

    def _ensure_enabled(self) -> None:
        if not self.is_enabled():
            raise ObservationDisabled("rclone observation disabled")

    def _add_reveal(
        self, activity: dict[str, Any], name: str, identifier: str
    ) -> str | None:
        if self.reveal_root is None:
            return None
        path = safe_child(self.reveal_root, name)
        if path is None:
            return None
        action_id = self._reveal_action_id(identifier)
        action = self.reveal.action(path, action_id)
        if action:
            activity["actions"] = [action]
            return action_id
        return None

    @staticmethod
    def _reveal_action_id(identifier: str) -> str:
        return f"reveal-{identifier[-16:]}"

    def _expire_reveals(self) -> None:
        now = self.clock()
        for action_id, deadline in list(self.reveal_deadlines.items()):
            if deadline <= now:
                self.reveal.remove(action_id)
                self.reveal_deadlines.pop(action_id, None)

    @staticmethod
    def _progress(transfer: dict[str, Any]) -> float | None:
        percentage = transfer.get("percentage")
        if isinstance(percentage, (int, float)):
            return min(1.0, max(0.0, percentage / 100))
        size = transfer.get("size")
        transferred = transfer.get("bytes")
        if (
            isinstance(size, (int, float))
            and size > 0
            and isinstance(transferred, (int, float))
        ):
            return min(1.0, max(0.0, transferred / size))
        return None

    def disable(self) -> None:
        for identifier in list(self.published):
            self._end(identifier)
        self.published.clear()
        self.reveal_deadlines.clear()
        self.reveal.clear()

    def _end(self, identifier: str) -> None:
        try:
            self.pulse.end(identifier, SOURCE)
        except PulseError:
            pass
        self.fingerprints.pop(identifier, None)
        self.last_published_at.pop(identifier, None)
        action_id = self._reveal_action_id(identifier)
        self.reveal_deadlines.pop(action_id, None)
        self.reveal.remove(action_id)

    def persisted(self, enabled: bool) -> dict[str, Any]:
        return {
            "enabled": enabled,
            "published": sorted(self.published),
            "seen": sorted(self.seen)[-512:],
            "completedAfter": self.completed_after,
            "completedAfterNanoseconds": self.completed_after_nanoseconds,
            "completedAtKeys": sorted(self.completed_at_keys)[-512:],
        }

    @property
    def completed_after(self) -> int:
        return self.completed_after_nanoseconds // NANOSECONDS_PER_MILLISECOND

    def close(self) -> None:
        self.disable()
        self.reveal.close()


def parser() -> argparse.ArgumentParser:
    result = argparse.ArgumentParser(description=__doc__)
    result.add_argument(
        "--url", default=os.environ.get("ISLET_RCLONE_RC_URL", "http://127.0.0.1:5572")
    )
    result.add_argument("--interval", type=float, default=2)
    result.add_argument("--reveal-root", type=Path)
    result.add_argument("--once", action="store_true")
    control = result.add_mutually_exclusive_group()
    control.add_argument("--enable", action="store_true")
    control.add_argument("--disable", action="store_true")
    result.add_argument(
        "--state-file",
        type=Path,
        default=Path.home()
        / "Library"
        / "Application Support"
        / "Islet"
        / "pulse-providers"
        / "rclone.json",
    )
    return result


def main(arguments: list[str] | None = None) -> int:
    argument_parser = parser()
    options = argument_parser.parse_args(arguments)
    if not math.isfinite(options.interval) or not (
        1 <= options.interval <= MAX_INTERVAL_SECONDS
    ):
        argument_parser.error(
            f"--interval must be between 1 and {MAX_INTERVAL_SECONDS} seconds"
        )
    store = StateStore(options.state_file)
    pulse = PulseClient()
    if options.enable:
        store.set_enabled(True)
        return 0
    if options.disable:
        state = store.set_enabled(False)
        provider = RcloneProvider(RcloneClient(options.url), pulse=pulse, state=state)
        provider.disable()
        store.save(provider.persisted(False))
        provider.reveal.close()
        return 0

    state = store.load()
    rc = RcloneClient(
        options.url,
        os.environ.get("ISLET_RCLONE_RC_USER"),
        os.environ.get("ISLET_RCLONE_RC_PASS"),
    )
    provider = RcloneProvider(
        rc,
        pulse=pulse,
        reveal_root=options.reveal_root,
        state=state,
        is_enabled=lambda: store.load()["enabled"],
    )
    stopping = False

    def stop(_signal: int, _frame: object) -> None:
        nonlocal stopping
        stopping = True

    signal.signal(signal.SIGINT, stop)
    signal.signal(signal.SIGTERM, stop)
    try:
        while not stopping:
            enabled = store.load()["enabled"]
            if enabled:
                try:
                    provider.observe()
                except ObservationDisabled:
                    provider.disable()
                except (RuntimeError, PulseError) as error:
                    print(str(error), file=sys.stderr)
                enabled = store.save_runtime(provider.persisted(True))
                if not enabled:
                    provider.disable()
                    store.save_runtime(provider.persisted(False))
            else:
                provider.disable()
                store.save_runtime(provider.persisted(False))
            if options.once:
                break
            time.sleep(options.interval)
    finally:
        if stopping:
            provider.disable()
        store.save_runtime(provider.persisted(store.load()["enabled"]))
        provider.reveal.close()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
