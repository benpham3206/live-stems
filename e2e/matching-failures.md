# Source-match repair checks

Record these cases before changing the search.

- The local reference has extra introduction audio. A passage five seconds away from Spotify metadata must still be found at the correct source frame.
- A proposed position has no corresponding passage. Reject it without muting Spotify.
- Low correlation must remain rejected. Report the best score rather than hiding it as zero.
- Silence must stay rejected. No permissive title-only handoff is allowed.
- Captured audio is resampled from the hardware rate. Admission must use continuous samples and preserve their host time.
- Broad initial search must remain off the audio callback. Record its compute time.
- After admission, a changed track or passage must still restore live Spotify.
- Verify against actual Spotify. The offline source cannot accept the live match by itself.
