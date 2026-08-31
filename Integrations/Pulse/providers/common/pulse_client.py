"""Small, dependency-free client helpers for out-of-process Pulse providers."""

from __future__ import annotations

import base64
import json
import os
from pathlib import Path
import secrets
import socket
import stat
import subprocess
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from typing import Any, Callable
from uuid import uuid4


SOURCE_LIMIT = 80
ID_LIMIT = 128
MAX_RESPONSE_BYTES = 64 * 1024
MAX_REVEAL_ACTIONS = 128


class PulseError(RuntimeError):
    """Pulse rejected a command or could not be reached."""

    def __init__(self, message: str, code: str | None = None) -> None:
        super().__init__(message)
        self.code = code


class PulseClient:
    def __init__(
        self, support_directory: Path | None = None, timeout: float = 5
    ) -> None:
        self.support_directory = support_directory or (
            Path.home() / "Library" / "Application Support" / "Islet"
        )
        self.timeout = timeout

    def send(self, command: dict[str, Any], attempts: int = 4) -> dict[str, Any]:
        request = dict(command)
        request["token"] = self._read_token()
        request["requestID"] = str(uuid4())
        encoded = json.dumps(request, separators=(",", ":")).encode() + b"\n"
        if len(encoded) > MAX_RESPONSE_BYTES:
            raise PulseError("Pulse command exceeds 64 KiB")

        delay = 0.25
        for attempt in range(attempts):
            response = self._exchange(encoded, request["requestID"])
            if response.get("ok") is True:
                return response
            code = response.get("errorCode")
            if code != "rateLimited" or attempt + 1 == attempts:
                raise PulseError(
                    response.get("error", "Pulse rejected the command"), code
                )
            time.sleep(delay)
            delay *= 2
        raise PulseError("Pulse command retry limit reached")

    def end(self, identifier: str, source: str) -> dict[str, Any]:
        return self.send({"operation": "end", "id": identifier, "source": source})

    def _read_token(self) -> str:
        token_path = self.support_directory / "pulse-token"
        try:
            flags = os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0)
            descriptor = os.open(token_path, flags)
            with os.fdopen(descriptor, encoding="utf-8") as token_file:
                details = os.fstat(token_file.fileno())
                if not stat.S_ISREG(details.st_mode):
                    raise PulseError("Pulse token is not a regular file")
                if details.st_uid != os.getuid() or details.st_mode & 0o077:
                    raise PulseError("Pulse token ownership or permissions are unsafe")
                token = token_file.read(129).strip()
            if len(token) > 128:
                raise PulseError("Pulse token is unavailable or invalid")
            decoded = base64.b64decode(token, validate=True)
        except (OSError, UnicodeDecodeError, ValueError) as error:
            raise PulseError("Pulse token is unavailable or invalid") from error
        if len(decoded) != 32:
            raise PulseError("Pulse token is unavailable or invalid")
        return token

    def _port(self) -> int:
        try:
            value = int((self.support_directory / "pulse-port").read_text().strip())
            if 1 <= value <= 65535:
                return value
        except (OSError, ValueError):
            pass
        return 47717

    def _exchange(self, payload: bytes, request_id: str) -> dict[str, Any]:
        data = bytearray()
        try:
            with socket.create_connection(
                ("127.0.0.1", self._port()), self.timeout
            ) as client:
                client.settimeout(self.timeout)
                client.sendall(payload)
                while b"\n" not in data:
                    chunk = client.recv(16 * 1024)
                    if not chunk:
                        raise PulseError(
                            "Pulse closed the connection before responding"
                        )
                    data.extend(chunk)
                    if len(data) > MAX_RESPONSE_BYTES:
                        raise PulseError("Pulse returned an oversized response")
        except OSError as error:
            raise PulseError(f"Could not reach Islet Pulse: {error}") from error

        try:
            response = json.loads(bytes(data).split(b"\n", 1)[0])
        except (UnicodeDecodeError, json.JSONDecodeError) as error:
            raise PulseError("Pulse returned invalid JSON") from error
        if not isinstance(response, dict) or response.get("requestID") != request_id:
            raise PulseError("Pulse returned a response for another request")
        return response


