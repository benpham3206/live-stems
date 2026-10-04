# Any-song live stems failure checks

Write these cases before the any-song playback code.

- Capture starts before stems exist: the first seconds play the delayed original mixture on the fixed timeline. Original Spotify is suppressed from the start. Do not play live original and hand off later.
- A skip, seek, or track change mid-window: the tap stream continues. Do not flush the delay line or replay audio. The delayed mixture carries the new song until its stems commit.
- Spotify pauses: the tap stream carries silence or stalls. Fill any stall with silence by host time. The output delay must stay constant. No underrun, no drift.
- A window result misses its commit deadline: commit the original mixture for that range on the same timeline. Count the fallback. Do not grow the delay to wait.
- A result arrives after its range was already covered: discard it. Never reorder the output stream.
- The worker exits, times out, or misses repeatedly: end the session. Release the tap. Original Spotify becomes live and audible again.
- Two eligible windows while the worker is busy: run the newest. The skipped range falls back to mixture at its deadline.
- Commit range arithmetic (window W = 343980, hop H = 85995, right context R = 85995): a window starting at s emits absolute [s+171990, s+257985). Crossfade with the previous window's estimate of the same absolute range (previous local offset 257985). A wrong offset plays the wrong passage or double-counts a range.
- Cross-correlation of output against input must show exactly D = 5.0 s (220500 frames, ±1) at the start, after the abrupt cut, and after the silence gap. Any other offset means the timeline drifted.
- Rendered output must stay finite and peak at or below 1.0. The limiter must hold when all four stems combine.
- Inference p95 must stay under half the hop (0.975 s). A slower worker turns every range into mixture fallback.
- A stem range must sum close to the mixture. A large residual means wrong channel layout or a broken crossfade.
- Audition: Ben must confirm the delayed mix and the vocals-mute audition sound right. Offline checks do not pass live listening.
