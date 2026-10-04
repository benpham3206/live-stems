"""Run worker, stream, recovery, and live-session acceptance checks.

The stream and recovery stages execute the native E2E binary. The worker stage
keeps malformed packet checks here because they exercise the process boundary.
The sustained stage observes the diagnostics file written by the running app.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import select
import struct
import subprocess
import sys
import time

import numpy as np

BASE = Path(__file__).resolve().parents[1]
ROOT = BASE.parent.parent
OUT = ROOT / 'outputs/live-stems-acceptance'
DIAGNOSTICS = Path.home() / 'Library/Application Support/Live Stems/active-session.json'
RATE = 44100
HOP = 4410
PACKET_P95_SECONDS = 0.08
PACKET_MAX_SECONDS = 0.10
FIXED_LAG_SECONDS = 0.26
FIXED_LAG_TOLERANCE_SECONDS = 0.03
HISTORY_LIMIT_FRAMES = 3 * RATE
QUEUE_LIMIT_FRAMES = RATE
CACHE_LIMIT_BYTES = 8 * 1024 * 1024
# These are acceptance limits for sampled process values, not GPU or peak CPU.
RESOURCE_LIMITS = {'app': {'rss_kib': 512 * 1024, 'cpu_percent': 50},
                   'worker': {'rss_kib': 2 * 1024 * 1024, 'cpu_percent': 150}}
HEADER = struct.Struct('<4sHHQQQIIHHI')


def packet(kind, generation=1, job=1, start=0, frames=0, rate=RATE, channels=2,
           stems=1, body=b'', version=1):
    return HEADER.pack(
        b'LSTM', version, kind, generation, job, start, rate, frames, channels,
        stems, len(body)
    ) + body


def read_exact(stream, count, deadline):
    body = bytearray()
    while len(body) < count:
        remaining = deadline - time.monotonic()
        if remaining <= 0 or not select.select([stream], [], [], remaining)[0]:
            raise TimeoutError('worker response timeout')
        part = os.read(stream.fileno(), count - len(body))
        if not part:
            raise EOFError('worker exited')
        body.extend(part)
    return bytes(body)


def reply(child, timeout=20):
    deadline = time.monotonic() + timeout
    header = HEADER.unpack(read_exact(child.stdout, HEADER.size, deadline))
    assert header[0:2] == (b'LSTM', 1) and header[-1] <= 16 * 1024 * 1024
    return header, read_exact(child.stdout, header[-1], deadline)


def launch(cache=None):
    worker = BASE / 'worker/stem_worker.py'
    if not worker.is_file():
        raise FileNotFoundError('Product worker missing')
    args = [sys.executable, str(worker), '--cache', str(cache or ROOT / 'work/model-cache')]
    OUT.mkdir(parents=True, exist_ok=True)
    env = dict(os.environ, OMP_NUM_THREADS='4', MKL_NUM_THREADS='4', PYTHONUNBUFFERED='1')
    # A real worker can log during inference. An unread stderr pipe can block
    # the protocol independently of the audio deadline.
    with (OUT / 'worker-packet-stderr.log').open('ab') as log:
        return subprocess.Popen(
            args, stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=log,
            bufsize=0, env=env
        )


def worker_stage():
    """Exercise the real worker and reject malformed process-boundary packets."""
    scenarios = json.loads((BASE / 'e2e/scenarios.json').read_text())
    manifest = json.loads((ROOT / 'outputs/four-stem-preflight.json').read_text())['inputs']['original']
    source = ROOT / 'work/dreamflasher-original.wav'
    assert hashlib.sha256(source.read_bytes()).hexdigest() == manifest['sha256']
    from demucs_mlx.audio import load_audio
    import mlx.core as mx

    audio, rate = load_audio(source, sr=RATE)
    mx.eval(audio)
    audio = np.asarray(audio).T
    records = []

    p = launch()
    try:
        ready, body = reply(p)
        assert ready[2] == 1
        ready_info = json.loads(body)
        assert ready_info['sources'] == ['vocals', 'drums', 'bass', 'other']
        assert ready_info['window_frames'] == RATE
        for job, start in enumerate(scenarios['worker_positive_starts'], 1):
            frames = int(scenarios['worker_seconds'] * rate)
            assert frames == RATE, f'Worker E2E window must be {RATE} frames, got {frames}'
            samples = np.ascontiguousarray(
                audio[start * rate:start * rate + frames], dtype='<f4')
            assert samples.nbytes == RATE * 2 * 4
            began = time.monotonic()
            request = packet(2, job=job, start=start * rate, frames=frames, body=samples.tobytes())
            count = p.stdin.write(request)
            assert count == len(request), f'Short packet write {count}/{len(request)}'
            p.stdin.flush()
            print(f'Worker packet {job} at {start}s sent in {time.monotonic()-began:.3f}s', flush=True)
            header, body = reply(p, 5)
            elapsed = time.monotonic() - began
            assert header[2:6] == (3, 1, job, start * rate)
            assert header[6:10] == (RATE, frames, 2, 4)
            stems = np.frombuffer(body, dtype='<f4').reshape(frames, 8)
            assert np.isfinite(stems).all() and len(body) == frames * 8 * 4
            records.append({'case': f'positive_{start}s', 'wall_seconds': elapsed, 'finite': True})
        p.stdin.write(packet(5))
        p.stdin.close()
        assert p.wait(timeout=5) == 0
    finally:
        if p.poll() is None:
            p.terminate()
            p.wait(timeout=5)

    p = launch(ROOT / 'work/nonexistent-stem-cache')
    try:
        header, body = reply(p)
        assert header[2] == 4 and b'cache' in body.lower()
        assert p.wait(timeout=5) != 0
        records.append({'case': 'missing_cache', 'pass': True})
    finally:
        if p.poll() is None:
            p.terminate()
            p.wait(timeout=5)

    for case in ['truncated_packet', 'bad_version', 'oversize_packet', 'nan_input', 'wrong_rate']:
        p = launch()
        try:
            assert reply(p)[0][2] == 1
            if case == 'truncated_packet':
                p.stdin.write(b'LSTM')
                p.stdin.close()
            elif case == 'bad_version':
                p.stdin.write(packet(2, version=2))
                p.stdin.flush()
            elif case == 'oversize_packet':
                p.stdin.write(HEADER.pack(
                    b'LSTM', 1, 2, 1, 1, 0, RATE, 1, 2, 1, 17 * 1024 * 1024))
                p.stdin.flush()
            else:
                frames = RATE
                samples = np.zeros((frames, 2), dtype='<f4')
                if case == 'nan_input':
                    samples[0, 0] = np.nan
                assert samples.nbytes == RATE * 2 * 4
                try:
                    p.stdin.write(packet(
                        2, frames=frames, rate=48000 if case == 'wrong_rate' else RATE,
                        body=samples.tobytes()))
                    p.stdin.flush()
                except BrokenPipeError:
                    # A rejected rate closes the pipe before its body is read.
                    assert case == 'wrong_rate'

            if case == 'truncated_packet':
                try:
                    header, _ = reply(p, 5)
                    assert header[2] == 4
                except (EOFError, TimeoutError):
                    pass
            else:
                header, body = reply(p, 5)
                assert header[2] == 4
                if case == 'nan_input':
                    assert b'Non-finite input' in body, 'NaN did not reach input validation'
                if case == 'wrong_rate':
                    assert b'Invalid audio shape or rate' in body
            assert p.wait(timeout=5) != 0
            records.append({'case': case, 'pass': True})
        finally:
            if p.poll() is None:
                p.terminate()
                p.wait(timeout=5)

    OUT.mkdir(parents=True, exist_ok=True)
    (OUT / 'worker.json').write_text(json.dumps({
        'status': 'pass', 'checks': records,
        'source_sha256': manifest['sha256'], 'rate': RATE,
    }, indent=2) + '\n')
    print('PASS worker', flush=True)


def native_stage(stage):
    OUT.mkdir(parents=True, exist_ok=True)
    subprocess.run([
        'swift', 'build', '--configuration', 'release', '--package-path', str(BASE),
        '--scratch-path', str(ROOT / 'work/live-stems-build')
    ], check=True)
    build_path = subprocess.check_output([
        'swift', 'build', '--configuration', 'release', '--package-path', str(BASE),
        '--scratch-path', str(ROOT / 'work/live-stems-build'), '--show-bin-path'
    ], text=True).strip()
    binary = Path(build_path) / 'LiveStems'
    if not binary.is_file():
        raise FileNotFoundError('Native product missing')
    subprocess.run([
        str(binary), '--e2e', stage, '--output', str(OUT)
    ], check=True)
    report = OUT / f'{stage}.json'
    if report.is_file():
        print(f'PASS {stage} · report {report}', flush=True)


def process_identity(pid, expected):
    output = subprocess.check_output(
        ['ps', '-p', str(pid), '-o', 'pid=,rss=,%cpu=,comm='], text=True).strip()
    fields = output.split(maxsplit=3)
    assert len(fields) == 4 and int(fields[0]) == pid, f'PID {pid} is not alive'
    assert expected in fields[3], f'PID identity mismatch: {fields[3]}'
    return {
        'pid': pid, 'rss_kib': int(fields[1]), 'cpu_percent': float(fields[2]),
        'command': fields[3],
    }


def gpu_utilization():
    """Whole-GPU Device Utilization % from IOKit; not per process. None if unavailable."""
    # ponytail: 5 s point samples miss sub-second peaks; powermetrics (needs root) sees peaks.
    output = subprocess.run(['ioreg', '-r', '-d', '1', '-c', 'IOAccelerator'],
                            capture_output=True, text=True).stdout
    match = re.search(r'"Device Utilization %"=(\d+)', output)
    return int(match.group(1)) if match else None


def load_summary(records):
    def stats(values):
        values = [value for value in values if value is not None]
        return {'mean': sum(values) / len(values), 'max': max(values)} if values else None
    return {
        'gpu_device_utilization_percent': stats(r['gpu_utilization_percent'] for r in records),
        'app_cpu_percent': stats(r['resources'][0]['cpu_percent'] for r in records),
        'worker_cpu_percent': stats(r['resources'][1]['cpu_percent'] for r in records),
    }


def sustained_stage(duration):
    """Observe the running native session; this does not replace listening."""
    records = []
    began = time.monotonic()
    last = None
    buffering_since = None
    ready_deadline = time.monotonic() + 180
    while time.monotonic() < ready_deadline:
        try:
            ready = json.loads(DIAGNOSTICS.read_text())
            fresh = time.monotonic() - ready['observedUptime'] < 5
            if ready['active'] and ready['handedOff'] and fresh:
                process_identity(ready['appPID'], 'LiveStems')
                process_identity(ready['workerPID'], 'python')
                break
        except (FileNotFoundError, json.JSONDecodeError, KeyError, AssertionError,
                subprocess.CalledProcessError):
            pass
        print(f'Waiting for live Spotify stems at {DIAGNOSTICS}', flush=True)
        time.sleep(5)
    else:
        raise TimeoutError(f'Spotify did not reach live playback within 180 seconds: {DIAGNOSTICS}')

    began = time.monotonic()
    report = None
    unexpected_underruns = []
    allowed_underruns = []
    stable_until = began + 1.5
    stable_samples = 0
    blended_samples = 0
    steady_frames = 0
    full_stem_frames = 0
    fallback_frames = 0
    try:
        while time.monotonic() - began < duration:
            state = json.loads(DIAGNOSTICS.read_text())
            assert state['active'], 'Live stems stopped'
            now = time.monotonic()
            assert now - state['observedUptime'] < 5, 'Native diagnostics stopped'
            if last is None:
                stable_until = max(stable_until, now + 1.5)
            else:
                if state.get('paused', False) or last.get('paused', False):
                    stable_until = max(stable_until, now + 1.5)
                if state.get('hardCuts', 0) != last.get('hardCuts', 0):
                    stable_until = max(stable_until, now + 1.5)
                if state.get('sessionGeneration') != last.get('sessionGeneration'):
                    stable_until = max(stable_until, now + 1.5)
                if state.get('handedOff', False) != last.get('handedOff', False):
                    stable_until = max(stable_until, now + 1.5)
            if state['handedOff']:
                buffering_since = None
            else:
                if buffering_since is None:
                    buffering_since = now
                assert now - buffering_since < 20, 'Output stayed in startup fallback for 20 seconds'

            assert state['historyFrames'] <= HISTORY_LIMIT_FRAMES, 'History bound exceeded'
            assert state['queuedFrames'] <= QUEUE_LIMIT_FRAMES, 'Output queue bound exceeded'
            assert state['cacheBytes'] <= CACHE_LIMIT_BYTES, 'Ready stem cache bound exceeded'
            assert state['cacheBytes'] <= state['cacheLimitBytes'], 'Configured cache limit exceeded'
            assert state['overflowCount'] == 0, 'Audio buffer overflow'
            assert state['windowFrames'] == RATE, 'Worker window shape changed'
            assert state['hopFrames'] == HOP, 'Worker hop changed'

            delay = float(state['estimatedDelaySeconds'])
            if not state.get('paused', False):
                assert abs(delay - FIXED_LAG_SECONDS) <= FIXED_LAG_TOLERANCE_SECONDS, \
                    f'Unexpected live lag {delay:.3f}s (expected {FIXED_LAG_SECONDS:.3f}s)'
            assert state['jumps'] == 0, 'Playback rewound to wait for stems'

            if (not state.get('paused', False) and now >= stable_until
                    and state.get('handedOff', False)):
                observed_age = state.get('observedCaptureToRenderSeconds')
                assert observed_age is not None and 0.2 <= observed_age <= 0.45, \
                    f'Observed capture-to-render age {observed_age} is outside 0.200–0.450s'
                stable_samples += 1
                if float(state.get('blendWeight', 0)) > 0.9:
                    blended_samples += 1

            if last:
                same_generation = state['sessionGeneration'] == last['sessionGeneration']
                if same_generation:
                    steady_frames += max(0, state['steadyFrames'] - last['steadyFrames'])
                    full_stem_frames += max(0, state['steadyFullStemFrames'] - last['steadyFullStemFrames'])
                    fallback_frames += max(0, state['steadyFallbackFrames'] - last['steadyFallbackFrames'])
                if same_generation:
                    if state.get('paused') and last.get('paused'):
                        assert state['captureFrames'] == last['captureFrames'], \
                            'Capture clock advanced while paused'
                    elif not state.get('paused'):
                        assert state['captureFrames'] > last['captureFrames'], \
                            'Audio capture clock stopped'
                        assert state['playedFrames'] > last['playedFrames'], \
                            'Audio output clock stopped'

                underrun_delta = max(0, state['underrunFrames'] - last['underrunFrames'])
                if underrun_delta:
                    allowed = bool(
                        state.get('paused') or last.get('paused')
                        or not same_generation
                        or state['hardCuts'] != last['hardCuts']
                    )
                    item = {
                        'elapsed': now - began, 'delta': underrun_delta,
                        'total': state['underrunFrames'], 'allowed': allowed,
                        'paused': state.get('paused', False),
                        'blend_weight': state.get('blendWeight', 0),
                    }
                    (allowed_underruns if allowed else unexpected_underruns).append(item)
                    if not allowed:
                        raise AssertionError(f'Unexpected continuous underrun: {item}')

            resources = [
                process_identity(state['appPID'], '/Contents/MacOS/LiveStems'),
                process_identity(state['workerPID'], '/python'),
            ]
            for role, values in zip(('app', 'worker'), resources):
                for metric, limit in RESOURCE_LIMITS[role].items():
                    assert values[metric] <= limit, \
                        f'{role} {metric} {values[metric]} exceeds sampled limit {limit}'
            records.append({
                'elapsed': now - began, 'state': state, 'resources': resources,
                'gpu_utilization_percent': gpu_utilization(),
            })
            last = state
            print(f'Live capture {round(now - began)} / {duration}s', flush=True)
            time.sleep(5)

        timings = [float(value) for value in (last['inferenceSeconds'] if last else [])
                   if np.isfinite(float(value))]
        timing_gate = len(timings) >= 10
        assert timing_gate, 'Insufficient actual worker timing samples (<10 jobs)'
        p95 = None
        maximum = None
        if timing_gate:
            p95 = sorted(timings)[int((len(timings) - 1) * 0.95)]
            maximum = max(timings)
            assert p95 < PACKET_P95_SECONDS, \
                f'Live inference p95 {p95:.3f}s exceeds {PACKET_P95_SECONDS:.3f}s'
            assert maximum < PACKET_MAX_SECONDS, \
                f'Live inference max {maximum:.3f}s exceeds {PACKET_MAX_SECONDS:.3f}s'
        assert steady_frames >= RATE, 'Insufficient steady audio frames'
        frame_coverage = full_stem_frames / steady_frames
        assert frame_coverage >= 0.995, f'Actual full-stem frame coverage {frame_coverage:.5f} is below 0.995'
        required_stable_samples = max(3, min(20, int(duration / 5 * 0.70)))
        assert stable_samples >= required_stable_samples, \
            f'Only {stable_samples} stable blend samples; need {required_stable_samples}'
        coverage = blended_samples / stable_samples
        assert coverage >= 0.9, \
            f'Stable live-stem blend coverage {coverage:.3f} is below 0.900'
        report = {
            'status': 'pass', 'duration_seconds': time.monotonic() - began,
            'diagnostics_path': str(DIAGNOSTICS), 'inference_count': len(timings),
            'inference_p95': p95, 'inference_max': maximum,
            'packet_p95_limit_seconds': PACKET_P95_SECONDS,
            'packet_max_limit_seconds': PACKET_MAX_SECONDS,
            'timing_gate': 'pass' if timing_gate else 'pending (<10 jobs)',
            'fixed_lag_seconds': FIXED_LAG_SECONDS,
            'fixed_lag_tolerance_seconds': FIXED_LAG_TOLERANCE_SECONDS,
            'steady_audio_frames': steady_frames,
            'full_stem_frames': full_stem_frames,
            'steady_fallback_frames': fallback_frames,
            'actual_frame_coverage': (full_stem_frames / steady_frames if steady_frames else None),
            'stable_blend_samples': stable_samples,
            'blended_samples': blended_samples,
            'stable_blend_coverage': coverage,
            'stable_blend_gate_samples': required_stable_samples,
            'unexpected_underruns': unexpected_underruns,
            'allowed_underruns': allowed_underruns,
            'samples': records,
            'audibility': 'requires human listening',
            'source_isolation': 'requires a separate non-Spotify sound check',
            'sampled_resource_limits': RESOURCE_LIMITS,
            'load': load_summary(records),
            'load_note': 'GPU: system-wide 5 s point samples. CPU: ps per process, 100 = one core.',
        }
    except Exception as error:
        report = {
            'status': 'fail', 'reason': str(error),
            'duration_seconds': time.monotonic() - began,
            'diagnostics_path': str(DIAGNOSTICS),
            'fixed_lag_seconds': FIXED_LAG_SECONDS,
            'fixed_lag_tolerance_seconds': FIXED_LAG_TOLERANCE_SECONDS,
            'steady_audio_frames': steady_frames,
            'full_stem_frames': full_stem_frames,
            'steady_fallback_frames': fallback_frames,
            'actual_frame_coverage': (full_stem_frames / steady_frames if steady_frames else None),
            'stable_blend_samples': stable_samples,
            'blended_samples': blended_samples,
            'stable_blend_coverage': (blended_samples / stable_samples
                                       if stable_samples else None),
            'unexpected_underruns': unexpected_underruns,
            'allowed_underruns': allowed_underruns,
            'load': load_summary(records),
            'samples': records,
        }
        raise
    finally:
        OUT.mkdir(parents=True, exist_ok=True)
        (OUT / 'sustained.json').write_text(json.dumps(report, indent=2) + '\n')


def main():
    global OUT
    parser = argparse.ArgumentParser()
    parser.add_argument('--stage', choices=['worker', 'stream', 'recovery', 'sustained'], required=True)
    parser.add_argument('--duration', type=int, default=900)
    parser.add_argument('--output', type=Path, default=OUT)
    args = parser.parse_args()
    OUT = args.output.resolve()
    if args.stage == 'worker':
        worker_stage()
    elif args.stage == 'sustained':
        sustained_stage(args.duration)
    else:
        native_stage(args.stage)


if __name__ == '__main__':
    main()
