"""Persistent local four-stem worker. Stdout contains only framed audio packets."""
import argparse
import json
from pathlib import Path
import struct
import sys
import os
import select
import threading
import time
import logging
from logging.handlers import RotatingFileHandler

HEADER=struct.Struct('<4sHHQQQIIHHI')
SOURCES=['vocals','drums','bass','other']
# The app hop is 100 ms; GPU contention needs the rest of that budget, so 60 ms is the cut-off.
SLOW_SECONDS=0.060


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
    parser.add_argument('--model',choices=['auto','htdemucs_ft','htdemucs'],default='auto')
    args=parser.parse_args()
    trace=logging.getLogger('stems.worker.timing')
    trace.setLevel(logging.INFO)
    if args.trace_dir:
        args.trace_dir.mkdir(parents=True,exist_ok=True)
        trace.addHandler(RotatingFileHandler(args.trace_dir/'worker-timing.jsonl',
                                            maxBytes=2*1024*1024,backupCount=1))
    def has_model(name):
        return all((args.cache/(name+suffix)).is_file() for suffix in ['.safetensors','_config.json'])
    # Only require the files the choice can use. auto starts with htdemucs_ft and may fall back to htdemucs.
    # A light install has only htdemucs; auto then uses it.
    if args.model=='auto' and not has_model('htdemucs_ft') and has_model('htdemucs'):args.model='htdemucs'
    if not has_model('htdemucs' if args.model=='htdemucs' else 'htdemucs_ft'):raise FileNotFoundError('Missing local model cache')
    import mlx.core as mx
    import numpy as np
    from demucs_mlx.mlx_convert import load_mlx_model_from_safetensors
    from demucs_mlx.mlx_transformer import set_attention_dtype
    from demucs_mlx.apply_mlx import apply_model
    def load(name):
        model=load_mlx_model_from_safetensors(name,cache_dir=str(args.cache))
        if set(model.sources)!=set(SOURCES) or model.samplerate!=44100:raise ValueError('Unexpected model format')
        for item in getattr(model,'models',[model]):
            item.eval();item.use_train_segment=False
            set_attention_dtype(item,mx.float32);mx.eval(item.parameters())
        return model
    # Keep the repeatedly used fixed-shape scratch allocations. A 128 MiB
    # cache churns allocations against roughly 800 MiB of persistent weights;
    # 512 MiB measured no slower than 1 GiB and frees about 0.5 GB.
    mx.set_cache_limit(512*1024*1024)
    state={}
    def use(name):
        # Load first. Assigning the new model drops the old reference.
        state.update(name=name,single=name=='htdemucs',model=load(name))
    def separate(samples):
        started=time.monotonic()
        model=state['model']
        mixture=mx.array(samples.T)
        reference=mx.mean(mixture,axis=0);mean=mx.mean(reference);std=mx.std(reference,ddof=1)+1e-8
        normalized=((mixture-mean)/std)[None]
        if state['single']:
            estimates=apply_model(model,normalized,shifts=0,split=False,batch_size=1)[0]
            stems=mx.stack([estimates[model.sources.index(name)] for name in SOURCES])
        else:
            # One network per source. other is the remainder, so its network never runs.
            parts=[apply_model(model,normalized,shifts=0,split=False,batch_size=1,
                               source_index=model.sources.index(name))[0,0] for name in SOURCES[:3]]
            stems=mx.stack(parts+[normalized[0]-sum(parts)])
        output=stems*std+mean
        mx.eval(output)
        evaluated=time.monotonic()
        data=np.asarray(output).transpose(2,0,1).reshape(44100,8)
        if not np.isfinite(data).all():raise ValueError('Non-finite estimates')
        data=np.ascontiguousarray(data,dtype='<f4')
        return data,{'model':state['name'],
                     'compute_seconds':evaluated-started,
                     'copy_seconds':time.monotonic()-evaluated,
                     'gpu_active_bytes':mx.get_active_memory(),
                     'gpu_cache_bytes':mx.get_cache_memory(),
                     'gpu_peak_bytes':mx.get_peak_memory()}
    # Eager forward, compile trace, then a warm call all finish before Ready.
    # Production requests use exactly this shape, including after a skip.
    warm=np.sin(np.arange(44100,dtype=np.float32)*.017)
    warm=np.stack([warm,warm*.8],axis=1)
    use('htdemucs' if args.model=='htdemucs' else 'htdemucs_ft')
    began=time.monotonic()
    for _ in range(3):separate(warm)
    median=None
    if args.model=='auto':
        median=float(np.median([separate(warm)[1]['compute_seconds'] for _ in range(5)]))
        if median>SLOW_SECONDS and has_model('htdemucs'):
            use('htdemucs');mx.clear_cache()
            for _ in range(3):separate(warm)
    send(1,json.dumps({'sources':SOURCES,'samplerate':44100,'window_frames':44100,
                       'model':state['name'],'median_compute_seconds':median,
                       'warmup_seconds':time.monotonic()-began}).encode())
    idle_cleared=False
    while True:
        # The model sleeps on a neutral mix or a pause: no requests come. After
        # 2 s idle, return the scratch cache; the next job reallocates it.
        if not idle_cleared and not select.select([sys.stdin.buffer],[],[],2.0)[0]:
            mx.clear_cache();idle_cleared=True
            if args.trace_dir:trace.info(json.dumps({'event':'idle-clear','uptime':time.monotonic(),
                                                      'gpu_cache_bytes':mx.get_cache_memory()}))
        h=HEADER.unpack(exact(48));idle_cleared=False
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
