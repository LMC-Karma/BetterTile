# Native action glyph baseline

The PNGs record `LayoutWheelActionGlyph` from commit
`ad5006d08ba06ece8a2c9d54f1cdda3441422497`. They were rendered before the
partition renderer changed, with macOS 27.0.1 build 26A434.

Each row uses 13, 16, 18 or 24 pt Semibold. The columns contain Left Half,
Right Half, Top Half, Bottom Half, Top Left Quarter, Top Right Quarter,
Bottom Left Quarter and Bottom Right Quarter. Each cell is 48 × 48 pt.
The files use 1× and 2× raster scales.

`WindowActionGlyphBaselineTests` compares decoded pixels on that OS build,
allowing one alpha level for system symbol cache rounding between processes.
On every OS, it also requires exact pixel equality against the preserved
native SF Symbol branch in the same process. This lets Apple update its
symbol artwork without requiring unrelated product changes.
