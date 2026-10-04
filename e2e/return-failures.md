# Return and rapid restart failure checks before code

- Run the signed app with real Spotify capture and the real model. Do not run
  another app or worker at the same time. Do not use GUI automation.
- Return while inference runs. The worker must stop. Capture, playback counters,
  and the session generation must continue. Keep the same output frame clock.
- Request stems, stop the new worker during startup, then request stems again.
  A cancelled worker must not end or replace the active session.
- The final worker must accept new estimates. The retired worker must exit.
- Across these actions, sampled rendered frames must not go backward. Steady
  capture-to-render age must stay between 200 and 450 ms.
- Save the native timing trace, action snapshots, and a pass/fail report. This
  proves runtime timing and lifecycle. The stream WAV test proves sample timing.
  A listening check is still needed to accept perceived sound quality.
