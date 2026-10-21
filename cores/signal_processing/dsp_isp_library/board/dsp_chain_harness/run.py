"""Real UART simulation, negative tests, then strict noalu route/pack gates."""
import argparse, collections, datetime, hashlib, json, os, re, shutil, struct, subprocess
from pathlib import Path
from protocol import HERE,LIB,cases,make_packet,verify
ROOT=LIB.parents[1]

def main():
    p=argparse.ArgumentParser()
    p.add_argument('--dc-source',type=Path)
    p.add_argument('--dc-latency',type=int,choices=(1,2))
    p.add_argument('--statistics-source',type=Path)
    p.add_argument('--stats-latency',type=int)
    p.add_argument('--build',action='store_true')
    p.add_argument('--vector-json',type=Path,help='Original host-input replay; golden outputs are recomputed')
    a=p.parse_args()
    if a.dc_source and a.dc_latency is None:p.error('--dc-source requires explicit --dc-latency')
    if a.statistics_source and a.stats_latency is None:p.error('--statistics-source requires explicit --stats-latency')
    stats=(a.statistics_source or LIB/'dsp/statistics/rtl/statistics_stream.sv').resolve()
    stats_latency=a.stats_latency if a.stats_latency is not None else (17 if stats.name=='statistics_stream.sv' and 'dsp/statistics/rtl' in str(stats).replace('\\','/') else None)
    if stats_latency is None:p.error('--stats-latency required for non-production statistics source')
    if stats.name!='statistics_stream.sv' or not 1<=stats_latency<=17:p.error('statistics basename/latency')
    dc=(a.dc_source or LIB/'dsp/dc/rtl/dc_stream.sv').resolve()
    manifest=json.loads((LIB/'dsp/dc/ip_manifest.json').read_text())
    if a.dc_source is None and hashlib.sha256(dc.read_bytes()).hexdigest()!=manifest['source_sha256']:
        raise ValueError('Production DC manifest/source mismatch')
    latency=a.dc_latency or manifest['latency_cycles']
    if dc.name!='dc_stream.sv':p.error('DC source basename must be dc_stream.sv')
    dest=HERE/'evidence'/datetime.datetime.now().strftime('chain_%Y%m%d_%H%M%S_%f');dest.mkdir(parents=True)
    tool=ROOT/'tools/oss-cad-suite/oss-cad-suite';binpath=tool/'bin'
    env=os.environ.copy();env['PATH']=str(binpath)+os.pathsep+str(tool/'lib')+os.pathsep+env['PATH']
    rtl=[HERE/'dsp_chain_harness.v',HERE/'chain_ram.v',dc,stats,LIB/'chains/dc_statistics/dc_statistics_stream.v',ROOT/'cores/communication/primitives/src/uart_rx.v',ROOT/'cores/communication/primitives/src/uart_tx.v']
    sources=rtl+[HERE/'tb_chain.sv',HERE/'tb_fault.sv',HERE/'protocol.py',HERE/'audit_build.py',HERE/'run_board.py',Path(__file__),LIB/'dsp/dc/models/dc_reference.py',LIB/'dsp/statistics/models/reference.py']
    for src in sources:shutil.copy2(src,dest/src.name)
    shutil.copy2(LIB/'board/uart_injection_probe.cst',dest/'top.cst')
    (dest/'hashes.json').write_text(json.dumps({str(s):hashlib.sha256(s.read_bytes()).hexdigest() for s in sources},indent=2))
    (dest/'variant.json').write_text(json.dumps(dict(dc_source=str(dc),dc_latency=latency,statistics_source=str(stats),stats_latency=stats_latency,chain_latency=latency+stats_latency),indent=2))
    work=cases();stim='';negative=[]
    if a.vector_json:
        saved=json.loads(a.vector_json.read_text());saved=saved if isinstance(saved,list) else [saved]
        work=[(item.get('tag',i),item['config'],item['words'],item['stall']) for i,item in enumerate(saved)]
        if not work:raise ValueError('Empty replay')
        shutil.copy2(a.vector_json,dest/'host_replay.json')
    for tag,c,words,stall in work:
        packet=make_packet(tag,c,words,stall)
        stim+=f'{len(packet)} {20+17*len(words)}\n'+''.join(f'{b:02x}\n' for b in packet)
    for tag,c,n,stall,flags in [(0xBAD001,0,0,0,1),(0xBAD002,0,65,0,1),(0xBAD003,0,1,8,1),(0xBAD004,3,1,0,8),(0xBAD005,7<<22,1,0,8),(0xBAD006,1<<31,1,0,8)]:
        packet=b'DSC1'+struct.pack('<IIBB',tag,c,n,stall)+(b'\0\0' if flags==8 else b'')
        stim+=f'{len(packet)} 20\n'+''.join(f'{b:02x}\n' for b in packet)
        negative.append(b'DST1'+struct.pack('<IIBBBBI',tag,c,0,flags,0,0,0))
    (dest/'stim.txt').write_text(stim)
    def run(cmd,log):
        with (dest/log).open('w') as f:r=subprocess.run(cmd,cwd=dest,env=env,stdout=f,stderr=subprocess.STDOUT)
        if r.returncode:raise RuntimeError(f'{log} failed: {dest}')
    names=[s.name for s in rtl]
    for tb in ('tb_chain','tb_fault'):
        run([str(binpath/'iverilog.exe'),'-g2012','-Wall','-s',tb,'-o',tb+'.vvp',tb+'.sv']+names,tb+'_compile.log')
        run([str(binpath/'vvp.exe'),tb+'.vvp']+(['+stim=stim.txt','+trace=trace.txt'] if tb=='tb_chain' else []),tb+'.log')
    raw=bytes(int(x,16) for x in (dest/'trace.txt').read_text().splitlines());(dest/'raw.bin').write_bytes(raw)
    offset=0;results=[];mutations=0
    for tag,c,words,stall in work:
        size=20+17*len(words);report=raw[offset:offset+size];offset+=size
        results.append(verify(report,tag,c,words,stall,latency,stats_latency))
        for pos in (0,4,8,12,13,14,15,16,20,36,len(report)-1):
            bad=bytearray(report);bad[pos]^=1
            try:verify(bad,tag,c,words,stall,latency,stats_latency)
            except AssertionError:mutations+=1
            else:raise AssertionError('corrupted report accepted')
    for expected in negative:
        if raw[offset:offset+20]!=expected:raise AssertionError(('negative',raw[offset:offset+20],expected))
        offset+=20
    if offset!=len(raw):raise AssertionError('extra UART bytes')
    (dest/'simulation_summary.json').write_text(json.dumps(dict(status='PASS',dc_latency=latency,stats_latency=stats_latency,chain_latency=latency+stats_latency,blocks=results,invalid_packets=len(negative),mutations_rejected=mutations,faults='truncation/badstop/late-busy/watchdog PASS'),indent=2))
    print('UART SIM PASS',dest,flush=True)
    if not a.build:return
    (dest/'build.ys').write_text('read_verilog -sv '+' '.join(names)+'\nsynth_gowin -noalu -family gw2a -top dsp_chain_harness -json top.json\ncheck -assert\nstat\n')
    run([str(binpath/'yosys.exe'),'-Q','-l','yosys.log','build.ys'],'synth_console.log')
    net=json.loads((dest/'top.json').read_text());counts=collections.Counter(c['type'] for c in net['modules']['dsp_chain_harness']['cells'].values())
    lut=sum(v for k,v in counts.items() if re.fullmatch(r'LUT[1-4]|ALU',k));dsp=sum(v for k,v in counts.items() if k.startswith(('MULT','PADD','ALU54')))
    (dest/'synthesis_counts.json').write_text(json.dumps(dict(lut=lut,dsp=dsp,cells=counts),indent=2))
    if lut>15000 or dsp>4:raise AssertionError('resource gate')
    run([str(binpath/'nextpnr-himbaechel.exe'),'--json','top.json','--write','pnr.json','--device','GW2A-LV18PG256C8/I7','--vopt','family=GW2A-18','--vopt','cst=top.cst','--freq','27','--seed','1','--log','nextpnr.log'],'pnr_console.log')
    log=(dest/'nextpnr.log').read_text();routed=re.search(r'\bLUT4:\s+(\d+)',log);clocks=re.findall(r'Max frequency for clock[^\n]*?:\s*([\d.]+)\s*MHz',log)
    if not routed or int(routed[1])>15000 or not clocks or min(map(float,clocks))<27:raise AssertionError('route/timing gate')
    from audit_build import audit
    audit(dest,tool)
    run([str(tool/'lib/python3.exe'),str(binpath/'gowin_pack-script.py'),'-d','GW2A-18','-o','chain.fs','pnr.json'],'pack.log')
    (dest/'build_summary.json').write_text(json.dumps(dict(status='BUILD_PASS_NOT_BOARD',dc_latency=latency,stats_latency=stats_latency,chain_latency=latency+stats_latency,lut=lut,dsp=dsp,routed_lut4=int(routed[1]),fmax_mhz=list(map(float,clocks)),bitstream_sha256=hashlib.sha256((dest/'chain.fs').read_bytes()).hexdigest()),indent=2))
    print('BUILD PASS',dest)

if __name__=='__main__':main()
