# Public beta releases

BetterTile public betas are ad-hoc signed, un-notarized DMGs published as GitHub
prereleases. The app uses Sparkle 2.9.5 to discover and verify later releases.
Tags and release titles carry the beta label; Apple bundle versions remain
numeric.

The first release is:

- marketing version `0.1.0`
- bundle build `2`
- tag `v0.1.0-beta`
- release title `BetterTile 0.1.0 Beta`

Increase both the marketing version and numeric build for every later release.

## Code signing

Two independent signatures are involved. Do not confuse them.

**Apple code signature.** The Release build runs with signing disabled, so
`Tools/release-beta.sh` signs the bundle itself, inside-out: each Sparkle
component first, then `Sparkle.framework`, then `BetterTile.app`. This is not
optional. An unsealed bundle is reported by macOS as *damaged* once it carries a
quarantine attribute, with no **Open Anyway** path, which would make the beta
unopenable. Signing also repairs Sparkle's own signature, which Xcode's embed
step invalidates by stripping the framework's `Headers` and `Modules`.

The default identity is ad-hoc (`-`). Override it with
`BETTERTILE_SIGNING_IDENTITY` once a paid Developer ID certificate exists:

```sh
BETTERTILE_SIGNING_IDENTITY="Developer ID Application: …" Tools/release-beta.sh 0.2.0 notes.md
```

An ad-hoc identity makes the designated requirement a bare cdhash, which changes
with every build. macOS therefore treats each update as a different application
and **discards the Accessibility grant on every update**. Until a Developer ID
certificate is in use, every set of release notes must tell testers to re-add
BetterTile in System Settings → Privacy & Security → Accessibility. Notarization
additionally requires the hardened runtime, which is currently off.

## Sparkle signing key

Sparkle's official `generate_keys` tool created the EdDSA key. The public key is
committed in `Sources/BetterTileApp/Info.plist`; the private key remains in the
maintainer's login Keychain under Sparkle's default `ed25519` account.

Before the first public release, export the private key once with Sparkle's
official tool, store that export as an encrypted item in the maintainer's
password manager, and securely delete the temporary export. Never commit it,
paste it into an issue or pull request, or add it to GitHub Actions. The release
tool reads the live key directly from the login Keychain.

## Release notes

Write a short Markdown file for each beta. Include:

- the most important user-visible changes
- known limitations or permission changes
- any update, privacy, or data-handling change

Do not put checksums or signatures in the notes; the release tool generates
those from the exact DMG it publishes.

## Validate without publishing

From the repository root:

```sh
Tools/release-beta.sh --dry-run 0.1.0 path/to/notes.md
```

A dry run may run from a feature branch. It runs the tests and builds, code
signs and verifies the Release app, validates its Info.plist, creates and mounts
the DMG, signs the DMG with the Keychain EdDSA key, and generates an appcast.
Artifacts are left in `.build/beta-release/v<version>-beta/` for manual
inspection.

Confirm the following before merging the release change:

- BetterTile and the Applications shortcut appear in the mounted DMG.
- Opening BetterTile directly from the mounted DMG shows the move-to-Applications
  explanation before Accessibility or update services start.
- An older test build discovers the update and turns the menu-bar icon blue.
- **Later** preserves the blue state; **Skip** and a confirmed no-update result
  clear it; transient network failures preserve it.
- Sparkle rejects a deliberately modified archive.
- automatic-check preference changes persist and no system profile is sent.
- `codesign --verify --deep --strict` passes on the app inside the mounted DMG.
- A quarantined copy is offered **Open Anyway** in System Settings rather than
  being reported as damaged. Reproduce the quarantine with
  `xattr -w com.apple.quarantine "0081;0;BetterTile;" /Applications/BetterTile.app`.
- The Accessibility re-grant step after an update matches what the release notes
  and README tell testers to do.

## Publish

Only publish after the draft pull request passes CI, the maintainer approves it,
and the change is merged. Check out the clean, current `main`, then run:

```sh
git switch main
git pull --ff-only origin main
Tools/release-beta.sh 0.1.0 path/to/notes.md
```

The command refuses to publish unless `main` is clean and matches
`origin/main`, the project version is correct and newer than the existing feed,
the tag and release are unused, GitHub CLI authentication works, the EdDSA key
matches the public key in the app, and all validation succeeds.

It publishes the DMG, SHA-256 checksum, and notes as a public GitHub prerelease.
Only after the release asset is reachable does it commit the generated
`appcast.xml` to the dedicated `updates` branch. That branch is the source of
`https://raw.githubusercontent.com/LMC-Karma/BetterTile/updates/appcast.xml`.

After publication, confirm the release assets and raw appcast are public,
inspect the appcast version, asset URL, and EdDSA signature, then complete one
controlled update from an older build. Do not merge or publish automatically
from CI; the EdDSA private key is intentionally absent from GitHub Actions.
