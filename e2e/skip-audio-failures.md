# Skip audio failure checks before code

- Play a nonzero previous-song frame, leave old frames queued, then flush.
  During the gap and the next short unprimed block, output must contain no
  previous-song sample. A reset-to-zero fixture does not test this failure.
- Leave unread capture in the native ring. A manual cut must discard it and
  reset converter carry before the next admitted source block.
- Start a long native capture callback, then cut before it completes. That old
  callback must not publish samples after the discard. The fixture must prove
  the discard happened before completion; otherwise it is not a race check.
- Keep new frames written after the flush boundary. Prime and resume using
  only the new source. Save rendered and expected WAVs and an exact comparison.
- A manual track change invalidates model context and queued audio. A natural
  boundary retains the source sequence. A stale result cannot undo either cut.
- Clear the render trace during flush priming. Do not report old frames as new.

Run the native skip scenario and the real-worker stream scenario. Verify live
skip notifications separately. CUA stays off.
