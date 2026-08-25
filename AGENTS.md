# AGENTS.md

Instructions for AI coding agents working in this repository. Human
contributors should read [CONTRIBUTING.md](CONTRIBUTING.md).

## Project

BetterTile is a native macOS window manager. It provides keyboard and drag
snapping, linked resizing, and adaptive Bento tiling. It uses Swift 6.3,
SwiftUI, AppKit, and the public Accessibility API.

BetterTile is free. It has no advertising, behavioral tracking, or sale of user
data.

## Read the relevant guide

- Read [CONTEXT.md](CONTEXT.md) before domain or user-behavior work. Use its
  terms. Add a term only when a distinct project concept needs one stable name.
- Read [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) before changing layers,
  coordinates, window mutations, application integrations, or updates.
- Read [SECURITY.md](SECURITY.md) before changing networking, permissions,
  dependencies, user data, privileged components, private APIs, distribution,
  or updates.
- Read [docs/DEVELOPMENT.md](docs/DEVELOPMENT.md) before setting up a machine,
  changing signing, or diagnosing the local build environment.
- Read [docs/BENTO_TESTING.md](docs/BENTO_TESTING.md) before changing Bento event
  handling, settlement, recovery, or placement transactions.
- Read [docs/RELEASING.md](docs/RELEASING.md) before changing a version, release,
  appcast, distributed signature, or update feed.

## Build and test

Run focused checks while you work. Before opening a ready pull request, run:

```sh
swift test
xcodebuild -project BetterTile.xcodeproj -scheme BetterTile \
  -configuration Debug CODE_SIGNING_ALLOWED=NO build
```

Add tests for geometry, state transitions, configuration migrations, and
failure paths. Test `BetterTileMacOS` with the fake window system in
`Tests/BetterTileMacOSTests/`, not with live Accessibility.

Use judgment for checks that require live macOS behavior or hardware. Run them
when the change affects behavior that automated tests cannot cover, and record
what was checked or skipped. The maintainer decides whether a remaining manual
check blocks merge or release.

`Package.swift` exposes libraries only. The runnable app comes from
`BetterTile.xcodeproj`. Keep it that way.

## Architecture limits

Keep this dependency direction:

```
BetterTileApp  →  BetterTileMacOS  →  BetterTileCore
   (SwiftUI)       (AppKit + AX)       (pure logic)
```

- `BetterTileCore` contains deterministic policy. It imports no AppKit,
  Accessibility, or macOS UI framework.
- `BetterTileMacOS` owns Accessibility, coordinate conversion, window-system
  integration, and window mutations.
- `BetterTileApp` owns the application lifecycle, UI integrations, and Sparkle.
- Core uses top-left logical points. Convert AppKit's bottom-left coordinates at
  the `BetterTileMacOS` boundary.
- Route every window mutation through the main-actor `WindowCoordinator`.
- The app delegate owns `SPUStandardUpdaterController` and implements
  `SPUUpdaterDelegate`. Keep updater APIs out of `BetterTileCore`.

## Security limits

Use public Apple APIs by default. BetterTile accepts no SIP workaround or code
injection.

Get maintainer approval through a written design discussion before implementing
a private API. Follow the review, fallback, test, and disclosure rules in
`SECURITY.md`.

Networking, dependencies, permissions, privileged components, user-data
handling, distribution, updates, and intentional architecture changes also
need the benefit, review, tests, and disclosure required by `SECURITY.md`. New
permissions need an in-product explanation before the system prompt. Record
compatible licensing, provenance, and attribution for adapted code.

Sparkle is the only approved runtime dependency.

## Work boundaries

- Keep one clear goal in each task. The goal can come from the user request, a
  discussion, an issue, or the pull-request body. A GitHub issue is optional.
- Clarify an unclear goal before editing. Use a written design discussion when
  an approval rule requires one.
- Keep one topic in each pull request. Report nearby problems without adding
  them unless they block safe completion.
- Use subagents only for independent work. Use separate branches and worktrees
  for parallel writers, give each writer non-overlapping files, and combine the
  work only after each part passes its checks.
- Add a repository skill only after the same manual workflow succeeds several
  times. Use real request phrases as its triggers.
- Improve these rules after a repeated failure or one serious safety failure.
  Avoid permanent rules for isolated minor corrections.

## Writing

Use plain technical English. These rules take inspiration from
[ASD-STE100 Simplified Technical English](https://www.asd-ste100.org/about_STE.html);
they do not claim formal compliance.

- Lead with the result. Add only the context needed to understand or act.
- Keep one topic in each sentence. Prefer short sentences and concrete verbs.
- Prefer active voice when it makes the responsible actor clear.
- Use one term for one concept. Use the BetterTile terms in `CONTEXT.md`.
- Name the behavior, file, command, or failure directly. Explain unavoidable
  jargon the first time it appears.
- Describe changes as the problem, behavior before and after, evidence, and
  anything not checked.
- If a reader says an explanation is unclear, rewrite it from the beginning
  with the missing context.

Apply these rules to agent replies, plans, issues, pull requests, review
comments, commit messages, and technical documentation.

## Git and pull requests

- Use local Git and `gh` for `LMC-Karma/BetterTile`. Fetch `origin/main` before
  starting.
- Branch as `feat/<short-description>`, `fix/<short-description>`,
  `docs/<short-description>`, or `refactor/<short-description>`.
- Commit and push only on a branch. Keep `main` unchanged.
- Preserve unrelated work. Stage explicit files instead of using `git add -A`.
- Ask the user for the exact action and target before force-pushing, using
  `git clean` to delete files, running `git reset --hard`, or deleting a branch.
- Open a ready pull request with `gh pr create --base main` after the change and
  local checks are complete. Use `--draft` only when the user requests a draft
  or the purpose is early feedback.
- Complete the pull-request body. Record checks that ran and checks that did not
  run.
- Verify automated review comments against the code, tests, and project rules.
  Fix confirmed faults. Explain false alarms and infrastructure failures.
- Merge only after CI passes, review is complete, review threads are resolved,
  and the maintainer approves the final pushed version.
- If automated review cannot run, report the failure and wait for a retry or a
  maintainer decision.
- When abandoning work, close its pull request and return the workspace to
  `origin/main`. Keep the branch unless the user asks to delete it.

## Local files

`/Local/` contains private, gitignored notes and scratch work. Keep its contents
out of tracked files and public documentation.
