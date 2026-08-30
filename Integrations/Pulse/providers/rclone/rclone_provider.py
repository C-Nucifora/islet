#!/usr/bin/env python3
"""Observe rclone's loopback remote-control API and publish transfer state to Pulse."""

from __future__ import annotations

import argparse
import base64
import hashlib
import ipaddress
import json
import os
from pathlib import Path, PurePosixPath
import signal
import sys
import tempfile
import time
from typing import Any
from urllib.error import HTTPError, URLError
from urllib.parse import urlparse
from urllib.request import HTTPRedirectHandler, Request, build_opener

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "common"))
from pulse_client import PulseClient, PulseError, RevealServer, safe_child  # noqa: E402


SOURCE = "rclone"
MAX_RC_RESPONSE = 1024 * 1024


def opaque_id(execute_id: str, job_id: int, name: str) -> str:
    digest = hashlib.sha256(f"{execute_id}\0{job_id}\0{name}".encode()).hexdigest()[:32]
    return f"rclone:{digest}"


def event_id(execute_id: str, job_id: int, record: dict[str, Any]) -> str:
    basis = f"{execute_id}\0{job_id}\0{record.get('name')}\0{record.get('timestamp')}\0{record.get('error')}"
    return hashlib.sha256(basis.encode()).hexdigest()


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
        self.opener = build_opener(_RejectRedirects)
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
        if self.authorization:
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


class StateStore:
    def __init__(self, path: Path) -> None:
        self.path = path
        self.disabled_path = path.with_name(path.name + ".disabled")

    def load(self) -> dict[str, Any]:
        try:
            value = json.loads(self.path.read_text(encoding="utf-8"))
        except (OSError, json.JSONDecodeError):
            return {
                "enabled": not self.disabled_path.exists(),
                "published": [],
                "seen": [],
                "completedAfter": int(time.time() * 1000),
            }
        if not isinstance(value, dict):
            return {
                "enabled": not self.disabled_path.exists(),
                "published": [],
                "seen": [],
                "completedAfter": int(time.time() * 1000),
            }
        return {
            "enabled": not self.disabled_path.exists(),
            "published": [
                item for item in value.get("published", []) if isinstance(item, str)
            ],
            "seen": [item for item in value.get("seen", []) if isinstance(item, str)][
                -512:
            ],
            "completedAfter": value.get("completedAfter", 0)
            if isinstance(value.get("completedAfter", 0), int)
            else 0,
        }

    def save(self, value: dict[str, Any]) -> None:
        value = dict(value)
        value["enabled"] = not self.disabled_path.exists()
        self.path.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
        os.chmod(self.path.parent, 0o700)
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
        self.path.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
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
    ) -> None:
        self.rc = rc
        self.pulse = pulse or PulseClient()
        self.reveal = reveal or RevealServer()
        self.reveal_root = reveal_root
        self.published = set((state or {}).get("published", []))
        self.seen = set((state or {}).get("seen", []))
        self.completed_after = int((state or {}).get("completedAfter", 0))
        self.fingerprints: dict[str, str] = {}
        self.active_command_budget = 12
        self.rotation = 0

    def observe(self) -> None:
        self.active_command_budget = 12
        jobs = self.rc.call("job/list")
        execute_id = jobs.get("executeId")
        if not isinstance(execute_id, str) or not execute_id:
            raise RuntimeError("rclone job/list omitted executeId")
        job_ids = jobs.get("jobids", jobs.get("jobIds", []))
        if not isinstance(job_ids, list):
            raise RuntimeError("rclone job/list returned invalid job IDs")

        active: set[str] = set()
        active_candidates: list[tuple[str, int, dict[str, Any]]] = []
        terminal: set[str] = set()
        max_timestamp = self.completed_after
        for raw_job_id in job_ids:
            if not isinstance(raw_job_id, int):
                continue
            group = {"group": f"job/{raw_job_id}"}
            stats = self.rc.call("core/stats", group)
            transfers = stats.get("transferring", [])
            if isinstance(transfers, list):
                for transfer in transfers:
                    if (
                        isinstance(transfer, dict)
                        and isinstance(transfer.get("name"), str)
                        and transfer["name"]
                    ):
                        active.add(opaque_id(execute_id, raw_job_id, transfer["name"]))
                        active_candidates.append((execute_id, raw_job_id, transfer))

            completed = self.rc.call("core/transferred", group).get("transferred", [])
            if isinstance(completed, list):
                for record in completed:
                    if not isinstance(record, dict) or record.get("checked") is True:
                        continue
                    timestamp = record.get("timestamp")
                    if not isinstance(timestamp, int):
                        continue
                    max_timestamp = max(max_timestamp, timestamp)
                    key = event_id(execute_id, raw_job_id, record)
                    if timestamp <= self.completed_after or key in self.seen:
                        continue
                    identifier = self._publish_terminal(execute_id, raw_job_id, record)
                    self.seen.add(key)
                    if identifier:
                        terminal.add(identifier)

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
        self.completed_after = max_timestamp
        if len(self.seen) > 512:
            self.seen = set(sorted(self.seen)[-512:])

    def _publish_active(
        self, execute_id: str, job_id: int, transfer: dict[str, Any]
    ) -> str | None:
        name = transfer.get("name")
        if not isinstance(name, str) or not name:
            return None
        identifier = opaque_id(execute_id, job_id, name)
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
        if self.fingerprints.get(identifier) == fingerprint:
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
        }
        if progress is not None:
            activity["progress"] = progress
            activity["subtitle"] = f"{round(progress * 100)}%"
        self._add_reveal(activity, name, identifier)
        self.pulse.send({"operation": "update", "activity": activity})
        self.active_command_budget -= 1
        self.fingerprints[identifier] = fingerprint
        self.published.add(identifier)
        return identifier

    def _publish_terminal(
        self, execute_id: str, job_id: int, record: dict[str, Any]
    ) -> str | None:
        name = record.get("name")
        if not isinstance(name, str) or not name:
            return None
        identifier = opaque_id(execute_id, job_id, name)
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
        self._add_reveal(activity, name, identifier)
        self.pulse.send({"operation": "event", "activity": activity})
        self.fingerprints.pop(identifier, None)
        self.published.discard(identifier)
        return identifier

    def _add_reveal(self, activity: dict[str, Any], name: str, identifier: str) -> None:
        if self.reveal_root is None:
            return
        path = safe_child(self.reveal_root, name)
        if path is None:
            return
        action = self.reveal.action(path, f"reveal-{identifier[-16:]}")
        if action:
            activity["actions"] = [action]

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
        self.reveal.clear()

    def _end(self, identifier: str) -> None:
        try:
            self.pulse.end(identifier, SOURCE)
        except PulseError:
            pass
        self.fingerprints.pop(identifier, None)

    def persisted(self, enabled: bool) -> dict[str, Any]:
        return {
            "enabled": enabled,
            "published": sorted(self.published),
            "seen": sorted(self.seen)[-512:],
            "completedAfter": self.completed_after,
        }

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
    options = parser().parse_args(arguments)
    if options.interval < 1:
        parser().error("--interval must be at least one second")
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
        rc, pulse=pulse, reveal_root=options.reveal_root, state=state
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
