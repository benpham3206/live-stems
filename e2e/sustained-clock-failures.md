# Sustained clock failure checks before code

- A configured 260 ms buffer can hide a real one-second startup backlog.
  Acceptance must use the capture and render host times for the same frame.
- After startup and source changes settle, observed capture-to-render age must
  stay between 200 and 450 ms. This includes conversion and the native queue.
  This does not measure the physical output device's latency.
- A fresh diagnostics file from a dead app must not count as a ready session.
  Check both process identities before the live observation starts.
- A pause or source change can invalidate a render sample. Do not count that
  sample as a steady latency check. Require steady samples during playback.
- Keep the existing 80 ms p95, 100 ms maximum, and 99.5 percent full-stem gates.
  Retain failed reports. Do not change limits to match a slower result.
