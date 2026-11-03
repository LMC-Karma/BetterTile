# Development setup

Everything a new contributor needs to build, run, and test BetterTile on their
own Mac. Read [AGENTS.md](../AGENTS.md) for the architecture rules and
[CONTRIBUTING.md](../CONTRIBUTING.md) for the branch and pull-request workflow.
The canonical security, privacy, dependency, networking, and permissions policy
is [SECURITY.md](../SECURITY.md).

---

## Prerequisites

- **Apple Silicon Mac**
- **macOS 26** or later
- **Xcode 26 / Swift 6.3** or later, with its **Metal Toolchain** component.
  `BetterTileMacOS` precompiles a Metal shader. If a build fails with
  "missing Metal Toolchain", run `xcodebuild -downloadComponent MetalToolchain`
  once (about 840 MB).
- A **free Apple ID** (no paid Apple Developer Program needed — see signing below)

---

## 1. Clone

```sh
git clone https://github.com/LMC-Karma/BetterTile.git
cd BetterTile
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
5. Open `BetterTile.xcodeproj`. Do not change the Team or bundle identifiers in
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
it's signed fresh.

### This has nothing to do with the published beta

Three signing contexts exist and they never touch each other:

- **Your BetterTile Debug Xcode builds** use *your* Apple Development identity from your
  gitignored `Config/LocalSigning.xcconfig`. Nothing here is committed.
- **CI and `swift build` / `swift test`** build with `CODE_SIGNING_ALLOWED=NO`.
  Those are unsigned validation builds and are never distributed.
- **The published beta** uses the maintainer-held, self-signed `BetterTile Beta`
  identity through `Tools/release-beta.sh` alone. It is not signed with a
  Developer ID. See [RELEASING.md](RELEASING.md).

Nothing you do locally changes what testers download, and the release tool never
reads your signing identity.

---

## 3. Run and grant Accessibility

1. Select the shared **BetterTile** scheme and **Run** (⌘R). Xcode builds
   **BetterTile Debug** and launches it from DerivedData into the **menu bar**
   (the Dock icon is optional, off by default). Do not copy the Debug app into
   `/Applications`.
2. On first launch it explains how to grant Accessibility. Open
   **System Settings → Privacy & Security → Accessibility**, and enable
   **BetterTile Debug**.
3. That's it — the grant is stored **per machine**, so every contributor does
   this once on their own Mac. It is not shareable across machines (macOS
   security design), but thanks to Personal Team signing it survives your
   rebuilds.

If you revoke and re-grant, or switch signing identity, remove the stale
BetterTile Debug entry from the Accessibility list once, then re-add the
freshly signed build.

BetterTile Debug is intentionally separate from the public app:

- its bundle identifier is `com.lmckarma.BetterTile.debug`
- its configuration is stored under
  `~/Library/Application Support/BetterTile Debug/`
- its `UserDefaults` and Accessibility grant are separate
- Sparkle and all update controls are inactive
- its icon carries a small **D** badge

Run, Test, Analyze, and Profile use the Debug identity. Archive uses the public
Release identity. If one variant is already running, the other asks to quit it
before registering shortcuts or observing windows. This permits both apps to
remain on the Mac without letting them manage the desktop at the same time.

---

## 4. Run the tests

Run focused checks while you work. Before opening a ready pull request, run:

```sh
swift test        # unit + fake-system integration tests
xcodebuild -project BetterTile.xcodeproj -scheme BetterTile \
  -configuration Debug CODE_SIGNING_ALLOWED=NO build
