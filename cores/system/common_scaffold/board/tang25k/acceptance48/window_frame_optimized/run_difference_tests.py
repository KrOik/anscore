from pathlib import Path
import sys,tempfile,json
H=Path(__file__).resolve().parent;SV=H.parents[3]/'signal_video';sys.path.insert(0,str(SV));from run_frame_difference_tests import fixtures,execute
cases=[]
with tempfile.TemporaryDirectory(prefix='a48_diff_pipeline_') as t:
 for bits in [1,8,16,24,32]:
  p=Path(t)/str(bits);p.mkdir();counts=fixtures(p,bits);binary=p/'test.vvp'
  execute(['iverilog','-g2012','-s','tb_cip_image_frame_difference',f'-Ptb_cip_image_frame_difference.DW={bits}','-o',binary,H/'cip_image_frame_difference.v',SV/'sim/tb_cip_image_frame_difference.v'],H,H/f'difference_w{bits}_compile.log')
  out=execute(['vvp',binary,f'+folder={p}',*[f'+{k}={v}' for k,v in counts.items()]],H,H/f'difference_w{bits}_simulation.log');assert f'FRAME_DIFFERENCE PASS width={bits}' in out;print(out.strip());cases.append({'width':bits,**counts})
(H/'difference_regression_summary.json').write_text(json.dumps({'status':'PASS','cases':cases},indent=2))
