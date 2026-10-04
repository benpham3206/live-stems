# Sustained playback repair: failure checks before code

- Run at least 120 seconds with the real worker. Compare the first 30 seconds
  with seconds 30–90 and the final 30 seconds. Keep failed reports.
- Record capture, queued output, rendered source frame, worker input range,
  usable result range, coverage, and mix changes in a bounded local live trace.
  Do not record audio or song titles. Do not write files on an audio callback.
- Fail if the trace calls a configured delay a measured delay. Host timestamps
  must identify their source. Capture minus played totals are not latency.
- Fail if Original and stems use different source frames. Fail if a mix change
  moves the playback cursor. Record track-relative time as an estimate.
- Fail if trace files grow without a limit, if the writer can block playback,
  or if diagnostics silently stop. Test rotation and parse every saved record.
- Simulate a blocking capture startup that accumulates old input. Begin the
  admitted source clock after the mute operation. No startup backlog may remain
  in the output queue. Live capture-to-render time must remain near the fixed
  producer buffer plus the small native queue, rather than one second.
- Starting the Spotify reader must return before a slow initial metadata poll
  completes. The capture/session queue must not wait for that poll.
- A second app launch must exit before creating a second capture or worker.
  Keep one live trace writer and one model worker. Save evidence for a real
  second launch while the installed app is running.
- Preserve all four fine-tuned models. Test a bounded larger MLX allocator
  cache against the saved baseline. Fail if steady job deadlines still miss,
  or sampled worker RSS exceeds 2 GiB. Do not loosen the timing gates.
- Inject repeated late results. Do not reuse old stems or rewind. Record every
  uncovered interval and all affected frames, not only periodic blend samples.
- Feed irregular capture block sizes and delay a job across a nominal hop.
  The next usable range must continue from the prior range at exact source
  frames. Do not lose a whole hop through rounding. Keep the one-second model
  shape, minimum 100 ms cadence, and fixed 260 ms producer buffer.
- A covered frame must not fade toward Original solely because it is near the
  end of the currently ready range. Test a result arriving near that boundary.
  Keep the initial fade and the recovery fade after an actual missing range.
- Return to Spotify's Original must preserve the queued source position. A
  processor reset must not reset the audio clock. Quit must restore direct audio.
- Menu clicks must show the controls on the first click. Mute and Solo must
  leave the window open. Verify close/reopen, readiness, and repeated actions.
- A skip must clear old queued samples and the de-click sample memory. Reject
  stale in-flight track metadata and worker results. Keep natural changes smooth.

Save source-frame records, rendered comparisons, resource samples, timing,
and a repeatable machine-readable result. Physical sound and window acceptance
remain separate from source checks and compilation.
