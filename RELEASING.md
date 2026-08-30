# Releasing Islet

GitHub Actions runs the complete build, test, lint, and static-analysis suite on pull requests and
on pushes to `main`. A `vMAJOR.MINOR.PATCH` tag on a commit in `main` starts a release after the
same checks pass again.

The release workflow builds a universal `arm64` and `x86_64` app, signs it with Developer ID,
submits it to Apple's notary service, staples the ticket, verifies it with Gatekeeper, and attaches
the app zip and its SHA-256 checksum to a GitHub release. It will not publish an unsigned or
unnotarized build.

## One-time repository setup

Create a GitHub environment named `release`. Protect it with required reviewers if releases should
need approval. Add these environment secrets:

- `DEVELOPER_ID_APPLICATION_P12`: Base64 of a Developer ID Application certificate and private key
  exported as PKCS#12.
- `DEVELOPER_ID_APPLICATION_P12_PASSWORD`: The PKCS#12 export password.
- `APP_STORE_CONNECT_KEY_ID`: The key ID for an App Store Connect API key that can notarize apps.
- `APP_STORE_CONNECT_ISSUER_ID`: The API key issuer ID.
- `APP_STORE_CONNECT_PRIVATE_KEY`: The complete contents of the API key's `.p8` file.

The certificate must contain a Developer ID Application identity. The workflow signs the
`dev.islet` bundle identifier. Store these values as secrets, not repository variables or files.

## Publish a release

Start from an up-to-date, clean `main` checkout, then create and push an annotated tag:

```sh
git switch main
git pull --ff-only
git tag -a v1.2.3 -m "Islet 1.2.3"
git push origin v1.2.3
```

The tag supplies `CFBundleShortVersionString`. The GitHub Actions run number supplies the numeric
`CFBundleVersion`. If the workflow fails, fix the cause and create a new version tag. Do not move a
published release tag.
