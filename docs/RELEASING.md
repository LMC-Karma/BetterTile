# Public beta releases

BetterTile public betas are published as GitHub releases: a DMG containing an
**ad-hoc signed application**. The DMG archive itself carries no Apple code
signature; it is authenticated separately by the Sparkle **EdDSA signature**
recorded in the appcast. The app uses Sparkle 2.9.5 to discover and verify later
releases. Tags and release titles carry the beta label; Apple bundle versions
remain numeric.

The first release is:

- marketing version `0.1.0`
- bundle build `2`
- tag `v0.1.0-beta`
- release title `BetterTile 0.1.0 Beta`

Increase both the marketing version and numeric build for every later release.

## Three signing contexts

These are separate and easy to confuse:

| Context | Signature | Purpose |
| --- | --- | --- |
| Contributor builds from Xcode | the contributor's own Apple Development / Personal Team identity, from the gitignored `Config/LocalSigning.xcconfig` | keeps the local Accessibility grant across rebuilds |
| CI, and the build steps inside this script | none — `CODE_SIGNING_ALLOWED=NO` | unsigned validation builds only; never distributed |
| The published beta | ad-hoc (`-`), applied by `Tools/release-beta.sh` | the application inside the downloadable DMG |

`Tools/release-beta.sh` is the only place the distributed signature is applied.
It does not touch `Config/LocalSigning.xcconfig` and does not use a contributor
identity. See [DEVELOPMENT.md](DEVELOPMENT.md) for the contributor setup.

## Code signing the beta

The Release build inside the script runs with signing disabled, so the script
signs the bundle itself, inside-out:

1. `Sparkle.framework/Versions/B/XPCServices/Downloader.xpc`
2. `Sparkle.framework/Versions/B/XPCServices/Installer.xpc`
3. `Sparkle.framework/Versions/B/Updater.app`
4. `Sparkle.framework/Versions/B/Autoupdate`
5. `Sparkle.framework/Versions/B`
6. `BetterTile.app`

then verifies with `codesign --verify --deep --strict`, both on disk and again
on the copy inside the mounted DMG.

This is not optional. A bundle with no seal is reported by macOS as *damaged*
once it carries a quarantine attribute, with no **Open Anyway** path, which
would make the beta unopenable. Signing also repairs Sparkle's own signature,
which Xcode's embed step invalidates by stripping the framework's `Headers` and
`Modules` without re-signing.

The default identity is ad-hoc (`-`). `BETTERTILE_SIGNING_IDENTITY` overrides it
if a Developer ID certificate is ever available:

```sh
BETTERTILE_SIGNING_IDENTITY="Developer ID Application: …" Tools/release-beta.sh 0.2.0 notes.md
```

An ad-hoc identity makes the designated requirement a bare cdhash, which changes
with every build. macOS therefore treats each update as a different application
and **discards the Accessibility grant on every update**. While the beta is
ad-hoc signed, every set of release notes must tell testers to re-add BetterTile
in System Settings → Privacy & Security → Accessibility.

## Where release work happens

A working copy can sit under a file provider or other synchronising storage that
attaches its own extended attributes to managed files. `codesign` refuses to
sign anything carrying them:

```
resource fork, Finder information, or similar detritus not allowed
```

The script therefore creates all Xcode DerivedData and every artifact that
enters the distributed DMG — the copied app bundle, staging tree, Applications
shortcut, disk image, mount point, and appcast working files — in a unique
`mktemp` directory under `/private/tmp`. An exit trap removes only that exact
directory. Stripping extended attributes afterwards races whatever reapplies
them, so these release artifacts never acquire them in the first place.

The validation-only `swift package resolve`, `swift test`, and `swift build`
commands continue to use the checkout's normal `.build`; their outputs are not
copied into the application or DMG.

Only the finished, inspectable artifacts are copied back into
`.build/beta-release/v<version>-beta/`:

- `BetterTile-<version>-beta.dmg`
- `BetterTile-<version>-beta.dmg.sha256`
- `BetterTile-<version>-beta.md` (the release notes as published)
- `appcast.xml`

DerivedData and the staging tree are intentionally not retained.

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

A dry run may run from a feature branch. It runs the tests and builds, ad-hoc
signs and verifies the Release app, validates its Info.plist, creates and mounts
the DMG, re-verifies the signature through the mounted image, generates an EdDSA
signature for the DMG with the Keychain key, and records it in the appcast. The
finished artifacts are copied to `.build/beta-release/v<version>-beta/` for
manual inspection; the temporary working directory is removed.

The automated suite already covers the indicator state machine, the feedback URL
contents, and the read-only-volume decision. The following need a person, and
are the remaining gates before publishing:

- BetterTile and the Applications shortcut appear in the mounted DMG.
- Opening BetterTile directly from the mounted DMG shows the move-to-Applications
  explanation before Accessibility or update services start.
- An older test build discovers the update and turns the menu-bar icon blue.
- Sparkle's own update UI appears, shows the release notes, and requires user
  action before downloading and before installing.
- **Later** preserves the blue state; **Skip** and a confirmed no-update result
  clear it; a transient network failure preserves it.
- Sparkle rejects a deliberately modified archive.
- Installation, bundle replacement, and relaunch complete successfully.
- automatic-check preference changes persist and no system profile is sent.
- `codesign --verify --deep --strict` passes on the app inside the mounted DMG.
- A quarantined copy is offered **Open Anyway** in System Settings rather than
  being reported as damaged. Reproduce the quarantine with
  `xattr -w com.apple.quarantine "0081;0;BetterTile;" /Applications/BetterTile.app`.
- Accessibility is re-granted after an ad-hoc-signed update exactly as the
  release notes and README describe.

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

It publishes the DMG, SHA-256 checksum, notes, and `appcast.xml` as a public
GitHub release marked Latest. Sparkle reads the appcast through GitHub's stable
Latest-release asset URL:
`https://github.com/LMC-Karma/BetterTile/releases/latest/download/appcast.xml`.

After publication, confirm the release assets and appcast are public,
inspect the appcast version, asset URL, and EdDSA signature, then complete one
controlled update from an older build. Do not merge or publish automatically
from CI; the EdDSA private key is intentionally absent from GitHub Actions.
