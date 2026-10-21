"""Host workflow against retained actual CSR RTL readbacks; no physical I/O."""
from datetime import datetime,timezone
import hashlib
import json
from pathlib import Path
import re
from cnn_host import ROOT,fixture,load_model,run_case
from run_uart import transport

BUILD_ID=0x2505abcd12345678


class FixtureBus:
    def __init__(self,model,images,readbacks,cycles):
        self.model=model;self.images=images;self.readbacks=readbacks;self.cycles=cycles
        self.run=-1;self.region=0;self.cursor=0;self.read_cursor=0;self.done=False
        self.loads=[0,0,0];self.acks=0;self.bad_count=False;self.never_done=False
        self.corrupt=False;self.fingerprint=BUILD_ID
    def access(self,a,data=None):
        if data is not None:
            if a==8:
                assert not self.done;self.region=data;self.cursor=0
            elif a==16:
                assert not self.done
                values=(self.images[self.run+1] if self.region==0 else
                        self.model['conv1']+self.model['conv2']+self.model['dense'] if self.region==1 else
                        self.model['bias1']+self.model['bias2']+self.model['bias3'])
                mask=0xffffffff if self.region==2 else 255
                assert data==values[self.cursor]&mask
                self.cursor+=1;self.loads[self.region]+=1
            elif a==20:
                if data==1:self.run+=1;self.done=True
                elif data==2:assert self.done;self.done=False;self.acks+=1
                else:raise ValueError('command')
            elif a==36:self.read_cursor=data
            else:raise ValueError('unexpected write')
            return 0
        if a==0:return 0x434e4e31
        if a==48:return self.fingerprint&0xffffffff
        if a==52:return self.fingerprint>>32
        if a==4:return 0 if self.done and self.never_done else 4 if self.done else 3
        if a==12:return self.cursor
        if a==32:return 0
        if a==28:return 10596 if self.bad_count else 10597
        if a==24:return self.cycles[self.run]
        if a==40:
            value=self.readbacks[self.run][self.read_cursor]&0xffffffff
            if self.corrupt and self.read_cursor==0:value^=1
            self.read_cursor=min(10596,self.read_cursor+1);return value
        raise ValueError('unexpected read')


class SerialFixture:
    def __init__(self,bus):self.bus=bus;self.reply=b''
    @staticmethod
    def crc(data):
        value=0
        for byte in data:
            value^=byte
            for _ in range(8):value=((value<<1)^(7 if value&128 else 0))&255
        return value
    def write(self,packet):
        assert packet[0]==0xa5 and self.crc(packet[:7])==packet[7]
        value=self.bus.access(packet[2],int.from_bytes(packet[3:7],'little') if packet[1] else None)
        body=bytes((0x5a,0,packet[2]))+value.to_bytes(4,'little');self.reply=body+bytes([self.crc(body)])
    def read(self,count):
        result=self.reply[:min(count,2)];self.reply=self.reply[len(result):];return result


def rejects(kind,fn):
    try:fn()
    except kind:return
    raise AssertionError('missing rejection '+kind.__name__)


def main():
    evidence=ROOT/'artifacts/cnn_infer_25k/control_20261020T190709765497Z'
    out=ROOT/'artifacts/cnn_infer_25k'/datetime.now(timezone.utc).strftime('host_%Y%m%dT%H%M%S%fZ');out.mkdir(parents=True)
    files=[Path(__file__).resolve()]+[Path(__file__).with_name(n) for n in ('cnn_host.py','run_uart.py','model.py')]+[ROOT/'cores/storage/buffer_dma/tools/run_uart.py',ROOT/'cores/storage/buffer_dma/tools/decode_metrics.py']
    report=dict(status='FAIL',physical_measurement=False,source_evidence=str(evidence.relative_to(ROOT)),sources={str(p.relative_to(ROOT)):hashlib.sha256(p.read_bytes()).hexdigest() for p in files})
    try:
        summary=json.loads((evidence/'summary.json').read_text())
        assert summary['status']=='PASS'
        for name,digest in summary['sources'].items():assert hashlib.sha256((ROOT/name).read_bytes()).hexdigest()==digest
        assert hashlib.sha256((evidence/'readback.txt').read_bytes()).hexdigest()==summary['readback_sha256']
        model,image_map=fixture(evidence/'fixture');images=list(image_map.values())
        readbacks=[[] for _ in range(3)]
        for line in (evidence/'readback.txt').read_text().splitlines():
            run,index,value=map(int,line.split());assert index==len(readbacks[run]);readbacks[run].append(value)
        cycles=[int(v) for n,v in re.findall(r'CSR_CNN_CYCLES run=(\d+) value=(\d+)',(evidence/'run.log').read_text())]
        def make():return FixtureBus(model,images,readbacks,cycles)
        underlying=make();bus=transport()(SerialFixture(underlying));load_model(bus,model,BUILD_ID)
        for image in images:
            states=[];capture=run_case(bus,model,image,BUILD_ID,lambda c:states.append(c['status']))
            assert capture['status']=='PASS' and states[-2:]==['CAPTURED','PASS']
        assert underlying.loads==[2352,4244,22] and underlying.acks==3
        bad=make();bad.fingerprint^=1
        rejects(ValueError,lambda:load_model(bad,model,BUILD_ID));assert bad.loads==[0,0,0]
        for attr,kind in [('corrupt',ValueError),('bad_count',ValueError),('never_done',TimeoutError)]:
            bad=make();setattr(bad,attr,True);load_model(bad,model,BUILD_ID)
            rejects(kind,lambda:run_case(bad,model,images[0],BUILD_ID,lambda c:None,max_polls=3))
            assert bad.acks==0  # retain failed/uncertain capture; no automatic retry
        report.update(status='PASS',network_runs=3,readback_words=31791,scope='software serial/CSR fixtures using RTL payloads; not physical UART/JTAG')
        print('PASS CNN host:load once/3runs,fragmented UART,alllayers,fingerprint,corruption,count,timeout')
    except Exception as exc:report['reason']=str(exc);raise
    finally:(out/'summary.json').write_text(json.dumps(report,indent=2)+'\n');print('Evidence='+str(out))


if __name__=='__main__':main()
