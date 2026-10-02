"""Isolated window-memory board-qualification harness driver.

Simulates the full UART-load -> synchronous-RAM -> stream_window_padded ->
record-RAM -> UART-export path with the independent raster oracle and the
cycle-level FSM model, then optionally synthesizes/routes/packs. No hardware.

Variants select ONLY the window memory implementation; the stream contract and
expected values are identical across variants:
  bram  - production inferred memories (infra/window, ram_style="block")
  reg   - all window memories forced to flip-flops (ram_style="registers")
  prim  - explicit Gowin SPX9/DPX9B primitives, same modes as inferred
"""
import argparse, collections, datetime, hashlib, json, os, re, shutil, struct, subprocess
from pathlib import Path
from protocol import HERE,LIB,HDR,cases,make_packet,rec_bytes,verify
ROOT=LIB.parents[1]

PRESETS=dict(
    w8=dict(width=8,height=8,k=3,pad_mode=1,data_width=8),
    w32=dict(width=32,height=24,k=3,pad_mode=1,data_width=8))

def audit_warnings(dest):
    patterns=(r'found logic loop',r'(?<!no )latch inferred',r'inferred latch',r'\$dlatch',
        r'no clocks? (found|defined|constrained)',r'unconstrained',r'no (timing|clock) constraints?',
        r'failed to (match|constrain)',r'not constrained')
    findings=[]
    for name in ('synthesis.log','route.log','nextpnr.log'):
        path=dest/name
        if path.exists():
            for line in path.read_text(errors='replace').splitlines():
                if any(re.search(p,line,re.I) for p in patterns):findings.append(dict(log=name,line=line))
    (dest/'warning_audit.json').write_text(json.dumps(dict(status='FAIL' if findings else 'PASS',findings=findings),indent=2))
    assert not findings,('strict warning gate',findings)