```

That validation build is also named `BetterTile Debug.app`; it is unsigned and
must not be distributed. The release script still builds and validates
`BetterTile.app` from the Release configuration.

CI first runs `changes`, which decides whether the pull request can affect a
build. Then these jobs run in parallel:

- `guards`: the timing and quarantine guard, its self-test, the Metal setup self-test,
  and the release test-completion self-test, on Ubuntu.
- `unit-tests`: the Core, MacOS and App test targets.
- `release-package`: the release tool tests, including the completion guard,
  and `swift build -c release`.
- `app-debug`: the Debug app build.
- `app-release`: the Release app build.

Every macOS job sets up Metal before its build or test. `release-package` runs
its shell tests first, then sets up Metal immediately before the release build.

The required `test` check passes only when `changes` succeeds and all five jobs
succeed. For a documentation-only pull request, it passes when `changes`
succeeds and all five jobs are skipped. A new CI job must be added to the
`needs` list of `test`; `test` then checks its result automatically.

> **Note:** The Layout Wheel liquid tests need the compiled shader,
> `LayoutWheelLiquid.metal`. Swift 6.4's default build system (Swift Build)
> compiles it. Swift 6.3's default native build system skips Metal files.
> `Tools/test.sh` therefore compiles the shader with
> `Tools/build-test-shader.sh`, with the same flags as the app build. It names
> the folder in `BETTERTILE_TEST_SHADER_DIRECTORY`, which only test builds read.
> Use `Tools/test.sh` for these tests, as CI does. Tests that draw with the
> liquid renderer carry the `.liquidPipeline` trait. Without the shader library
> or a usable Metal device, each of them fails once and names the step that
> failed, for example "BetterTile_BetterTileMacOS.bundle with default.metallib
> is missing".

> **Note:** `swift test` needs the full Xcode toolchain. If you see
> `no such module 'Testing'`, point the command line at Xcode:
> `sudo xcode-select -s /Applications/Xcode.app/Contents/Developer`.

> **Note:** If the checkout is in iCloud Drive or another synced folder,
> `swift test` can fail at `CodeSign` with "resource fork, Finder information,
> or similar detritus not allowed". The sync service adds extended attributes
> to the build products in `.build/`. Put SwiftPM's build output outside the
> synced folder:
>
> ```sh
> swift test --scratch-path /tmp/bettertile-build
> ```
>
> `xcodebuild` is not affected by default because it writes to
> `~/Library/Developer/Xcode/DerivedData`.

Check the command’s exit status. Piping `xcodebuild` output through `tail`
hides a failed build unless the shell preserves the pipeline’s failure status.

### Verify complete test runs

`Tools/test.sh LOG` runs `swift test`, preserves its exit status and requires three
complete passing Swift Testing summaries, one for each test product. A helper
can exit 0 before its tests finish when AppKit stops the async runner's main
run loop. Exit 0 alone does not establish a pass. Read all three summaries and
check for an unfinished `Test run started.` section. To check an existing full
log, run `Tools/check-test-log.sh LOG`. For a filter that selects one product,
use `Tools/test.sh LOG --expected-runs 1 --filter PATTERN`. A filter that selects
several products needs `--expected-runs` set to that product count. Do not accept a
missing summary or replace a failing full run with isolated passing tests.

Native test products bootstrap an empty application before any test body runs.
The shared `NativeApplicationTrait` applies at suite level where possible;
global `@Test` functions need `.appTestApplication` or `.macOSTestApplication`.
Swift Testing does not guarantee suite order. A shared startup task gates only
bootstrap, so test bodies retain their normal parallel execution.

The application starts with prohibited activation policy and no windows. Before
each `NSApplication.run` entry, support requires accessory policy. App tests start
their long-lived host at the outer run-loop boundary before fixtures can create
or order a window. macOS tests first enter an empty owned loop, then retain a
short owned event pump for each native interaction. An accessory application
with an already ordered window can become active during a native application loop entry;
starting the empty host first avoids that activation path.

Test hosts must stay inactive and must never take focus from the user. Tests do
not need a Dock icon or regular activation policy. After each test and UI lease,
support checks process activity and policy, naming the test on failure. After
recording an activity failure, it requests deactivation of this process once and
logs the request. This does not confirm that inactivity or user focus was restored.
The recorded failure remains. Passing checks never deactivate the process. Window
fixture, ordering, launch, and loop helpers reject a missing bootstrap context.
Native interactions also require `.settingsUI` or `.macOSUI`. Once the App host
is running, `withNativeEventLoop` checks the lease and runs the operation directly.
After bootstrap, the macOS pump uses `nextEvent`, `sendEvent` and `updateWindows`
until the scheduled operation completes, with the existing ten-second ceiling.
It does not re-enter `NSApplication.run` or call `NSApp.stop`. `NSApp.isRunning`
is false inside the pump; the fixture ownership flag identifies the owned loop.
Native tracking
stays inside this owned pump instead of SwiftPM’s outer executor loop.
The operation still runs in common run-loop modes; the App host’s outer-loop
startup gate is unchanged.

Offscreen fixtures that need real key status use `makeKeyAndOrderFrontForTesting`.
The shared helper completes native ordering before making one key request.
AppKit's combined `makeKeyAndOrderFront` call makes a window key before ordering
finishes; a deactivation during ordering can clear that key state. The regression
runs after the long-lived App host has started, injects deactivation during
ordering, and requires a real key window without activating the test process.
It does not depend on which suite runs first. macOS render fixtures use the same
helper. Keep an ordered key fixture only for the step that needs it. The Space
fixture orders and makes its panel key inside the admitted native operation,
requires real key status at the press, then orders it out before the pump returns.
This reduces exposure to external activation; it does not establish that the
window server excludes every test window from fallback activation.
Key-status assertions retain their original conditions and include
process-local activation, ordering, occlusion, and loop diagnostics. Diagnostics
record only whether this process is frontmost, without another app's identity.
Set `BETTERTILE_TEST_APPLICATION_AUDIT` to a JSONL path for timestamped state checks.
Set `BETTERTILE_TEST_ACTIVATION_TRACE` to a separate JSONL path for activation
notifications, current test scopes, and owned-window state. Both are opt-in and
process-local; neither activates another application.

### Release test lane

Run the default suites with Release optimization and the same completion guard:

```sh
Tools/test.sh /tmp/bettertile-release-tests.log --release
```

`--release` passes `-c release -Xswiftc -enable-testing -Xswiftc
-DBETTERTILE_TEST_HOOKS` to SwiftPM. It does not define `DEBUG`. On a shared
machine, pass `--release` through the prescribed full-suite lock helper.
The log must contain all three complete passing product summaries. Filters
still require the matching `--expected-runs N` before `--release`.

`BETTERTILE_TEST_HOOKS` exposes instrumentation read only by tests. Never use it
for product behaviour. `Package.swift` enables it for Debug SwiftPM targets and
Xcode's Debug package targets. The Xcode app target does not inherit that define,
so App-module hooks are available in SwiftPM test builds, not in the Xcode app.
The Release test lane enables the define only on the command line. A normal
Release library or Release Xcode app has neither these hooks nor testability.
Keep Debug identity, diagnostics,
calibration and updater differences under `DEBUG`. Tests of those differences
must exercise their Release counterparts where available. Arrival-trace tests
cover Debug-only diagnostics and retain their existing Debug condition.

Optimized tests must wait for the state they assert. A fixed number of
`Task.yield()` calls does not establish that another task completed.

This lane keeps the default suite's strict inactivity guard. The native focus
lane remains separate and opt-in; do not enable it for a full Release run.
Never distribute a Release app built with the lane's compiler flags.

CI sets `BETTERTILE_LOCAL_WINDOW_TESTS=1` in its unit-test job. This disables
only TestWindowAudit’s periodic display-intersection sampler. The synchronous
offscreen-frame checks and the default inactivity guard still run. Unset it
for the periodic sampler in local full-suite runs; the name does not select the
native focus lane.

### Native focus tests

The opt-in native focus lane contains 18 macOS test functions that inspect key
state or exercised an observed activation path. App tests stay in the default
run unless they require a real key window while the process is inactive, or have
test-specific activation evidence. A negative key-state assertion alone does not
justify excluding an App test from the default run.

The 13 App exceptions require real key status: the ordering regression, the
already-ordered host check, the strip ordering/key-status check, two chooser Escape
tests, seven Settings picker tests, and the Add Rule badge test. Six Settings tests
and the badge test call `LivePanelHarness.open`, which requires a real key panel
before native keyboard dispatch. The remaining exceptions assert positive real
key status directly. No App exception is based on a measured activation episode.

Gated suites use `.enabled(if: NativeFocusTestLane.isEnabled)` and the recursive
`.nativeFocus` marker. Every other test stays in the default run, whose activity
guard still fails if its process activates. App rendering, non-key-state and
unordered-host tests remain enabled by default.

Run native focus tests only while nobody is using the Mac, or on a spare machine.
They may take keyboard focus. Activation is recorded in this lane without failing
the support activity guard. Each run ends with an activation episode count, the
tests at the first active sample and notification delivery, and observed durations.
An episode still active at exit is marked explicitly. Notification delivery can
lag actual activation, so its current test does not identify the cause.
All test-body assertions still apply, including the ordering regression's inactive
precondition; a failure of that precondition is a lane failure.

Run only the filtered per-product lane commands, with attribution and the activity
audit enabled:

```sh
BETTERTILE_NATIVE_FOCUS_TESTS=1 \
BETTERTILE_TEST_ACTIVATION_TRACE=/tmp/bettertile-native-focus-macos.trace.jsonl \
BETTERTILE_TEST_APPLICATION_AUDIT=/tmp/bettertile-native-focus-macos.audit.jsonl \
Tools/test.sh /tmp/bettertile-native-focus-macos.log --expected-runs 1 \
  --filter 'BetterTileMacOSTests.*NativeFocus'

