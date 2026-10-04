# Live Stems internals

Engineering notes for the playback pipeline and its checks. The user guide is
[README.md](../README.md).

## Playback

The processor uses one-second input windows. It requests a new result every
at least 100 ms after the previous request. Each result supplies the new source
frames since that request. The usable output ends 50 ms before the input ends.
Window ends follow actual capture blocks. They are not rounded to a time grid.
The model uses short-context single-pass inference. This changes the estimates
compared with full contextual inference, even though the weights are the same.

Original and stems share a fixed 260 ms producer buffer. The native output
queue and conversion add time. The current live Return test measures about
339 ms from capture to render. This excludes physical device latency. The model warms before capture starts. The first
captured second plays Original while the processor builds context. It then
fades into fresh stems. A seek or skip builds new context in the same way.

Every result retains its actual source frame range. Processing time determines
whether it arrives before that frame's playback deadline. A late result uses
the stem-free part of the mix at the same frame: Original at Other's gain. It never rewinds the song or increases the buffer.
Adjacent estimates blend over 10 ms at identical uncommitted source frames.

The model rests when its output is not needed: all four stems have the same
gain after Mute and Solo, or Spotify is paused. Equal gains play Original at
that gain, so neutral controls give Original and all-stem mute gives silence.
Resting stops GPU jobs but keeps the worker loaded. A control change wakes it,
and stems fade in from the last captured second. Resting frames are not counted
as steady stem frames. Reset returns all controls to neutral, selects stems, and starts a worker if none runs. Reopening
the app during a Quit relay does the same.
Pause drains the short buffered tail, then stops. Resume keeps the source
sequence and prepares new model context. A manual skip discards the old queue,
the last rendered sample, unread capture, and converter carry. Notifications
publish without waiting for the blocking metadata reader. Stale reads cannot
restore a track after a skip. A cut inside one second of the last cut that
names either side of it is the same transition, not a new skip. The render
fades the last sample over 2 ms at a flush instead of cutting hard. The
notice precedes the acoustic change by about 50 ms and a silence gap follows
the old-track tail, so the first gap start becomes the new model boundary
without delaying playback. The post-skip rebuild rehearses the latest second
at the steady hop (results discarded) so the first real jobs are not cold.
Each result keeps its 50 ms right-context tail as a provisional estimate. A
partly late result commits its uncommitted suffix, and missing frames use the
tail instead of Original. The next result replaces provisional frames with a
short crossfade. Jobs also start on result arrival, not only on the 10 ms tick.
The cut also rejects samples with hardware timestamps before the notification
boundary. A callback that starts after a cut can still contain an older block.
Only the fresh suffix of a crossing block enters the converter.
Natural changes keep the captured source sequence and reject old model context.

Equal gains reproduce Original at that gain without stems. The difference
between the stem sum and Original is assigned to Other. Bass Solo uses the bass
estimate. The processed mix limiter allows the larger of 0.98 and that frame's
Original peak. The panel has no Original/Stems or Return buttons.
Quit uses the same Original fade, stops the worker, and closes the controls and menu icon.
A small Original relay keeps the playback clock until Spotify pauses. It then
drains the queued tail and exits. Open the app again to restore its controls
and cancel the pending exit. The relay does not run the model.

At cold startup, direct Spotify remains audible while the worker warms and the
Original queue fills. Capture takes over only with at least 50 ms queued.
This removes the empty-queue mute. Direct Spotify and captured playback still
have an initial timing offset of about 340 ms. Within captured playback,
Original and stems use the same source frames.

Capture history is bounded to three seconds and compacts to two seconds. Ready
stem data has an 8 MiB bound. No song library or long track cache is retained.
The model allocation cache has a 1 GiB bound. Live process memory and inference
deadlines remain acceptance checks. Only one app instance can acquire capture.
Metadata is used to invalidate context on seeks and track changes. The captured
sample clock remains the authority for audio alignment.

## Verification

Live timing logs are local under `~/Library/Application Support/Live Stems/`.
`live-trace.jsonl` records mix changes, source frames, job windows and durations,
coverage gaps, queue depth, and thermal state. Late and partly late results,
provisional cover, skip boundaries with the old-track tail length, duplicate
cuts, warmup jobs, and first post-cut audio are recorded with frame counts. `worker-timing.jsonl` records
model computation, output transfer, and MLX memory. Each log has a 2 MiB limit
and one previous file. The trace records timing only; it does not record audio
or song titles. File writes run outside the audio callback.

