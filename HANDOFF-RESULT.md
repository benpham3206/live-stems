# Handoff result: channel-strip panel (direction B, Liquid Glass)

Branch: `ui-channel-strips`. UI only. No audio, session, pipeline, worker, or C code changed.

## Files changed

- `Sources/LiveStems/ControlsPanel.swift` (new). `ControlsPanel` holds the layout: source picker
  and Reset, status line, output line with `headphones`, four `ChannelStrip`s, the All stems row,
  and Quit with `power`. `ChannelStrip` draws the colored name plate with the stem symbol. It
  holds the waveform, the vertical fader, the level meter, and M / S. The file also has the
  `symbol(_:)` helper (moved from MenuController) and `Backdrop` (the rounded tray).
- `Sources/LiveStems/StemViews.swift`. `LogicToggle` is restyled: M lights systemBlue with white
  text, S lights yellow with black text. Target and action now come from the caller.
  `StemWaveform` has a darker inset background. New views: `LevelMeter` (24 segments, -48 to
  0 dB, short fall-off) and `FaderCell` (groove, dB scale 0/-3/-6/-10/-20/-inf, metal cap).
- `Sources/LiveStems/MenuController.swift`. Wiring only. The window is still titled, closable,
  and floating, and it joins all Spaces. It adds `.fullSizeContentView`, a transparent title bar,
  and a hidden title. The content view is an `NSGlassEffectView` that holds the panel. The layout
  code moved out, so the file went from 294 to 235 lines.

## Behavior notes

- Faders send the same linear 0–1 gain as before. The dB marks are drawn at `10^(dB/20)`.
- Meters use the existing 30 Hz `session.takeMeters` pre-fader peaks, multiplied by the
  stem's effective gain (after mute/solo), so a meter follows its fader like a Logic channel
  meter. The waveforms still show pre-fader peaks. No new audio taps.
- All accessibility labels are unchanged: "<Stem> volume", "<Stem> Mute", "<Stem> Solo",
  "Mute all", "Clear all solos", "Audio source", and the "Reset" / "Quit Live Stems" titles.
  Each strip is also an accessibility group named after its stem.

## Checks (in this sandbox)

The build needs `--disable-sandbox`, because SwiftPM's manifest sandbox cannot nest here:
`swift build --disable-sandbox --configuration release --scratch-path .build` printed
`Build complete!`.

| Stage | Result |
| --- | --- |
| rest | `PASS rest · no jobs while resting or paused; wake starts a job` |
| flutter | `PASS flutter · [... "pass": true, "underruns": 0 ...]` |
| transitions | `PASS transitions · 25 seeds × 75 s of random skips, seeks, pauses, sleeps, late results` |
| menu | **Not run.** The process exits 0 with no output. |
| spam | **Not run.** Same cause. |
| snapshot | **Not run.** Same cause. No PNGs written. |

Cause: inside this sandbox, `NSStatusBar.system.statusItem(...)` ends the process silently with
exit 0. A 6-line probe binary confirmed it: `NSApplication` and `NSWindow` work, and the process
stops at the status-item call. The same thing happens on the unchanged `main` code, so this
change did not cause it. Do not read exit 0 from these three stages as a pass here.

What I checked instead: I compiled `StemViews.swift` + `ControlsPanel.swift` into a scratch
renderer (`.build/probe/`, not committed). It wraps the panel in `NSGlassEffectView` and walks
the views the same way `MenuE2E.descendants` does. It found all the labels and 4 `NSSlider`s. It
rendered light and dark PNGs with the same `cacheDisplay` path that the snapshot stage uses. The
fader cap at gain 0.5 sits on the -6 mark, so the scale matches the value.

## Not done (needs Ben, outside the sandbox)

1. Run the AppKit stages:
   ```sh
   B=$(swift build --configuration release --scratch-path .build --show-bin-path)
   for st in menu spam snapshot; do "$B/LiveStems" --e2e $st --output .build/e2e/$st || echo "FAIL $st"; done
   ```
2. Look at `.build/e2e/snapshot/panel-light.png` and `.build/e2e/snapshot/panel-dark.png`.
3. Copy the dark one to `docs/panel.png`. I did not change `docs/panel.png`, because the
   snapshot stage could not run here.
4. Look at the live window once. `cacheDisplay` cannot draw the glass blur (the window server
   draws it), so the snapshots show the plain window background behind the panel. Real fader
   dragging is also not checked yet: the fader uses a 26 pt `knobThickness` so that AppKit's
   tracking matches the drawn cap.
