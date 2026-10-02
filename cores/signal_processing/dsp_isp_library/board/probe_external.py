"""Exclusive SRAM probe + fresh serial stimulus and FX2 capture; no Flash writes."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import secrets
import subprocess
import time
import serial
from board_lock import BoardLock

HERE=Path(__file__).resolve().parent
ROOT=HERE.parents[2]

def verify_decoded(decoded, expected):
    if len(expected)!=32 or len(decoded)<96:
        raise ValueError('Expected 32-byte nonce and at least 96 captured bytes')
    positions=[i for i in range(32) if decoded==bytes(expected[(i+j)%32] for j in range(len(decoded)))]
    if not positions:
        raise ValueError('Capture contains data, order, insertion or deletion mismatch')
    return positions[0]

def parse_decode(text):
    result=bytearray()
    for line in text.splitlines():
        if not line.strip():continue
        match=re.fullmatch(r'uart-\d+:\s*([0-9A-Fa-f]{2})\s*',line)
        if match is None:raise ValueError('Unexpected decoder output: '+line)
        result.append(int(match.group(1),16))
    return bytes(result)

def main():
    p=argparse.ArgumentParser()
    p.add_argument('--image',type=Path,required=True)
    p.add_argument('--output',type=Path,required=True)
    p.add_argument('--port',default='COM24')
    a=p.parse_args();image=a.image.resolve();out=a.output.resolve()
    out.mkdir(parents=True,exist_ok=False)
    lock=BoardLock(purpose='DSP ISP external UART probe',output=str(out))
    lock.acquire()
    status=dict(status='FAIL',image=str(image),sha256=hashlib.sha256(image.read_bytes()).hexdigest())
    capture=None
    try:
        cmd=['pwsh','-NoProfile','-File',str(HERE/'program_probe.ps1'),'-Image',str(image)]
        with (out/'program.log').open('w') as log:
            r=subprocess.run(cmd,stdout=log,stderr=subprocess.STDOUT,timeout=60)
        if r.returncode: raise RuntimeError('JTAG/program failed; see program.log')
        status['sram_programmed']=True
        packet=b'INJ1'+secrets.token_bytes(28)
        expected=bytes(x^0xa5 for x in packet)
        (out/'input_packet.bin').write_bytes(packet)
        (out/'expected_packet.bin').write_bytes(expected)
        sigrok=Path('C:/Program Files/sigrok/sigrok-cli/sigrok-cli.exe')
        with serial.Serial(a.port,115200,timeout=0,write_timeout=1) as port:
            port.reset_input_buffer()
            with (out/'capture.log').open('w') as log:
                capture=subprocess.Popen([str(sigrok),'-d','fx2lafw','--config','samplerate=4m',
                    '--samples','4000000','-o',str(out/'capture.sr')],stdout=log,stderr=subprocess.STDOUT)
                received=bytearray();sent=bytearray()
                time.sleep(0.25)
                for repeat in range(24):
                    for byte in packet:
                        port.write(bytes([byte]));sent.append(byte)
                        time.sleep(0.002)
                        received.extend(port.read(4096))
                (out/'sent.bin').write_bytes(sent)
                (out/'serial_received.bin').write_bytes(received)
                capture.wait(timeout=30)
                if capture.returncode: raise RuntimeError('FX2 capture failed')
        r=subprocess.run([str(sigrok),'-i',str(out/'capture.sr'),'-P',
                          'uart:rx=D0:baudrate=115200:format=hex','-A','uart=rx-data'],
                         text=True,capture_output=True,timeout=30)
        (out/'decoded.txt').write_text(r.stdout)
        (out/'decode_stderr.log').write_text(r.stderr)
        if r.returncode: raise RuntimeError('Decode failed')
        decoded=parse_decode(r.stdout)
        (out/'decoded.bin').write_bytes(decoded)
        # Every observed byte must belong to the repeated nonce stream. Permit
        # only start/end fragments consistent with it; require 2 complete packets.
        offset=verify_decoded(decoded,expected)
        status.update(status='PASS',decoded_bytes=len(decoded),cyclic_start=offset,
                      serial_received_bytes=len(received),sent_bytes=len(sent),
                      scope='transport external UART input to FPGA XOR to FX2 output only')
    except Exception as exc:
        status['error']=str(exc)
    finally:
        if capture is not None and capture.poll() is None:
            capture.terminate();capture.wait(timeout=10)
        (out/'verdict.json').write_text(json.dumps(status,indent=2)+'\n')
        rec=lock._read()
        if rec and rec.get('token')==lock.owner['token']:
            (out/'released_boardlock.json').write_text(json.dumps(rec,indent=2))
        lock.release()
    print(json.dumps(status,indent=2))
    return 0 if status['status']=='PASS' else 1

if __name__=='__main__':raise SystemExit(main())
