# rclone transfer provider

This provider reads rclone's documented remote-control endpoints and publishes each active copy or
upload as a separate Pulse item. It does not launch rclone, read its config, or scan transfer
directories.

## Run

Start a persistent authenticated loopback RC daemon:

```sh
export ISLET_RCLONE_RC_USER=islet
export ISLET_RCLONE_RC_PASS='choose-a-long-local-secret'
rclone rcd --rc-addr 127.0.0.1:5572 \
  --rc-user "$ISLET_RCLONE_RC_USER" --rc-pass "$ISLET_RCLONE_RC_PASS"
```

Run the provider with the same credentials in another terminal:

```sh
export ISLET_RCLONE_RC_USER=islet
export ISLET_RCLONE_RC_PASS='choose-a-long-local-secret'
python3 Integrations/Pulse/providers/rclone/rclone_provider.py
```

Launch transfers as asynchronous jobs against that daemon:

```sh
rclone rc --url http://127.0.0.1:5572 \
  --user "$ISLET_RCLONE_RC_USER" --pass "$ISLET_RCLONE_RC_PASS" \
  sync/copy srcFs=./large-files dstFs=remote:archive _async=true
```

Keeping `rclone rcd` alive lets the provider read the finished job from `core/transferred`, even if
the provider restarts after the copy ends. A top-level `rclone copy --rc` process closes its RC
endpoint as it exits, so it cannot reliably expose its terminal result to a separate poller.

The RC URL defaults to `http://127.0.0.1:5572`. Set `ISLET_RCLONE_RC_URL` or pass `--url` for a
different loopback port. The provider rejects non-loopback hosts and URLs containing credentials.
Credentials stay in environment variables and memory. They are not written to provider state.

Pass `--reveal-root /absolute/local/root` if transfer names are paths below one local directory.
The provider then offers **Reveal in Finder** only when the resolved file exists below that root.
Omit this option for remote-to-remote jobs or when rclone's names do not map to local paths.

Each ID hashes rclone's process `executeId`, its stats group or RC job ID, and the complete transfer
name. Two files named `report.pdf` in different directories or groups remain independent, while Islet
displays only `report.pdf`.
The state files contain only opaque Pulse IDs, completion fingerprints, a millisecond watermark,
and the enabled marker. They do not contain file names, paths, remote names, URLs, or credentials.

## Disable and recover

The long-running provider checks its local enabled flag before every RC request:

```sh
python3 Integrations/Pulse/providers/rclone/rclone_provider.py --disable
python3 Integrations/Pulse/providers/rclone/rclone_provider.py --enable
```

`--disable` also ends cached Pulse items. A running observer sees the flag, stops all RC polling,
and clears its live items. `SIGINT` and `SIGTERM` also stop polling and clean up. On restart, the
provider republishes active rclone transfers and ends opaque cached IDs that rclone no longer
reports. Successful and failed completions that happened while the provider was down are recovered
from `core/transferred` when they are newer than the stored watermark.

Use `--once` for a single observation cycle. The default interval is two seconds and must stay
between one and 30 seconds. Changed progress publishes immediately; unchanged active work receives
a 30-second heartbeat and expires after 90 seconds if the provider stops. Pulse rate-limit responses
use bounded exponential backoff.

## Test

```sh
python3 -m unittest discover -s tests -p 'test_*.py'
```
