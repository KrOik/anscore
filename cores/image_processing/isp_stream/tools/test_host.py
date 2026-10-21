"""Hardware-free host acceptance tests using simulation-derived fixtures."""
from copy import deepcopy
from datetime import datetime,timezone
import hashlib
import json
from pathlib import Path
from types import SimpleNamespace
from isp_host import ROOT,UartCsr,crc8,config_words,golden_frame,capture_snapshot,decode,verify_run
from run_uart import execute


class FixtureBus:
    def __init__(self, words):
        self.words=list(words);self.version=words[20]-1;self.selector=259
        self.snapshot_id=0;self.captured=False;self.shadow={};self.lut={};self.commits=0

    def access(self,address,value=None):
        if value is not None:
            if address==0x1c:self.selector=value
            elif address==0x0c:self.snapshot_id+=1;self.captured=True
            elif address==0x10:self.lut[(value>>24,(value>>16)&255)]=value&255
            elif 0x20<=address<=0x5c:self.shadow[(address-0x20)//4]=value
            elif address==4:self.version+=1;self.words[20]=self.version;self.commits+=1
            else:raise ValueError('unexpected fixture write')
            return 0
        if address==8:return 0x49535031
        if address==0:return 1
        if address==4:return self.version
        if address==0x1c:return self.selector
        if address==0x0c:return int(self.captured)
        if address==0x18:return self.snapshot_id
        if address==0x10:return 123
        if address==0x14:return 2
        if address>=0xc0:return self.words[((self.selector>>8)&1)*16+(address-0xc0)//4]
        raise ValueError('unexpected fixture read')


class SerialFixture:
    def __init__(self, corrupt=False,error=False):
        self.reply=b'';self.corrupt=corrupt;self.error=error

    def write(self,command):
        assert len(command)==8 and command[0]==0xa5 and command[7]==crc8(command[:7])
        body=bytes((0x5a,int(self.error),command[2]))+bytes.fromhex('78563412')
        self.reply=body+bytes((crc8(body)^int(self.corrupt),))

    def read(self,count):
        # Exercise fragmented serial reads rather than assuming a full reply.
        data=self.reply[:min(2,count)];self.reply=self.reply[len(data):];return data


def must_reject(fn):
    try:fn()
    except (ValueError,RuntimeError,KeyError,TypeError,TimeoutError):return
    raise AssertionError('malformed input unexpectedly accepted')


def main():
    fixture=ROOT/'cores/image_processing/isp_stream/fixtures/host_control.json'
    sources=[Path(__file__).resolve(),Path(__file__).with_name('isp_host.py'),Path(__file__).with_name('run_uart.py'),fixture,
             ROOT/'cores/storage/buffer_dma/tools/run_uart.py',ROOT/'cores/storage/buffer_dma/tools/decode_metrics.py']
    out=ROOT/'artifacts/isp_stream_25k'/datetime.now(timezone.utc).strftime('host_%Y%m%dT%H%M%S%fZ');out.mkdir(parents=True)
    report={'status':'IN_PROGRESS','source_kind':'simulation_fixture','physical_measurement':False,
            'sources':{str(p.relative_to(ROOT)):hashlib.sha256(p.read_bytes()).hexdigest() for p in sources}}
    try:
        assert UartCsr(SerialFixture()).access(8)==0x12345678
        must_reject(lambda:UartCsr(SerialFixture(corrupt=True)).access(8))
        must_reject(lambda:UartCsr(SerialFixture(error=True)).access(8))
        for run in json.loads(fixture.read_text())['runs']:
            payload=bytearray()
            for f in range(run['frames']):
                data,_=golden_frame(run['width'],run['height'],f,run['seed'],run['raw_bits'],run['pattern'],run['bypass'],run.get('bayer_bypass',False));payload+=data
            assert payload.hex()==run['payload_hex']
            extra=[run.get(name,False) for name in ('bayer_bypass','awb_bypass','ccm_bypass','blc_bypass')]
            args=SimpleNamespace(width=7,height=7,frames=run['frames'],period_cycles=1000,seed=run['seed'],raw_bits=10,
                                 pattern=run['pattern'],center_bypass=run['bypass'],gamma_identity=run['gamma'],probe_page=2,seconds=1,
                                 **dict(zip(('bayer_bypass','awb_bypass','ccm_bypass','blc_bypass'),extra)))
            words=config_words(7,7,args.frames,1000,args.seed,10,args.pattern,args.center_bypass,args.gamma_identity,*extra)
            bus=FixtureBus(run['words']);saved=[]
            capture,result=execute(bus,words,args,saved.append)
            # execute labels physical use; the fixture explicitly relabels it.
            capture['source_kind']='simulation'
            verify_run(capture,7,7,args.frames,args.seed,10,args.pattern,args.center_bypass,args.gamma_identity,*extra)
            assert bus.commits==1 and bus.shadow==dict(enumerate(words)) and bus.selector==2
            assert len(bus.lut)==(768 if args.gamma_identity else 0)
            assert all(value==address for (_,address),value in bus.lut.items())
            for change in (
                lambda c:c.update(snapshot_id_after=c['snapshot_id_before']+1),
                lambda c:c.update(captured=False),lambda c:c.update(clock_hz=float('nan')),
                lambda c:c.update(epoch_id=''),lambda c:c['words'].__setitem__(31,1),
                lambda c:c['words'].__setitem__(15,1<<16)):
                bad=deepcopy(capture);change(bad);must_reject(lambda:decode(bad))
            for index in (0,1,2,6,7,8,9,11,12,13,14,20,21,22):
                bad=deepcopy(capture);bad['words'][index]^=1
                if index==20:
                    # Version binding belongs to execute's submitted run check.
                    continue
                must_reject(lambda:verify_run(bad,7,7,args.frames,args.seed,10,args.pattern,args.center_bypass,args.gamma_identity,*extra))
        for values in ((4,7,1,1000),(7,7,0,1000),(7,7,1,1)):
            must_reject(lambda:config_words(*values))
        report.update(status='PASS',fixture_runs=len(json.loads(fixture.read_text())['runs']),scope='host protocol/config/golden/snapshot tests; no physical evidence')
        print('PASS ISP host UART codec, config staging, identity LUT, golden fixtures, snapshot coherence and corruption rejection')
    except Exception as exc:
        report.update(status='FAIL',reason=str(exc));raise
    finally:
        (out/'summary.json').write_text(json.dumps(report,indent=2)+'\n');print('Evidence='+str(out))


if __name__=='__main__':main()
