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
swift Tools/islet-pulse.swift show build-1842 "Build running" "UQR-AV" \
  --source build --revision 1
swift Tools/islet-pulse.swift update build-1842 "Building" "UQR-AV" \
  --source build --revision 2 --progress 0.65 --priority high
swift Tools/islet-pulse.swift event build-1842 "Build succeeded" "All checks passed" \
  --source build --revision 3
swift Tools/islet-pulse.swift end build-1842 --source build --revision 4
```

## Xcode builds and tests

`Tools/islet-xcode-pulse.swift` is the first-party provider for local command-line Xcode work. Put
provider options before `--` and pass normal `xcodebuild` arguments after it:

```sh
swift Tools/islet-xcode-pulse.swift --label Islet -- \
  -project Islet.xcodeproj -scheme Islet \
  -destination 'platform=macOS,arch=arm64' test
```

The wrapper mirrors `xcodebuild` output and exits with the same status. One invocation creates one
random stable Pulse item ID, then updates that item for the lifetime of the build. Use `--id NAME`
when an outer build system already has a stable run identifier. Concurrent invocations get distinct
items unless the caller deliberately reuses an ID.

Pulse reports elapsed time while the command runs. When `xcodebuild` emits bounded `[completed/total]`
steps, the provider publishes a clamped `0...1` progress value. It does not invent a percentage for
output that has no total. The final item expires after 8 seconds on success, 15 seconds on
cancellation, or 60 seconds on failure.

Optional actions must be explicit safe HTTP(S) URLs:

```sh
swift Tools/islet-xcode-pulse.swift \
  --project-url https://example.com/project \
  --report-url https://example.com/builds/1842 \
  --failure-url https://example.com/builds/1842/failures \
  -- -workspace App.xcworkspace -scheme App test
