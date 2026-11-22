# Security Policy

This file states how to report a vulnerability and which rules protect users.
Feature-by-feature records are in
[docs/SECURITY_DISCLOSURES.md](docs/SECURITY_DISCLOSURES.md).

## Reporting a vulnerability

Report security or privacy concerns privately. Use
[GitHub private vulnerability reporting](https://github.com/LMC-Karma/BetterTile/security/advisories/new).
Do not open a public issue, pull request, or discussion that contains
sensitive details.

Include:

- what you observed and why it is a security or privacy problem
- the steps to reproduce it
- the BetterTile version and build, and the macOS version
- the effect: what an attacker gains, and what the attacker needs first
- a proof of concept, if you have one

Do not post exploit details, proof-of-concept code, or user data in public
before a fix is released. Do not attach personal data or window contents to a
report.

### What to expect

One maintainer runs this project, so fixes can take time. You can expect an
initial reply within a few days. For a confirmed problem, the fix ships first,
then a public GitHub security advisory that credits the reporter if the
reporter agrees.

## Supported versions

Only the latest beta release receives security fixes. Update through
**Check for Updates…** in BetterTile or from the
[Releases page](https://github.com/LMC-Karma/BetterTile/releases).

Release builds run on Apple silicon Macs with macOS 26 or later. Intel Macs
stay on 0.5.2, the last universal release. That release receives no security
fixes.

## Scope

In scope:

- the BetterTile app and its update path
- BetterTile's handling of its configuration, Saved Layouts, and other local
  files
- the release and CI configuration in this repository
- a way to make BetterTile read, write, send, or keep more data than this
  policy and the disclosures state

Out of scope:

- a problem that needs an attacker who already controls the user's account or
  has administrator rights
- a flaw in macOS, in another application, or in Sparkle itself. Report these to
  Apple, to the application's maker, or to the
  [Sparkle project](https://github.com/sparkle-project/Sparkle).
- the missing notarization of a release. This is documented under
  [Distribution](#distribution-and-updates).
- a report with no demonstrated effect on security or privacy

## Security and privacy commitments

BetterTile is a free utility. It has no paywall, subscription, advertising,
behavioral tracking, or sale of user data. BetterTile does not monetize window,
configuration, diagnostic, or usage data. Window geometry and configuration
stay on the Mac. Update checks send no window data, configuration, analytics,
telemetry, crash reports, or system profile. Product behavior and material data
handling are disclosed in this repository.

If an existing configuration cannot be read, BetterTile keeps the file and
stops saving for that session. See
[Configuration load failure](docs/SECURITY_DISCLOSURES.md#configuration-load-failure).

## Permissions

Accessibility is the only macOS permission BetterTile asks for. It moves and
resizes windows. BetterTile also uses event taps for gestures and for the
optional Layout Wheel middle click. It never calls the API that asks for Input
Monitoring. **Launch at login** is off
by default.

A new permission or privileged component needs a design review, a
least-privilege justification, an update to the disclosures, and an in-product
explanation before the system prompt appears. See
[Permissions and dependencies](docs/SECURITY_DISCLOSURES.md#permissions-and-dependencies).

## Private APIs

BetterTile uses public Apple APIs by default. Two rules are permanent:

- Do not inject code into other processes.
- Do not bypass System Integrity Protection.

A small set of read-only private observations is approved for macOS 26. They
join Accessibility windows to window IDs, read stated minimum window sizes, and
read Spaces membership. BetterTile finds them at runtime. A missing symbol or an
invalid value uses the public fallback and never stops BetterTile from
launching. The approved list, validation, and fallbacks are in
[Private window observations](docs/SECURITY_DISCLOSURES.md#private-window-observations).

To turn all private capabilities off, run this command, then quit and reopen
BetterTile:

```sh
defaults write com.lmckarma.BetterTile disablePrivateAPIs -bool true
```

To restore automatic use, run
`defaults delete com.lmckarma.BetterTile disablePrivateAPIs`.

## Network

BetterTile contacts `github.com` over HTTPS for two reasons: to fetch the public
update feed, and to download a release when the user chooses to. GitHub sees
ordinary connection data such as the IP address. Automatic checks run every four
hours and can be turned off in Settings. **Send Feedback…** opens a GitHub
issue form in the browser with only the BetterTile version and build. Debug
builds make no update requests. See
[Network disclosure](docs/SECURITY_DISCLOSURES.md#network-disclosure).

## Distribution and updates

Public beta builds are signed with a maintainer-held, self-signed certificate.
They are not notarized. First launch needs **Open Anyway** in System Settings →
Privacy & Security.

Sparkle checks every update archive against an EdDSA public key built into the
app. That check does not depend on the code signature. The signing credentials
and the EdDSA private key are not in the repository or in CI. CI builds are
validation builds and are never distributed. See
[Distribution](docs/SECURITY_DISCLOSURES.md#distribution) and
[docs/RELEASING.md](docs/RELEASING.md).

## Rules for changes

These rules apply to every pull request. Contributors, maintainers, and
automated reviewers use them.

- Public Apple APIs are the default. Other implementation choices may change
  when the user benefit justifies it. Changes are judged on security, privacy,
  transparency, maintainability, and user benefit. There is no blanket ban on
  a technology.
- **Private API.** Open a design discussion in an issue or a draft pull request
  first. The discussion must show that the API fits BetterTile's product goals
  and that no public API gives the same user benefit. It must cover scope,
  failure and compatibility risks, security and privacy impact, distribution,
  maintenance cost, the test plan, and a safe fallback for when the API is
  missing or changes. The maintainer must approve it before implementation.
  Add a record to the disclosures before release. Test the fallback.
- **Dependency.** Review need, maintenance, security history, license
  compatibility, update strategy, and removal cost. Pin it and record it in
  [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md). Sparkle is the only
  runtime dependency. Adapted code needs clear provenance, a compatible
  license, and attribution.
- **Network.** A new network feature needs a documented user-facing purpose,
  the least data, secure transport, and a record of its endpoints and payload
  purpose in the disclosures before release. Optional diagnostics also need a
  separate design decision, informed opt-in, documented retention, and an off
  switch.
- **Permission or privileged component.** See [Permissions](#permissions).
- **Disclosure.** A pull request must call out any change to networking,
  permissions, privileged components, dependencies, user-data handling,
  distribution, updates, private APIs, or architecture. An intentional
  architecture change is allowed when the pull request gives the reason, the
  documentation, the migration impact, and the tests.
