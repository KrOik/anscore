"""Host acceptance with CRC/count/version fixtures from actual serial RTL."""
from copy import deepcopy
from datetime import datetime,timezone
import hashlib,json,re,subprocess,sys
from pathlib import Path
from video_host import ROOT,profile,run_case,BankedBus
P=ROOT/'cores/image_processing/video_compositor';BUILD=0x123456789abcdef0
class Bus:
    def __init__(self,words):
        self.words=deepcopy(words);self.versions=[0]*3;self.started=0;self.acks=0;self.writes=[];self.identity=BUILD;self.never_done=False
    def access(self,a,v=None):
        if v is not None:
            self.writes.append((a,v))
            if a==16:self.acks+=1;self.started=0
            if a>=256:
                g=a//256-1;offset=a%256
                if offset==56:self.versions[g]+=1
                if offset==48:self.started|=1<<g
            return 0
        if a==0:return 0x56494431
        if a in (8,12):return (self.identity>>(32 if a==12 else 0))&0xffffffff
        if a==4:return 0 if self.never_done else self.started
        if a>=256:
            if a%256==44:return 1
            if a%256==52:return self.versions[a//256-1]
            if a%256==96:return self.words.get(a,1)
        return self.words[a]
def main():
    r=subprocess.run([sys.executable,str(P/'tools/test_uart.py')],cwd=ROOT,capture_output=True,text=True,timeout=120)
    if r.returncode:raise RuntimeError(r.stdout+r.stderr)
    fixture=Path(re.search(r'Evidence=(.+)',r.stdout)[1].strip())
    words={0xa0:0,0xa4:0,0xa8:0}
    for epoch,g,f,c,p,e,v in (map(int,x.split()[1:]) for x in (fixture/'run.log').read_text().splitlines() if x.startswith('SNAP ')):
        if epoch:continue
        # Numerical fields are actual UART RTL; timestamp/serial transport state
        # is synthetic here and separately checked by the CSR RTL testbench.
        for n,value in enumerate([f,c,p,e,v,1,123+g,0]):words[64+g*32+n*4]=value
    profiles=[profile(4+g,3,g+1,0x123456+g*0x10101) for g in range(3)]
    bus=Bus(words);saved=[];capture=run_case(bus,profiles,BUILD,lambda x:saved.append(deepcopy(x)))
    assert bus.acks==1 and saved[-2]['status']=='VERIFIED' and capture['status']=='ACKNOWLEDGED'
    negatives=0
    for address,value in [(0x40,1),(0x44,0),(0x48,1),(0x4c,1),(0x50,999),(0x54,0),(0x58,0),(0x160,2)]:
        bus=Bus(words);bus.words[address]=value
        try:run_case(bus,profiles,BUILD,lambda x:None)
        except ValueError:assert bus.acks==0;negatives+=1
        else:raise AssertionError('accepted corrupt word '+hex(address))
    bus=Bus(words);bus.identity=1
    try:run_case(bus,profiles,BUILD,lambda x:None)
    except ValueError:assert not bus.writes;negatives+=1
    else:raise AssertionError('wrong identity')
    bus=Bus(words);bus.never_done=True
    try:run_case(bus,profiles,BUILD,lambda x:None,max_polls=2)
    except TimeoutError:assert bus.acks==0;negatives+=1
    else:raise AssertionError('unbounded wait')
    class Window:
        def __init__(self):self.calls=[]
        def access(self,a,v=None):self.calls.append((a,v));return 17
    window=Window();assert BankedBus(window).access(0x234)==17
    assert window.calls==[(252,2),(52,None)]
    out=ROOT/'artifacts/video_compositor_25k'/datetime.now(timezone.utc).strftime('host_%Y%m%dT%H%M%S%fZ');out.mkdir(parents=True)
    (out/'capture.json').write_text(json.dumps(capture,indent=2)+'\n')
    report=dict(status='PASS',physical_measurement=False,rtl_fixture=str(fixture.relative_to(ROOT)),negative_cases=negatives,sources={str(p.relative_to(ROOT)):hashlib.sha256(p.read_bytes()).hexdigest() for p in [Path(__file__).resolve(),P/'tools/video_host.py']})
    (out/'summary.json').write_text(json.dumps(report,indent=2)+'\n')
    print('Evidence='+str(out));print(f'PASS host actual UART numerical fixture,{negatives} negative guards,no ACK on failure,bank mapping')
if __name__=='__main__':main()
