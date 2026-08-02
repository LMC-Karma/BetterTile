# Development setup

Everything a new contributor needs to build, run, and test BetterTile on their
own Mac. Read [AGENTS.md](../AGENTS.md) for the architecture rules and
[CONTRIBUTING.md](../CONTRIBUTING.md) for the branch/PR workflow.

---

## Prerequisites

- **Apple Silicon Mac**
- **macOS 26** or later
- **Xcode 26 / Swift 6.3** or later
- A **free Apple ID** (no paid Apple Developer Program needed — see signing below)

---

## 1. Clone

```sh
git clone https://github.com/LMC-Karma/BetterTile.git
cd bettertile
```

---

## 2. Sign the app with your own free Personal Team

BetterTile controls other windows through the Accessibility API. macOS grants
that permission to a specific **code-signing identity**, so each developer signs
the app on their own machine. You do **not** need the paid ($99/yr) Apple
Developer Program — a free **Personal Team** is enough.

**One-time setup on your Mac:**

1. **Xcode → Settings → Accounts →** add your Apple ID (the `+` button).
2. Make sure Xcode has created an Apple Development certificate for that
   account, then find its Team ID:

   ```sh
   security find-identity -v -p codesigning
   ```

   The 10-character value in parentheses after your Apple Development identity
   is the Team ID. If more than one identity is listed, choose the intended
   Personal Team.
3. Create your private signing configuration:

   ```sh
   cp Config/LocalSigning.xcconfig.example Config/LocalSigning.xcconfig
   ```

   Replace `YOUR_TEAM_ID` in the copied file with the Team ID from step 2.
4. Confirm Git will never publish it:

   ```sh
   git check-ignore Config/LocalSigning.xcconfig
   ```
5. Open `BetterTile.xcodeproj`. Do not change the Team or bundle identifier in
   the shared project; signing is supplied by your local configuration.

The repository tracks only `Signing.xcconfig` and the example. Each contributor's
`LocalSigning.xcconfig` is gitignored, so changing signing identities never
changes `project.pbxproj`.

### Let an agent perform the setup

After cloning, give your coding agent this instruction:

> Set up BetterTile for development on this Mac. Follow `AGENTS.md` and
> `docs/DEVELOPMENT.md`. Configure the gitignored local signing file, but never
> access or export signing private keys, change the bundle identifier, or commit
> machine-specific configuration.

The agent can detect an existing Apple Development identity, create the local
configuration, validate the build, and open the Xcode project. Account login,
certificate creation, `sudo`, and the Accessibility permission remain explicit
user actions.

### Why not just "Sign to Run Locally"?

Xcode's ad-hoc *Sign to Run Locally* identity changes on **every** rebuild, so
macOS drops the Accessibility grant each time and you re-grant constantly. A
Personal Team gives you a **stable Apple Development identity**, so the grant
survives rebuilds on your machine.

### The one free-tier limitation

A free Personal Team's provisioning profile **expires after 7 days**. If you're
actively developing you rebuild from Xcode well within that, so it never bites.
If the app ever refuses to launch after a week off, just rebuild from Xcode and
it's signed fresh. (When we later add non-developer testers, we'll distribute a
notarized build so they don't deal with signing at all — that step needs the
paid program and is out of scope here.)

---

## 3. Run and grant Accessibility

1. Select the shared **BetterTile** scheme and **Run** (⌘R). BetterTile launches
   into the **menu bar** (the Dock icon is optional, off by default).
2. On first launch it explains how to grant Accessibility. Open
   **System Settings → Privacy & Security → Accessibility**, and enable
   **BetterTile**.
3. That's it — the grant is stored **per machine**, so every contributor does
   this once on their own Mac. It is not shareable across machines (macOS
   security design), but thanks to Personal Team signing it survives your
   rebuilds.

If you revoke and re-grant, or switch signing identity, remove the stale
BetterTile entry from the Accessibility list once, then re-add the freshly
signed build.

---

## 4. Run the tests

Before opening a PR:

```sh
swift test        # unit + fake-system integration tests
swift build       # library build
```

Full application-bundle build (what CI also runs):

```sh
xcodebuild -project BetterTile.xcodeproj -scheme BetterTile \
  -configuration Debug CODE_SIGNING_ALLOWED=NO build
```

> **Note:** `swift test` needs the full Xcode toolchain. If you see
> `no such module 'Testing'`, point the command line at Xcode:
> `sudo xcode-select -s /Applications/Xcode.app/Contents/Developer`.

---

## 5. Branch, commit, and open a PR

Never work on `main`. Branch from the latest `origin/main`:

```sh
git fetch origin
git switch -c feat/short-description origin/main
```

Prefixes: `feat/`, `fix/`, `docs/`, `refactor/`. Stage only the files you
changed (avoid `git add -A`), then:

```sh
git push -u origin feat/short-description
gh pr create --draft --base main
```

Mark the PR **Ready for review** when it's done. Wait for CI and review before
merging.

---

## 6. Automated review on pull requests

- **Claude** reviews every update to a non-draft PR, including when it is opened,
  marked **Ready for review**, or receives new commits. It comments inline on
  the diff. You can also write **`@claude`** in a PR comment to ask a follow-up.
- **GPT/Codex** is available as a second opinion through ChatGPT. Write
  **`@codex review`** in a PR comment to request a review, or enable automatic
  reviews in [Codex settings](https://chatgpt.com/codex/settings/code-review).

Repo maintainer setup for the Claude reviewer (one time):

1. Install the **Claude GitHub App** on the repository.
2. Run `claude setup-token` locally (needs a Claude Pro/Max subscription) to
   generate an OAuth token.
3. Add it as a repository secret named **`CLAUDE_CODE_OAUTH_TOKEN`**
   (Settings → Secrets and variables → Actions).

The workflow lives at [.github/workflows/claude-review.yml](../.github/workflows/claude-review.yml).

---

## Architecture in one minute

```
BetterTileApp  →  BetterTileMacOS  →  BetterTileCore
   (SwiftUI)       (AppKit + AX)       (pure logic)
```

`BetterTileCore` is pure, deterministic placement policy with **no** AppKit or
Accessibility imports — that's what makes it directly testable. `BetterTileMacOS`
owns every side effect and all coordinate conversion. `BetterTileApp` is SwiftUI
scenes only. Full detail in [docs/ARCHITECTURE.md](ARCHITECTURE.md).
