"""Isolated sorter and complete window+sorter Gowin mapping, no timing claim."""
import concurrent.futures,datetime,hashlib,itertools,json,os,shutil,subprocess
from collections import Counter
from test_median import HERE,LIB,ROOT
def main():
 out=HERE/'evidence'/('synth_'+datetime.datetime.now().strftime('%Y%m%d_%H%M%S_%f'));out.mkdir(parents=True);src=out/'sources';src.mkdir()
 files=[HERE/'median_network.v',HERE/'median_stream.v',LIB/'infra/window/stream_window.v',LIB/'infra/window/stream_window_padded.v',HERE/'synth_median.py']
 for f in files:shutil.copy2(f,src/f.name)
 (out/'hashes.json').write_text(json.dumps({f.name:hashlib.sha256(f.read_bytes()).hexdigest() for f in files},indent=2))
 env=dict(os.environ);cad=ROOT/'tools/oss-cad-suite/oss-cad-suite';env['PATH']=str(cad/'bin')+os.pathsep+str(cad/'lib')+os.pathsep+env['PATH']
 configs=[('median_network',k,d,None) for k,d in itertools.product((3,5),(8,10))]+[('median_stream',k,d,p) for k,d,p in itertools.product((3,5),(8,10),(0,1))]
 def one(config):
  top,k,d,pad=config;case=out/f'{top}_k{k}_d{d}_pad{pad}';case.mkdir()
  script=''.join(f'read_verilog "{(src/f.name).resolve().as_posix()}"\n' for f in files if f.suffix=='.v')
  script+=f'chparam -set K {k} -set BITS {d} '+(f'-set WIDTH 32 -set HEIGHT 24 -set PAD_MODE {pad} ' if pad is not None else '')+top+'\n'
  script+=f'synth_gowin -noalu -family gw2a -top {top} -json mapped.json\nstat\n';(case/'build.ys').write_text(script)
  with (case/'synth.log').open('w') as log:r=subprocess.run([str(cad/'bin/yosys.exe'),'-s','build.ys'],cwd=case,env=env,stdout=log,stderr=subprocess.STDOUT)
  assert r.returncode==0,case
  net=json.loads((case/'mapped.json').read_text());cells=Counter(c['type'] for c in net['modules'][top]['cells'].values());assert not any('LATCH' in t.upper() for t in cells)
  row=dict(top=top,k=k,bits=d,pad=pad,width=32 if pad is not None else None,height=24 if pad is not None else None,LUT1_4=sum(cells.get('LUT'+str(i),0) for i in range(1,5)),FF=sum(n for t,n in cells.items() if t.startswith('DFF')),BSRAM=sum(cells.get(t,0) for t in ('DPX9B','SPX9','SDPX9B','DPB','SP','SDPB')),DSP=sum(n for t,n in cells.items() if t.startswith(('MULT','PADD','ALU54'))),raw_cells=dict(cells),status='SYNTHESIS_PASS_ONLY',timing='NOT_RUN',board='NOT_RUN')
  assert row['LUT1_4']<=15000 and row['DSP']<=4,row
  (case/'resources.json').write_text(json.dumps(row,indent=2));print('PASS',case.name,row['LUT1_4'],row['FF'],row['BSRAM'],row['DSP'],flush=True);return row
 with concurrent.futures.ThreadPoolExecutor(max_workers=2) as pool:results=list(pool.map(one,configs))
 (out/'summary.json').write_text(json.dumps(dict(status='PASS',results=results),indent=2));print(out)
if __name__=='__main__':main()
