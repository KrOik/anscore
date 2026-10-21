"""Physical per-result qualification. Only route-gated block images are allowed."""
import argparse
import hashlib
import json
import os
from pathlib import Path
from board_lock import BoardLock
import secrets
import subprocess
import sys
import time
import serial
from probe_external import ROOT,HERE,parse_decode
from build_log_gate import assert_clean_build

sys.path.insert(0,str(HERE/'block_harness'))
from protocol import cases,make_packet,oracle,verify

def main():
    p=argparse.ArgumentParser()
    p.add_argument('--build',required=True,type=Path)
    p.add_argument('--output',required=True,type=Path)
    p.add_argument('--port',default='COM24')
    p.add_argument('--vector-json',type=Path,help='Replay a saved host-input object or list of objects; expected values are recomputed')
    a=p.parse_args();build=a.build.resolve();out=a.output.resolve()
    summary=json.loads((build/'build_summary.json').read_text())
    assert_clean_build(build)
    sim=json.loads((build/'simulation_summary.json').read_text())
    if sim['status']!='PASS':raise ValueError('UART simulation gate')
    for source,expected_hash in json.loads((build/'hashes.json').read_text()).items():
        frozen=build/Path(source).name
        if hashlib.sha256(frozen.read_bytes()).hexdigest()!=expected_hash:
            raise ValueError('Frozen source identity mismatch: '+str(frozen))
    image=build/'block.fs';sha=hashlib.sha256(image.read_bytes()).hexdigest()
    if summary['status']!='BUILD_PASS_NOT_BOARD' or summary['bitstream_sha256']!=sha:
        raise ValueError('Build gate/image identity mismatch')
    if summary['dsp']>4 or summary['routed_lut4']>15000 or min(summary['fmax_mhz'])<27:
        raise ValueError('Resource/timing gate')
    core={'dc':0,'csc':1,'identity':2}[sim['core']];bits=sim['bits']
    latency=sim.get('latency',1)
    if summary.get('latency',1)!=latency:raise ValueError('Build/simulation latency identity mismatch')
    out.mkdir(parents=True,exist_ok=False)
    lock=BoardLock(purpose='DSP ISP external block qualification',output=str(out))
    lock.acquire()
    verdict=dict(status='FAIL',image=str(image),sha256=sha,core=sim['core'],bits=bits,latency=latency,cases=[])
    cap=None
    try:
        with (out/'program.log').open('w') as log:
            r=subprocess.run(['pwsh','-NoProfile','-File',str(HERE/'program_probe.ps1'),'-Image',str(image)],
                             stdout=log,stderr=subprocess.STDOUT,timeout=60)
        if r.returncode:raise RuntimeError('Programming failed; SRAM state unconfirmed')
        verdict['sram_programmed']=True
        sigrok='C:/Program Files/sigrok/sigrok-cli/sigrok-cli.exe'
        with serial.Serial(a.port,115200,timeout=0,write_timeout=1) as port:
            # Retain any old serial bytes as diagnostic only, never use for verdict.
            (out/'serial_before_diagnostic.bin').write_bytes(port.read(65536))
            work=cases(core,bits)
            if a.vector_json:
                saved=json.loads(a.vector_json.read_text())
                saved = saved if isinstance(saved,list) else [saved]
                if not saved:raise ValueError('Empty host vector matrix')
                work=[(i,item['config'],item['words'],item['stall']) for i,item in enumerate(saved)]
                verdict['replayed_host_vector']=str(a.vector_json.resolve())
            for index,(_,config,initial,stall) in enumerate(work):
                folder=out/f'case_{index:02d}';folder.mkdir()
                tag=secrets.randbits(32)
                words=list(initial)
                if not a.vector_json:
                    for i in range(4,len(words)):
                        words[i]=secrets.randbits(32 if core==2 else (3*bits if core else 16))
                packet=make_packet(tag,config,words,stall)
                (folder/'request.bin').write_bytes(packet)
                (folder/'expected.json').write_text(json.dumps(dict(tag=tag,config=config,words=words,stall=stall,
                                                outputs=oracle(core,bits,config,words)),indent=2))
                with (folder/'capture.log').open('w') as log:
                    started=time.monotonic()
                    cap=subprocess.Popen([sigrok,'-l','4','-d','fx2lafw','--config','samplerate=4m','--samples','4000000',
                                          '-o',str(folder/'capture.sr')],stdout=log,stderr=subprocess.STDOUT)
                    # Use positive transfer evidence, not a guessed USB startup delay.
                    while 'receive_transfer():' not in (folder/'capture.log').read_text(errors='replace'):
                        if cap.poll() is not None or time.monotonic()-started>10:
                            raise RuntimeError('No live FX2 acquisition transfer observed')
                        time.sleep(0.005)
                    send_start=time.monotonic()
                    for byte in packet:
                        if port.write(bytes([byte]))!=1:raise RuntimeError('Short serial write')
                        time.sleep(0.0015)
                    port.flush();send_end=time.monotonic();cap.wait(timeout=30)
                    (folder/'timing.json').write_text(json.dumps(dict(acquisition_ready_seconds=send_start-started,
                                                      send_seconds=send_end-send_start),indent=2))
                    (folder/'serial_diagnostic.bin').write_bytes(port.read(65536))
                if cap.returncode:raise RuntimeError('FX2 capture failed')
                r=subprocess.run([sigrok,'-i',str(folder/'capture.sr'),'-P',
                                  'uart:rx=D0:baudrate=115200:format=hex','-A','uart=rx-data'],
                                 text=True,capture_output=True,timeout=30)
                (folder/'decoded.txt').write_text(r.stdout)
                (folder/'decode_stderr.log').write_text(r.stderr)
                if r.returncode:raise RuntimeError('Decode failed')
                data=parse_decode(r.stdout);(folder/'decoded.bin').write_bytes(data)
                result=verify(data,tag,config,words,core,bits,stall,latency=latency)
                # Physically observed response must also fail controlled corruption.
                bad=bytearray(data);bad[-1]^=1
                try:verify(bad,tag,config,words,core,bits,stall,latency=latency)
                except AssertionError:pass
                else:raise RuntimeError('Checker accepted corrupted payload')
                result['negative_check']='PASS'
                (folder/'verdict.json').write_text(json.dumps(result,indent=2))
                verdict['cases'].append(result)
                print('PASS',sim['core'],index,result,flush=True)
            (out/'serial_after_diagnostic.bin').write_bytes(port.read(65536))
        verdict['status']='PASS'
    except Exception as exc:verdict['error']=repr(exc)
    finally:
        if cap is not None and cap.poll() is None:cap.terminate();cap.wait(timeout=10)
        (out/'verdict.json').write_text(json.dumps(verdict,indent=2)+'\n')
        rec=lock._read()
        if rec and rec.get('token')==lock.owner['token']:
            (out/'released_boardlock.json').write_text(json.dumps(rec,indent=2))
        lock.release()
    print(json.dumps(verdict,indent=2))
    return int(verdict['status']!='PASS')

if __name__=='__main__':raise SystemExit(main())