BETTERTILE_NATIVE_FOCUS_TESTS=1 \
BETTERTILE_TEST_ACTIVATION_TRACE=/tmp/bettertile-native-focus-app.trace.jsonl \
BETTERTILE_TEST_APPLICATION_AUDIT=/tmp/bettertile-native-focus-app.audit.jsonl \
Tools/test.sh /tmp/bettertile-native-focus-app.log --expected-runs 1 \
  --filter 'BetterTileAppTests.*NativeFocus'
```

Use fresh evidence paths for each run. Setting the flag does not permit activation
in tests outside a `.nativeFocus` suite. Startup bootstrap still requires an empty,
inactive accessory host. Only the native interaction and after-test support checks
permit activation inside the enabled lane. Do not set the flag for an unfiltered
product run: a lane activation can remain active when following default tests run.
Their strict activity guard will fail, and the process can keep the user's keyboard
focus. The filtered commands keep these two kinds of checks in separate processes.

`NativeLaneMembershipTests` pins the exact 18 macOS and 13 App function names by
reading the gated suite declarations, including tests inside nested suites. Review
any membership change and update the documented lane list together with the pin.

UI test leases are acquired in the outer function scope, before Swift Testing
starts each case's time limit. `.settingsUI` and `.macOSUI` serialize a function's
parameter cases while it owns the resource. Native application startup also
runs before case timers; per-case activity checks remain in place. Keep body
limits unchanged when adding a UI lease. Queueing has a separate ten-minute
watchdog that reports test lease starvation, and cancellation removes a queued
waiter without consuming the next ownership. The test-only `AsyncTestLease`
accepts an injected clock for watchdog and cancellation checks.

Never stop the main run loop in tests. Test bodies and fixtures must not call
`NSApp.stop` or `CFRunLoopStop` themselves. Use `withNativeEventLoop` or
`performNativeClick` under `.settingsUI` or `.macOSUI`; only the shared loop
support may stop a loop that it owns. Stopping the outer loop can make SwiftPM's
helper exit 0 before the test run finishes.

### Live desktop tests

Some tests need a live desktop session that GitHub's hosted macOS runner does not
provide. The `.liveDesktop` trait skips them when the `CI` environment variable
is set. GitHub Actions sets it for every step. Local runs and the pre-PR full run
leave it unset, so these tests still run there. The maintainer also checks the
Debug build by hand on a macOS 26 Mac.

Tag a test only when its CI failure comes from the environment:

- pixels of rendered native glass or Liquid Glass, and contrast measured on that
  rendering;
- golden comparisons whose result depends on the GPU or the display;
- Vision text recognition;
- synthetic mouse or keyboard input into native controls;
- real key-window or activation state.

Never use the trait for a timing or ordering flake, a wrong result, or a hang.
Fix those, or quarantine them with `.disabled("quarantine: #<issue> …")` and no
retries. Do not remove checks or raise time limits when you add the trait.

A model-level or colour-maths test must still cover the logic of each tagged
test on CI. Name that test in a comment at the tagged suite, and in the commit
message. To see which tests CI runs, set `CI=1` for a local run.

`.liveDesktop` is separate from the opt-in native focus lane. A native focus
suite stays gated by `BETTERTILE_NATIVE_FOCUS_TESTS`, with or without `CI`.

### Export snapshots separately

Never set `BT_SNAPSHOT_DIR` for a full product or suite run. Exporting every UI
snapshot adds main-actor work and can invalidate elapsed-time tests. `Tools/test.sh`
refuses a set `BT_SNAPSHOT_DIR` (even empty) before it builds or runs tests. Unset that
variable for suite validation. On a shared machine, use the prescribed full-suite
lock helper as usual.

Export captures in a separate focused command that selects only the intended
snapshot suite, for example:

```sh
mkdir -p /tmp/bettertile-snapshots
BT_SNAPSHOT_DIR=/tmp/bettertile-snapshots \
  swift test --filter SavedLayoutPagePlanOutcomeSnapshotTests
