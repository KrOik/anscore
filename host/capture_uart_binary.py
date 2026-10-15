"""Read-only VCP capture; emit raw bytes and normalized verifier annotations."""
import argparse
import json
import time
from pathlib import Path
import serial

p=argparse.ArgumentParser(description=__doc__)
p.add_argument('--port',required=True)
p.add_argument('--seconds',type=float,default=2)
p.add_argument('--output',type=Path,required=True,help='Fresh basename, no suffix')
a=p.parse_args()
if a.seconds<=0:p.error('seconds must be positive')
paths=[a.output.with_suffix(s) for s in ('.bin','.txt','.capture.json')]
if any(x.exists() for x in paths):p.error('capture output already exists')
a.output.parent.mkdir(parents=True,exist_ok=True)
s=serial.Serial(port=None,baudrate=115200,timeout=0.1)
s.dtr=False;s.rts=False;s.port=a.port
s.open()
try:
    s.reset_input_buffer()
    started=time.time();deadline=time.monotonic()+a.seconds
    data=bytearray()
    while time.monotonic()<deadline:data.extend(s.read(max(1,s.in_waiting)))
finally:s.close()
paths[0].write_bytes(data)
paths[1].write_text('# Source: physical VCP UART, not logic-analyzer annotations\n'+''.join(f'uart-1: {b:02x}\n' for b in data))
metadata=dict(source='pyserial VCP',port=a.port,baud=115200,started_unix=started,
              duration_requested=a.seconds,bytes=len(data),dtr=False,rts=False)
paths[2].write_text(json.dumps(metadata,indent=2))
print(json.dumps(metadata))
if not data:raise SystemExit('No UART bytes captured')
