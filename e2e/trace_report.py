"""Summarize saved live traces. This reads timing records, never audio samples."""
import argparse
import json
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
    return {'status': 'observations', 'duration_seconds': samples[-1]['uptime']-first,
            'sample_count': len(samples), 'job_count': len(jobs),
            'render_samples_with_stems': sum(r.get('blend', 0) > 0 for r in samples),
            'coverage_gap_events': sum(r['event'] == 'coverage-gap' for r in records),
            'trace_dropped_records': sum(r.get('droppedRecords', 0) for r in records),
            'gpu_active_bytes': stats([r['gpu_active_bytes'] for r in worker]),
            'gpu_cache_bytes': stats([r['gpu_cache_bytes'] for r in worker]),
            'gpu_peak_bytes': stats([r['gpu_peak_bytes'] for r in worker]),
            'phases': phases,
            'limits': 'One shared output frame identifies Original/stem timing; this trace does not '
                      'independently verify their sample content. Tap-to-render timing includes an '
                      'estimate through sample-rate conversion and excludes device latency. '
                      'MLX allocator observations are not device-wide GPU load. Observations are not acceptance.'}


if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('--directory', type=Path, default=Path.home()/'Library/Application Support/Live Stems')
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    records = read_records([args.directory/'live-trace.previous.jsonl', args.directory/'live-trace.jsonl'])
    worker = read_records([args.directory/'worker-timing.jsonl.1', args.directory/'worker-timing.jsonl'])
    report = summarize(records, worker)
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(report, indent=2)+'\n')
    print(json.dumps(report, indent=2))
