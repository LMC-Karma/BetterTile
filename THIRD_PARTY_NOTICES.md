# Third-party notices

## Sparkle

- Source: <https://github.com/sparkle-project/Sparkle>
- Version: 2.9.5
- Copyright: Copyright (c) 2006–2013 Andy Matuschak; 2009–2013 Elgato Systems
  GmbH; 2011–2014 Kornel Lesiński; 2015–2017 Mayur Pawashe; 2014 C.W. Betts;
  2014 Petroules Corporation; 2014 Big Nerd Ranch
- License: MIT License

BetterTile links Sparkle to discover, verify, and install application updates.
The complete Sparkle license text is included with the resolved dependency and
is available in its [upstream repository](https://github.com/sparkle-project/Sparkle/blob/2.9.5/LICENSE).

## Vorssaint

- Source: <https://github.com/vorssaint/vorssaint-utils>
- Copyright: Copyright (C) 2026 Vorssaint
- License: GNU General Public License v3.0 or later

BetterTile contains portions adapted from Vorssaint's SwiftUI settings and
menu-panel presentation code: the settings sidebar and its search field, and the
menu panel's cards and footer buttons in `Sources/BetterTileApp/SettingsView.swift`
and `Sources/BetterTileApp/BetterTileApp.swift`. Those files carry Vorssaint's
copyright notice. BetterTile modified the adapted code.

Vorssaint's demand-based service ownership and teardown patterns informed
BetterTile's runtime lifecycle, and its `LiquidGlassMixerSlider` and
`HUDBackdrop` inspired the divider's glass knob and the glass accessibility
fallback. BetterTile's divider and glass surfaces are its own code; they use
public Core Animation layers, the Core Image `CIGlassLozenge` filter, and native
AppKit glass.

BetterTile is distributed under the GNU General Public License v3.0 or later.
The complete license terms are provided in [LICENSE](LICENSE).

## Rectangle

- Source: <https://github.com/rxhanson/Rectangle>
- Copyright: Copyright (c) 2019–2026 Ryan Hanson
- License: MIT License

BetterTile learned the bounded WindowManager group/list/button Accessibility
hierarchy that exposes `AXWindowIDs` from Rectangle's `StageUtil.swift`.
`StageManagerGroupResolver` is BetterTile's own code; no Rectangle code is
included. BetterTile adds strict WindowServer validation and a single-window
drag policy. Rectangle's license is available in its
[upstream repository](https://github.com/rxhanson/Rectangle/blob/main/LICENSE).

## AeroSpace

- Source: <https://github.com/nikitabobko/AeroSpace>
- Copyright: Copyright (c) 2023 Nikita Bobko
- License: MIT License

AeroSpace's `isDialogHeuristic` in
[`Sources/AppBundle/model/AxUiElementWindowType.swift`](https://github.com/nikitabobko/AeroSpace/blob/d56e1637c3a1ed660d0cadd7534e94fb3218d1c3/Sources/AppBundle/model/AxUiElementWindowType.swift)
at commit `d56e1637c3a1ed660d0cadd7534e94fb3218d1c3` decides whether a window
is a dialog from its subrole and its title-bar buttons.
`PopupWindowClassifier` adapts those rules, their order, and their
application-specific cases: terminals, editors, and Chromium browsers that lack
an enabled full-screen button; Firefox windows without an enabled minimize
button; Ghostty; and qutebrowser's subrole. BetterTile adds its own modal check,
attached-sheet handling, and handling of failed Accessibility reads.

AeroSpace's license:

```text
MIT License

Copyright (c) 2023 Nikita Bobko

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
```
