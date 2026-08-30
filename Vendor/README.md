# MediaRemoteAdapter

Islet vendors the BSD-3-Clause licensed
[MediaRemoteAdapter](https://github.com/ungive/mediaremote-adapter) framework and
its Perl loader. `MediaRemoteAdapter-LICENSE` contains the upstream license.

## Pinned source

- Repository: `https://github.com/ungive/mediaremote-adapter`
- Commit: `3ac3d4bdf862c7b5399b4fba4df5689f5c38609a`
- Commit URL: `https://github.com/ungive/mediaremote-adapter/commit/3ac3d4bdf862c7b5399b4fba4df5689f5c38609a`
- Source archive and SHA-256: `MediaRemoteAdapter.provenance.json`

That commit was the tip of upstream `master` when Islet added the framework on
2026-07-22. The vendored framework and license match that commit. The loader at
`Islet/Resources/mediaremote-adapter.pl` applies the reviewed timeout change in
`MediaRemoteAdapter.loader.patch`. A clean build of the pinned commit and patch
with the pinned toolchain reproduces every checked-in artifact byte for byte.

## Rebuild and verify

Run these commands on macOS:

```sh
Scripts/rebuild-mediaremote-adapter.sh
Scripts/verify-mediaremote-adapter.sh \
  Vendor/mediaremote-adapter-build/MediaRemoteAdapter.framework
diff --brief --recursive --no-dereference \
  Vendor/MediaRemoteAdapter.framework \
  Vendor/mediaremote-adapter-build/MediaRemoteAdapter.framework
cmp Islet/Resources/mediaremote-adapter.pl \
  Vendor/mediaremote-adapter-build/mediaremote-adapter.pl
cmp Vendor/MediaRemoteAdapter-LICENSE \
  Vendor/mediaremote-adapter-build/LICENSE
```

The rebuild script downloads the exact source archive and CMake release listed
in `MediaRemoteAdapter.provenance.json`, checks their SHA-256 values, verifies
and applies the loader patch, checks the Xcode and SDK versions, and builds with
the recorded generator and deployment target. It writes only to ignored build
and download-cache directories.

The verifier checks the framework's full binary checksum, the checksum of each
architecture slice, architectures, exported symbols, `Info.plist`, signature
resources, loader script and patch, and code signature. CI verifies both the
checked-in framework and a clean rebuild.

## Review an update

1. Read the upstream commits between the old and proposed revisions. Pay
   particular attention to private-framework calls, exported entry points, and
   changes to the Perl loader.
2. Set the new immutable commit, archive URL, and archive checksum in
   `MediaRemoteAdapter.provenance.json`. Update pinned build tools only when the
   new source requires them.
3. Run `Scripts/rebuild-mediaremote-adapter.sh`. Review `nm -gjU -arch arm64`
   and `nm -gjU -arch x86_64` output against
   `MediaRemoteAdapter.expected-exports.txt`. Review the framework
   `Info.plist` against `MediaRemoteAdapter.expected-Info.plist`.
4. Replace the framework, loader, and license only after that review. Take all
   three from `Vendor/mediaremote-adapter-build`. If Islet needs a local loader
   change, keep it as a minimal reviewed patch against the pinned source.
   Regenerate the two expected files and artifact checksums in the provenance
   manifest from the reviewed build.
5. Run `Scripts/verify-mediaremote-adapter.sh`, the clean rebuild comparison
   above, Islet's arm64 and Intel tests, and `git diff --check`.

Never update a checksum merely to make the verifier pass. A checksum change is
the result of a reviewed source or toolchain change.
