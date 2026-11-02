# Changelog

All notable changes to this project will be documented in this file.

## [1.0.1] - 2026-11-02

### Changed
- Listed under **Tools → Games**, grouped by category, instead of its own
  entry in the Tools menu (game-common 1.9.1).

## [1.0.0] - 2026-10-30

### Added
- First release: Heyawake (Nikoli) in 6×6, 8×8 and 10×10, easy / medium /
  hard.
- Generator with a built-in logic solver: every puzzle has exactly one
  solution, and its difficulty is the set of techniques the solver needed.
- Tap cycles empty → shaded → dot; hold clears. Check, Hint (deduced from the
  current marks), Undo, Show solution, timer, save and restore.
- Fast generation: worst case over 150 seeds about 0.15 s at 10×10 hard on a
  desktop (an incremental solver, and a shading search that branches where a
  dead end shows first and restarts early). A progress bar shows when
  generation takes longer, as it can on an e-reader.
- Generation is a pure function of the random seed (no clock-based limits),
  so the Daily Challenge is the same everywhere.
- English and French.
