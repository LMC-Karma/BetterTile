# App icon variants

Classic uses the existing [AppIcon.icon](../../Resources/AppIcon.icon) document.
[Ice Blue](../../Resources/AppIconIce.icon) is a copy of that document. It changes
only the background color to ice blue. Every foreground SVG is an exact copy. The SVG geometry, layer positions, scale, groups, and Liquid Glass
settings match the source. The Debug copies add the existing D badge.

Open either `.icon` document in Apple's Icon Composer. When changing source
geometry or effects, copy those changes into the other three documents.
`appIconVariantsPreserveSourceGeometryAndEffects` checks that they stay aligned.

Settings → General → Appearance has a native radio picker with both icon
previews. Classic is the default. The local `BetterTileAppIcon` preference saves
the selection across launches. Unknown values use Classic. Debug and Release
keep their existing separate preferences and Debug retains its D badge.

The picker loads icons from Xcode's compiled asset catalog and uses the public
AppKit `NSApplication.applicationIconImage` API. It changes the running app's
Dock icon. Finder and the installed app keep the Classic icon. Returning to
Classic restores the system's primary icon. This follows
[Apple's documented Dock icon behavior](https://developer.apple.com/documentation/appkit/nsapplication/applicationiconimage).
No new dependency, permission, networking, private API, or window mutation is
introduced. The only new stored value is the local icon preference.

## Verification

- Debug and Release Xcode builds with `CODE_SIGNING_ALLOWED=NO`.
- Swift tests with `--scratch-path /tmp/bettertile-icon-tests`. The default
  iCloud build directory hit the documented extended-attribute signing error.
- Both compiled icon names load in Release. Both Debug choices load with badges.
- Native picker interaction in an isolated app using the actual picker source
  and compiled icon catalog; the running window manager was left in place.
- Light and dark picker captures and Apple-rendered icon previews are in
  [previews](previews). Icon exports use Icon Composer's `ictool`, macOS,
  design generation 26. They are review images, not runtime PNG resources.
- Full-app relaunch, live Dock appearance changes, and VoiceOver traversal
  remain manual checks. These builds are unsigned and are not distributed.
