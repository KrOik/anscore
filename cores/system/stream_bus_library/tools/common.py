import os
import hashlib
from pathlib import Path
import subprocess
from datetime import datetime,timezone

ROOT=Path(__file__).resolve().parents[1]
REPO=ROOT.parents[1]
SUITE=REPO/'tools/oss-cad-suite/oss-cad-suite'

CORES=[
 ('frame_switch4','stream','4x4 frame-locked round-robin switch'),
 ('width_converter','stream','TKEEP/TLAST-aware32/8-bit width conversion, both directions'),
 ('packet_async_fifo','stream','Atomic store-and-forward packet CDC, oversize discard'),
 ('backpressure_isolator','stream','Two-slot buffer with registered upstream readiness'),
 ('axi_lite_interconnect','control','Independent AW/W/AR routing to four4K windows, DECERR'),
 ('bus_timeout_monitor','control','Passive deadlines, overlap and late-completion accounting'),
 ('atomic_config','control','Shadow write and boundary-safe atomic commit'),
 ('register_snapshot','control','Coherent register/timestamp/sequence snapshot'),
 ('timestamp64','acquisition','Acceptance-time64-bit sample timestamp'),
 ('frame_align4','acquisition','Four-channel epoch alignment, late discard and missing flags'),
 ('trigger_window','acquisition','Synchronous circular pre/post-trigger capture'),
 ('calibration24','acquisition','Signed24 offset/Q2.14 gain calibration,0DSP serial multiplier'),
 ('march_controller','test','Complete March C- request/response RAM test controller'),
 ('fault_injector','test','Controlled XOR/stuck0/stuck1 stream corruption'),
 ('stream_metrics','test','Timestamp-based ordered-stream latency/stall accounting'),
 ('capture_replay','test','Host-loaded synchronous stimulus and raw response RAM')]

def env():
    out=os.environ.copy()
    out['PATH']=os.pathsep.join([str(SUITE/'bin'),str(SUITE/'lib'),out['PATH']])
    return out

def run(argv,log,timeout=120):
    argv=[str(a) for a in argv]
    exe=SUITE/'bin'/(argv[0]+'.exe')
    if exe.exists(): argv[0]=str(exe)
    with log.open('wb') as stream:
        p=subprocess.run(argv,cwd=ROOT,env=env(),stdout=stream,stderr=subprocess.STDOUT,timeout=timeout)
    text=log.read_text(encoding='utf-8',errors='replace')
    if p.returncode: raise RuntimeError(f'{argv[0]} exit={p.returncode}; {log}')
    return text

def evidence(kind):
    p=ROOT/'evidence'/(kind+'_'+datetime.now(timezone.utc).strftime('%Y%m%dT%H%M%S%fZ'))
    p.mkdir(parents=True,exist_ok=False)
    return p

def hashes():
    return {p.relative_to(ROOT).as_posix():hashlib.sha256(p.read_bytes()).hexdigest()
            for folder in ['rtl','sim','models','board','tools','ip','doc','vectors','diagnostics']
            for p in sorted((ROOT/folder).rglob('*')) if p.is_file() and '__pycache__' not in p.parts}
