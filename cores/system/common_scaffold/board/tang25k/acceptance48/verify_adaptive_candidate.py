from pathlib import Path
import sys,json,tempfile,shutil
HERE=Path(__file__).resolve().parent;COMMON=HERE.parents[2]
sys.path.insert(0,str(COMMON/'integration'));sys.path.insert(0,str(COMMON/'image/filters'))
from tooling import execute
from run_adaptive_tests import fixture
out=Path(sys.argv[1]).resolve();regdir=out/'adaptive_independent';regdir.mkdir(exist_ok=True)
bench=regdir/'tb_img_filter_adaptive_mean3x3.v';shutil.copy2(COMMON/'image/filters/sim'/bench.name,bench)
results=[]
with tempfile.TemporaryDirectory(prefix='a48_adaptive_') as tmp:
 for g,w in [(g,w) for g in (0,1) for w in (1,8,12,16)]:
  folder=Path(tmp);data=folder/'fixture.txt';n=fixture(data,w,g);binary=folder/'sim.vvp';label=f'g{g}w{w}'
  execute(['iverilog','-g2012','-s','tb_img_filter_adaptive_mean3x3',f'-Ptb_img_filter_adaptive_mean3x3.PIXEL_W={w}',f'-Ptb_img_filter_adaptive_mean3x3.GAUSSIAN={g}','-o',binary,out/'source/img_filter_adaptive_mean3x3.v',out/'source/img_filter_adaptive_gaussian3x3.v',bench],out,regdir/(label+'_compile.log'))
  text=execute(['vvp',binary,f'+fixture={data}'],out,regdir/(label+'_simulation.log'))
  kind='GAUSSIAN' if g else 'MEAN'
  if f'ADAPTIVE_{kind} PASS width={w} checks={n}' not in text:raise RuntimeError('missing pass')
  results.append(dict(gaussian=g,width=w,checks=n))
(regdir/'summary.json').write_text(json.dumps({'status':'PASS','cases':results},indent=2)+'\n')
print(json.dumps({'adaptive':'PASS','profiles':len(results),'checks':sum(x['checks'] for x in results)}))
