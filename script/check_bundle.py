"""Check packaged worker startup and inference without audio capture or app launch."""
import json,math,struct,subprocess,sys
from pathlib import Path
resources=Path(sys.argv[1])/'Contents/Resources'
h=struct.Struct('<4sHHQQQIIHHI')
source=[0.03*math.sin(2*math.pi*440*i/44100) for i in range(44100)]
body=struct.pack('<88200f',*(v for x in source for v in (x,x*0.8)))
request=h.pack(b'LSTM',1,2,1,1,0,44100,44100,2,1,len(body))+body+h.pack(b'LSTM',1,5,0,0,0,44100,0,2,0,0)
results={}
models=['htdemucs','htdemucs_ft']
if (resources/'Models/htdemucs_6s_config.json').exists(): models.append('htdemucs_6s')
for model in models:
 count=6 if model=='htdemucs_6s' else 4
 command=[str(resources/'Runtime/bin/python3.12'),'-I','-B',str(resources/'worker/stem_worker.py'),'--cache',str(resources/'Models'),'--model',model]
 p=subprocess.run(command,input=request,capture_output=True,timeout=45)

 assert p.returncode==0,(p.returncode,p.stderr[-2000:])
 data=p.stdout; offset=0; packets=[]
 while offset<len(data):
  fields=h.unpack_from(data,offset); offset+=48
  block=data[offset:offset+fields[-1]];offset+=fields[-1]
  assert fields[0]==b'LSTM'
  if fields[2]==1: results[model]=json.loads(block)
  if fields[2]==3:
   samples=struct.unpack('<%df'%(len(block)//4),block)
   assert len(samples)==44100*2*count and all(math.isfinite(x) for x in samples) and max(map(abs,samples))>1e-5
  packets.append(fields[2])
 assert packets==[1,3],packets
 assert not list((resources/'Models').glob('*.verified.json'))
subprocess.run(['codesign','--verify','--deep','--strict',str(resources.parents[1])],check=True,timeout=60)
print(json.dumps(results,indent=2))
