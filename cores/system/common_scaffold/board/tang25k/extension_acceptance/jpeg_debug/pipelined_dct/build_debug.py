from prepare_debug import *
import shutil

def main():
 gate=json.loads((H/'simulation_gate.json').read_text());assert gate['status']=='SIMULATION_PASS_NOT_BOARD'
 assert all(sha(Path(k))==v for k,v in gate['files'].items())
 board=H.parents[2];sys.path.insert(0,str(board/'acceptance48'));import build_case
 chipdb=ROOT/'scratch/bram_timing_db_20261017/GW5A-25A_patched.bin'
 inputs={str(p.resolve()):sha(p) for p in [*SOURCES,UART,TOP,H/'prepare_debug.py',H/'build_debug.py',ORIGINAL/'pixels.hex',ORIGINAL/'expected_uart.bin',chipdb,board/'acceptance48/build_case.py',board/'resume_candidate_route_official.py']}
 (H/'build_input_sha256.json').write_text(json.dumps(dict(status='BUILD_IN_PROGRESS',files=inputs,before=inputs),indent=2)+'\n')
 with tempfile.TemporaryDirectory(prefix='jpeg_diag_build_') as tmp:
  p=Path(tmp)
  for src in [*SOURCES,UART,TOP]:shutil.copy2(src,p/src.name)
  build_case.route.device_flow.write_cst(p)
  (p/'expected_uart.txt').write_text((ORIGINAL/'expected_uart.bin').read_bytes().hex()+'\n')
  spec=dict(top='jpeg_debug_uart_25k',sources=[src.name for src in [*SOURCES,UART,TOP]])
  (p/'case.json').write_text(json.dumps(spec,indent=2)+'\n')
  frozen={src.name:sha(src) for src in p.iterdir() if src.is_file()}
  (p/'build_status.json').write_text(json.dumps(dict(status='SIMULATION_PASS',simulation='PASS',source_sha256=frozen),indent=2)+'\n')
  try:
   rc=build_case.build(p,'jpeg_diag',chipdb,no_lutram=True)
  finally:
   for src in p.iterdir():
    if src.is_file() and (src.suffix in ('.log','.fs','.cst','.ys') or src.suffix=='.json' and src.name not in ('top25k.json','pnr25k_jpeg_diag.json')):
     # Large routed/synthesized netlists stay in the automatically cleaned scratch directory.
     if src.stat().st_size<10000000:shutil.copy2(src,H/src.name)
  if rc:raise RuntimeError(f'route returned {rc}')
 assert all(sha(Path(k))==v for k,v in inputs.items())
 (H/'build_input_sha256.json').write_text(json.dumps(dict(status='PASS_BUILD_INPUT_STABLE',files=inputs,before=inputs,after=inputs,route_runtime='existing pinned official open-source plus corrected chipdb'),indent=2)+'\n')
 print('JPEG diagnostic candidate built; no board operation')
if __name__=='__main__':main()
