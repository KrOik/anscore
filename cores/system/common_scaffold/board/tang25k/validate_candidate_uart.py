"""Validate a gated Tang25K SRAM candidate against its golden UART bytes."""
import argparse
import datetime
import hashlib
import json
import os
from pathlib import Path
import re
import subprocess
import time

import serial
from resume_candidate_route_official import verify_simulation_gate

ROOT=Path(__file__).resolve().parents[4]


def sha(path):
    with path.open('rb') as stream:
        return hashlib.file_digest(stream,'sha256').hexdigest()


def verify_frozen_artifacts(candidate,summary):
    """Recheck frozen inputs and fixture before opening UART or touching JTAG."""
    provenance=verify_simulation_gate(candidate)
    hashes=dict(provenance.get('source_sha256_verified',{}))
    hashes.update(provenance.get('freeze_files_sha256_verified',{}))
    fixture=candidate/'expected_uart.txt'
    if hashes.get('expected_uart.txt')!=sha(fixture):
        raise RuntimeError('Golden UART fixture is not covered by the simulation/freeze gate')
    netlist=candidate/'top25k.json'
    expected_netlist=summary.get('input_top25k_sha256')
    if not expected_netlist or sha(netlist)!=expected_netlist:
        raise RuntimeError('Routed input netlist SHA256 does not match the retained netlist')
    if not summary.get('gates') or min(summary.get('fmax_mhz',[]),default=0)<50:
        raise RuntimeError('Missing resource/timing gate evidence or sub-50MHz result')
    return dict(simulation_freeze=provenance,retained_netlist_sha256=expected_netlist,
                expected_uart_sha256=sha(fixture))


def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('candidate',type=Path)
    parser.add_argument('--port',default='COM44')
    parser.add_argument('--summary',default='build_25k_summary.json')
    args=parser.parse_args()
    candidate=args.candidate.resolve()
    now=datetime.datetime.now().astimezone()
    record=candidate/('board_uart_'+now.strftime('%Y%m%d_%H%M%S_%f')+'.json')
    result=dict(status='FAIL',programming='NOT_RUN',date=now.isoformat(),
                programming_mode='SRAM only',com_port=args.port,baud=115200,
                validator_source_sha256=sha(Path(__file__)))
    port=None
    try:
        summary_path=candidate/args.summary
        if summary_path.parent!=candidate:
            raise RuntimeError('Build summary must be inside the candidate directory')
        summary=json.loads(summary_path.read_text())
        if summary.get('status')!='BUILD_PASS_NOT_BOARD' or not all(summary.get('gates',{}).values()):
            raise RuntimeError('Build resource/timing gates did not pass')
        if summary.get('device')!='GW5A-LV25MG121NES' or summary.get('clk_mhz')!=50:
            raise RuntimeError('Unexpected target device or clock')
        if summary['util']['lut4']>15000 or summary['util']['mult12']>4:
            raise RuntimeError('15K LUT / 4 DSP gate exceeded')
        result['pre_program_artifact_verification']=verify_frozen_artifacts(candidate,summary)
        image=candidate/summary['bitstream']
        if image.parent!=candidate or sha(image)!=summary['bitstream_sha256'].lower():
            raise RuntimeError('Unsafe bitstream path or mismatched SHA256')
        if image.stat().st_size!=summary['bitstream_bytes']:
            raise RuntimeError('Mismatched bitstream size')
        expected=(candidate/'expected_uart.txt').read_bytes()
        if not expected.endswith(b'\n') or len(expected)>100000:
            raise RuntimeError('Invalid golden UART fixture')
        result.update(build_summary_sha256=sha(summary_path),bitstream=str(image),
                      bitstream_sha256=sha(image),expected_uart=expected.decode('ascii'),
                      expected_uart_sha256=hashlib.sha256(expected).hexdigest())
        # Keep separately constrained diagnostic clock rates explicit in each
        # board record; a low-rate PASS must not become a full-rate claim.
        for key in ('scope','functional_clk_mhz','core_enable_divisor','clock_checks'):
            if key in summary:
                result[key]=summary[key]
        loader=ROOT/'tools/oss-cad-suite/oss-cad-suite/bin/openFPGALoader.exe'
        env=dict(os.environ)
        env['PATH']=os.pathsep.join((str(loader.parent),str(loader.parent.parent/'lib'),env['PATH']))
        port=serial.Serial(args.port,115200,timeout=0.2)
        detect_cmd=[str(loader),'-b','tangprimer25k','--detect']
        detect=subprocess.run(detect_cmd,env=env,capture_output=True,text=True,timeout=15)
        match=re.search(r'(?i)\bid\s*code\b[^\r\n]*?\b0x([0-9a-f]+)\b',detect.stdout+detect.stderr)
        ident=int(match.group(1),16) if match else None
        result.update(jtag_detect_command=detect_cmd,jtag_detect_stdout=detect.stdout,
                      jtag_detect_stderr=detect.stderr,jtag_detect_returncode=detect.returncode,
                      jtag_detected_idcode=hex(ident) if ident is not None else None)
        if detect.returncode or ident!=0x1281B:
            raise RuntimeError('JTAG IDCODE must be 0x1281b')
        port.reset_input_buffer()
        program_cmd=[str(loader),'-b','tangprimer25k',str(image)]
        program=subprocess.run(program_cmd,env=env,capture_output=True,text=True,timeout=45)
        result.update(program_command=program_cmd,programmer_returncode=program.returncode,
                      programmer_stdout=program.stdout,programmer_stderr=program.stderr)
        if program.returncode:
            raise RuntimeError('SRAM programming failed')
        result['programming']='PASS_SRAM_ONLY'
        raw=bytearray()
        deadline=time.monotonic()+20
        while time.monotonic()<deadline:
            raw.extend(port.read(1024))
            if raw.count(b'\n')>=expected.count(b'\n'):
                break
        # A line match alone misses a delayed duplicate byte. Observe an extra
        # host-side quiet interval; this is byte-level evidence, not an electrical
        # UART waveform measurement. A 0.1s interval exceeds twelve UART bit times.
        quiet_start=time.monotonic()
        quiet_deadline=quiet_start+0.1
        extra=bytearray()
        while time.monotonic()<quiet_deadline:
            extra.extend(port.read(1024))
        raw.extend(extra)
        result.update(post_line_observation_seconds=time.monotonic()-quiet_start,
                      post_line_min_requested_seconds=0.1,post_line_extra_bytes=len(extra),
                      quiet_check_scope='host serial byte stream after completed line')
        result.update(uart_bytes=len(raw),uart_capture=raw.decode('ascii',errors='replace'))
        if bytes(raw)!=expected:
            raise RuntimeError('Actual UART bytes differ from independent golden fixture')
        result.update(status='PASS',uart_validation='PASS_EXACT_BYTES')
    except Exception as error:
        result['error']=str(error)
    finally:
        if port is not None:
            port.close()
        record.write_text(json.dumps(result,indent=2)+'\n',encoding='utf-8')
    print('record='+str(record))
    print('status='+result['status'])
    print(result.get('uart_capture',result.get('error','')))
    return 0 if result['status']=='PASS' else 1


if __name__=='__main__':
    raise SystemExit(main())
