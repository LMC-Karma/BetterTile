# App icon variants

Classic uses the existing [AppIcon.icon](../../Resources/AppIcon.icon) document.
[Ice Blue](../../Resources/AppIconIce.icon) derives from that document. It keeps
the pane outlines, corner radii, canvas, layer order, positions, and scale.
It uses a pale ice background, blue left panes, and a mint-to-teal right pane.
Inset SVG gradient contours create the thicker glossy rims inside the original
outlines. Pane translucency and shadow strength are adjusted for these colors.
The traffic-light SVG remains an exact copy. Each Debug copy adds the existing D
badge. Ice Blue places that badge above its opaque panes so it stays visible.
[Dark](../../Resources/AppIconDark.icon) uses the same foreground as Ice Blue
with a dark background. It is a separate choice, independent of the app's
appearance setting, and has a matching Debug copy.

Open any `.icon` document in Apple's Icon Composer. When changing source
geometry, copy those changes into the other five documents. Keep appearance
changes aligned within each base/Debug pair. Edit the pane SVG gradients to
adjust the Ice rim colors; Icon Composer retains the native glass and shadow
effects. `appIconVariantsPreserveSourceGeometry` checks the outlines, canvas,
composition, and matching Debug copies.

Settings → General → Appearance has three buttons: Classic, Ice Blue, and Dark.
Each button contains its centered preview and name. A border and checkmark show
the selected choice. Tab moves between choices; Space or Return selects one.
Classic is the default. The local `BetterTileAppIcon` preference saves
the selection across launches. Unknown values use Classic. Debug and Release
keep their existing separate preferences and Debug retains its D badge.

Show Dock icon sits directly above the picker. When it is off, the picker
explains that the choice is saved and the toggle must be on to display it.
Showing the Dock icon reapplies the saved choice. The picker does not silently
change the Dock visibility preference when selecting an icon.

The picker loads icons from Xcode's compiled asset catalog and uses the public
AppKit `NSApplication.applicationIconImage` API. It changes the running app's
Dock icon. Finder and the installed app keep the Classic icon. Returning to
Classic restores the system's primary icon. This follows
[Apple's documented Dock icon behavior](https://developer.apple.com/documentation/appkit/nsapplication/applicationiconimage).
No new dependency, permission, networking, private API, or window mutation is
introduced. The only new stored value is the local icon preference.

## Verification

- Debug and Release Xcode builds with `CODE_SIGNING_ALLOWED=NO`.
- Swift tests with `--scratch-path /tmp/bettertile-picker-tests`: preference
  restoration (including Dark), fallback, geometry, and matching Debug copies.
- All three compiled icon names load in Release and Debug.
- Native picker interaction in an isolated app using the actual picker source
  and compiled icon catalog: click, Tab, Space, Return, and Dock visibility.
- The reported unchanged Dock icon was reproduced with Show Dock icon off.
  The maintainer confirmed that the running app changed to Ice Blue when the
  toggle was turned on. No Dock rendering API change was required.
- Light and dark picker captures and Apple-rendered icon previews are in
  [previews](previews). Icon exports use Icon Composer's `ictool` for macOS.
  Unsuffixed icon exports use design generation 26; `*-27.png` exports use
  generation 27. The final Ice source was also opened and checked in Icon
  Composer. These are review images, not runtime PNG resources.
- Full-app relaunch, live system appearance changes, and VoiceOver traversal
  remain manual checks. These builds are unsigned and are not distributed.
