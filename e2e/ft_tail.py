"""Isolated fine-tuned tail benchmark; never changes the installed worker."""
import argparse
import hashlib
import json
import time
from pathlib import Path

import mlx.core as mx
import numpy as np
import soundfile as sf
from demucs_mlx.apply_mlx import apply_model
from demucs_mlx.audio import load_audio
from demucs_mlx.mlx_convert import load_mlx_model_from_safetensors
from demucs_mlx.mlx_transformer import set_attention_dtype

ROOT = Path(__file__).resolve().parents[3]
RATE = 44100
NAMES = ['vocals', 'drums', 'bass', 'other']
PASSAGES = [60, 100, 180]


def score(actual, reference):
    error = np.sum((actual.astype(np.float64) - reference) ** 2)
    energy = np.sum(reference.astype(np.float64) ** 2)
    return float(10 * np.log10(max(energy, 1e-20) / max(error, 1e-20)))


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--continuous', action='store_true')
    args = parser.parse_args()
    args.output.mkdir(parents=True, exist_ok=True)
    path = ROOT / 'work/dreamflasher-original.wav'
    audio, rate = load_audio(path, sr=RATE)
    mx.eval(audio)
    audio = np.asarray(audio)
    model = load_mlx_model_from_safetensors('htdemucs_ft', cache_dir=str(ROOT / 'work/model-cache'))
    for item in model.models:
        item.eval()
        set_attention_dtype(item, mx.float32)
        mx.eval(item.parameters())
    order = [model.sources.index(name) for name in NAMES]

    def infer(start, length, shifts, split):
        began = time.perf_counter()
        mixture = mx.array(audio[:, start:start + length])
        mono = mx.mean(mixture, axis=0)
        mean, std = mx.mean(mono), mx.std(mono, ddof=1) + 1e-8
        result = apply_model(model, ((mixture - mean) / std)[None],
                             shifts=shifts, seed=0, split=split, overlap=.25, batch_size=1) * std + mean
        mx.eval(result)
        result = np.asarray(result[0])[order]
        elapsed = time.perf_counter() - began
        assert result.shape == (4, 2, length) and np.isfinite(result).all()
        return result, elapsed

    references = {}
    for point in PASSAGES:
        # Centered context is for the offline comparison only. Tail candidates
        # below stop exactly at point and never see these future samples.
        start = int((point - 3.9) * RATE)
        result, seconds = infer(start, int(7.8 * RATE), 1, True)
        references[point] = result[:, :, int(3.8 * RATE):int(3.9 * RATE)]
        print(f'reference {point}s {seconds:.3f}s', flush=True)

    if args.continuous:
        render_continuous(model, audio, infer, order, args.output)
        return

    candidates = [
        ('production_tail', 7.8, 1, True, True),
        ('single_pass_tail', 7.8, 0, False, True),
        ('two_second_tail', 2., 0, False, False),
        ('one_second_tail', 1., 0, False, False),
        ('half_second_tail', .5, 0, False, False),
    ]
    records = []
    for name, window, shifts, split, train_pad in candidates:
        for item in model.models:
            item.use_train_segment = train_pad
        times, comparisons, cold = [], [], None
        saved = {stem: [] for stem in NAMES}
        for point in PASSAGES:
            length, end = int(window * RATE), point * RATE
            for repeat in range(5):
                result, elapsed = infer(end - length, length, shifts, split)
                if repeat == 0:
                    cold = max(cold or 0, elapsed)
                else:
                    times.append(elapsed)
            tail = result[:, :, -4410:]
            comparisons.append({'point': point, 'difference_snr_db': {
                stem: score(tail[i], references[point][i]) for i, stem in enumerate(NAMES)}})
            for i, stem in enumerate(NAMES):
                # Repeat 100 ms comparison snippets only for inspection. These
                # WAVs are not a streamed product or proof of seam quality.
                saved[stem].append(tail[i].T)
        for stem, chunks in saved.items():
            sf.write(args.output / f'{name}-{stem}-tail.wav', np.concatenate(chunks), RATE, subtype='FLOAT')
        record = {'candidate': name, 'window_seconds': window, 'shifts': shifts,
                  'split': split, 'train_padding': train_pad, 'attention': 'fp32',
                  'cold_max_seconds': cold, 'warm_seconds': times,
                  'warm_p50_seconds': float(np.median(times)),
                  'warm_p95_seconds': float(np.percentile(times, 95)),
                  'comparisons': comparisons}
        records.append(record)
        (args.output / 'benchmark.json').write_text(json.dumps({
            'source_sha256': hashlib.sha256(path.read_bytes()).hexdigest(),
            'model': 'htdemucs_ft', 'four_models': len(model.models),
            'reference': 'centered production inference, not ground truth',
            'candidates': records}, indent=2) + '\n')
        print(f'{name}: warm p50 {record["warm_p50_seconds"]:.3f}s '
              f'p95 {record["warm_p95_seconds"]:.3f}s', flush=True)
    for i, stem in enumerate(NAMES):
        sf.write(args.output / f'reference-{stem}-tail.wav',
                 np.concatenate([references[p][i].T for p in PASSAGES]), RATE, subtype='FLOAT')


