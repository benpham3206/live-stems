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

The source is any open app, picked in the panel (saved across launches). The
tap takes the app's bundle ID, its helpers (bundle IDs with the app's ID as a
case-insensitive prefix, e.g. com.google.Chrome.helper), and for Safari the
shared com.apple.WebKit.GPU process. Spotify alone adds transport notices,
Apple Events reads, and the self-pause; other apps work from audio alone.

The app arms at launch: capture and the worker start, the source stays direct, and
the pipeline commits nothing (holdForBreak), so waiting cannot fill the queue.
It takes over at the next natural break: while Spotify is paused (silent), or at
a track change or seek notice. Takeover discards everything already heard, so
playback resumes from that point after the steady lag and nothing repeats; the
shift lands on silence or a fresh start. Quit before takeover ends at once.

For every source, 250 ms of quiet capture (below about -48 dBFS) is also a
break. For apps other than Spotify, if no break comes within 3 s of stems being
wanted, the session takes over anyway: a dip, a 0.3 s gap whose first 50 ms
after the gap fade in. Quit hands back at a Spotify pause, or for other apps at
a quiet moment, at most 3 s later.

If stems are wanted before any break and the source is Spotify, the session makes one: it sends Spotify
"pause" over Apple Events, takes over when the paused state arrives, and sends
"play" (always, even if the pause notice never came, so Spotify is never left
paused). If no pause arrives within 2 s it takes over anyway, which leaves a
0.3 s gap and never a replay. An earlier time-stretch ease (AVAudioUnitTimePitch,
6 % then 1.5 %) was audible, especially on Bluetooth, and was removed.

A change of default output moves the AVAudioEngine output to the new device.
Capture, the queue, and the delay stay, so no second takeover happens.

Stems (re)enter after on-time results, then fade in over 200 ms. One isolated
coverage gap, a skip, or a wake needs one on-time result, so a single miss
recovers within the stream stage's 500 ms. A second gap within 2 s needs three
results in a row; a partly late result resets that count. Without the gate,
partly late results made stems flicker against Original about ten times a
second. The `flutter` stage uses a worker whose every third answer is 300 ms
late: without escalation the stem weight turns down 20 times in 12 s, with it
twice, and stems return once the worker is healthy.

Spotify state reads are stamped at the middle of the AppleScript call, when
Spotify sampled the position. Stamping at publish time made slow reads (worse
while a pause or play command shares the reader queue) look like seeks, which
flushed playback. The skip-state stage checks the stamp with a 0.6 s read.
A read samples the position at an unknown point inside a call that can take
about 0.5 s, so a same-track position counts as a seek only beyond 1 s. A false
seek flushes audible playback; a missed sub-second seek costs only model context.

Within
captured playback, Original and stems use the same source frames.

Capture history is bounded to three seconds and compacts to two seconds. Ready
stem data has an 8 MiB bound. No song library or long track cache is retained.
The model allocation cache has a 512 MiB bound; 1 GiB measured no faster
(p50 about 60 ms either way) and used 0.45 GB more. After 2 s without requests
(the model sleeps), the worker empties the cache: about 0.85 GB idle instead of
1.5 GB, and the first job after a sleep takes about 77 ms instead of 60. Live process memory and inference
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

The `transitions` stage needs no worker. It runs 25 seeds of random skips,
seeks, pauses, duplicate notices, model sleep and wake, late results, and the
takeover (break or self-pause). Playback must never go backward, must replay
nothing at takeover, must not underrun outside a transition, and must
settle at the steady delay.

The signed `quit` stage checks actual capture, worker exit, Original relay,
reopen, and final drain. It injects the metadata pause locally. It does not
pause Spotify. The `quit-race` stage uses session barriers to cancel a Quit
completion already queued on the main run loop. The `capture-cut` stage sends
old and crossing timestamped blocks through the actual capture callback and
converter. It saves the converted WAVs and exact comparison.

Launch the live `quit` and `return` stages through `open`, not from a shell.
Run from a shell, macOS can refuse to mute Spotify's tap ('!hog',
560492391), and the session stops at the handoff. Quit the normal app first.

```sh
open -W -g "/Applications/Live Stems.app" --args --e2e quit --output "$PWD/outputs/live-stems-acceptance/pr2-live/quit"
open -W -g "/Applications/Live Stems.app" --args --e2e return --output "$PWD/outputs/live-stems-acceptance/pr2-live/return"
```

The GPU-free stages run from a shell:

```sh
"/Applications/Live Stems.app/Contents/MacOS/LiveStems" --e2e transitions --output outputs/live-stems-acceptance/transitions
"/Applications/Live Stems.app/Contents/MacOS/LiveStems" --e2e quit-race --output outputs/live-stems-acceptance/transitions-2/repeat-race
"/Applications/Live Stems.app/Contents/MacOS/LiveStems" --e2e capture-cut --output outputs/live-stems-acceptance/transitions-2/repeat-cut
```

The earlier cache and no-rewind reports describe previous builds. They are not
acceptance for this stream processor. The local A/B page under
`outputs/live-stems-acceptance/ft-continuous` compares short context to a full
contextual reference. Similarity scores are not separation accuracy scores.
