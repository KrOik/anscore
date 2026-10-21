from pathlib import Path
import sys,tempfile,json
H=Path(__file__).resolve().parent;SV=H.parents[3]/'signal_video';sys.path.insert(0,str(SV));from run_downsample_tests import fixtures,execute
sources=[H/'cip_image_downsample.v',H/'img_geo_area_resample.v',H/'geo_serial_divider.v',SV.parent/'image/geometry/rtl/img_geo_crop_decimate.v',SV/'sim/tb_cip_image_downsample.v']
cases=[]
with tempfile.TemporaryDirectory(prefix='a48_geo_downsample_') as t:
 for bits,gray in [(1,1),(8,8),(12,12),(24,8),(32,16),(7,8),(24,0)]:
  label=f'w{bits}_g{gray}';p=Path(t)/label;p.mkdir();counts=fixtures(p,bits,gray);binary=p/'test.vvp'
  execute(['iverilog','-g2012','-s','tb_cip_image_downsample',f'-Ptb_cip_image_downsample.DW={bits}',f'-Ptb_cip_image_downsample.GB={gray}','-o',binary,*sources],H,H/f'downsample_{label}_compile.log')
  out=execute(['vvp',binary,f'+folder={p}',*[f'+{k}={counts[k]}' for k in ['commands','pixels','outputs']]],H,H/f'downsample_{label}_simulation.log');assert f'DOWNSAMPLE PASS width={bits}' in out;print(out.strip());cases.append(counts)
(H/'downsample_regression_summary.json').write_text(json.dumps({'status':'PASS','cases':cases},indent=2))