Capture-to-render time uses the captured host timestamp and the render callback
host timestamp. Sample-rate conversion contributes an estimate. Device latency
is not measured. Track-relative position is also an estimate. The configured
producer buffer is separate from this observed value.

```sh
tail -f "$HOME/Library/Application Support/Live Stems/live-trace.jsonl"
python3 outputs/live-stems-source/e2e/trace_report.py --output outputs/live-stems-acceptance/sustained-repair/live-trace-report.json
python3 outputs/live-stems-source/e2e/trace_report.py --follow
```

User action logs are also available in Console under subsystem
`com.benpham.livestems`, categories `Timing` and `Windowing`.

Failure criteria are in `e2e/stream-failures.md`. Run one GPU worker at a time.
Disable the installed processor while running the fixture and packet stages.

```sh
work/stems-venv/bin/python outputs/live-stems-source/e2e/run.py --stage stream --output outputs/live-stems-acceptance/short-stream
work/stems-venv/bin/python outputs/live-stems-source/e2e/run.py --stage recovery --output outputs/live-stems-acceptance/short-stream
work/stems-venv/bin/python outputs/live-stems-source/e2e/run.py --stage worker --output outputs/live-stems-acceptance/short-stream
work/stems-venv/bin/python outputs/live-stems-source/e2e/run.py --stage sustained --duration 120 --output outputs/live-stems-acceptance/sustained-repair/final-live
work/stems-venv/bin/python outputs/live-stems-source/e2e/signing.py
```

The paced stream test uses audible source passages and real model output. It
covers fresh playback, seeks, pause/resume, natural/manual changes, mix controls,
and a deliberately late result. It saves source/output WAVs, commit records,
frame comparisons, model timing, and a pass/fail report.

The live monitor reads `~/Library/Application Support/Live Stems/active-session.json`.
It checks clock advancement, bounded history and ready data, fixed delay, zero
rewinds, actual per-frame stem coverage, underruns, and sampled process CPU/RAM. CPU uses one core as 100 percent.
It also checks actual capture-to-render age, with a 200–450 ms range after
startup and source changes settle. The configured buffer alone cannot prove
observed latency. Each sample also records whole-GPU utilization from IOKit. The report gives mean
and maximum GPU and CPU load. GPU load is not per process. Samples are 5 s apart,
so they do not show peak load. A passing fixture is not proof
of live capture or human sound quality. Current results and limitations are in
`outputs/live-stems-state.md`.

The native `skip`, `skip-state`, `trace`, `startup`, `menu`, and `rest` stages run
through the release binary with `--e2e <stage> --output <directory>`. The `return` stage
uses the signed app, live Spotify capture, and the real worker. Close the normal
app and leave Spotify playing before that stage. It checks Return, cancellation
during worker startup, and recovery without a playback clock reset. It saves
the timing trace and action snapshots. It does not use CUA. The `rest` stage
needs no worker. It checks that the model gets no jobs while it rests or while
Spotify is paused, and that the resting mix follows the controls.

The signed `quit` stage checks actual capture, worker exit, Original relay,
reopen, and final drain. It injects the metadata pause locally. It does not
pause Spotify. The `quit-race` stage uses session barriers to cancel a Quit
completion already queued on the main run loop. The `capture-cut` stage sends
old and crossing timestamped blocks through the actual capture callback and
converter. It saves the converted WAVs and exact comparison.

```sh
"/Applications/Live Stems.app/Contents/MacOS/LiveStems" --e2e quit --output outputs/live-stems-acceptance/transitions-2/repeat-quit
"/Applications/Live Stems.app/Contents/MacOS/LiveStems" --e2e quit-race --output outputs/live-stems-acceptance/transitions-2/repeat-race
"/Applications/Live Stems.app/Contents/MacOS/LiveStems" --e2e capture-cut --output outputs/live-stems-acceptance/transitions-2/repeat-cut
```

The earlier cache and no-rewind reports describe previous builds. They are not
acceptance for this stream processor. The local A/B page under
`outputs/live-stems-acceptance/ft-continuous` compares short context to a full
contextual reference. Similarity scores are not separation accuracy scores.
