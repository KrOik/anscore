"""Main-owned, route-gated physical IMG1/IMR1 complete-frame qualification."""
import argparse, hashlib, json, os, secrets, subprocess, sys, time
from pathlib import Path
from board_lock import BoardLock
import serial
from probe_external import ROOT,HERE,parse_decode
from build_log_gate import assert_clean_build
sys.path.insert(0,str(HERE/'image_harness'))
from protocol import cases,make_packet,oracle,verify

def main():
    p=argparse.ArgumentParser();p.add_argument('--build',type=Path,required=True)
    p.add_argument('--output',type=Path,required=True);p.add_argument('--port',default='COM24')
    p.add_argument('--vector-json',type=Path,help='Replay saved host frame(s) with new tags and recomputed oracle')
    a=p.parse_args();build=a.build.resolve();out=a.output.resolve()
    summary=json.loads((build/'build_summary.json').read_text())
    assert_clean_build(build)
    sim=json.loads((build/'simulation_summary.json').read_text())
    if sim['status']!='PASS':raise ValueError('simulation gate')
    for source,digest in json.loads((build/'hashes.json').read_text()).items():
        if hashlib.sha256((build/Path(source).name).read_bytes()).hexdigest()!=digest:
            raise ValueError('frozen source identity: '+source)
    image=build/'image.fs';sha=hashlib.sha256(image.read_bytes()).hexdigest()
    if summary['status']!='BUILD_PASS_NOT_BOARD' or summary['bitstream_sha256']!=sha:
        raise ValueError('image identity/build gate')
    if summary['routed_lut4']>15000 or summary['dsp']>4 or min(summary['fmax_mhz'])<27:
        raise ValueError('resource/timing gate')
    bits=summary['bits'];padding=summary['padding']
    if (sim['bits'],sim['padding'])!=(bits,padding):raise ValueError('configuration identity')
    out.mkdir(parents=True,exist_ok=False)
    lock=BoardLock(purpose='CSC morphology external frame qualification',output=str(out))
    lock.acquire()
    verdict=dict(status='FAIL',image=str(image),sha256=sha,bits=bits,padding=padding,cases=[])
    cap=None
    try:
        with (out/'program.log').open('w') as log:
            r=subprocess.run(['pwsh','-NoProfile','-File',str(HERE/'program_probe.ps1'),'-Image',str(image)],stdout=log,stderr=subprocess.STDOUT,timeout=60)
        if r.returncode:raise RuntimeError('SRAM programming failed; image unconfirmed')
        verdict['sram_programmed']=True
        sigrok='C:/Program Files/sigrok/sigrok-cli/sigrok-cli.exe'
        with serial.Serial(a.port,115200,timeout=0,write_timeout=1) as port:
            (out/'serial_before_diagnostic.bin').write_bytes(port.read(65536))
            work=cases(bits)
            if a.vector_json:
                saved=json.loads(a.vector_json.read_text());saved=saved if isinstance(saved,list) else [saved]
                if not saved:raise ValueError('Empty host frame matrix')
                if any((item.get('bits',bits),item.get('padding',padding))!=(bits,padding) for item in saved):raise ValueError('Replay configuration identity')
                work=[(i,item['config'],item['words'],item['stall']) for i,item in enumerate(saved)]
                verdict['replayed_host_vector']=str(a.vector_json.resolve())
            for index,(_,config,initial,stall) in enumerate(work):
                folder=out/f'case_{index:02d}';folder.mkdir()
                tag=secrets.randbits(32)
                words=list(initial) if a.vector_json else [0 if i%7==0 else secrets.randbits(3*bits) for i in range(64)]
                packet=make_packet(tag,config,words,stall)
                (folder/'request.bin').write_bytes(packet)
                (folder/'expected.json').write_text(json.dumps(dict(tag=tag,bits=bits,padding=padding,config=config,words=words,stall=stall,outputs=oracle(bits,config,words,padding)),indent=2))
                with (folder/'capture.log').open('w') as log:
                    started=time.monotonic()
                    cap=subprocess.Popen([sigrok,'-l','4','-d','fx2lafw','--config','samplerate=4m','--samples','4000000','-o',str(folder/'capture.sr')],stdout=log,stderr=subprocess.STDOUT)
                    while 'receive_transfer():' not in (folder/'capture.log').read_text(errors='replace'):
                        if cap.poll() is not None or time.monotonic()-started>10:raise RuntimeError('No live FX2 transfer')
                        time.sleep(.005)
                    send_start=time.monotonic()
                    for byte in packet:
                        if port.write(bytes([byte]))!=1:raise RuntimeError('short UART write')
                        time.sleep(.0015)
                    port.flush();send_end=time.monotonic();cap.wait(timeout=30)
                    (folder/'timing.json').write_text(json.dumps(dict(acquisition_ready_seconds=send_start-started,send_seconds=send_end-send_start),indent=2))
                    (folder/'serial_diagnostic.bin').write_bytes(port.read(65536))
                if cap.returncode:raise RuntimeError('FX2 capture failed')
                r=subprocess.run([sigrok,'-i',str(folder/'capture.sr'),'-P','uart:rx=D0:baudrate=115200:format=hex','-A','uart=rx-data'],text=True,capture_output=True,timeout=30)
                (folder/'decoded.txt').write_text(r.stdout);(folder/'decode_stderr.log').write_text(r.stderr)
                if r.returncode:raise RuntimeError('decode failed')
                data=parse_decode(r.stdout);(folder/'decoded.bin').write_bytes(data)
                result=verify(data,tag,config,words,bits,stall,padding)
                bad=bytearray(data);bad[-1]^=1
                try:verify(bad,tag,config,words,bits,stall,padding)
                except AssertionError:pass
                else:raise RuntimeError('checker accepted corrupted result')
                result['negative_check']='PASS'
                (folder/'verdict.json').write_text(json.dumps(result,indent=2));verdict['cases'].append(result)
                print('PASS image',index,result,flush=True)
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
    print(json.dumps(verdict,indent=2));return int(verdict['status']!='PASS')

if __name__=='__main__':raise SystemExit(main())
