#!/usr/bin/env python3
"""Chrome native messaging host that translates download state to Pulse commands."""

from __future__ import annotations

import hashlib
import json
import os
from datetime import datetime, timedelta, timezone
from pathlib import Path
import struct
import sys
from typing import Any, BinaryIO

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "common"))
from pulse_client import PulseClient, PulseError, RevealServer  # noqa: E402


SOURCE = "chrome-downloads"
MAX_NATIVE_MESSAGE = 1024 * 1024
CANCEL_ERRORS = {"USER_CANCELED", "USER_SHUTDOWN"}
ACTIVE_EXPIRY_SECONDS = 90


def active_expiry() -> str:
    expiry = datetime.now(timezone.utc) + timedelta(seconds=ACTIVE_EXPIRY_SECONDS)
    return expiry.replace(microsecond=0).isoformat().replace("+00:00", "Z")


def activity_id(profile_id: str, download_id: int) -> str:
    profile = hashlib.sha256(profile_id.encode()).hexdigest()[:16]
    return f"chrome-download:{profile}:{download_id}"


def display_name(filename: object) -> str:
    if not isinstance(filename, str) or not filename:
        return "download"
    name = os.path.basename(filename.rstrip(os.sep)) or "download"
    return name[:140]


def progress_value(received: object, total: object) -> float | None:
    if not isinstance(received, (int, float)) or not isinstance(total, (int, float)):
        return None
    if total <= 0:
        return None
    return min(1.0, max(0.0, received / total))


class ChromeDownloadProvider:
    def __init__(
        self, pulse: PulseClient | None = None, reveal: RevealServer | None = None
    ) -> None:
        self.pulse = pulse or PulseClient()
        self.reveal = reveal or RevealServer()
        self.published: set[str] = set()

    def command_for(self, message: dict[str, Any]) -> dict[str, Any] | None:
        kind = message.get("kind")
        if kind == "disable":
            self.disable()
            return None
        if kind == "end":
            identifier = self._identifier(message)
            self.pulse.end(identifier, SOURCE)
            self.published.discard(identifier)
            return None
        if kind != "upsert" or not isinstance(message.get("item"), dict):
            raise ValueError("unknown native host command")

        item = message["item"]
        identifier = self._identifier(message, item)
        state = item.get("state")
        error = item.get("error")
        if state == "interrupted" and error in CANCEL_ERRORS:
            self.pulse.end(identifier, SOURCE)
            self.published.discard(identifier)
            return None

        name = display_name(item.get("filename"))
        progress = progress_value(item.get("bytesReceived"), item.get("totalBytes"))
        activity: dict[str, Any] = {
            "id": identifier,
            "source": SOURCE,
            "title": f"Downloading {name}",
            "symbol": "arrow.down.circle.fill",
            "state": "progress",
            "priority": "normal",
        }
        if progress is not None:
            activity["progress"] = progress
            activity["subtitle"] = f"{round(progress * 100)}%"
        elif item.get("paused") is True:
            activity["subtitle"] = "Paused"

        terminal = state in {"complete", "interrupted"}
        if not terminal:
            activity["expiresAt"] = active_expiry()
        if state == "complete":
            activity.update(
                title=f"Downloaded {name}",
                state="succeeded",
                progress=1.0,
                subtitle="Complete",
            )
        elif state == "interrupted":
            activity.update(
                title=f"Download failed: {name}",
                state="failed",
                priority="high",
                subtitle="Chrome reported a transfer error",
            )

        filename = item.get("filename")
        if isinstance(filename, str) and item.get("exists") is not False:
            action = self.reveal.action(Path(filename), f"reveal-{identifier[-24:]}")
            if action:
                activity["actions"] = [action]

        command = {"operation": "event" if terminal else "update", "activity": activity}
        self.pulse.send(command)
        if terminal:
            self.published.discard(identifier)
        else:
            self.published.add(identifier)
        return command

    def disable(self) -> None:
        for identifier in list(self.published):
            try:
                self.pulse.end(identifier, SOURCE)
            except PulseError:
                pass
        self.published.clear()
        self.reveal.clear()

    def close(self) -> None:
        self.disable()
        self.reveal.close()

    @staticmethod
    def _identifier(message: dict[str, Any], item: dict[str, Any] | None = None) -> str:
        profile_id = message.get("profileID")
        download_id = (item or message).get("id")
        if (
            not isinstance(profile_id, str)
            or not profile_id
            or not isinstance(download_id, int)
        ):
            raise ValueError("download identity is missing")
        return activity_id(profile_id, download_id)


def read_message(stream: BinaryIO) -> dict[str, Any] | None:
    header = stream.read(4)
    if not header:
        return None
    if len(header) != 4:
        raise ValueError("truncated native message header")
    length = struct.unpack("=I", header)[0]
    if length > MAX_NATIVE_MESSAGE:
        raise ValueError("native message is too large")
    payload = stream.read(length)
    if len(payload) != length:
        raise ValueError("truncated native message")
    value = json.loads(payload)
    if not isinstance(value, dict):
        raise ValueError("native message must be an object")
    return value


def write_message(stream: BinaryIO, value: dict[str, Any]) -> None:
    payload = json.dumps(value, separators=(",", ":")).encode()
    stream.write(struct.pack("=I", len(payload)))
    stream.write(payload)
    stream.flush()


def main() -> int:
    provider = ChromeDownloadProvider()
    try:
        while (message := read_message(sys.stdin.buffer)) is not None:
            request_id = message.get("requestID")
            try:
                provider.command_for(message)
                write_message(sys.stdout.buffer, {"ok": True, "requestID": request_id})
            except (PulseError, ValueError) as error:
                write_message(
                    sys.stdout.buffer,
                    {"ok": False, "error": str(error), "requestID": request_id},
                )
    finally:
        provider.close()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
