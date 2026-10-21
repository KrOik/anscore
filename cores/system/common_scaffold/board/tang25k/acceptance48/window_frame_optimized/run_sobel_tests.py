from pathlib import Path
import sys,tempfile,json,argparse
H=Path(__file__).resolve().parent;SV=H.parents[3]/'signal_video';sys.path.insert(0,str(SV));from run_edge_tests import fixtures,execute
sources=list((H.parent/'cases/sobel_v1/source').glob('*.v'));sources=[p for p in sources if p.name not in ['acceptance48_top.v','acceptance48_driver.v','cip_image_window_filter_frame.v']]+[H/'cip_image_window_filter_frame.v',SV/'rtl/cip_image_prewitt.v',SV/'rtl/cip_image_laplacian.v',SV/'sim/tb_cip_image_edge.v']
ap=argparse.ArgumentParser();ap.add_argument("--operation",type=int,choices=[0,1,2],default=0);op=ap.parse_args().operation
cases=[]
with tempfile.TemporaryDirectory(prefix='a48_sobel_reset_') as t:
 for bits,shift in [(w,s) for w in [1,8,16,24,32] for s in [0,2]]+[(8,12)]:
  label=f'op{op}_w{bits}_s{shift}';p=Path(t)/label;p.mkdir();counts=fixtures(p,bits,op,shift);binary=p/'test.vvp'
  execute(['iverilog','-g2012','-s','tb_cip_image_edge',f'-Ptb_cip_image_edge.DW={bits}',f'-Ptb_cip_image_edge.OP={op}',f'-Ptb_cip_image_edge.SHIFT={shift}','-o',binary,*sources],H,H/f'sobel_{label}_compile.log')
  out=execute(['vvp',binary,f'+folder={p}',*[f'+{k}={counts[k]}' for k in ['commands','inputs','outputs']]],H,H/f'sobel_{label}_simulation.log');assert f'EDGE_ADAPTER PASS width={bits} operation={op} shift={shift}' in out;print(out.strip());cases.append({'width':bits,'shift':shift,**counts})
(H/f'edge_op{op}_regression_summary.json').write_text(json.dumps({'status':'PASS','cases':cases},indent=2))