```

Keep private captures outside tracked files.
Do not use a broad filter such as `BetterTileAppTests` for capture export.

### Testing timers without real time

Use `BetterTileClock.live` as the product default. Timer tests can import the
test-only `BetterTileTestSupport` target and inject `ManualClock().clock`.
Keep the manual clock instance so the test can advance it:

```swift
let manual = ManualClock()
let debouncer = DisplayRefreshDebouncer(clock: manual.clock)
debouncer.schedule { refreshCount += 1 }
let task = try #require(debouncer.task)
await manual.waitForSleepers(count: 1)
manual.advance(by: .milliseconds(120))
await manual.drain(task)
#expect(refreshCount == 1)
```

The task handle above is available through `@testable import BetterTileMacOS`.
Wait for sleep registration before advancing. Otherwise a new task could
start its delay after the advance. `advance(by:)` resumes due continuations
in deadline order, with registration order breaking ties. The executor
controls when their task bodies run. `drain(task)` waits for that known task
to complete; it does not guess how many executor turns are enough, advance
time, or drain the AppKit run loop. For chained delays, wait for each new
sleep registration and advance to its deadline before joining the task.
For cancellation tests, retain the task before cancelling, advance beyond
every relevant deadline, and drain it before asserting no action occurred.

`waitForSleepers(count:)` counts every registered sleeper that has not resumed,
not only new ones. `waitForSleepers` and `drain` wait until the expected sleep
or task happens. Give suites that use them a `.timeLimit`, so a missing sleep
fails the test instead of stalling the run.

For a failure-sensitive registration handshake, require
`await manual.waitForSleepers(count: 1, timeout: .seconds(45))`. This overload
returns false at its deadline or on cancellation. Its live monotonic deadline
bounds executor progress; it does not advance virtual policy time or add a
product delay. Native AppKit tests can block the main actor for several seconds,
so this handshake allows 45 seconds within the suite's one-minute backstop.
Keep the suite time limit as a backstop for joining known tasks.

The app fake drives waits with a virtual budget above 200 ms by jumping to the
next registered sleeper. At most 200 one-millisecond turns remain available for
short boundary probes. Fixtures can also explicitly request deadline driving
for shorter waits. A real executor handoff lets resumed operations register
their next wait before the driver chooses another deadline. With no policy
sleeper, virtual time stays frozen while a separate bounded executor watchdog
observes completion. The fixture announces a queued event pass's sleep and
waits for its clock continuation to register before choosing an unrelated
deadline. A virtual budget is only a bound: when the earliest registered
sleeper lies beyond it, the driver keeps time frozen while an in-budget sleep
can still register. It does not invent a jump to the budget timestamp. The
driver also observes work resumed exactly at its virtual budget deadline.

Use `joinWindowEvent(on:)` to join one captured event pass. It observes the
model's task-handle release before joining the task with virtual time frozen.
This prevents a later backoff or recovery timer from running while completion
of the captured pass is still being delivered. `advance(by:)` likewise stops
virtual time at the requested checkpoint while observing task completion.
`joinSettlement(_:on:)` uses the same contract for one captured sampling pass,
before any replacement retry. These helpers do not spend the rest of their
budget on unrelated policy timers.

Runtime fixtures must also observe the state they are waiting for. An automatic
Saved Layout attempt held for unlock intentionally stays non-idle. Join its
scheduled forward tasks and observe the registered hold; do not spin a fixed
number of executor turns waiting for idle. Direct user actions with no runtime
task handle need an explicit outcome predicate. Advancing a ManualClock wakes
continuations; use a bounded registration handshake before asserting that a
resumed operation has reached its next wait.

The app fake's `drive` and `join` helpers record a test failure and return nil
when their virtual-time budget expires. `drive` cancels its operation task;
`join` also cancels the input task it was waiting for. Neither awaits an
unfinished task after timeout. Cancellation removes registered manual-clock
sleepers. A noncooperative operation can outlive its helper, so test cleanup
must still release any fixture resources it owns.

### Test timing and quarantine guard

Run `Tools/ci/check-test-timing.sh` to check Swift files under `Tests/` without
building them. It checks sleep calls and reads from real clocks. Use the
injected clock in new tests. When a test needs real time, put
`// real-time: <reason>` on the call line with a non-empty reason.

