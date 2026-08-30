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
workflow watcher, and common developer tools. Health is inferred locally from active items and
payload-free session history; Islet does not phone home. A failed or needs-action item marks its
provider as needing attention. Unknown source names remain visible as unlisted local sources.
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

The schema in [pulse-command.schema.json](pulse-command.schema.json) describes the wire payload.
