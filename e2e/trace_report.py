"""Summarize saved live traces. This reads timing records, never audio samples."""
import argparse
import json
import time
from pathlib import Path


def read_records(paths):
    records = []
    for path in paths:
        if path.exists():
            for line in path.read_text().splitlines():
                try:
                    records.append(json.loads(line))
                except json.JSONDecodeError:
                    # The active writer can be between writes. Retry a saved
                    # copy for strict parsing; never invent a missing record.
                    raise ValueError(f'Incomplete record in {path}; copy after the writer flushes')
    return records


def stats(values):
    values = sorted(values)
    if not values:
        return None
    return {'count': len(values), 'min': values[0], 'p50': values[int((len(values)-1)*.5)],
            'p95': values[int((len(values)-1)*.95)], 'max': values[-1]}


def pair_durations(records, start_event, end_event):
    """Pair each start with the next end. Returns [(start, ms, frames)]."""
    pairs = []
    pending = None
    for r in sorted(records, key=lambda r: r['uptime']):
        if r['event'] == start_event:
            pending = r
        elif r['event'] == end_event and pending is not None:
            frames = (r.get('sourceFrame') or 0) - (pending.get('sourceFrame') or 0)
            pairs.append({'uptime': pending['uptime'], 'duration_ms': (r['uptime']-pending['uptime'])*1000,
                          'frames': frames})
            pending = None
    return pairs


