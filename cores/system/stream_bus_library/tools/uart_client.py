"""Runs on board USB host. Stores complete wire responses; no golden outputs."""
import argparse
import json
import time
from pathlib import Path
import serial
from codec import request,decode,status_fields,metric_fields

def main():
    ap=argparse.ArgumentParser(); ap.add_argument('--cases',required=True,type=Path)
    ap.add_argument('--output',required=True,type=Path); ap.add_argument('--port',default='/dev/ttyUSB1'); a=ap.parse_args()
    config=json.loads(a.cases.read_text()); report={'status':'IN_PROGRESS','profile':config['profile'],'runs':[]}
    s=serial.Serial(a.port,115200,timeout=2,write_timeout=2)
    s.reset_input_buffer()
    def transaction(cmd,address=0,payload=0,bad=False,status=0):
        packet=bytearray(request(cmd,address,payload))
        if bad: packet[-1]^=1
        s.write(packet); s.flush()
        response=s.read(31)
        return decode(response,cmd,address,status),response.hex()
    try:
        identity,_=transaction(0)
        assert (identity>>8)&255==config['profile'] and (identity>>32)&0xffffffff==0x53595032
        transaction(0,bad=True,status=1); transaction(99,status=3); transaction(1,256,status=2)
        for case in config['cases']:
            n=len(case['rows']); m=case['outputs']
            for i,a0 in enumerate(case['rows']): transaction(1,i,int(a0,16))
            transaction(2,n,case['core']|(case['stall']<<8)|(m<<16))
            deadline=time.monotonic()+5
            while True:
                raw,_=transaction(3); status=status_fields(raw)
                if status['done']: break
                assert time.monotonic()<deadline,'board run did not terminate'
            assert not status['error'] and not status['active'] and status['issued']==n and status['captured']==m,status
            responses=[transaction(4,i) for i in range(m)]
            metric0,_=transaction(5,0); metric1,_=transaction(5,1)
            metrics=metric_fields(metric0,metric1)
            assert metrics['inputs']==n and metrics['outputs']==m
            item=dict(name=case['name'],core=case['core'],seed=case['seed'],stall=case['stall'],
                inputs=case['rows'],raw=[f'{r:048x}' for r,_ in responses],wire=[w for _,w in responses],
                status=status,metrics=metrics)
            report['runs'].append(item)
            a.output.write_text(json.dumps(report,indent=2)+'\n')
            print(f'CAPTURE {case["name"]} seed={case["seed"]} stall={case["stall"]} inputs={n} outputs={m} cycles={status["cycles"]}',flush=True)
        transaction(2,257,1<<16)
        status=status_fields(transaction(3)[0]); assert status['done'] and status['error'] and not status['active']
        report['status']='CAPTURED'
    except Exception as e: report['status']='FAIL'; report['reason']=str(e); raise
    finally:
        s.close(); a.output.write_text(json.dumps(report,indent=2)+'\n')

if __name__=='__main__': main()
