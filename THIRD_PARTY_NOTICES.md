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
menu-panel presentation code. Vorssaint's demand-based service ownership and
teardown patterns also informed BetterTile's runtime lifecycle.

BetterTile is distributed under the GNU General Public License v3.0 or later.
The complete license terms are provided in [LICENSE](LICENSE).

## Rectangle

- Source: <https://github.com/rxhanson/Rectangle>
- Copyright: Copyright (c) 2019–2026 Ryan Hanson
- License: MIT License

Rectangle's `StageUtil.swift` documented the bounded WindowManager
group/list/button Accessibility hierarchy used to find `AXWindowIDs`. BetterTile
adapts that hierarchy pattern, then applies its own strict WindowServer
validation and single-window drag policy. Rectangle's complete license text is
available in its [upstream repository](https://github.com/rxhanson/Rectangle/blob/main/LICENSE).
