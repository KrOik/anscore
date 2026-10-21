"""Check configurable host arithmetic against retained actual all-mode RTL payloads."""
from datetime import datetime, timezone
import hashlib
import json
from pathlib import Path
import re
from types import SimpleNamespace

from isp_host import ROOT, config_words, golden_frame, verify_run
from run_uart import execute, color_args
from test_host import FixtureBus, must_reject


def main():
    evidence=ROOT/'artifacts/isp_stream_25k/all_modes_20261020T183333608166Z'
    out=ROOT/'artifacts/isp_stream_25k'/datetime.now(timezone.utc).strftime('host_parameters_%Y%m%dT%H%M%S%fZ')
    out.mkdir(parents=True)
    sources=[Path(__file__).resolve()]+[Path(__file__).with_name(n) for n in ('isp_host.py','run_uart.py','test_host.py')]
    report=dict(status='FAIL',physical_measurement=False,
                source_evidence=str(evidence.relative_to(ROOT)),
                note='Payload,CRC and RGB sums are RTL observations; other fixture metrics are synthetic.',
                sources={str(p.relative_to(ROOT)):hashlib.sha256(p.read_bytes()).hexdigest() for p in sources})
    try:
        summary=json.loads((evidence/'summary.json').read_text())
        assert summary['status']=='PASS'
        for name,digest in summary['sources'].items():
            assert hashlib.sha256((ROOT/name).read_bytes()).hexdigest()==digest,name
        actual=(evidence/'pixels.bin').read_bytes()
        assert hashlib.sha256(actual).hexdigest()==summary['output_sha256']
        log=(evidence/'run.log').read_text()
        crc={int(n):int(v,16) for n,v in re.findall(r'CONTROL_CRC run=(\d+) value=([0-9a-fA-F]+)',log)}
        rgb=[{int(n):int(v) for n,v in re.findall(r'CONTROL_'+c+r' run=(\d+) value=(\d+)',log)} for c in 'RGB']
        matrix=(1024,128,-64,-128,1024,128,64,-128,1024,-5,3,7)
        params=dict(levels=(13,29,41,57),target=21,gains=(300,200,400),matrix=matrix)
        for mode in range(64):
            extra=dict(blc_bypass=bool(mode&1),bayer_bypass=bool(mode&2),awb_bypass=bool(mode&4),ccm_bypass=bool(mode&8))
            seed=(71+17*mode)&1023;pattern=mode%4;bypass=bool(mode&32);gamma=bool(mode&16)
            payload,sums=golden_frame(7,7,0,seed,10,pattern,bypass,**extra,**params)
            assert payload==actual[mode*36:(mode+1)*36:4]
            assert sums==[c[mode+1] for c in rgb]
            words=config_words(7,7,1,1000,seed,10,pattern,bypass,gamma,**extra,**params)
            assert words[5:10]==[21,13|(29<<16),41|(57<<16),300|(200<<16),400]
            unpacked=[((words[10+i//2]>>(16*(i%2)))&65535) for i in range(12)]
            assert [v-65536 if v&32768 else v for v in unpacked]==list(matrix)
            flags=(pattern<<4)|int(extra['blc_bypass'])|(int(gamma)<<1)|(int(bypass)<<2)|(int(extra['bayer_bypass'])<<3)|(int(extra['awb_bypass'])<<6)|(int(extra['ccm_bypass'])<<7)
            assert words[4]==flags
            metrics=[0]*32
            metrics[0]=3;metrics[1]=1;metrics[6]=9;metrics[7]=1
            metrics[8]=metrics[9]=crc[mode+1];metrics[12]=25;metrics[13]=5
            for c in range(3):metrics[14+2*c]=rgb[c][mode+1]
            metrics[20]=1;metrics[22]=flags
            args=SimpleNamespace(width=7,height=7,frames=1,seed=seed,raw_bits=10,pattern=pattern,
                                 center_bypass=bypass,gamma_identity=gamma,probe_page=2,seconds=1,
                                 black_levels=params['levels'],blc_target=21,gains=params['gains'],matrix=matrix,**extra)
            bus=FixtureBus(metrics)
            capture,_=execute(bus,words,args,lambda c:None)
            assert bus.shadow==dict(enumerate(words)) and bus.commits==1
            capture['source_kind']='simulation'
            changed=dict(params,target=22)
            if not extra['blc_bypass']:
                must_reject(lambda:verify_run(capture,7,7,1,seed,10,pattern,bypass,gamma,**extra,**changed))
        for key,value in [('levels',(0,0,0,1024)),('target',-1),('gains',(256,65536,256)),('matrix',(32768,)*12),('matrix',(1,2))]:
            invalid=dict(params);invalid[key]=value
            must_reject(lambda:config_words(7,7,1,1000,**invalid))
        report.update(status='PASS',mode_runs=64,output_pixels=576,scope='host fixture, not physical UART')
        print('PASS configurable host:64 RTL mode payloads,RGB/CRC,CSR packing/staging,range guards')
    except Exception as exc:
        report['reason']=str(exc)
        raise
    finally:
        (out/'summary.json').write_text(json.dumps(report,indent=2)+'\n')
        print('Evidence='+str(out))


if __name__=='__main__':main()