def slack_histogram(records):
    values = sorted(r['deadlineSlackSeconds']*1000 for r in records if r.get('deadlineSlackSeconds') is not None)
    edges = [-100, -50, -25, 0, 10, 20, 30, 40, 50, 75, 100, float('inf')]
    bins = [0]*(len(edges)-1)
    for v in values:
        for i in range(len(bins)):
            if edges[i] <= v < edges[i+1]:
                bins[i] += 1
                break
    labels = ['<0' if e == float('inf') else f'{edges[i]}-{int(e)}' for i, e in enumerate(edges[1:])]
    return {'count': len(values),
            'min_ms': values[0] if values else None,
            'p5_ms': values[int((len(values)-1)*.05)] if values else None,
            'median_ms': values[(len(values)-1)//2] if values else None,
            'bins': dict(zip(labels, bins))}


def skip_timelines(records):
    """One row per manual cut: notice, first audio, boundary, stems, blips."""
    cuts = sorted([r for r in records if r['event'] == 'source-change'], key=lambda r: r['uptime'])
    rows = []
    for i, cut in enumerate(cuts):
        horizon = cuts[i+1]['uptime'] if i+1 < len(cuts) else float('inf')
        later = [r for r in records if cut['uptime'] < r['uptime'] < min(horizon, cut['uptime']+8)]
        first = next((r for r in later if r['event'] == 'skip-first-audio'), None)
        boundary = next((r for r in later if r['event'] == 'skip-boundary'), None)
        restored = next((r for r in later if r['event'] == 'coverage-restored'), None)
        blips = pair_durations([r for r in later if r['event'] in ('coverage-gap', 'coverage-restored')],
                               'coverage-gap', 'coverage-restored')
        provs = pair_durations([r for r in later if r['event'] in ('provisional-cover', 'provisional-end')],
                               'provisional-cover', 'provisional-end')
        tail = None
        if boundary and boundary.get('sourceFrame') is not None and boundary.get('sourceEnd') is not None:
            tail = (boundary['sourceFrame']-boundary['sourceEnd'])/44.1
        rows.append({'cut_uptime': cut['uptime'], 'queued_frames': cut.get('queuedFrames'),
                     'notice_to_first_audio_ms': (first['uptime']-cut['uptime'])*1000 if first else None,
                     'boundary_tail_ms': tail,
                     'notice_to_stems_ms': (restored['uptime']-cut['uptime'])*1000 if restored else None,
                     'blips': len(blips), 'blip_total_ms': sum(b['duration_ms'] for b in blips),
                     'provisional_covers': len(provs),
                     'duplicates': sum(1 for r in later if r['event'] == 'source-duplicate')})
    return rows


def summarize(records, worker):
    starts = [r['uptime'] for r in records if r['event'] == 'start']
    if starts:
        records = [r for r in records if r['uptime'] >= starts[-1]]
        worker = [r for r in worker if r['uptime'] >= starts[-1]]
    samples = [r for r in records if r['event'] == 'sample']
    jobs = [r for r in records if r['event'] == 'job-finish']
    if not samples:
        raise ValueError('No live render samples in trace')
    first = samples[0]['uptime']
    worker_by_job = {(r.get('pid', 0), r['generation'], r['job']): r for r in worker}
    phases = []
    for start, end in [(0, 30), (30, 90), (90, 180)]:
        phase = [r for r in samples if start <= r['uptime']-first < end]
        results = [r for r in jobs if start <= r['uptime']-first < end]
        measured = [r['estimatedCaptureToRenderSeconds'] for r in phase
                    if 'estimatedCaptureToRenderSeconds' in r]
        paired = []
        for r in results:
            key = (r['workerPID'], r['generation'], r['jobID'])
            legacy_key = (0, r['generation'], r['jobID'])
            if key in worker_by_job:
                paired.append(worker_by_job[key])
            elif legacy_key in worker_by_job:
                paired.append(worker_by_job[legacy_key])
        phases.append({'start_seconds': start, 'end_seconds': end,
                       'round_trip_seconds': stats([r['elapsedSeconds'] for r in results]),
                       'compute_seconds': stats([r['compute_seconds'] for r in paired]),
                       'copy_seconds': stats([r['copy_seconds'] for r in paired]),
                       'send_seconds': stats([r['send_seconds'] for r in paired]),
                       'estimated_capture_to_render_seconds': stats(measured),
                       'queued_frames': stats([r['queuedFrames'] for r in phase]),
                       'thermal_states': sorted({r['thermalState'] for r in phase if 'thermalState' in r})})
    blips = pair_durations(records, 'coverage-gap', 'coverage-restored')
    provs = pair_durations(records, 'provisional-cover', 'provisional-end')
    warmups = sorted(r['elapsedSeconds']*1000 for r in records
                     if r['event'] == 'warmup-finish' and r.get('elapsedSeconds') is not None)
    return {'status': 'observations', 'duration_seconds': samples[-1]['uptime']-first,
            'sample_count': len(samples), 'job_count': len(jobs),
            'render_samples_with_stems': sum(r.get('blend', 0) > 0 for r in samples),
            'coverage_gap_events': sum(r['event'] == 'coverage-gap' for r in records),
            'trace_dropped_records': sum(r.get('droppedRecords', 0) for r in records),
            'late_results': sum(r['event'] == 'late-result' for r in records),
            'late_frames_total': sum(r.get('lateFrames', 0) for r in records if r['event'] == 'late-result'),
            'partial_late_results': sum(r['event'] == 'partial-late' for r in records),
            'partial_late_frames_total': sum(r.get('lateFrames', 0) for r in records if r['event'] == 'partial-late'),
            'provisional_covers': len(provs),
            'provisional_cover_total_ms': sum(p['duration_ms'] for p in provs),
            'provisional_cover_max_ms': max([p['duration_ms'] for p in provs] or [0]),
            'blips': {'count': len(blips), 'total_ms': sum(b['duration_ms'] for b in blips),
                      'max_ms': max([b['duration_ms'] for b in blips] or [0]),
                      'pairs': blips[-20:]},
            'skips': skip_timelines(records),
            'duplicate_cuts': sum(r['event'] == 'source-duplicate' for r in records),
            'slack_histogram_ms': slack_histogram(records),
            'warmup_seconds': stats([w/1000 for w in warmups]),
            'gpu_active_bytes': stats([r['gpu_active_bytes'] for r in worker]),
            'gpu_cache_bytes': stats([r['gpu_cache_bytes'] for r in worker]),
            'gpu_peak_bytes': stats([r['gpu_peak_bytes'] for r in worker]),
            'phases': phases,
            'limits': 'One shared output frame identifies Original/stem timing; this trace does not '
                      'independently verify their sample content. Tap-to-render timing includes an '
                      'estimate through sample-rate conversion and excludes device latency. '
                      'MLX allocator observations are not device-wide GPU load. Observations are not acceptance.'}


def render_html(report, records):
    def bar(label, count, peak):
        width = int(120*count/max(peak, 1))
        return f'<div class="row"><span>{label}</span><div class="bar" style="width:{width}px"></div>{count}</div>'
    peak = max(report['slack_histogram_ms']['bins'].values() or [1])
    hist = ''.join(bar(k, v, peak) for k, v in report['slack_histogram_ms']['bins'].items())
    skips = ''.join(
        '<tr><td>{:.1f}</td><td>{}</td><td>{}</td><td>{}</td><td>{}</td><td>{}</td></tr>'.format(
            s['cut_uptime'],
            '-' if s['notice_to_first_audio_ms'] is None else f"{s['notice_to_first_audio_ms']:.0f} ms",
            '-' if s['boundary_tail_ms'] is None else f"{s['boundary_tail_ms']:.0f} ms",
            '-' if s['notice_to_stems_ms'] is None else f"{s['notice_to_stems_ms']/1000:.2f} s",
            s['blips'], s['provisional_covers']) for s in report['skips'])
    blips = ''.join('<tr><td>{:.1f}</td><td>{:.1f} ms</td><td>{} frames</td></tr>'.format(
        b['uptime'], b['duration_ms'], b['frames']) for b in report['blips']['pairs'])
    return ('<html><head><style>body{font-family:system-ui;margin:24px}'
            '.bar{background:#369;height:12px;display:inline-block;margin:0 8px}'
            '.row{white-space:nowrap}table{border-collapse:collapse}'
            'td,th{border:1px solid #ccc;padding:4px 8px;text-align:right}</style></head><body>'
            f"<h1>Live Stems trace ({report['duration_seconds']:.0f} s)</h1>"
            f"<p>Blips: {report['blips']['count']} total {report['blips']['total_ms']:.0f} ms. "
            f"Late: {report['late_results']}. Partial-late: {report['partial_late_results']}. "
            f"Provisional covers: {report['provisional_covers']}. "
            f"Duplicate cuts: {report['duplicate_cuts']}.</p>"
            '<h2>Slack at acceptance (ms)</h2>' + hist +
            '<h2>Skips</h2><table><tr><th>uptime</th><th>notice to audio</th>'
            '<th>old-track tail</th><th>notice to stems</th><th>blips</th><th>provisional</th></tr>'
            + skips + '</table><h2>Recent blips</h2><table><tr><th>uptime</th><th>duration</th>'
            '<th>frames</th></tr>' + blips + '</table></body></html>')


def follow_pairs(directory):
    """Follow mode with gap/restored pairing for BLIP lines."""
    path = directory/'live-trace.jsonl'
    print(f'Following {path} (Ctrl-C stops)', flush=True)
    offset, inode, gap, cuts = 0, None, None, []
    while True:
        try:
            stat = path.stat()
            if inode != stat.st_ino or stat.st_size < offset:
                inode, offset = stat.st_ino, 0
            with open(path) as handle:
                handle.seek(offset)
                lines = handle.readlines()
                offset = handle.tell()
            for line in lines:
                try:
                    r = json.loads(line)
                except json.JSONDecodeError:
                    break
                event = r.get('event')
                if event == 'coverage-gap':
                    gap = r
                elif event == 'coverage-restored' and gap is not None:
                    ms = (r['uptime']-gap['uptime'])*1000
                    print(f"BLIP {ms:.0f} ms of Original inside stems", flush=True)
                    gap = None
                elif event == 'provisional-cover':
                    print(f"PROVISIONAL stems covering a late result at frame {r.get('sourceFrame')}",
                          flush=True)
                elif event == 'partial-late':
                    print(f"LATE-PARTIAL {r.get('lateFrames', 0)} frames committed early, "
                          f"suffix kept as stems", flush=True)
                elif event == 'late-result':
                    print(f"LATE-DISCARDED {r.get('lateFrames', 0)} frames, fell back", flush=True)
                elif event == 'source-change':
                    cuts.append(r)
                    print(f"SKIP cut at frame {r.get('sourceFrame')}, "
                          f"{r.get('queuedFrames', 0)} queued frames flushed", flush=True)
                elif event == 'source-duplicate':
                    print('SKIP-DUP duplicate notice ignored, no second flush', flush=True)
                elif event == 'skip-boundary':
                    tail = (r.get('sourceFrame', 0) or 0)-(r.get('sourceEnd', 0) or 0)
                    if tail > 0:
                        print(f"SKIP-BOUNDARY old-track tail {tail/44.1:.0f} ms kept out of context",
                              flush=True)
                elif event == 'skip-first-audio':
                    print(f"SKIP-AUDIO first post-cut audio {(r.get('elapsedSeconds', 0))*1000:.0f} ms "
                          f"after notice", flush=True)
                elif event == 'warmup-finish':
                    print(f"WARMUP {(r.get('elapsedSeconds', 0))*1000:.0f} ms", flush=True)
                if event == 'coverage-restored' and cuts:
                    cut = cuts[-1]
                    if r['uptime']-cut['uptime'] < 8:
                        print(f"SKIP notice to stems {(r['uptime']-cut['uptime']):.2f} s", flush=True)
                        cuts.pop()
        except FileNotFoundError:
            pass
        time.sleep(0.5)


if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('--directory', type=Path, default=Path.home()/'Library/Application Support/Live Stems')
    parser.add_argument('--output', type=Path, required=False)
    parser.add_argument('--follow', action='store_true')
    parser.add_argument('--html', type=Path, required=False)
    args = parser.parse_args()
    if args.follow:
        try:
            follow_pairs(args.directory)
        except KeyboardInterrupt:
            pass
    else:
        if args.output is None:
            parser.error('--output is required without --follow')
        records = read_records([args.directory/'live-trace.previous.jsonl', args.directory/'live-trace.jsonl'])
        worker = read_records([args.directory/'worker-timing.jsonl.1', args.directory/'worker-timing.jsonl'])
        report = summarize(records, worker)
        args.output.parent.mkdir(parents=True, exist_ok=True)
        args.output.write_text(json.dumps(report, indent=2)+'\n')
        print(json.dumps(report, indent=2))
        if args.html:
            args.html.write_text(render_html(report, records)+'\n')
            print(f'Wrote {args.html}')
