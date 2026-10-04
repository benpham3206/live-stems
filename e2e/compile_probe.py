"""Compare an outer fixed graph with canonical warmed submodel compilation."""
import argparse
import json
from pathlib import Path
import time

import mlx.core as mx
import numpy as np
from demucs_mlx.apply_mlx import apply_model
from demucs_mlx.audio import load_audio
from demucs_mlx.mlx_convert import load_mlx_model_from_safetensors
from demucs_mlx.mlx_transformer import set_attention_dtype


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--root', type=Path, required=True)
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    args.output.mkdir(parents=True, exist_ok=True)
    source, _ = load_audio(args.root / 'work/dreamflasher-original.wav', sr=44100)
    mx.eval(source)
    source = np.asarray(source)
    model = load_mlx_model_from_safetensors('htdemucs_ft', cache_dir=str(args.root / 'work/model-cache'))
    assert len(model.models) == 4
    for item in model.models:
        item.eval(); item.use_train_segment = False
        set_attention_dtype(item, mx.float32); mx.eval(item.parameters())
    mx.set_cache_limit(1024 * 1024 * 1024)

    def separate(mixture):
        reference = mx.mean(mixture, axis=0)
        mean = mx.mean(reference)
        std = mx.std(reference, ddof=1) + 1e-8
        return apply_model(model, ((mixture - mean) / std)[None],
                           shifts=0, split=False, batch_size=1) * std + mean

    warm = mx.array(source[:, :44100])
    for _ in range(3):
        mx.eval(separate(warm))
    compiled = mx.compile(separate)
    began = time.monotonic()
    for _ in range(2):
        mx.eval(compiled(warm))
    startup = time.monotonic() - began
    errors = []
    for seconds in [0, 30, 90, 120, 180, None]:
        data = mx.zeros((2, 44100)) if seconds is None else mx.array(source[:, seconds * 44100:(seconds + 1) * 44100])
        direct = separate(data); candidate = compiled(data)
        mx.eval(direct, candidate)
        a, b = np.asarray(direct), np.asarray(candidate)
        assert np.isfinite(a).all() and np.isfinite(b).all()
        error = float(np.max(np.abs(a - b)))
        errors.append({'source_seconds': seconds, 'max_absolute_error': error})
        assert error < 1e-5, f'Graph changed estimates: {error}'
    timings = {'canonical': [], 'outer_graph': []}
    for index in range(240):
        method = 'canonical' if index % 2 == 0 else 'outer_graph'
        start = (30 + index % 120) * 44100
        data = mx.array(source[:, start:start + 44100])
        began = time.monotonic()
        result = separate(data) if method == 'canonical' else compiled(data)
        mx.eval(result)
        elapsed = time.monotonic() - began
        timings[method].append(elapsed)
        time.sleep(max(0, 0.1 - elapsed))
        if index % 40 == 0:
            print(f'Compile probe {index}/240', flush=True)
    summary = {}
    for method, values in timings.items():
        ordered = sorted(values)
        summary[method] = {'p50_seconds': ordered[len(ordered) // 2],
                           'p95_seconds': ordered[int((len(ordered) - 1) * .95)],
                           'max_seconds': max(values)}
    report = {'status': 'pass', 'all_four_models': True, 'fp32_attention': True,
              'cache_limit_bytes': 1024 * 1024 * 1024, 'compile_startup_seconds': startup,
              'sample_comparisons': errors, 'timings_seconds': timings,
              'summary': summary, 'gpu_peak_bytes': mx.get_peak_memory(),
              'gpu_active_bytes': mx.get_active_memory(), 'gpu_cache_bytes': mx.get_cache_memory()}
    (args.output / 'compile.json').write_text(json.dumps(report, indent=2) + '\n')
    print(json.dumps(summary, indent=2), flush=True)


if __name__ == '__main__':
    main()
