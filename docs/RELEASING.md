# Public beta releases

BetterTile public betas are unsigned DMGs published as GitHub prereleases. The
app uses Sparkle 2.9.5 to discover and verify later releases. Tags and release
titles carry the beta label; Apple bundle versions remain numeric.

The first release is:

- marketing version `0.1.0`
- bundle build `2`
- tag `v0.1.0-beta`
- release title `BetterTile 0.1.0 Beta`

Increase both the marketing version and numeric build for every later release.

## Signing key

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

A dry run may run from a feature branch. It runs the tests and builds, validates
the unsigned Release app, creates and mounts the DMG, signs it with the Keychain
EdDSA key, and generates an appcast. Artifacts are left in
`.build/beta-release/v<version>-beta/` for manual inspection.

Confirm the following before merging the release change:

- BetterTile and the Applications shortcut appear in the mounted DMG.
- Opening BetterTile directly from the mounted DMG shows the move-to-Applications
  explanation before Accessibility or update services start.
- An older test build discovers the update and turns the menu-bar icon blue.
- **Later** preserves the blue state; **Skip** and a confirmed no-update result
  clear it; transient network failures preserve it.
- Sparkle rejects a deliberately modified archive.
- automatic-check preference changes persist and no system profile is sent.
- Accessibility still works after an unsigned update, or reauthorization is
  documented as a public-beta limitation.

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
