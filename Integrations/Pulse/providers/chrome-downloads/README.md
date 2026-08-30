# Chrome downloads provider

This unpacked Manifest V3 extension observes Chrome's documented `downloads` API. A native
messaging host translates the minimum download state into Pulse commands. Neither component reads
the Chrome History database.

## Install

1. Start Islet and leave Pulse enabled.
2. Open `chrome://extensions`, enable Developer mode, choose **Load unpacked**, and select this
   directory.
3. Copy the 32-letter extension ID shown by Chrome.
4. Run `./install-native-host.sh EXTENSION_ID` from this directory.
5. Reload the extension once so Chrome reconnects to the new native host.

Chrome requires the native-host manifest to name the exact extension ID. The installer writes
`~/Library/Application Support/Google/Chrome/NativeMessagingHosts/dev.islet.pulse.chrome_downloads.json`
with mode `0600`. It points to `native_host.py` in this checkout. Move the provider directory first
if it needs a permanent location.

Open the extension's **Options** page to disable or re-enable observation. Disabling removes all
three Chrome download listeners, stops the two-second active-download refresh, ends current Pulse
items, clears reveal mappings, and closes the native host. Chrome download IDs are persistent
across browser sessions. A random profile ID stored in `chrome.storage.local` separates identical
download IDs from different Chrome profiles.

## Data handling

The extension sends the native host only the numeric ID, local filename, byte counts, state,
pause flag, error category, and existence flag. It does not send source URLs or referrers. The
native host uses the full filename only for an in-memory Finder reveal mapping and displays the
base name in Islet. Chrome's cancellation states send `end`; other interruptions publish a failed
event. Completed and failed events use Pulse's default eight-second expiry.

The native host reads the Pulse token for each command through the shared client. It never returns
the token to Chrome or writes it anywhere. Progress searches happen every two seconds, but the
provider only publishes changed values. Pulse rate-limit responses use bounded exponential
backoff.

## Test

```sh
node --test tests/test_provider_core.js
python3 -m unittest discover -s tests -p 'test_*.py'
```
