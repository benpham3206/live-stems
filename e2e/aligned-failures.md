# Live Spotify admission checks

Write these cases before the aligned playback code.

- A prepared source matches with a level change and a different metadata position: find its sample position within one frame.
- Input is from another passage or song: reject the proposed position. Keep Spotify audible.
- Input is silence: do not infer a match or mute Spotify.
- Prepared stems do not cover the current position: keep Spotify audible.
- A track changes while prepared stems play: reject its first mismatched capture block. Do not play the previous cache while waiting for model work.
- Core Audio does not supply a valid host timestamp: keep Spotify audible.
- Render is at a future host time: read that position in the prepared source. Do not queue historical audio.
- Render reaches the end of the asset: stop cached playback and restore Spotify.
- Any loading or render failure: restore Spotify and release the private tap.
- A source is over five minutes or a stem is invalid: reject it before callback use.
- Actual Spotify transition: Ben must confirm that no passage repeats and no skip delay is perceptible. Offline alignment does not pass this check.

This path requires a matching complete local source. It does not make uncached first-play stems available from a live-only stream.