def render_continuous(model, audio, infer, order, output):
    hop, duration = 4410, 4 * RATE
    reference = {}
    for point in PASSAGES:
        result, _ = infer(int((point - 1.95) * RATE), int(7.8 * RATE), 1, True)
        reference[point] = result[:, :, int(1.95 * RATE):int(1.95 * RATE) + duration]
        for i, stem in enumerate(NAMES):
            sf.write(output / f'{point}-reference-{stem}.wav', reference[point][i].T,
                     RATE, subtype='FLOAT')
        sf.write(output / f'{point}-original.wav', audio[:, point * RATE:point * RATE + duration].T,
                 RATE, subtype='FLOAT')
    records = []
    for name, window, guard, precision in [
        ('one_second', 1., 0., mx.float32),
        ('one_second_guard50', 1., .05, mx.float32),
        ('two_second_guard100', 2., .1, mx.float32),
        ('one_second_fp16_guard50', 1., .05, mx.float16),
    ]:
        # Attention dtype is captured by compiled forwards. Discard only the
        # isolated process's compilation entries before changing it.
        from demucs_mlx.apply_mlx import _COMPILED_FORWARDS
        _COMPILED_FORWARDS.clear()
        for item in model.models:
            item.use_train_segment = False
            set_attention_dtype(item, precision)
        length, guard_frames = int(window * RATE), int(guard * RATE)
        warmup = [infer(60 * RATE - length, length, 0, False)[1] for _ in range(3)]
        times, comparisons = [], []
        for point in PASSAGES:
            chunks = []
            for at in range(point * RATE, point * RATE + duration, hop):
                end = at + hop + guard_frames
                result, elapsed = infer(end - length, length, 0, False)
                times.append(elapsed)
                chunks.append(result[:, :, length - guard_frames - hop:length - guard_frames])
            rendered = np.concatenate(chunks, axis=2)
            assert rendered.shape == (4, 2, duration) and np.isfinite(rendered).all()
            metrics = {}
            for i, stem in enumerate(NAMES):
                sf.write(output / f'{point}-{name}-{stem}.wav', rendered[i].T, RATE, subtype='FLOAT')
                seam = np.abs(rendered[i, :, hop::hop] - rendered[i, :, hop - 1:-1:hop])
                original_seam = np.abs(reference[point][i, :, hop::hop]
                                       - reference[point][i, :, hop - 1:-1:hop])
                metrics[stem] = {'difference_snr_db': score(rendered[i], reference[point][i]),
                                 'max_seam_step': float(seam.max()),
                                 'reference_max_seam_step': float(original_seam.max())}
            comparisons.append({'point': point, 'stems': metrics})
        p95 = float(np.percentile(times, 95))
        record = {'candidate': name, 'model': 'htdemucs_ft', 'models': len(model.models),
                  'window_seconds': window, 'hop_seconds': .1, 'guard_seconds': guard,
                  'attention': str(precision), 'warmup_seconds': warmup, 'seconds': times,
                  'p50_seconds': float(np.median(times)), 'p95_seconds': p95,
                  'max_seconds': max(times), 'compute_fraction_of_hop': p95 / .1,
                  'scheduling_age_p95_seconds': .1 + guard + p95,
                  'within_100ms_target': .1 + guard + p95 <= .1,
                  'sustained_hop': max(times) < .1, 'comparisons': comparisons}
        records.append(record)
        (output / 'continuous.json').write_text(json.dumps({
            'status': 'experiment_only', 'no_product_changes': True,
            'reference_is_ground_truth': False, 'records': records}, indent=2) + '\n')
        print(f'{name}: p95 {p95 * 1000:.1f} ms; '
              f'scheduling age {record["scheduling_age_p95_seconds"] * 1000:.1f} ms', flush=True)


if __name__ == '__main__':
    main()
