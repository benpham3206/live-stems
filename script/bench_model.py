"""Time one 1 s separation per model option on this Mac's GPU.

Run from the workspace root (the folder with work/ and outputs/):
  work/stems-venv/bin/python outputs/live-stems-source/script/bench_model.py
The app needs p95 under 0.1 s (its hop) to keep stems live.
"""
import sys
import time
from pathlib import Path

import mlx.core as mx
import numpy as np
from demucs_mlx.apply_mlx import apply_model
from demucs_mlx.mlx_convert import load_mlx_model_from_safetensors
from demucs_mlx.mlx_transformer import set_attention_dtype

CACHE = Path(sys.argv[1] if len(sys.argv) > 1 else 'work/model-cache')
RUNS = 40


def load(name):
    model = load_mlx_model_from_safetensors(name, cache_dir=str(CACHE))
    for item in getattr(model, 'models', [model]):
        item.eval(); item.use_train_segment = False
        set_attention_dtype(item, mx.float32); mx.eval(item.parameters())
    return model


def timed(run):
    mix = mx.array(np.random.default_rng(0).standard_normal((2, 44100)).astype(np.float32))[None]
    for _ in range(3): mx.eval(run(mix))
    times = []
    for _ in range(RUNS):
        began = time.monotonic(); mx.eval(run(mix)); times.append(time.monotonic() - began)
    return np.percentile(times, 50), np.percentile(times, 95)


def report(label, run):
    p50, p95 = timed(run)
    verdict = 'fits' if p95 < 0.1 else 'too slow'
    print(f'{label:28s} p50 {p50*1000:6.1f} ms   p95 {p95*1000:6.1f} ms   {verdict}', flush=True)


ft = load('htdemucs_ft')
full = lambda mix: apply_model(ft, mix, shifts=0, split=False, batch_size=1)
three = lambda mix: [apply_model(ft, mix, shifts=0, split=False, batch_size=1, source_index=ft.sources.index(s))
                     for s in ('drums', 'bass', 'vocals')]
report('htdemucs_ft, 4 networks', full)
report('htdemucs_ft, 3 networks', three)
del ft
if (CACHE / 'htdemucs.safetensors').is_file():
    single = load('htdemucs')
    report('htdemucs, 1 network', lambda mix: apply_model(single, mix, shifts=0, split=False, batch_size=1))
print(f'peak GPU memory {mx.get_peak_memory()/2**30:.2f} GB')
