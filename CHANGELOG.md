# Changelog

All notable changes to this project will be documented in this file.

## [1.1.0] - 2026-11-05

### Changed
- Hard no longer needs a guess. Until now every Hard puzzle could only be
  finished by shading a cell and seeing a rule break ("what if this cell
  were shaded?"). Hard now asks for room analysis (every way of placing a
  room's shaded cells agrees on a cell) several times over: at least 2 on
  6×6 and 3 on 8×8 and 10×10, where Medium needs exactly one. Hard rooms
  may also merge into larger ones (up to 16 cells).
- The hint only gives cells found by logic without guessing. On a Hard game
  saved by an older version, when logic finds nothing it reveals a cell of
  the solution instead.
- Medium and Hard puzzles differ from those of 1.0.x for the same seed, so
  the Daily Challenge may show a different Heyawake grid once. Hard
  generation takes longer (up to ~0.35 s on a desktop, a few seconds on a
  Kobo, with the progress bar).
- Faster generation, about twice as fast: the solver no longer makes a new
  closure for every solve, and the generator's own steps run outside
  LuaJIT's compiler, which kept flushing and recompiling the solver. Worst
  case over 50 seeds on a desktop: 10×10 and 8×8 Hard ~0.21 s → ~0.1 s,
  6×6 Hard ~0.1 s → ~50 ms. Same puzzles for the same seed.

## [1.0.5] - 2026-11-04

### Fixed
- A game no longer crashes when an outdated plugin is installed alongside:
  shared modules left behind by an older plugin are replaced by this
  plugin's own copy instead of being used as they are.

## [1.0.4] - 2026-11-04

### Changed
- Uses less memory: the game loads when you open it, not when KOReader
  starts, so it no longer takes memory or startup time while unplayed.

## [1.0.3] - 2026-11-03

### Changed
- Picks up game-common 1.11.0: the shared on-screen keyboard (where used)
  gives every key the same letter size, and the no-repeat history helper.

## [1.0.2] - 2026-11-02

### Changed
- Picks up game-common 1.10.0: the shared Tools → Games menu also lists
  the games' new "· multiplayer" entries under Party & quiz.

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