```

The provider sends at most three actions named Open project, Open report, and Open failure.
It rejects URLs with embedded credentials and never infers a remote URL from Git configuration.
It parses only the `xcodebuild` byte stream, keeps at most 8 KiB of the current line, and does not
read source files, result bundles, credentials, or other projects. Pulse receives a bounded display
label, elapsed time, progress when present, and a truncated test name or source filename and line on
failure. Terminal controls, newlines, and malformed UTF-8 are removed or replaced before publishing.
The full build log stays on the wrapper's standard output and is not stored by the provider or Pulse.

The provider supports `xcodebuild` first because the Xcode GUI does not expose the same supported,
stable output stream. Builds started with Xcode's Run, Test, or Product menu are not reported. To see
them in Pulse, run the equivalent scheme action through this wrapper. Xcode may omit bounded step
counts for some build phases, so those runs show elapsed time without a percentage.

The reference tool reads only the path supplied through `--credential-file` or
`ISLET_PULSE_CREDENTIAL_FILE` and sends one newline-delimited JSON command to TCP port `47717` on
`localhost`. Islet binds separate numeric loopback listeners for `127.0.0.1` and `::1`, so
providers may use either address (or `localhost`) without exposing Pulse on a LAN interface. The
server rejects messages over 64 KiB, invalid or revoked credentials, commands for another source,
missing permissions, replays, unsafe
action URL schemes, more than three actions, and more than 100 simultaneous items.
The listener accepts at most 16 concurrent clients, each socket is capped at 128 commands, and each
provider credential is capped at 512 accepted commands per rolling minute across reconnects. Pulse
also keeps a 2,048-command process-wide rolling-minute ceiling so a collection of providers cannot
overload Islet. A rate-limited provider receives a structured `rateLimited` error with an integer
`retryAfter` value in seconds. It is the protocol equivalent of HTTP's `Retry-After` header and
lets the sender wait before reconnecting. If capacity ordering would immediately evict the submitted
item, the provider receives `capacityExceeded` instead of a false success.
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

Providers that can persist a counter should include `revision` on every command for an activity.
The value is an integer from 0 through 9,007,199,254,740,991 and must increase within the normalized
source and provider-local ID. Islet applies only values greater than the last accepted revision.
A duplicate or lower value returns `staleRevision` and leaves the item, deadlines, and history
metadata unchanged. This makes the final state independent of the order in which connections reach
Islet.

Once an identity sends a revision, later commands for that identity must include one. Omitting it
returns `revisionRequired`. An ordered `end` records a retained tombstone even when no item is active,
so it must include `source`. After `end`, a higher `update` returns `generationEnded`; use a higher
`show` or `event` to start the next lifecycle. Delayed commands from the old lifecycle remain below
the tombstone and cannot reopen it. Islet restores revision high-water marks and tombstones before it
accepts commands after a restart. Providers should still keep their counter and resend current state
after reconnecting.

Revision tracking is capped at 2,048 identities. A new ordered identity returns `capacityExceeded`
after that limit, while identities already being tracked continue to work. Inactive revision records
expire 30 days after their last accepted command, which prevents abandoned identities from consuming
the bound forever. The persisted record contains only normalized source, provider-local ID, revision,
ended state, and acceptance time. It excludes bearer tokens and presentation payloads and is not part
of settings exports.

Disabling and re-enabling Pulse, or using Dismiss all, clears items but keeps revision records. Stale
requests still fail after Pulse starts again or Islet relaunches. A higher update may restore locally
dismissed work, but an activity closed by ordered `end` still requires a higher `show` or `event`.

Legacy providers may omit `revision`. They retain arrival-order upserts and idempotent unscoped
ends until that identity first uses an ordered command. This compatibility mode cannot protect
against reordered requests, so new providers should use revisions.

Include `source` on `end` to select the provider namespace. For compatibility, Islet accepts an
unscoped end while exactly one active source owns that ID. If multiple sources own it, Islet leaves
every item untouched and returns `ambiguousIdentifier`. A scoped end for the wrong source returns
`sourceMismatch`. Pulse item state and history are session-only, so restarting into this protocol
expires the old process's global-keyed state instead of attempting an on-disk migration.

Set a unique `requestID` on every command. Provider credentials require it and reject a repeated ID
within a bounded recent window. Islet echoes it on decoded responses, allowing clients
to correlate results if they reuse a connection. Clients that omit it should send only one command
at a time. Rejections include a stable `errorCode` for automation and a human-readable `error`.
Pulse validates an optional `symbol` against the SF Symbols available on the host. An empty,
unknown, or unavailable symbol is replaced with Pulse's `waveform.path.ecg` fallback. The command
still succeeds and includes a field-specific `warning` in its response.
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

Settings includes health and capability metadata for Shortcuts, the reference CLI, local Xcode
builds, a local GitHub workflow watcher, Chrome downloads, rclone transfers, and common developer
tools. Health is inferred locally from active items and payload-free session history; Islet does not
phone home. A failed or needs-action item marks its provider as needing attention. Unknown source
names remain visible as unlisted local sources. The machine-readable gallery is in
[providers.json](providers.json).

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
--revision 0...9007199254740991
--progress 0.0...1.0
--state active|progress|needsAction|succeeded|failed|cancelled
--priority low|normal|high|critical
--expires 2...86400
--action "Open run" https://example.com/run/1842
```

## GitHub Actions provider

The supported watcher uses the GitHub CLI credential store. Sign in once, then select one or more
repositories:

```sh
gh auth login
Integrations/Pulse/examples/github-actions.sh \
  --repo C-Nucifora/islet \
  --repo OWNER/ANOTHER-REPOSITORY
```

Do not put a token in Islet, this provider's arguments, or a configuration file. The provider does
not accept a token option. It removes GitHub token environment variables from child processes, so
`gh` uses its stored login. The watcher reads GitHub's Actions and repository API responses; it
does not read checked-out source files.

Use `--workflow` more than once to limit every selected repository by workflow display name,
workflow path, or numeric workflow ID:

```sh
Integrations/Pulse/examples/github-actions.sh \
  --repo C-Nucifora/islet \
  --workflow CI \
  --workflow .github/workflows/release.yml \
  --poll-seconds 30 \
  --max-backoff-seconds 900 \
  --terminal-expires-seconds 30
```

