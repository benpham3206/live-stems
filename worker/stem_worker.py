"""Persistent local four-stem worker. Stdout contains only framed audio packets."""
import argparse
import json
from pathlib import Path
import struct
import sys
import os
import threading
import time
import logging
from logging.handlers import RotatingFileHandler

HEADER=struct.Struct('<4sHHQQQIIHHI')
SOURCES=['vocals','drums','bass','other']


def send(kind,body=b'',identity=(0,0,0),frames=0,stems=0):
    sys.stdout.buffer.write(HEADER.pack(b'LSTM',1,kind,*identity,44100,frames,2,stems,len(body))+body)
    sys.stdout.buffer.flush()


def exact(count):
    parts=bytearray()
    while len(parts)<count:
        data=sys.stdin.buffer.read(count-len(parts))
        if not data:raise EOFError('Truncated packet')
        parts.extend(data)
    return bytes(parts)


def main():
    parent=os.getppid()
    def parent_watch():
        while True:
            time.sleep(.25)
            if os.getppid()!=parent:os._exit(0)
    threading.Thread(target=parent_watch,daemon=True).start()
    parser=argparse.ArgumentParser()
    parser.add_argument('--cache',type=Path,required=True)
    parser.add_argument('--trace-dir',type=Path)
    args=parser.parse_args()
    trace=logging.getLogger('stems.worker.timing')
    trace.setLevel(logging.INFO)
    if args.trace_dir:
        args.trace_dir.mkdir(parents=True,exist_ok=True)
        trace.addHandler(RotatingFileHandler(args.trace_dir/'worker-timing.jsonl',
                                            maxBytes=2*1024*1024,backupCount=1))
    for suffix in ['.safetensors','_config.json']:
        if not (args.cache/('htdemucs_ft'+suffix)).is_file():raise FileNotFoundError('Missing local model cache')
    import mlx.core as mx
    import numpy as np
    from demucs_mlx.mlx_convert import load_mlx_model_from_safetensors
    from demucs_mlx.mlx_transformer import set_attention_dtype
    from demucs_mlx.apply_mlx import apply_model
    model=load_mlx_model_from_safetensors('htdemucs_ft',cache_dir=str(args.cache))
    if set(model.sources)!=set(SOURCES) or model.samplerate!=44100:raise ValueError('Unexpected model format')
    for item in model.models:
        item.eval();item.use_train_segment=False
        set_attention_dtype(item,mx.float32);mx.eval(item.parameters())
    # Keep the repeatedly used fixed-shape scratch allocations. A 128 MiB
    # cache churns allocations against roughly 800 MiB of persistent weights.
    # This cache stays bounded; live RSS and job deadlines are acceptance gates.
    mx.set_cache_limit(1024*1024*1024)
    def separate(samples):
        started=time.monotonic()
        mixture=mx.array(samples.T)
        reference=mx.mean(mixture,axis=0);mean=mx.mean(reference);std=mx.std(reference,ddof=1)+1e-8
        output=apply_model(model,((mixture-mean)/std)[None],shifts=0,split=False,batch_size=1)*std+mean
        mx.eval(output)
        evaluated=time.monotonic()
        data=np.asarray(output[0])[[model.sources.index(name) for name in SOURCES]].transpose(2,0,1).reshape(44100,8)
        if not np.isfinite(data).all():raise ValueError('Non-finite estimates')
        data=np.ascontiguousarray(data,dtype='<f4')
        return data,{'compute_seconds':evaluated-started,
                     'copy_seconds':time.monotonic()-evaluated,
                     'gpu_active_bytes':mx.get_active_memory(),
                     'gpu_cache_bytes':mx.get_cache_memory(),
                     'gpu_peak_bytes':mx.get_peak_memory()}
    # Eager forward, compile trace, then a warm call all finish before Ready.
    # Production requests use exactly this shape, including after a skip.
    warm=np.sin(np.arange(44100,dtype=np.float32)*.017)
    warm=np.stack([warm,warm*.8],axis=1)
    began=time.monotonic()
    for _ in range(3):separate(warm)
    send(1,json.dumps({'sources':SOURCES,'samplerate':44100,'window_frames':44100,
                       'warmup_seconds':time.monotonic()-began}).encode())
    while True:
        h=HEADER.unpack(exact(48))
        magic,version,kind,generation,job,start,rate,frames,channels,stems,size=h
        if magic!=b'LSTM' or version!=1 or kind not in [2,5] or size>16*1024*1024:raise ValueError('Invalid packet header')
        if kind==5:
            if size!=0:raise ValueError('Invalid shutdown')
            return
        if rate!=44100 or channels!=2 or stems!=1 or frames!=44100 or size!=frames*2*4:raise ValueError('Invalid audio shape or rate')
        samples=np.frombuffer(exact(size),dtype='<f4').reshape(frames,2)
        if not np.isfinite(samples).all():raise ValueError('Non-finite input')
        data,metrics=separate(samples)
        sent=time.monotonic()
        send(3,data.tobytes(),(generation,job,start),frames,4)
        if args.trace_dir:
            trace.info(json.dumps(dict(metrics,event='job',uptime=time.monotonic(),
                                      pid=os.getpid(),
                                      generation=generation,job=job,window_start=start,
                                      send_seconds=time.monotonic()-sent)))
        del data,samples


if __name__=='__main__':
    try:main()
    except Exception as error:
        send(4,json.dumps({'error':str(error)}).encode());print(str(error),file=sys.stderr);sys.exit(1)
