"""Reproducible isolated padded-window Gowin mapping; no P&R/board claim."""
import argparse,datetime,hashlib,json,os,pathlib,shutil,subprocess
from collections import Counter
HERE=pathlib.Path(__file__).resolve().parent
ROOT=HERE.parents[3]

def main():
    p=argparse.ArgumentParser();p.add_argument('--output',type=pathlib.Path);a=p.parse_args()
    out=a.output or HERE/'evidence'/('padding_synth_'+datetime.datetime.now().strftime('%Y%m%d_%H%M%S_%f'))
    out.mkdir(parents=True,exist_ok=False)
    sources=out/'sources';sources.mkdir()
    hashes={}
    for name in ('stream_window.v','stream_window_padded.v','synth_window.py'):
        src=HERE/name;shutil.copy2(src,sources/name)
        hashes[name]=hashlib.sha256(src.read_bytes()).hexdigest()
    (out/'source_sha256.json').write_text(json.dumps(hashes,indent=2))
    env=dict(os.environ);cad=ROOT/'tools/oss-cad-suite/oss-cad-suite'
    env['PATH']=str(cad/'bin')+os.pathsep+str(cad/'lib')+os.pathsep+env['PATH']
    yosys=shutil.which('yosys',path=env['PATH']) or 'yosys'
    results=[]
    configs=[(32,24,k,d,pad) for k in (3,5) for d in (8,10) for pad in (0,1)]
    configs += [(1,1,k,10,pad) for k in (3,5) for pad in (0,1)]
    for w,h,k,d,pad in configs:
        work=out/f'w{w}_h{h}_k{k}_d{d}_pad{pad}';work.mkdir()
        script=''.join(f'read_verilog "{(sources/name).resolve().as_posix()}"\n' for name in ('stream_window.v','stream_window_padded.v'))
        script+=f'chparam -set WIDTH {w} -set HEIGHT {h} -set K {k} -set DATA_WIDTH {d} -set PAD_MODE {pad} stream_window_padded\n'
        script+='synth_gowin -family gw2a -noalu -top stream_window_padded -json mapped.json\nstat\n'
        (work/'build.ys').write_text(script)
        cmd=[yosys,'-s','build.ys']
        run=subprocess.run(cmd,cwd=work,env=env,stdout=subprocess.PIPE,stderr=subprocess.STDOUT,text=True)
        (work/'synth.log').write_text('$ '+' '.join(cmd)+'\n'+run.stdout)
        assert run.returncode==0,run.stdout[-3000:]
        net=json.loads((work/'mapped.json').read_text())
        cells=Counter(c['type'] for c in net['modules']['stream_window_padded']['cells'].values())
        warnings=[line for line in run.stdout.splitlines() if 'Warning:' in line or 'ERROR:' in line]
        assert not any('LATCH' in typ.upper() for typ in cells),cells
        counts=dict(LUT1_4=sum(cells.get('LUT'+str(i),0) for i in range(1,5)),
                    LUT_MUX=sum(n for t,n in cells.items() if t.startswith('MUX') and 'LUT' in t),
                    FF=sum(n for t,n in cells.items() if t.startswith('DFF')),
                    BSRAM=sum(cells.get(t,0) for t in ('DPB','DPX9B','SP','SPX9','SDPB','SDPX9B','ROM','ROMX9')),
                    DSP=sum(n for t,n in cells.items() if t.startswith(('MULT','ALU54','PADD'))))
        result=dict(width=w,height=h,k=k,data_width=d,padding=pad,core_logic_counts=counts,
                    raw_cells=dict(cells),warnings=warnings,
                    status='SYNTHESIS PASS',scope='mapped synthesis; core counts exclude IO pads and constants',
                    timing='NOT RUN',board='NOT RUN')
        (work/'resources.json').write_text(json.dumps(result,indent=2))
        results.append(result);print(work.name,counts,flush=True)
    (out/'summary.json').write_text(json.dumps(results,indent=2))
    print('PASS',len(results),'configurations',out,flush=True)
if __name__=='__main__':main()
