# Handoff: Live Stems panel redesign (direction B, Liquid Glass)

**Intent:** rebuild the controls panel as Logic-style channel strips with a macOS 26 Liquid Glass
look, keeping every control and its behavior. **Must not break:** audio behavior, accessibility
labels, the GPU-free test stages.

## Objective

Redesign the controls panel to match `docs/design-b-channel-strips.png`, with a Liquid Glass look:

- Translucent glass panel background (macOS 26 glass: `NSGlassEffectView` if available, otherwise
  `NSVisualEffectView` with `.hudWindow` material). No plain grey window.
- Top row: source picker (app icon + name, popup) and Reset (with `arrow.counterclockwise`).
- Status line ("Spotify · Live stems") and the output device line with a headphones symbol.
- Four vertical channel strips side by side: Vocals (pink), Drums (orange), Bass (purple), Other
  (green). Each strip, top to bottom: a colored name plate with the stem's SF Symbol, the small
  scrolling waveform, a tall vertical fader with a dB scale, a level meter in the stem color, and
  M (mute, lit blue) and S (solo, lit yellow) buttons.
- An "All stems" row with the global M and S.
- Quit Live Stems at the bottom, with the `power` symbol.
- Light and dark appearance both look right.

## Ownership (write-capable, this worktree only)

- `Sources/LiveStems/MenuController.swift` (layout and wiring)
- `Sources/LiveStems/StemViews.swift` (LogicToggle, StemWaveform, and any new views)
- New view files under `Sources/LiveStems/` if a view grows large
- `docs/panel.png` (regenerate from the snapshot stage at the end)

## Non-goals and constraints

- Do not change audio, session, pipeline, worker, or C code. UI only.
- Keep every control's behavior: sliders 0–1 linear gain (a dB scale may be drawn, but the value
  sent stays the same), M/S toggles, All-stems M and S, Reset, source picker, Quit.
- Keep these accessibility labels exactly: "<Stem> volume", "<Stem> Mute", "<Stem> Solo",
  "Mute all", "Clear all solos", "Audio source", and the Reset/Quit button titles. Tests find
  controls by them.
- Level meters: use the existing pre-fader peaks (`session.takeMeters`, already pulled at 30 Hz for
  the waveforms). Do not add new audio taps.
- Keep the panel a floating window that joins all Spaces (same window behavior as now).
- No new dependencies. AppKit only, or SwiftUI hosted in AppKit if clearly simpler.
- Do not install the app, push, merge, or touch other worktrees.

## Build and checks (all must pass)

Build into this worktree, so the sandbox allows it:

```sh
swift build --configuration release --scratch-path .build
B=$(swift build --configuration release --scratch-path .build --show-bin-path)
for st in menu spam snapshot rest flutter transitions; do "$B/LiveStems" --e2e $st --output .build/e2e/$st || echo "FAIL $st"; done
```

- `menu` (11 AppKit checks) and `spam` (3000 random clicks) must pass unchanged.
- `snapshot` writes `.build/e2e/snapshot/panel-light.png` and `panel-dark.png`. Look at both and
  iterate until they match the design intent. Copy the dark one to `docs/panel.png`.

## Return contract

Commit on branch `ui-channel-strips` (one or more commits, end messages with
`Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>`). Then write `HANDOFF-RESULT.md` with:
files changed, what each check printed, paths to the two snapshot PNGs, and anything you could
not do. Delete nothing outside your ownership.
