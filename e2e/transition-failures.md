# Transition checks before code

- A capture callback can start after a skip but contain a hardware block dated
  before the skip. Reject old timestamped frames, including the old prefix of
  a crossing block. Reset converter carry. Do not add an arbitrary hold time.
- Deliver that old block through the actual native callback, then convert with
  AudioSession. Compare with conversion of only the new source. Save WAVs and
  a report. A callback-generation check alone does not test this failure.
- Cold startup must keep direct Spotify audible until output has a primed
  source queue. Do not suppress Spotify while the output queue is empty.
- Original, stems, and Return keep the same output frame clock. The first
  direct-to-buffer handoff has an inherent timing offset; record it honestly.
- Quit must not release capture into ahead-of-buffer direct audio while the
  user requests the same timing. Preserve Original playback until a paused
  source drains. Close controls and stop AI. Reopening must restore one menu
  and the same audio session. Keep final process termination possible.
- Keep all four models, current source-frame deadlines, logging bounds, stable
  signing, and CUA off. Save installed-app runtime evidence and physical limits.
- Queue Quit completion while the main run loop cannot deliver it. Reopen
  before delivery. The queued completion must not terminate the reopened app.
  Use a session-queue barrier. Do not rely on a sleep to win the race.
