# Public beta releases

BetterTile public betas are published as GitHub releases: a DMG containing an
application signed with the maintainer's **Developer ID Application**
certificate and notarized by Apple. The app and the DMG each carry a stapled
notarization ticket. Sparkle authenticates the DMG separately, with the
**EdDSA signature** recorded in the appcast. The app uses Sparkle 2.10.1 to discover and verify later releases. Tags
and release titles carry the beta label; Apple bundle versions remain numeric.

The first release is:

- marketing version `0.1.0`
- bundle build `2`
- tag `v0.1.0-beta`
- release title `BetterTile 0.1.0 Beta`

Increase the numeric build for every later release. Sparkle compares
`CFBundleVersion` / `sparkle:version` to determine update order. The marketing
version (`CFBundleShortVersionString` / `sparkle:shortVersionString`) is a
unique, three-component numeric display label; it must not reuse an existing
feed version or release tag.

For example, `0.4.6` (build `12`) follows `0.4.51` (build `11`). The display
labels do not determine update order. The release script rejects a build that
is less than or equal to any published build, even with a different label.
See [Sparkle's internal build number documentation](https://sparkle-project.org/documentation/publishing/#internal-build-numbers).

## Supported Macs and debug symbols

Release builds support Apple silicon (arm64) only. Intel Macs are no longer
supported. Sparkle 2.10.1 generates
`<sparkle:hardwareRequirements>arm64</sparkle:hardwareRequirements>` from the
app's executable. The release script rejects an appcast that lacks this element
on the new build. Intel users stay on the last compatible universal build;
Sparkle filters out the Apple silicon release. Retain that universal item and
its download in the production feed. The minimum system version remains macOS 26.0. Debug build settings
are unchanged.

The Release build produces a stripped executable and `BetterTile.app.dSYM`.
The script uses `xcodebuild build` with Release deployment postprocessing;
archive/export is not needed. Xcode generates the dSYM before stripping.
The script checks that the arm64 executable and dSYM UUIDs match, then retains
`BetterTile.app.dSYM` beside the DMG in the versioned artifact directory.
The dSYM is not inside the app or DMG and is not uploaded by the script.
Keep it privately with the exact release artifacts and source commit for crash
analysis. The dSYM contains full symbols and absolute source paths. Never
upload it to GitHub or attach it to a release; the script retains it locally
only.

Check the UUID in a crash report's Binary Images section against both files:

```sh
dwarfdump --uuid BetterTile.app/Contents/MacOS/BetterTile
dwarfdump --uuid BetterTile.app.dSYM
```

For an arm64 crash address, supply the image load address from that section:

```sh
atos -arch arm64 -o BetterTile.app.dSYM/Contents/Resources/DWARF/BetterTile \
  -l <image-load-address> <crash-address>
```

## Three signing contexts

These are separate and easy to confuse:

| Context | Signature | Purpose |
| --- | --- | --- |
| BetterTile Debug builds from Xcode | the contributor's own Apple Development / Personal Team identity, from the gitignored `Config/LocalSigning.xcconfig` | keeps the separate Debug Accessibility grant across rebuilds |
| CI, and the build steps inside this script | none — `CODE_SIGNING_ALLOWED=NO` | unsigned validation builds only; never distributed |
| The published beta | the maintainer's Developer ID Application certificate, applied by `Tools/release-beta.sh`, then notarized | lets Gatekeeper open the download without **Open Anyway**, and gives successive releases one stable identity |

`Tools/release-beta.sh` is the only place the distributed signature is applied.
It does not touch `Config/LocalSigning.xcconfig` and does not use a contributor
identity. See [DEVELOPMENT.md](DEVELOPMENT.md) for the contributor setup.

## Code signing the beta

The Release build inside the script runs with signing disabled, so the script
signs the bundle itself, inside-out:

1. `Sparkle.framework/Versions/B/XPCServices/Downloader.xpc` (its
   entitlements are preserved, as Sparkle documents)
2. `Sparkle.framework/Versions/B/XPCServices/Installer.xpc`
3. `Sparkle.framework/Versions/B/Updater.app`
4. `Sparkle.framework/Versions/B/Autoupdate`
5. `Sparkle.framework/Versions/B`
6. `BetterTile.app`

then verifies with `codesign --verify --deep --strict`, both on disk and again
on the copy inside the mounted DMG.

This is not optional. A bundle with no seal is reported by macOS as *damaged*
once it carries a quarantine attribute, which would make the release
unopenable. Signing also repairs Sparkle's own signature, which Xcode's embed
step invalidates by stripping the framework's `Headers` and `Modules` without
re-signing.

With a Developer ID identity, every `codesign` call also uses the hardened
runtime (`--options runtime`) and a secure timestamp (`--timestamp`).
Notarization requires both. BetterTile needs no hardened-runtime entitlements:
Accessibility needs none, and the system libraries it opens are Apple-signed.

Dry runs default to ad-hoc signing (`-`) without the hardened runtime. A
hardened, ad-hoc signed app cannot load an ad-hoc signed framework, because
library validation requires the same Team ID, and an ad-hoc signature has
none. Publication fails unless `BETTERTILE_SIGNING_IDENTITY` selects a valid
Developer ID Application identity in the login Keychain. The name or the
SHA-1 hash from `security find-identity -v -p codesigning` both work:

```sh
BETTERTILE_SIGNING_IDENTITY="Developer ID Application: <Name> (<TEAMID>)" \
  Tools/release-beta.sh 0.7.0 notes.md
```

The script pins the Team ID in `expected_team_id`. The signed app, its Sparkle
components, the DMG, and the app inside the mounted DMG must each satisfy a
requirement for an Apple-issued Developer ID certificate of that team. The app
must also carry the `com.lmckarma.BetterTile` identifier. Another certificate
with the same Keychain name does not pass.

The certificate gives successive releases a stable designated requirement, so
macOS keeps one Accessibility grant across updates. A renewed Developer ID
certificate from the same team satisfies the same requirement. The first
Developer ID release is a one-time identity change from the self-signed
`BetterTile Beta` certificate used from 0.4.1 to 0.6.3: users grant
Accessibility again once, and its release notes must say so. Sparkle accepts
that update because its EdDSA signature is valid; Sparkle allows a change of
either the EdDSA key or the code-signing certificate, not both at once.

Certificate loss, compromise, or a change of team is an identity-breaking event
that requires a warning and focused release tests. Private keys, credentials,
and recovery instructions stay outside this repository.

## Notarization

Publication always notarizes. After signing, the script:

1. zips the app with `ditto`, submits it with `xcrun notarytool submit --wait`,
   and staples the ticket to the app, so a copy dragged out of the DMG passes
   Gatekeeper offline;
2. creates the DMG, signs it with the Developer ID identity and a timestamp,
   submits it, and staples its ticket;
3. checks both with `xcrun stapler validate` and `spctl --assess`, which must
   report `source=Notarized Developer ID`, on disk and through the mounted DMG;
4. only then computes the checksums and the Sparkle EdDSA signature. Stapling
   changes the DMG's bytes, so a signature made earlier would fail in Sparkle.

`notarytool` reads credentials from a Keychain profile, `BetterTile-Notary` by
default, or the name in `BETTERTILE_NOTARY_PROFILE`. Create it once on each
release Mac with `xcrun notarytool store-credentials`. An App Store Connect
team API key with the Developer role is preferred; an app-specific password also
works. The script checks the profile before the build and stops at once if it
is missing or rejected.

A rejected submission stops the release before anything is published, and names
Apple's log. The script reads the verdict from `notarytool`'s JSON result, not
its exit status. Each submission's result and log are kept in
`.build/beta-release/v<version>-beta/notarization/`. Each submission usually
takes a few minutes.

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

The validation-only `swift package resolve`, `Tools/test.sh`, and `swift build`
commands continue to use the checkout's normal `.build`; their outputs are not
copied into the application or DMG. `Tools/test.sh` runs `swift test`, checks
complete passing products, and records `tests.log` in the private release workspace.

Appcast hardware validation requires an arm64 requirement on the requested build.
It accepts the legacy Sparkle namespace and the literal `sparkle:` prefix
compatibility form. Build identification still requires a recognized Sparkle
namespace; the literal `sparkle:` prefix is accepted on the requirement element
regardless of its namespace.

Only the finished, inspectable artifacts are copied back into
`.build/beta-release/v<version>-beta/`:

- `BetterTile-<version>-beta.dmg`
- `BetterTile-<version>-beta.dmg.sha256`
- `BetterTile.dmg` and `BetterTile.dmg.sha256` (a byte-identical copy of the
  DMG under a fixed name, and its checksum)
- `BetterTile-<version>-beta.md` (the release notes as published)
- `appcast.xml`
- `BetterTile.app.dSYM` (local symbols; not a published asset)
- `notarization/` (Apple's submission results and logs, when notarized; not
  published assets)

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
signature for the DMG, and records it in the appcast. Dry runs create a fresh
disposable EdDSA key without accessing the release Keychain. They substitute
its public key only in the temporary built app before code signing, and pass
the private seed explicitly to Sparkle. The temporary key is deleted on exit.
Dry-run artifacts cannot update production installations. A dry run does not
notarize unless it is given `--notarize` and a Developer ID identity:

```sh
BETTERTILE_SIGNING_IDENTITY="Developer ID Application: <Name> (<TEAMID>)" \
  Tools/release-beta.sh --dry-run --notarize 0.7.0 path/to/notes.md
```

A notarized dry run submits the build to Apple but publishes nothing. Use it
before the first release after a signing or notarization change. Dry runs fetch the
public appcast read-only and reject already published versions or build
numbers. They keep that feed separate from their generated test appcast so
production entries are not signed with the disposable key. Never publish their
appcast or DMG. The finished artifacts are
copied to `.build/beta-release/v<version>-beta/` for inspection; the temporary
working directory is removed.

Before publishing, inspect the artifact and test the user paths affected by the
release. For an ordinary beta, confirm that the app in the built DMG launches.
Use the locally signed Debug app and its existing Accessibility grant to confirm
that a basic window action and the affected app behavior work. Also confirm that
the Sparkle dependency, updater integration, feed URL, signing configuration,
appcast generation, and update packaging have not changed since the previous
release.

Run a controlled update from an older supported build when the release changes
any of these surfaces: the Sparkle dependency, updater integration, feed URL,
signing configuration, appcast generation, and update packaging. Test the fresh
release app's permission flow when signing or
Accessibility behavior changes. Add other focused checks when a release changes
permissions or macOS integration. Use `docs/BENTO_TESTING.md` as guidance when
Bento behavior changes. Record material risks or skipped checks; the maintainer
decides whether they block the release.

## Publish

Only publish after the pull request passes CI, review threads are resolved, the
maintainer approves the final version, and the change is merged. Check out the
clean, current `main`, then run:

```sh
git switch main
git pull --ff-only origin main
BETTERTILE_SIGNING_IDENTITY="Developer ID Application: <Name> (<TEAMID>)" \
  Tools/release-beta.sh 0.1.0 path/to/notes.md
```

The command refuses to publish unless `main` is clean and matches
`origin/main`, the project version is correct and newer than the existing feed,
the tag and release are unused, GitHub CLI authentication works, the EdDSA key
matches the public key in the app, and all validation succeeds.

Publication creates the tag at the exact commit validated before packaging.
If remote `main` advances during validation, the tag still names the source
used to build the artifacts.

It publishes the DMG, SHA-256 checksum, notes, and `appcast.xml` as a public
GitHub release marked Latest. Sparkle reads the appcast through GitHub's stable
Latest-release asset URL:
`https://github.com/LMC-Karma/BetterTile/releases/latest/download/appcast.xml`.

The release also carries `BetterTile.dmg` and `BetterTile.dmg.sha256`, a
byte-identical copy of the versioned DMG under a fixed name. The website and
README Download links use
`https://github.com/LMC-Karma/BetterTile/releases/latest/download/BetterTile.dmg`,
which GitHub resolves to the newest release, so they need no update after a
release. The appcast still points Sparkle at the versioned DMG. The script
confirms that both DMG URLs answer after publication.

One time only: releases up to 0.6.2 have no `BetterTile.dmg`, so the website
links to the latest-release page for now. After the first release that
carries `BetterTile.dmg`, change the website's single download-link constant
on `gh-pages` to the direct file URL above.

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