class _RevealHTTPServer(ThreadingHTTPServer):
    daemon_threads = True

    def __init__(self, maximum_actions: int, clock: Callable[[], float]) -> None:
        super().__init__(("127.0.0.1", 0), _RevealHandler)
        self.maximum_actions = maximum_actions
        self.clock = clock
        self.paths: dict[str, Path] = {}
        self.action_tokens: dict[str, str] = {}
        self.deadlines: dict[str, float] = {}
        self.paths_lock = threading.Lock()

    def remove_token_locked(self, token: str) -> None:
        self.paths.pop(token, None)
        self.deadlines.pop(token, None)
        for action_id, current_token in list(self.action_tokens.items()):
            if current_token == token:
                self.action_tokens.pop(action_id, None)


class _RevealHandler(BaseHTTPRequestHandler):
    server: _RevealHTTPServer

    def do_GET(self) -> None:  # noqa: N802, macOS ships Python naming this callback.
        token = self.path.removeprefix("/reveal/")
        with self.server.paths_lock:
            path = self.server.paths.get(token)
            deadline = self.server.deadlines.get(token)
            if deadline is not None and deadline <= self.server.clock():
                self.server.remove_token_locked(token)
                path = None
        if path is None or not path.exists():
            self.send_error(404)
            return
        try:
            subprocess.Popen(
                ["/usr/bin/open", "-R", str(path)],
                stdin=subprocess.DEVNULL,
                stdout=subprocess.DEVNULL,
                stderr=subprocess.DEVNULL,
                start_new_session=True,
            )
        except OSError:
            self.send_error(500)
            return
        self.send_response(204)
        self.send_header("Cache-Control", "no-store")
        self.end_headers()

    def log_message(self, _format: str, *_args: object) -> None:
        pass


class RevealServer:
    """Loopback-only HTTP bridge for Pulse's HTTP(S)-only action contract."""

    def __init__(
        self,
        maximum_actions: int = MAX_REVEAL_ACTIONS,
        clock: Callable[[], float] = time.monotonic,
    ) -> None:
        self._server = _RevealHTTPServer(maximum_actions, clock)
        self._thread = threading.Thread(target=self._server.serve_forever, daemon=True)
        self._thread.start()

    def action(
        self,
        path: Path,
        action_id: str = "reveal",
        expires_in: float | None = None,
    ) -> dict[str, str] | None:
        try:
            resolved = path.expanduser().resolve(strict=True)
        except OSError:
            return None
        token = secrets.token_urlsafe(24)
        with self._server.paths_lock:
            previous = self._server.action_tokens.pop(action_id, None)
            if previous:
                self._server.paths.pop(previous, None)
                self._server.deadlines.pop(previous, None)
            self._server.action_tokens[action_id] = token
            self._server.paths[token] = resolved
            if expires_in is not None:
                self._server.deadlines[token] = self._server.clock() + expires_in
            while len(self._server.action_tokens) > self._server.maximum_actions:
                oldest_action = next(iter(self._server.action_tokens))
                oldest_token = self._server.action_tokens.pop(oldest_action)
                self._server.paths.pop(oldest_token, None)
                self._server.deadlines.pop(oldest_token, None)
        port = self._server.server_address[1]
        return {
            "id": action_id,
            "title": "Reveal in Finder",
            "url": f"http://127.0.0.1:{port}/reveal/{token}",
        }

    def clear(self) -> None:
        with self._server.paths_lock:
            self._server.paths.clear()
            self._server.action_tokens.clear()
            self._server.deadlines.clear()

    def remove(self, action_id: str) -> None:
        with self._server.paths_lock:
            token = self._server.action_tokens.pop(action_id, None)
            if token:
                self._server.paths.pop(token, None)
                self._server.deadlines.pop(token, None)

    def close(self) -> None:
        self._server.shutdown()
        self._server.server_close()
        self._thread.join(timeout=2)


def safe_child(root: Path, relative_name: str) -> Path | None:
    """Return an existing path below root without allowing traversal or absolute names."""
    if not relative_name or Path(relative_name).is_absolute():
        return None
    try:
        resolved_root = root.expanduser().resolve(strict=True)
        candidate = (resolved_root / relative_name).resolve(strict=True)
        candidate.relative_to(resolved_root)
    except (OSError, ValueError):
        return None
    return candidate
