# Islet Pulse provider protocol

Pulse is Islet's local, out-of-process activity API. A provider submits bounded JSON data; it never
loads code into Islet. Islet owns layout, priority, expiry, accessibility, and action safety.

## Quick start

After Islet has started its Pulse server:

```sh
swift Tools/islet-pulse.swift show build-1842 "Build running" "UQR-AV"
swift Tools/islet-pulse.swift update build-1842 "Building" "UQR-AV" \
  --source build --progress 0.65 --priority high
swift Tools/islet-pulse.swift event build-1842 "Build succeeded" "All checks passed"
swift Tools/islet-pulse.swift end build-1842
```

The reference tool reads a user-only token from
`~/Library/Application Support/Islet/pulse-token` and sends one newline-delimited JSON command to
TCP port `47717` on `127.0.0.1`. The server rejects messages over 64 KiB, invalid tokens, unsafe
action URL schemes, more than three actions, and more than 100 simultaneous items.

## Operations

- `show`: create an item, or replace an existing item with the same `id`.
- `update`: the same idempotent upsert semantics as `show`, named for provider readability.
- `event`: create an item that expires after eight seconds unless `expiresAt` is supplied.
- `end`: remove an item by `id`.

Dates use ISO 8601. `progress` is clamped to `0...1`. Web actions may use only host-bearing
`http` or `https` URLs, cannot embed credentials, and are limited to 2,048 characters. Activity
and action IDs are trimmed, bounded to 128 characters, and action IDs must be unique within one
activity. Providers should use a stable `source` and id, update only when data changes, and always
end work that is no longer relevant.

## Delivery profiles and privacy-safe history

The user can choose Everything, Focus, Critical only, or Paused in Settings, the menu, Shortcuts,
or Quick Actions. Filtering happens after validation. A suppressed update still receives a success
response, so providers do not need to know the user's focus state. If an existing item is no longer
allowed after an update, Islet hides it from the visible stack. Still-live filtered state remains
in memory, so switching back to Everything reveals it without requiring a provider retransmission.

Each gallery provider and previously seen unlisted source has a session policy:

- Allow accepts and presents updates under the current delivery profile.
- Mute accepts and retains state without presenting it; changing back to Allow reveals live work.
- Revoke removes retained work and rejects future show, update, and event commands from that source.

End remains accepted after revocation so providers can perform idempotent cleanup. Policies are
local and session-scoped; Pulse never contacts a provider when a policy changes. A source is a
self-declared routing name under the shared user token, not a cryptographically verified process
identity. Revoke is a content-routing control, not a sandbox or security boundary.

Islet keeps at most 200 history entries for the current process. Each entry contains only time,
operation, item id, source, state, priority, and outcome. It never contains titles, subtitles,
action labels or URLs, authentication tokens, or error descriptions. History is not written to
disk and can be cleared from Settings at any time.

## Provider gallery

Settings includes health and capability metadata for Shortcuts, the reference CLI, GitHub Actions,
and common developer tools. Health is inferred locally from active items and privacy-safe session
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
checked-out workflow or a local CI watcher. Its arguments are explicit; it does not read repository
contents or credentials.

The schema in [pulse-command.schema.json](pulse-command.schema.json) describes the wire payload.
