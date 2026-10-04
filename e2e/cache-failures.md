# Track-cache E2E failure checks

Write these checks before the cache playback code. Each check must exercise the
real fine-tuned worker, the timeline, the cache, the C mixer, and the output
write hook. Internal counters alone do not pass a check.

- First play starts from the live source. The output may remain Original while
  the worker obtains future context. It must match the captured source at the
  current position with the normal near-40 ms output-queue offset.
- A seek-back into cached audio must use stems only after waveform matching
  confirms the cached passage. The fade-in may use same-position stems. A
  wrong passage must keep original audio live.
- Crossing from cached coverage into the split frontier must keep the timeline
  continuous. The frontier must return Original while coverage ends. It must
  not starve backfill, repeat a cached block, or move the capture cursor.
- Pause must stop capture-time advancement. Resume must continue from the
  same source position and must not leak more than the documented output queue
  and de-click tail.
- A seek-forward into an unseen region must cut to the new source position,
  keep original fallback audible, and retain zero lag and zero jumps.
- A natural track change must never mix the old track's cache with the new
  track. The first new-track output must stay live and correlate with the
  distinct new-track fixture data.
- A manual skip must be distinct from a natural change. The old cache must not
  be selected after the skip, even when positions are numerically similar. The
  new content must remain on the live capture timeline.
- Every playback observation must report `lagFrames == 0` and `jumps == 0`.
  These are invariants in every phase, including cached seek and frontier
  backfill.
- Every output commit must match the captured source at its global capture
  frame, using only the measured near-40 ms output-queue offset. Commit starts
  must not move backward within a segment. An explicit seek may change the
  source passage, but it must not change the global capture-frame clock.
- A stale generation result must be rejected after reset or track change. It
  must not restore invalidated cache frames or alter the current output.
- Stem writes must be finite, stay below the limiter, and sum to the original
  mixture within the measured SNR threshold. Stem controls must not alter
  original fallback frames.
- Native ring output must record no repeated underrun envelope during a
  continuous run. A deliberate feed stall must produce only the bounded
  silence/de-click envelope described by the scenario.
- Worker exit, timeout, or cancellation must restore the original path and
  release the worker. The recovery result must include the bounded deadline
  and cancellation evidence.
- The native recovery mixer must use 11-channel frames made from the real
  worker result and the exact source frame. With the vocal channel muted,
  toggling Original (`ls_stems(core, 0)`) and Stems (`ls_stems(core, 1)`) must
  keep one queued timeline. Original output must converge to the unchanged source
  at the recorded frame indexes after the 8 ms blend settles. Original must
  retain source peaks above 0.98. The limiter must act on the processed stem mix
  before the fade to Original. There must be no fixed output attenuation. The
  switched-back Stems output must match the summed non-vocal worker channels at
  the same indexes. The played count must advance continuously, the switch
  step must stay bounded, and the continuous switch window must have zero
  underruns and overflows.
- A mixer reset must clear queued audio while an old audible block is still
  queued. An empty output flush must leave a write shorter than the 50 ms
  prime unconsumed, then consume output after a sufficient prime. The recovery
  artifact must save the rendered switch WAV and the measured reset/flush
  results.
- The fallback check must include audible source peaks above 0.98. Mute all
  stems, then toggle Stems off and on while fallback continues. After the
  startup envelope, every rendered sample must equal the source. Record the
  sample count, source peak, and maximum error. A global limiter or fixed gain
  on Original is a failure.
- After a stale generation is injected, the next matching request from the
  real worker must be accepted. The cache byte count must grow, and the
  discarded-result count must stay unchanged for the matching result. A stale
  result must not be used as proof of cache progress.
- The signed build must retain the same identity. A build that changes the
  identity or loses the AppleEvents permission is a failure.

The mixer, reset, and stale-generation checks are isolated recovery checks.
They use the real worker result and pipeline objects but do not replace the
80-second paced cache scenario or prove sustained 192 MiB pressure.

The paced scenario below runs these events in order:

1. Play track A from its beginning while the worker processes real source
   windows.
2. Seek back into already cached audio and verify waveform correlation before
   accepting stems.
3. Cross the split frontier and verify that output remains continuous while
   new work is admitted.
4. Pause and resume at the same position.
5. Seek forward into an unseen region and verify zero-lag original fallback.
6. Let track A change naturally to track B and verify track identity at the
   seam.
7. Manually skip to distinct content and verify that the old cache is not
   reused.
8. Submit a result from the old generation and verify that it is discarded.

The report must contain source/output waveform correlation at the measured
near-40 ms queue offset for every phase, stem-sum SNR, finite and limiter
checks, write-hook records, zero-valued lag/jump observations, global commit
frame checks, underrun envelopes, worker deadline/cancellation evidence, and
the exact fixture paths. A passing report is a rerunnable artifact, not a
self-reported counter.
