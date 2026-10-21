"""Software transport fixtures, explicitly not physical JTAG acceptance."""
from datetime import datetime,timezone
import hashlib
import json
from pathlib import Path
from scan_protocol import crc8
from scan_bus import ScanCsr

ROOT=next(p for p in Path(__file__).resolve().parents if (p/'cores').is_dir())


def response(tag=255,busy=False,valid=True,error=False,rejected=False,data=0x12345678):
    word=(0x5a<<56)|(tag<<48)|(int(rejected)<<43)|(int(error)<<42)|(int(valid)<<41)|(int(busy)<<40)|(data<<8)|1
    payload=word.to_bytes(8,'little');return payload+bytes([crc8(payload)])


class Backend:
    def __init__(self,mode='ok'):
        self.tag=255;self.command=None;self.polls=0;self.requests=0;self.mode=mode
    def __call__(self,frame):
        if any(frame):
            self.requests+=1;self.command=frame;self.polls=0
            return response(self.tag)  # old valid response must not complete request
        if self.command is None:return response(self.tag)
        self.polls+=1
        if self.mode=='reject':return response(self.tag,rejected=True)
        if self.mode=='bad_crc':return bytes(9)
        if self.polls<3 or self.mode=='timeout':return response(self.tag,busy=True)
        self.tag=self.command[6];self.command=None
        return response(self.tag,error=self.mode=='csr_error')


def rejects(kind,fn):
    try:fn()
    except kind:return
    raise AssertionError('expected '+kind.__name__)


def main():
    out=ROOT/'artifacts/ip_test_shell_25k'/datetime.now(timezone.utc).strftime('scan_bus_%Y%m%dT%H%M%S%fZ')
    out.mkdir(parents=True)
    sources=[Path(__file__).resolve()]+[Path(__file__).with_name(n) for n in ('scan_bus.py','scan_protocol.py')]
    report=dict(status='FAIL',physical_jtag_verified=False,sources={str(p.relative_to(ROOT)):hashlib.sha256(p.read_bytes()).hexdigest() for p in sources})
    try:
        backend=Backend();bus=ScanCsr(backend,max_polls=8)
        for _ in range(260):assert bus.access(8)==0x12345678
        assert backend.requests==260 and backend.tag==3
        assert bus.access(32,0xdeadbeef,strobe=3)==0x12345678
        commands=[bytes.fromhex(e['command']) for e in bus.exchanges if any(bytes.fromhex(e['command']))]
        last=int.from_bytes(commands[-1][:8],'little')
        assert (last>>47)&1 and (last>>43)&15==3 and (last>>35)&255==32 and (last>>3)&0xffffffff==0xdeadbeef
        for mode,error in [('timeout',TimeoutError),('reject',RuntimeError),('bad_crc',ValueError)]:
            backend=Backend(mode);bus=ScanCsr(backend,max_polls=4)
            rejects(error,lambda:bus.access(32,1));assert backend.requests==1 and bus.poisoned
            rejects(RuntimeError,lambda:bus.access(32,1));assert backend.requests==1
        backend=Backend('csr_error');bus=ScanCsr(backend)
        rejects(RuntimeError,lambda:bus.access(8));assert not bus.poisoned
        backend=Backend();bus=ScanCsr(backend)
        rejects(ValueError,lambda:bus.access(256));assert backend.requests==0
        rejects(ValueError,lambda:ScanCsr(backend,timeout=float('inf')))
        report.update(status='PASS',transactions=261,scope='software fixture only; hard user instruction binding remains open')
        print('PASS scan host: delayed/stale replies,tag wrap,packing,errors,bounded polling,no write retry')
    except Exception as exc:
        report['reason']=str(exc);raise
    finally:
        (out/'summary.json').write_text(json.dumps(report,indent=2)+'\n');print('Evidence='+str(out))


if __name__=='__main__':main()
