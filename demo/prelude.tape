# Shared settings. Sourced by every scene; holds no Output of its own.
#
# Width and Height are pixels; VHS has no grid setting, so they are calibrated
# to a 100x30 terminal for this font, size, line height, and padding. Change any
# of those and re-run `make demo-calibrate`, which prints the resulting grid.

Require scroll
Require pv

Set Shell bash
Set FontFamily "JetBrains Mono"
Set FontSize 13
Set LineHeight 1.2
Set Padding 20
Set Width 870
Set Height 652
Set Framerate 12
Set TypingSpeed 45ms
Set Theme "Catppuccin Mocha"
Set CursorBlink false