The baseline records unannotated call counts by file and API. It survives line
shifts, but cannot detect a removed call replaced by another call to the same
API in the same file. A count increase fails. A decrease passes with a hint.
After removing calls, run `Tools/ci/check-test-timing.sh --update-baseline` to
lower the counts. This command refuses increases unless `--allow-increase` is
also supplied. Review any increase before accepting it.

Disable a flaky test with `.disabled("quarantine: #123 <reason>")`. Use its issue
number and a non-empty reason. Other `.disabled(...)` calls fail unless already
baselined. Condition gates, `.enabled(if:)` and `.disabled(if:)`, are allowed.

The guard checks the known API spellings, including calls split across lines.
It ignores comments, string contents, fixed dates such as
`Date(timeIntervalSince1970:)`, and clock instant types. It does not resolve
aliases or calls inside string interpolation. Run its fixture tests with
`Tools/tests/check-test-timing-test.sh`.

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
gh pr create --base main
```

This opens a ready pull request, which starts the automated review. Use
`--draft` only when you want early feedback or the maintainer asks for a draft.
When a draft is complete and locally validated, mark it **Ready for review**.

Check automated review comments against the code, tests, and project rules.
Resolve every review thread. Merge only after CI passes and the maintainer
approves the final pushed version. If automated review cannot run, report the
failure and wait for a retry or a maintainer decision.

---

## 6. Automated review on pull requests

- **Claude** checks each non-draft pull request against its stated goal and the
  BetterTile repository rules. It reviews the pull request when it opens, when
  a draft becomes ready, and when it receives new commits. It comments inline
  on confirmed problems. You can write **`@claude`** in a comment to ask a
  follow-up question.
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
owns window-system integration, window mutations, and coordinate conversion.
`BetterTileApp` owns application lifecycle, SwiftUI UI, AppKit UI integrations,
and Sparkle. Full detail in [docs/ARCHITECTURE.md](ARCHITECTURE.md).
