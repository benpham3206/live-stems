"""Self-check for script/models.py using synthetic data only.

Run: <python> -I script/test_models.py
Checks: exact round trip, damaged download is rejected and deleted, non-exact weights refused.
"""
import hashlib
import importlib.util
import json
import struct
import tempfile
from pathlib import Path

import numpy as np

HERE = Path(__file__).resolve().parent
_spec = importlib.util.spec_from_file_location('models', HERE / 'models.py')
models = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(models)

NAME = 'tiny'
EXACT_BODY = np.arange(16, dtype=np.float16).astype('<f4').tobytes()


def make_safetensors(body):
    header = json.dumps({'w': {'dtype': 'F32', 'shape': [16], 'data_offsets': [0, 64]}}).encode()
    return struct.pack('<Q', len(header)) + header + body


def pack_into(cache, out):
    out.mkdir(parents=True, exist_ok=True)  # the CLI creates <out-dir> before calling pack
    models.pack(cache, out, NAME)


def write_cache(cache, body):
    cache.mkdir(parents=True, exist_ok=True)
    raw = make_safetensors(body)
    (cache / f'{NAME}.safetensors').write_bytes(raw)
    digest = hashlib.sha256(raw).hexdigest()
    (cache / f'{NAME}_config.json').write_text(json.dumps({'safetensors_sha256': digest}))
    return raw


def copy_packed(out, fresh, flip_last_byte=False):
    fresh.mkdir(parents=True, exist_ok=True)
    data = bytearray((out / f'{NAME}.f16').read_bytes())
    if flip_last_byte:
        data[-1] ^= 0xFF  # last byte belongs to the float16 body
    (fresh / f'{NAME}.f16').write_bytes(bytes(data))
    (fresh / f'{NAME}_config.json').write_bytes((out / f'{NAME}_config.json').read_bytes())


def check_round_trip(tmp):
    cache, out, fresh = tmp / 'cache', tmp / 'out', tmp / 'fresh'
    raw = write_cache(cache, EXACT_BODY)
    pack_into(cache, out)
    copy_packed(out, fresh)
    models.unpack(fresh, NAME)
    rebuilt = (fresh / f'{NAME}.safetensors').read_bytes()
    assert rebuilt == raw, 'round trip changed the safetensors bytes'
    assert not (fresh / f'{NAME}.f16').exists(), 'packed file was not removed after unpack'


def check_corruption(tmp):
    cache, out, fresh = tmp / 'cache', tmp / 'out', tmp / 'fresh'
    write_cache(cache, EXACT_BODY)
    pack_into(cache, out)
    copy_packed(out, fresh, flip_last_byte=True)
    try:
        models.unpack(fresh, NAME)
    except SystemExit:
        pass
    else:
        raise AssertionError('unpack accepted a damaged download')
    assert not (fresh / f'{NAME}.f16').exists(), 'damaged .f16 was not deleted'
    assert not list(fresh.glob('*.safetensors')), 'a .safetensors was written from a damaged download'


def check_non_exact(tmp):
    cache, out = tmp / 'cache', tmp / 'out'
    write_cache(cache, np.full(16, 0.1, dtype='<f4').tobytes())
    try:
        models.pack(cache, out, NAME)
    except SystemExit:
        return
    raise AssertionError('pack accepted weights that are not exact float16 values')


if __name__ == '__main__':
    with tempfile.TemporaryDirectory() as d:
        root = Path(d)
        check_round_trip(root / 'round_trip')
        check_corruption(root / 'corruption')
        check_non_exact(root / 'non_exact')
    print('PASS models')
