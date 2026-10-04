# Live short-window failure checks

Write these checks before the new stream implementation. Use the real four
fine-tuned models and the native capture-frame timeline. No prepared stems.

- Fresh first playback must reach audible stems within 1.5 seconds after the
  first captured sample. An unseen track must not need a replay or cache seek.
- Input windows are one second. New jobs advance by 100 ms. The output core
  ends 50 ms before the input window ends. Cold compilation occurs before the
  worker sends Ready. Record cold warm-up and actual packet timing separately.
- Original and stems use the same global capture frame. Original is held by
  a fixed 260 ms producer buffer from session start. The native 40–55 ms queue
  adds to that delay. Never change the read cursor because a result finishes.
- Every committed Original sample must equal the fixture at its source frame.
  Record all comparisons. Rendered waveform timing must match the fixed buffer
  plus the measured native queue offset in every play/seek/skip phase.
- A worker miss must use same-position Original. It must not repeat an old
  stem chunk or grow playback delay. Returning from a miss must fade smoothly.
- Seek back and seek forward to unseen audio. Both must regain fresh stems.
  Pause/resume and natural/manual track changes must reject old context. The
  track change cannot mix a previous track's stem result into the new source.
- Deliberately hold a real worker result past its output deadline, and release
  it. Prove fallback and subsequent fresh recovery from actual output samples.
- Original/Stems toggles must keep the same queued frame sequence. Neutral
  controls must reconstruct Original at unity gain. Bass Solo must select only
  the model's bass pair. All-stem mute must produce silence on full stem frames.
  The mixture residual belongs to Other. Limit processed peaks against the
  larger of 0.98 and that frame's Original peak. Never attenuate Original.
- A result must retain its input frame range. Reject wrong generation, wrong
  shape, non-finite samples, and context changed during inference. An injected
  wrong identity must leave the actual in-flight request available to finish.
- Continuous playback must not underrun. Explicit pause/skip priming is
  measured separately. No backward or overlapping output commits are allowed.
- Steady packet p95 must be below 80 ms and every accepted one-second result
  must complete below its sustainable 100 ms hop. Record all packet samples.
- Retain bounded history and pending stem data. Keep process samples within
  the existing CPU/RAM limits. Signing identity must remain stable.

The E2E must save rendered, captured, and expected WAVs, actual commit records,
deadline/coverage observations, exact-frame comparison totals, timing, and a
machine-readable pass/fail report. Human sound quality and GPU use remain
separate checks. Do not replace missing evidence with counters alone.

Live handoff correction: The 230 ms producer deadline left little room for
capture scheduling and chunk fades. Use 260 ms before device latency. The
pause tail must stop within 330 ms. Keep the timing gates unchanged and retain
the first live failure report. Status text must not change on each blend dip.

Pulsing regression: Count full stem weights over every steady committed frame,
not only periodic status samples. At least 99.5 percent must have full coverage.
Count steady frames only after the first second of each new capture context.
Controls window regression: Keep the panel across Spaces. When capture becomes
ready, show the controls once in the background. A user close must remain closed
until the user selects the menu icon. Starting capture must not remove the icon.
