"""Half-size model files for a fast install with no PyTorch.

Every weight in the converted Demucs caches is an exact float16 value stored as
float32, so the body halves losslessly. A .f16 file is the original
safetensors header, unchanged, followed by the body as float16. Unpacking gives
back the identical file; the sha256 in <name>_config.json proves it.

  pack:   python models.py pack <model-cache> <out-dir> htdemucs htdemucs_ft
  unpack: python models.py unpack <model-cache> htdemucs     (needs <name>.f16 and <name>_config.json there)
"""
import hashlib
import json
import struct
import sys
from pathlib import Path

import numpy as np


def split(raw):
    size = struct.unpack('<Q', raw[:8])[0]
    header = json.loads(raw[8:8 + size])
    if any(v['dtype'] != 'F32' for k, v in header.items() if k != '__metadata__'):
        raise SystemExit('Only float32 caches can be packed')
    return raw[:8 + size], raw[8 + size:]


def pack(cache, out, name):
    head, body = split((cache / f'{name}.safetensors').read_bytes())
    weights = np.frombuffer(body, '<f4')
    half = weights.astype('<f2')
    if not np.array_equal(half.astype('<f4'), weights):
        raise SystemExit(f'{name} has weights that are not exact float16 values')
    (out / f'{name}.f16').write_bytes(head + half.tobytes())
    (out / f'{name}_config.json').write_bytes((cache / f'{name}_config.json').read_bytes())


def unpack(cache, name):
    packed = cache / f'{name}.f16'
    head, body = split(packed.read_bytes())
    data = head + np.frombuffer(body, '<f2').astype('<f4').tobytes()
    expected = json.loads((cache / f'{name}_config.json').read_text())['safetensors_sha256']
    if hashlib.sha256(data).hexdigest() != expected:
        packed.unlink()  # corrupt download: the next install run fetches it again
        raise SystemExit(f'{name}: the download is damaged. Run the installer again.')
    target = cache / f'{name}.safetensors'
    target.with_suffix('.tmp').write_bytes(data)
    target.with_suffix('.tmp').rename(target)
    packed.unlink()


if __name__ == '__main__':
    command, cache, *rest = sys.argv[1:]
    if command == 'pack':
        out = Path(rest[0])
        out.mkdir(parents=True, exist_ok=True)
        for name in rest[1:]: pack(Path(cache), out, name)
    elif command == 'unpack':
        for name in rest: unpack(Path(cache), name)
    else:
        raise SystemExit(__doc__)
