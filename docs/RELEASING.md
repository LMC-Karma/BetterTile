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
| BetterTile Debug builds from Xcode | the contributor's own Apple Development / Personal Team identity, from the gitignored `Config/LocalSigning.xcconfig` | keeps the separate Debug Accessibility grant across rebuilds |
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

Sparkle verifies update archives against the EdDSA public key committed in
`Sources/BetterTileApp/Info.plist`. The release tool uses Sparkle's standard
local signing configuration. Configure and back up the corresponding private
signing material outside this repository through private operator instructions.
Keep private keys, storage details, and recovery instructions out of tracked
files, logs, issues, pull requests, and CI.

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
signature for the DMG, and records it in the appcast. The finished artifacts are
copied to `.build/beta-release/v<version>-beta/` for inspection; the temporary
working directory is removed.

Before publishing, inspect the artifact and test the user paths affected by the
release. For an ordinary beta, confirm that the app in the built DMG launches.
Use the locally signed Debug app and its existing Accessibility grant to confirm
that a basic window action and the affected app behavior work. Also confirm that
the Sparkle dependency, updater integration, feed URL, signing configuration,
and appcast generation have not changed since the previous release.

Run a controlled update from an older supported build when the release changes
Sparkle, update configuration, signing, feed generation, or update packaging.
Test the fresh release app's permission flow when signing or Accessibility
behavior changes. Add other focused checks when a release changes permissions
or macOS integration. Use `docs/BENTO_TESTING.md` as guidance when Bento
behavior changes. Record material risks or skipped checks; the maintainer
decides whether they block the release.

## Publish

Only publish after the pull request passes CI, review threads are resolved, the
maintainer approves the final version, and the change is merged. Check out the
clean, current `main`, then run:

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

After publication, confirm the release assets and appcast are public, then
inspect the appcast version, asset URL, and EdDSA signature. The maintainer can
check the update on an installed copy. Require a controlled update from an
older build only when the Sparkle or update surfaces named above changed.
Publishing is a deliberate maintainer action and does not run automatically
from CI.

Also confirm that the address the published application will actually ask for
serves the release. Read the URL out of the shipped bundle rather than trusting
this document, because the value that matters is the one compiled into the app
testers are running:

```sh
curl -sfL "$(/usr/libexec/PlistBuddy -c 'Print :SUFeedURL' \
    /Applications/BetterTile.app/Contents/Info.plist)" \
    | grep -E 'sparkle:(version|shortVersionString)'
```

The release tool already polls the Latest-release asset URL and reports if it
does not yet serve the new build. That check can lag behind GitHub's CDN by a
minute; re-run it before announcing rather than treating the first failure as
final.

## Relocating the appcast

Moving the feed to a new address strands every installation that predates the
move: those builds keep asking the old URL, and once it stops answering they
report only a generic update error, with no way to discover any later release.

Before removing an old feed location, either rebuild and replace the previous
release so a fresh download carries the new `SUFeedURL`, or leave the old
location serving an appcast that points at the current release until no
installation is still asking for it. Removing the old address first cannot be
undone from the users' side — a stranded build has to be replaced by hand.
