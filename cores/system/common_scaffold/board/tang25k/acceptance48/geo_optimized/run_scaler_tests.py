from pathlib import Path
import sys,importlib.util,json,hashlib,tempfile,shutil
H=Path(__file__).resolve().parent;SV=H.parents[3]/'signal_video';REPO=SV.parents[2];sys.path.insert(0,str(SV))
C=Path(sys.argv[1]).resolve() if len(sys.argv)>1 else H
LABEL=sys.argv[2] if len(sys.argv)>2 else 'v8_latencybound'
with tempfile.TemporaryDirectory(prefix='a48_scaler_sourcefreeze_') as t:
 root=Path(t);snap=root/'cores/system/common_scaffold/signal_video';(snap/'rtl').mkdir(parents=True);(snap/'sim').mkdir()
 source_lines=(SV.parent/'image/rtl_sources.f').read_text().splitlines();divider_line='cores/system/common_scaffold/image/geometry/rtl/geo_serial_divider.v'
 if divider_line not in source_lines:source_lines.append(divider_line)
 for line in source_lines:
  if not line.strip() or line.startswith('#'):continue
  dest=root/line;dest.parent.mkdir(parents=True,exist_ok=True)
  shutil.copy2(C/'geo_serial_divider.v' if dest.name=='geo_serial_divider.v' else REPO/line,dest)
 (snap.parent/'image/rtl_sources.f').write_text('\n'.join(source_lines)+'\n')
 for name in ['cip_image_bicubic_frame.v','cip_image_scaler.v']:
  shutil.copy2(C/name if (C/name).exists() else SV/'rtl'/name,snap/'rtl'/name)
 for name in ['tb_cip_image_scaler.v','tb_cip_image_bicubic_frame.v']:shutil.copy2(SV/'sim'/name,snap/'sim'/name)
 # Only watchdog bounds change for the exact18x4 multicycle multiply.
 bench=snap/'sim/tb_cip_image_bicubic_frame.v'
 bench.write_text(bench.read_text().replace('cycles>200000','cycles>4000000').replace('#100000000;','#2000000000;'))
 for script in ['run_scaler_tests.py','run_bicubic_tests.py']:
  spec=importlib.util.spec_from_file_location('original_'+script[:-3],SV/script);module=importlib.util.module_from_spec(spec);spec.loader.exec_module(module)
  original_execute=module.execute
  def execute(argv,cwd,log,timeout=1200):
   return original_execute(argv,cwd,log,timeout=timeout)
  module.execute=execute
  logdir=H/(LABEL+'_frozen_regression_'+script[4:-3]);logdir.mkdir(exist_ok=True);original_write=module.write_json
  def write(path,data):
   data['candidate_sources']={p.name:hashlib.sha256(p.read_bytes()).hexdigest() for p in [snap/'rtl/cip_image_bicubic_frame.v',root/divider_line]};original_write(path,data)
  module.HERE=snap;module.write_json=write;module.evidence_dir=lambda tag:logdir;module.main()
