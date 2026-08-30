# Islet Pulse provider protocol

Pulse is Islet's local, out-of-process activity API. A provider submits bounded JSON data; it never
loads code into Islet. Islet owns layout, priority, expiry, accessibility, and action safety.

## Quick start

First add a provider in Islet Settings > Integrations > Pulse. Give it the source used by the
script and only the permissions it needs. Islet writes a user-only credential file for that
provider. Use **Reveal credential** on its row, then explicitly configure that path for the
reference CLI. It never chooses a credential from the caller-controlled `--source` value and never
falls back to the legacy token.
The commands below need Events, Persistent activities, and Progress.

After Islet has started its Pulse server:

```sh
export ISLET_PULSE_CREDENTIAL_FILE="$HOME/Library/Application Support/Islet/pulse-credentials/REVEALED-ID.credential"
swift Tools/islet-pulse.swift show build-1842 "Build running" "UQR-AV" --source build
swift Tools/islet-pulse.swift update build-1842 "Building" "UQR-AV" \
  --source build --progress 0.65 --priority high
swift Tools/islet-pulse.swift event build-1842 "Build succeeded" "All checks passed" --source build
swift Tools/islet-pulse.swift end build-1842 --source build
```

The reference tool reads only the path supplied through `--credential-file` or
`ISLET_PULSE_CREDENTIAL_FILE` and sends one newline-delimited JSON command to TCP port `47717` on
`127.0.0.1`. The server rejects messages over 64 KiB, invalid or
revoked credentials, commands for another source, missing permissions, replays, unsafe
action URL schemes, more than three actions, and more than 100 simultaneous items.
The listener accepts at most 16 concurrent clients, each socket is capped at 128 commands, and the
provider credential is capped at 512 accepted commands per rolling minute across reconnects. A
rate-limited provider receives a structured `rateLimited` error and should retry with backoff. If
capacity ordering would immediately evict the submitted item, the provider receives
`capacityExceeded` instead of a false success.
When Pulse is disabled, Islet clears retained items and rejects every transport or Shortcuts update
with `featureDisabled`.

## Operations

- `show`: create an item, or replace an existing item with the same source and `id`.
- `update`: the same idempotent upsert semantics as `show`, named for provider readability.
- `event`: create an item that expires after at most eight seconds. A later `expiresAt` is clamped
  to that transient window.
- `end`: remove an item by source and `id`.

Dates use ISO 8601, with or without fractional seconds. `progress` outside `0...1` is rejected.
Islet marks nonterminal work stale when a provider stops sending valid updates. The timeout is
configurable in Pulse settings. A stale item remains for one hour unless the user keeps or dismisses
it, and a later valid update recovers the item and starts a fresh timeout.
Web actions may use only host-bearing
`http` or `https` URLs, cannot embed credentials, and are limited to 2,048 characters. Activity
and action IDs are trimmed, bounded to 128 characters, and action IDs must be unique within one
activity. Islet keys each activity by its trimmed, lowercased source and its provider-local ID, so
different sources can use the same natural ID without overwriting each other. Source normalization
also means names such as `Build`, `build`, and ` build ` share one namespace. Provider-local IDs
remain case-sensitive. Providers should update only when data changes and always end work that is
no longer relevant.

Include `source` on `end` to select the provider namespace. For compatibility, Islet accepts an
unscoped end while exactly one active source owns that ID. If multiple sources own it, Islet leaves
every item untouched and returns `ambiguousIdentifier`. A scoped end for the wrong source returns
`sourceMismatch`. Pulse item state and history are session-only, so restarting into this protocol
expires the old process's global-keyed state instead of attempting an on-disk migration.

Set a unique `requestID` on every command. Provider credentials require it and reject a repeated ID
within a bounded recent window. Islet echoes it on decoded responses, allowing clients
to correlate results if they reuse a connection. Clients that omit it should send only one command
at a time. Rejections include a stable `errorCode` for automation and a human-readable `error`.
The socket rejects unknown JSON fields so a misspelled protocol key cannot fail silently.

## Delivery profiles and bounded history

The user can choose Everything, Focus, Critical only, or Paused in Settings, the menu, Shortcuts,
or Quick Actions. Filtering happens after validation. A suppressed update still receives a success
response, so providers do not need to know the user's focus state. If an existing item is no longer
allowed after an update, Islet hides it from the visible stack. Still-live filtered state remains
in memory, so switching back to Everything reveals it without requiring a provider retransmission.

Each gallery provider and previously seen unlisted source has a session routing policy:

- Allow accepts and presents updates under the current delivery profile.
- Mute accepts and retains state without presenting it; changing back to Allow reveals live work.
- Revoke removes retained work and rejects future show, update, and event commands from that source.

End remains accepted after a routing Revoke so providers can perform idempotent cleanup. Policies
are local and session-scoped; Pulse never contacts a provider when a policy changes. Source names
are bound to provider credentials. A command that declares another source is rejected before it
reaches activity state.

Provider credentials are cooperative bearer tokens, not a sandbox between processes running as
the same macOS user. File permissions exclude other user accounts, while any same-user process that
can read a credential can use its permissions. Give credential paths only to trusted local tools,
configure each tool with one explicit path, and revoke a credential if its file may have been read
by another process.

Credential permissions separately control transient events, persistent show/update/end operations,
progress fields, and web actions. Settings shows the current credential's age, last use,
permissions, and revocation state. Rotating or revoking one credential disconnects only that
provider. Rotation atomically replaces its credential file. Revocation removes that file and keeps
a metadata-only record in Settings. If file deletion fails, Islet reports the failure and a repeated
revoke retries cleanup while the registry remains revoked.

On first launch after upgrading, Islet records the old `pulse-token` as a legacy provider bound to
the source `legacy`. It receives only the Events permission. Islet rewrites legacy commands to that
source and will not grant persistent activity, progress, or web-action access unless the user
explicitly changes permissions. Create a provider credential for each script, then revoke the
legacy entry. This is deliberately narrower than the old shared token.

Islet keeps at most 200 history entries for the current process. Each accepted entry contains time,
operation, source routing name, provider-local ID, state, priority, and outcome. It never contains
titles, subtitles, action labels or URLs, authentication tokens, or error descriptions. Rejected
payloads do not contribute an unvalidated source or ID. History is not written to disk and can be
cleared from Settings at any time.

## Provider gallery

Settings includes health and capability metadata for Shortcuts, the reference CLI, a local GitHub
workflow watcher, and common developer tools. Health is inferred locally from active items and
bounded session history; Islet does not phone home. Unknown source names remain visible as unlisted
local sources.
The machine-readable gallery is in [providers.json](providers.json).

The gallery's capabilities are explanatory protocol boundaries, not access to Islet data:

- Events: transient eight-second events.
- Persistent activities: retained show, update, and end operations.
- Progress: a bounded `0...1` value.
- Web links: up to three validated HTTP(S) actions.

No provider can load executable code into Islet, read other providers' items, or read history over
the Pulse socket. A credential grants write-only access to its bound source and selected
permissions.

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