Without `--workflow`, the provider follows the repository's latest run. It uses one stable Pulse
item for each watched repository or repository/workflow pair. Queued and running items carry an
expiry that the next poll refreshes. If the watcher exits, those items clear instead of remaining
stuck. Completed, cancelled, failed, and needs-attention runs publish once, stop receiving API
detail requests, and expire after 30 seconds by default.

The watcher adds safe web actions for the run and first failed job. If the current `gh` account has
push permission, it also adds a `Rerun in GitHub` action that opens the run page. Pulse actions do
not execute shell commands. To request a rerun directly, use the provider's deliberate CLI command.
GitHub checks the stored credential and repository permission:

```sh
swift run --package-path Integrations/Pulse/GitHubActionsProvider \
  islet-github-actions rerun --repo OWNER/REPOSITORY --run RUN_ID --failed
```

Authentication, rate-limit, and network failures publish one needs-attention health item. Repeated
failures of the same kind do not republish it. Polling backs off exponentially to the configured
maximum, then returns to the normal interval after a successful request. The health item ends on
recovery. Error details and API response bodies are not sent to Pulse or retained in its history.

The watcher must run locally, or on a self-hosted Mac runner in the same login session as Islet. A
GitHub-hosted runner cannot reach Islet's loopback listener. Use `--once` for one polling pass or
`--help` for the full option list.

Recorded API fixtures and mapping tests live in
`GitHubActionsProvider/Tests/GitHubActionsProviderCoreTests`. Run them with:

```sh
swift test --package-path Integrations/Pulse/GitHubActionsProvider
```

## Transfer providers

The [Chrome downloads provider](providers/chrome-downloads/README.md) uses Chrome's `downloads`
extension API. It does not read Chrome's private History database. The extension sends no source
URL or referrer to its native host. It keeps only Chrome's numeric download IDs in extension
storage so it can remove stale items after a service-worker restart. Active transfer items carry a
bounded expiry that a low-rate heartbeat refreshes.

The [rclone provider](providers/rclone/README.md) polls `job/list`, `job/status`, `core/stats`, and
`core/transferred` on a persistent `rclone rcd` loopback endpoint. Transfers run as asynchronous RC
jobs so terminal results remain available after a provider restart. It stores hashed activity and
completion IDs, never transfer names, paths, remote names, RC credentials, or Pulse credentials.
Both providers publish state changes immediately, refresh unchanged active work at a low rate, and
clean up active Pulse items when disabled or stopped.

Reveal actions use an ephemeral loopback URL because Pulse deliberately rejects `file:` actions.
The provider maps the random URL to an existing path in memory. The HTTP handler binds to
`127.0.0.1`, returns no file content, and asks Finder to reveal the mapped file. rclone reveal
actions are optional and require an explicit local root. Paths outside that root and inaccessible
files get no action. Each provider process retains at most 128 reveal mappings and evicts the oldest
mapping when it reaches that limit. Terminal mappings expire with their eight-second events, and
providers revoke mappings as soon as the associated transfer is canceled or disappears.

## Adding another transfer provider

1. Use a documented event or control API. Do not scan the home directory or parse another app's
   private database.
2. Build the Pulse ID from the provider's stable instance, transfer, and job identifiers. Hash
   local paths, remote names, and URLs rather than placing them in the ID. Display only the base
   file name.
3. Recover active transfers on startup. Persist only opaque IDs needed to end work that vanished
   while the provider was stopped.
4. Coalesce progress updates, respect `rateLimited` responses with backoff, and always send `end`
   for cancellation, removal, and provider shutdown.
5. Stop event listeners and polling before reporting the provider as disabled. Clear every active
   item and in-memory reveal mapping at the same time.
6. Add fixtures for duplicate base names, restart recovery, success, failure, cancellation, and
   inaccessible paths. Test the reducer without requiring Islet, Chrome, or the transfer tool.

The schema in [pulse-command.schema.json](pulse-command.schema.json) describes the wire payload.

## Shortcuts starter kit

The [Shortcuts starter kit](shortcuts/README.md) includes signed, importable macOS shortcuts for
an event, a progress task, a failed task, guarded completion, a temporary Focus delivery profile,
and a focus timer. It documents every field they send and the fixed identifiers that keep updates
from creating duplicate Pulse items.
