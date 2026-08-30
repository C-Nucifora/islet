# Islet Pulse provider protocol

Pulse is Islet's local, out-of-process activity API. A provider submits bounded JSON data; it never
loads code into Islet. Islet owns layout, priority, expiry, accessibility, and action safety.

## Quick start

After Islet has started its Pulse server:

```sh
swift Tools/islet-pulse.swift show build-1842 "Build running" "UQR-AV" --source build
swift Tools/islet-pulse.swift update build-1842 "Building" "UQR-AV" \
  --source build --progress 0.65 --priority high
swift Tools/islet-pulse.swift event build-1842 "Build succeeded" "All checks passed" --source build
swift Tools/islet-pulse.swift end build-1842 --source build
```

The reference tool reads a user-only token from
`~/Library/Application Support/Islet/pulse-token` and sends one newline-delimited JSON command to
TCP port `47717` on `127.0.0.1`. The server rejects messages over 64 KiB, invalid tokens, unsafe
action URL schemes, more than three actions, and more than 100 simultaneous items.
The listener accepts at most 16 concurrent clients, each socket is capped at 128 commands, and the
shared token is capped at 512 accepted commands per rolling minute across reconnects. A
rate-limited provider receives a structured `rateLimited` error and should retry with backoff. If
capacity ordering would immediately evict the submitted item, the provider receives
`capacityExceeded` instead of a false success.
When Pulse is disabled, Islet clears retained items and rejects every transport or Shortcuts update
with `featureDisabled`.

## Operations

- `show`: create an item, or replace an existing item with the same `id`.
- `update`: the same idempotent upsert semantics as `show`, named for provider readability.
- `event`: create an item that expires after eight seconds unless `expiresAt` is supplied.
- `end`: remove an item by `id`.

Dates use ISO 8601, with or without fractional seconds. `progress` outside `0...1` is rejected.
Islet marks nonterminal work stale when a provider stops sending valid updates. The timeout is
configurable in Pulse settings. A stale item remains for one hour unless the user keeps or dismisses
it, and a later valid update recovers the item and starts a fresh timeout.
Web actions may use only host-bearing
`http` or `https` URLs, cannot embed credentials, and are limited to 2,048 characters. Activity
and action IDs are trimmed, bounded to 128 characters, and action IDs must be unique within one
activity. Activity IDs are global within Islet's current stack: an update from a different source
cannot overwrite an existing ID. Providers should prefix IDs with their source, update only when
data changes, and always end work that is no longer relevant. Include `source` on `end`; Islet then
rejects cleanup if the ID belongs to another source. Omitting it remains supported for older
clients.

Set a unique `requestID` on every command. Islet echoes it on decoded responses, allowing clients
to correlate results if they reuse a connection. Clients that omit it should send only one command
at a time. Rejections include a stable `errorCode` for automation and a human-readable `error`.
Pulse validates an optional `symbol` against the SF Symbols available on the host. An empty,
unknown, or unavailable symbol is replaced with Pulse's `waveform.path.ecg` fallback. The command
still succeeds and includes a field-specific `warning` in its response.
The socket rejects unknown JSON fields so a misspelled protocol key cannot fail silently.

## Delivery profiles and payload-free history

The user can choose Everything, Focus, Critical only, or Paused in Settings, the menu, Shortcuts,
or Quick Actions. Filtering happens after validation. A suppressed update still receives a success
response, so providers do not need to know the user's focus state. If an existing item is no longer
allowed after an update, Islet hides it from the visible stack. Still-live filtered state remains
in memory, so switching back to Everything reveals it without requiring a provider retransmission.

Each gallery provider and previously seen unlisted source has a session routing policy:

- Allow accepts and presents updates under the current delivery profile.
- Mute accepts and retains state without presenting it; changing back to Allow reveals live work.
- Revoke removes retained work and rejects future show, update, and event commands from that source.

End remains accepted after revocation so providers can perform idempotent cleanup. Policies are
local and session-scoped; Pulse never contacts a provider when a policy changes. A source is a
self-declared routing name under the shared user token, not a cryptographically verified process
identity. A token holder can bypass a source Revoke by declaring another source, so Revoke is a
content-routing control, not credential revocation, a sandbox, or a security boundary. Use **Rotate
provider token** in Settings to atomically replace the shared credential and disconnect every
provider. Every legitimate provider must then reread the token before reconnecting.

Islet keeps at most 200 history entries for the current process. Each entry contains only time,
operation, source routing name, state, priority, and outcome. It never contains payload IDs, titles, subtitles,
action labels or URLs, authentication tokens, or error descriptions. History is not written to
disk and can be cleared from Settings at any time.

## Provider gallery

Settings includes health and capability metadata for Shortcuts, the reference CLI, a local GitHub
workflow watcher, and common developer tools. Health is inferred locally from active items and payload-free session
history; Islet does not phone home. Unknown source names remain visible as unlisted local sources.
The machine-readable gallery is in [providers.json](providers.json).

The gallery's capabilities are explanatory protocol boundaries, not access to Islet data:

- Events: transient and state updates.
- Progress: a bounded `0...1` value.
- Web links: up to three validated HTTP(S) actions.

No provider can load executable code into Islet, read other providers' items, or read history over
the Pulse socket. Possession of the user-only token grants write-only access to this bounded API.

## Reference CLI

The CLI keeps the positional quick start and adds optional provider fields:

```text
--source NAME
--progress 0.0...1.0
--state active|progress|needsAction|succeeded|failed
--priority low|normal|high|critical
--expires 2...86400
--action "Open run" https://example.com/run/1842
```

See [examples/github-actions.sh](examples/github-actions.sh) for a provider wrapper suitable for a
local GitHub CLI watcher or a self-hosted Mac runner where Islet is running in the same login
session. It cannot reach Islet from a GitHub-hosted runner. Its arguments are explicit; it does not
read repository contents or credentials.

The schema in [pulse-command.schema.json](pulse-command.schema.json) describes the wire payload.
