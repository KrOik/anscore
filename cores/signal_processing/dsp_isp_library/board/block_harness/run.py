"""UART simulation then optional strict noalu synthesis/place/route/pack."""
import argparse,collections,datetime,hashlib,json,os,re,shutil,subprocess,struct
from pathlib import Path
from protocol import HERE,LIB,cases,make_packet,verify
ROOT=LIB.parents[1]

def main():
    p=argparse.ArgumentParser();p.add_argument('--core',choices=('dc','csc','identity'),default='dc');p.add_argument('--bits',type=int,choices=(8,10),default=8);p.add_argument('--mem',choices=('inferred','explicit'),default='inferred');p.add_argument('--dc-source',type=Path);p.add_argument('--csc-source',type=Path);p.add_argument('--latency',type=int);p.add_argument('--build',action='store_true');args=p.parse_args()
    if args.latency is None:
        if args.csc_source is not None:parser_error='Explicit --csc-source requires --latency';p.error(parser_error)
        if args.dc_source is not None:p.error('Explicit --dc-source requires --latency')
        args.latency=4 if args.core=='csc' else (json.loads((LIB/'dsp/dc/ip_manifest.json').read_text())['latency_cycles'] if args.core=='dc' else 1)
    core={'dc':0,'csc':1,'identity':2}[args.core];bits=args.bits
    mem=int(args.mem=='explicit')
    dest=HERE/'evidence'/(args.core+str(bits)+'_'+args.mem+'_'+datetime.datetime.now().strftime('%Y%m%d_%H%M%S_%f'));dest.mkdir(parents=True)
    binpath=ROOT/'tools/oss-cad-suite/oss-cad-suite/bin';env=os.environ.copy();env['PATH']=str(binpath)+os.pathsep+str(binpath.parent/'lib')+os.pathsep+env['PATH']
    dc_source=(args.dc_source or LIB/'dsp/dc/rtl/dc_stream.sv').resolve()
    csc_source=(args.csc_source or LIB/'isp/csc_stream.v').resolve()
    if dc_source.name!='dc_stream.sv' or csc_source.name!='csc_stream.v' or not 1<=args.latency<=16:raise ValueError('source basename/latency')
    sources=[HERE/'block_harness.v',HERE/'block_ram.v',HERE/'tb_block.sv',HERE/'tb_fault.sv',ROOT/'cores/communication/primitives/src/uart_rx.v',ROOT/'cores/communication/primitives/src/uart_tx.v',ROOT/'cores/image_processing/window/sim/gowin_bsram_sim.v',csc_source,LIB/'isp/csc_coeffs.vh',dc_source]
    (dest/'variant.json').write_text(json.dumps(dict(core=args.core,bits=bits,mem=args.mem,latency=args.latency,dc_source=str(dc_source),csc_source=str(csc_source)),indent=2))
    for src in sources:shutil.copy2(src,dest/src.name)
    for src in (HERE/'protocol.py',HERE/'run.py',LIB/'isp/csc_model.py',LIB/'dsp/dc/models/dc_reference.py'):
        shutil.copy2(src,dest/src.name)
    shutil.copy2(LIB/'board/uart_injection_probe.cst',dest/'top.cst')
    (dest/'hashes.json').write_text(json.dumps({str(f):hashlib.sha256(f.read_bytes()).hexdigest() for f in sources},indent=2))
    work=cases(core,bits);stim=''
    for tag,c,words,stall in work:
        packet=make_packet(tag,c,words,stall);stim+=f'{len(packet)} {20+len(words)*4}\n'+''.join(f'{b:02x}\n' for b in packet)
    negative=[]
    for tag,c,n,stall,flags in [(0xBAD00001,0,0,0,1),(0xBAD00002,0,65,0,1),(0xBAD00003,0,1,8,1),(0xBAD00004,12 if core else 3,1,0,8),(0xBAD00005,0x80000000,1,0,8)]:
        packet=b'BLK1'+struct.pack('<IIBB',tag,c,n,stall)+(b'\0'*4 if flags==8 else b'')
        stim+=f'{len(packet)} 20\n'+''.join(f'{b:02x}\n' for b in packet)
        negative.append(b'RES1'+struct.pack('<IIBBBBI',tag,c,0,flags,0,0,0))
    (dest/'stim.txt').write_text(stim)
    def run(cmd,log):
        with (dest/log).open('w') as f:r=subprocess.run(cmd,cwd=dest,env=env,stdout=f,stderr=subprocess.STDOUT)
        if r.returncode:raise RuntimeError(f'{log} failed, preserved {dest}')
    run([str(binpath/'iverilog.exe'),'-g2012','-Wall','-I.','-s','tb_block',f'-Ptb_block.CORE={core}',f'-Ptb_block.BITS={bits}',f'-Ptb_block.MEM_IMPL={mem}','-o','test.vvp','tb_block.sv','block_harness.v','block_ram.v','gowin_bsram_sim.v','uart_rx.v','uart_tx.v','csc_stream.v','dc_stream.sv'],'compile.log')
    run([str(binpath/'vvp.exe'),'test.vvp','+stim=stim.txt','+trace=trace.txt'],'simulation.log')
    raw=bytes(int(line,16) for line in (dest/'trace.txt').read_text().splitlines());(dest/'raw.bin').write_bytes(raw)
    results=[];offset=0
    for tag,c,words,stall in work:
        size=20+4*len(words);report=raw[offset:offset+size];results.append(verify(report,tag,c,words,core,bits,stall,latency=args.latency));offset+=size
        for pos in (0,4,8,12,13,14,15,16,20,len(report)-1):
            bad=bytearray(report);bad[pos]^=1
            try:verify(bad,tag,c,words,core,bits,stall,latency=args.latency)
            except AssertionError:pass
            else:raise AssertionError('corruption accepted')
    for expected in negative:
        if raw[offset:offset+20]!=expected:raise AssertionError(('negative response',raw[offset:offset+20],expected))
        offset+=20
    if offset!=len(raw):raise AssertionError('extra output')
    run([str(binpath/'iverilog.exe'),'-g2012','-I.','-s','tb_fault',f'-Ptb_fault.MEM_IMPL={mem}','-o','fault.vvp','tb_fault.sv','block_harness.v','block_ram.v','gowin_bsram_sim.v','uart_rx.v','uart_tx.v','csc_stream.v','dc_stream.sv'],'fault_compile.log')
    run([str(binpath/'vvp.exe'),'fault.vvp'],'fault.log')
    (dest/'simulation_summary.json').write_text(json.dumps(dict(status='PASS',core=args.core,bits=bits,latency=args.latency,blocks=results,negative_packets=len(negative),mutations_per_block=10,faults='truncated/badstop/late-busy/watchdog-capture PASS'),indent=2))
    print('UART SIM PASS',dest,flush=True)
    if not args.build:return
    (dest/'build.ys').write_text(f'read_verilog -sv -I. block_harness.v block_ram.v uart_rx.v uart_tx.v csc_stream.v dc_stream.sv\nchparam -set CORE {core} -set BITS {bits} -set MEM_IMPL {mem} block_harness\nsynth_gowin -noalu -family gw2a -top block_harness -json top.json\nstat\n')
    run([str(binpath/'yosys.exe'),'-Q','-l','yosys.log','build.ys'],'synth_console.log')
    net=json.loads((dest/'top.json').read_text());counts=collections.Counter(c['type'] for c in net['modules']['block_harness']['cells'].values())
    lut=sum(v for k,v in counts.items() if re.fullmatch(r'LUT[1-4]|ALU',k));dsp=sum(v for k,v in counts.items() if k.startswith(('MULT','PADD','ALU54')))
    (dest/'synthesis_counts.json').write_text(json.dumps(dict(lut=lut,dsp=dsp,cells=counts),indent=2))
    if lut>15000 or dsp>4:raise AssertionError('resource gate')
    run([str(binpath/'nextpnr-himbaechel.exe'),'--json','top.json','--write','pnr.json','--device','GW2A-LV18PG256C8/I7','--vopt','family=GW2A-18','--vopt','cst=top.cst','--freq','27','--seed','1','--log','nextpnr.log'],'pnr_console.log')
    log=(dest/'nextpnr.log').read_text();routed=re.search(r'\bLUT4:\s+(\d+)',log)
    clocks=re.findall(r'Max frequency for clock[^\n]*?:\s*([\d.]+)\s*MHz',log)
    if not routed or int(routed[1])>15000 or not clocks or min(map(float,clocks))<27:raise AssertionError('route/timing gate')
    python=binpath.parent/'lib/python3.exe'
    if not python.exists(): python=binpath/'python.exe'
    run([str(python),str(binpath/'gowin_pack-script.py'),'-d','GW2A-18','-o','block.fs','pnr.json'],'pack.log')
    (dest/'build_summary.json').write_text(json.dumps(dict(status='BUILD_PASS_NOT_BOARD',core=args.core,bits=bits,mem=args.mem,latency=args.latency,lut=lut,dsp=dsp,routed_lut4=int(routed[1]),fmax_mhz=list(map(float,clocks)),bitstream_sha256=hashlib.sha256((dest/'block.fs').read_bytes()).hexdigest()),indent=2))
    print('BUILD PASS',dest)

if __name__=='__main__':main()