def main():
    p=argparse.ArgumentParser()
    p.add_argument('--variant',choices=('bram','reg','prim','fix1','fix2','fix3','dbg','fix4','fix5'),default='bram')
    p.add_argument('--preset',choices=sorted(PRESETS),default='w8')
    p.add_argument('--width',type=int);p.add_argument('--height',type=int)
    p.add_argument('--k',type=int,choices=(3,5));p.add_argument('--pad-mode',type=int,choices=(0,1))
    p.add_argument('--data-width',type=int,default=None)
    p.add_argument('--build',action='store_true')
    p.add_argument('--replay-json',type=Path,help='Replay saved host pixels; oracle recomputed')
    p.add_argument('--replay-plus-default',action='store_true')
    a=p.parse_args()
    cfg=dict(PRESETS[a.preset])
    for key in ('width','height','k','pad_mode','data_width'):
        v=getattr(a,key)
        if v is not None:cfg[key]=v
    W,H,K,PAD,DW=cfg['width'],cfg['height'],cfg['k'],cfg['pad_mode'],cfg['data_width']
    if a.variant=='prim' and DW>9:p.error('prim variant requires DATA_WIDTH<=9')
    if DW>8:p.error('harness packs one byte per pixel; DATA_WIDTH<=8')
    dest=HERE/'evidence'/f'wp_{a.variant}_{W}x{H}k{K}p{PAD}d{DW}_{datetime.datetime.now().strftime("%Y%m%d_%H%M%S_%f")}'
    dest.mkdir(parents=True)
    cad=ROOT/'tools/oss-cad-suite/oss-cad-suite';env=dict(os.environ)
    env['PATH']=str(cad/'bin')+os.pathsep+str(cad/'lib')+os.pathsep+env['PATH']
    wsrc={ 'bram':[LIB/'infra/window/stream_window.v',LIB/'infra/window/stream_window_padded.v'],
           'reg':[HERE/'variants/reg/stream_window.v',HERE/'variants/reg/stream_window_padded.v'],
           'prim':[HERE/'variants/prim/stream_window.v',HERE/'variants/prim/stream_window_padded.v'],
           'fix1':[HERE/'variants/fix1/stream_window.v',HERE/'variants/fix1/stream_window_padded.v'],
           'fix2':[HERE/'variants/fix2/stream_window.v',HERE/'variants/fix2/stream_window_padded.v'],
           'fix3':[HERE/'variants/fix3/stream_window.v',HERE/'variants/fix3/stream_window_padded.v'],
           'dbg':[HERE/'variants/dbg/stream_window_padded.v'],
           'fix4':[HERE/'variants/fix4/stream_window.v',HERE/'variants/fix4/stream_window_padded.v'],
           'fix5':[HERE/'variants/fix5/stream_window.v',HERE/'variants/fix5/stream_window_padded.v']}[a.variant]
    top=HERE/'variants'/a.variant/'window_probe.v' if a.variant in ('fix1','fix2','fix3','dbg','fix4','fix5') else HERE/'window_probe.v'
    rtl=[top,HERE/'probe_ram.v',*wsrc,
         ROOT/'cores/communication/primitives/src/uart_rx.v',ROOT/'cores/communication/primitives/src/uart_tx.v']
    sim_extra=[HERE/'variants/prim/gowin_prims_sim.v'] if a.variant=='prim' else []
    frozen=[*rtl,*sim_extra,HERE/'tb_window_probe.sv',HERE/'tb_fault.sv',HERE/'protocol.py',
            HERE/'audit_build.py',Path(__file__),LIB/'infra/window/model.py']
    for f in frozen:shutil.copy2(f,dest/f.name)
    shutil.copy2(LIB/'board/uart_injection_probe.cst',dest/'top.cst')
    (dest/'hashes.json').write_text(json.dumps({str(f):hashlib.sha256(f.read_bytes()).hexdigest() for f in frozen},indent=2))
    (dest/'variant.json').write_text(json.dumps(dict(variant=a.variant,preset=a.preset,**cfg),indent=2))
    work=cases(W,H,DW);stim='';negative=[]
    if a.replay_json:
        saved=json.loads(a.replay_json.read_text());saved=saved if isinstance(saved,list) else [saved]
        work=[(item.get('tag',i),item.get('config',0),item['pixels'],item.get('stall',0)) for i,item in enumerate(saved)]
        if not work:raise ValueError('Empty replay')
        shutil.copy2(a.replay_json,dest/'host_replay.json')
        if a.replay_plus_default:work+=cases(W,H,DW)
    rb=rec_bytes(K,DW);pix=W*H
    for tag,c,pixels,stall in work:
        packet=make_packet(tag,c,pixels,stall)
        stim+=f'{len(packet)} {HDR+len(pixels)*rb}\n'+''.join(f'{b:02x}\n' for b in packet)
    for tag,c,count,stall,flag in [
        (0xBAD70001,0,0,0,1),            # count zero
        (0xBAD70002,0,pix+1,0,1),        # not a multiple of PIX
        (0xBAD70003,0,2048+pix,0,1),     # over capture capacity
        (0xBAD70004,0,pix,8,1),          # stall > 7
        (0xBAD70005,1,pix,0,8),          # nonzero reserved config
        (0xBAD70006,1,pix,8,1)]:         # count/stall check precedes config check
        packet=b'WPR1'+struct.pack('<IIHB',tag,c,count,stall)
        stim+=f'{len(packet)} {HDR}\n'+''.join(f'{b:02x}\n' for b in packet)
        negative.append(b'WPO1'+struct.pack('<IIHBHHI',tag,c,0,flag,0,0,0))
    (dest/'stim.txt').write_text(stim)
    def run(command,log):
        command=[shutil.which(command[0],path=env['PATH']) or command[0],*command[1:]]
        with (dest/log).open('w') as f:
            f.write('$ '+' '.join(map(str,command))+'\n');f.flush()
            r=subprocess.run(command,cwd=dest,env=env,stdout=f,stderr=subprocess.STDOUT)
        if r.returncode:raise RuntimeError(f'{log} failed; {dest}')
    names=[f.name for f in rtl]
    for tb in ('tb_window_probe','tb_fault'):
        pstr=[f'-P{tb}.WIDTH={W}',f'-P{tb}.HEIGHT={H}',f'-P{tb}.K={K}',f'-P{tb}.PAD_MODE={PAD}',f'-P{tb}.DATA_WIDTH={DW}']
        run(['iverilog','-g2012','-Wall','-s',tb,*pstr,
             '-o',tb+'.vvp',tb+'.sv',*[s.name for s in sim_extra],*names],tb+'_compile.log')
        run(['vvp',tb+'.vvp']+(['+stim=stim.txt','+trace=trace.txt'] if tb=='tb_window_probe' else []),tb+'.log')
    raw=bytes(int(x,16) for x in (dest/'trace.txt').read_text().splitlines());(dest/'raw.bin').write_bytes(raw)
    offset=0;results=[];mutations=0
    for tag,c,pixels,stall in work:
        size=HDR+len(pixels)*rb;report=raw[offset:offset+size];offset+=size
        if a.variant=='dbg':
            if len(report)!=size or report[:4]!=b'WPO1':raise AssertionError(('dbg report framing',len(report),report[:8]))
            results.append(dict(status='DBG_RAW',tag=tag,bytes=len(report)))
        else:
            results.append(verify(report,tag,c,pixels,stall,W,H,K,DW,PAD))
            for pos in (0,4,8,12,14,15,17,19,HDR,HDR+rb//2,len(report)-1):
                bad=bytearray(report);bad[pos]^=1
                try:verify(bad,tag,c,pixels,stall,W,H,K,DW,PAD)
                except AssertionError:mutations+=1
                else:raise AssertionError('corrupted report accepted')
    for expected in negative:
        if raw[offset:offset+HDR]!=expected:raise AssertionError(('negative',raw[offset:offset+HDR],expected))
        offset+=HDR
    if offset!=len(raw):raise AssertionError('extra UART bytes')
    (dest/'simulation_summary.json').write_text(json.dumps(dict(
        status='PASS',variant=a.variant,**cfg,packets=results,
        invalid_packets=len(negative),mutations_rejected=mutations,
        faults='truncation/badstop/late-busy/watchdog PASS'),indent=2))
    print('UART SIM PASS',dest,flush=True)
    if not a.build:return
    (dest/'build.ys').write_text(
        'read_verilog -sv '+' '.join(names)+'\n'
        f'chparam -set WIDTH {W} -set HEIGHT {H} -set K {K} -set PAD_MODE {PAD} -set DATA_WIDTH {DW} window_probe\n'
        'synth_gowin -noalu -family gw2a -top window_probe -json top.json\nstat\n')
    run(['yosys','-s','build.ys'],'synthesis.log')
    audit_warnings(dest)
    net=json.loads((dest/'top.json').read_text())
    cells=collections.Counter(c['type'] for c in net['modules']['window_probe']['cells'].values())
    lut=sum(n for t,n in cells.items() if re.fullmatch('LUT[1-4]|ALU',t))
    dsp=sum(n for t,n in cells.items() if t.startswith(('MULT','PADD','ALU54')))
    ff=sum(n for t,n in cells.items() if t.startswith('DFF'))
    bram=sum(n for t,n in cells.items() if t in ('SPX9','DPX9B','SP','SDP','SDPX9','SDPX9B','DP','DPB','DPX16','SPX9'))
    (dest/'resources.json').write_text(json.dumps(dict(lut=lut,dsp=dsp,ff=ff,bram=bram,cells=dict(cells)),indent=2))
    assert lut<=15000 and dsp<=4,'resource gate'
    if a.variant=='reg':
        # DUT window memories must be flip-flops; only harness probe RAMs may
        # remain BSRAM. Prove it from the forced-mapping log lines.
        slog=(dest/'synthesis.log').read_text(errors='replace')
        forced=re.findall(r"ram_style = registers' on memory (window_probe\.dut\.[\w.\[\]]+)",slog)
        assert len(forced)>=K+1 and not cells.get('SPX9'),('reg variant DUT memories not forced to FF',forced)
        (dest/'register_forced.json').write_text(json.dumps(dict(forced_ff=forced),indent=2))
    if a.variant=='prim':
        assert cells.get('SPX9',0)>=K and cells.get('DPX9B',0)>=1,'prim variant must instantiate SPX9+DPX9B'
    run(['nextpnr-himbaechel','--json','top.json','--write','pnr.json','--device','GW2A-LV18PG256C8/I7',
         '--vopt','family=GW2A-18','--vopt','cst=top.cst','--freq','27','--seed','1','--log','nextpnr.log'],'route.log')
    text=(dest/'nextpnr.log').read_text();routed=re.search(r'\bLUT4:\s+(\d+)',text)
    freq=re.findall(r'Max frequency for clock[^\n]*?:\s*([\d.]+)\s*MHz',text)
    audit_warnings(dest)
    assert routed and int(routed[1])<=15000 and freq and min(map(float,freq))>=27,'route/timing gate'
    from audit_build import audit
    audit(dest,cad)
    py=cad/'lib/python3.exe';py=py if py.exists() else cad/'bin/python.exe'
    run([str(py),str(cad/'bin/gowin_pack-script.py'),'-d','GW2A-18','-o','window_probe.fs','pnr.json'],'pack.log')
    (dest/'build_summary.json').write_text(json.dumps(dict(
        status='BUILD_PASS_NOT_BOARD',variant=a.variant,**cfg,lut=lut,ff=ff,bram=bram,dsp=dsp,
        routed_lut4=int(routed[1]),fmax_mhz=list(map(float,freq)),
        bitstream_sha256=hashlib.sha256((dest/'window_probe.fs').read_bytes()).hexdigest()),indent=2))
    print('BUILD PASS',dest,flush=True)

if __name__=='__main__':main()
