from prepare import *
import shutil

def main():
 gate=json.loads((H/'simulation_gate.json').read_text());assert gate['status']=='SIMULATION_PASS_NOT_BOARD'
 assert all(sha(ROOT/k)==v for k,v in gate['sources'].items())
 assert sha(H/'expected_uart.bin')==gate['uart_sha256']
 sys.path.insert(0,str(ROOT/'cores/signal_processing/dsp_isp_library/board/tang25k'))
 import device_flow
 original_run=device_flow.run
 def board_run(dest,argv,log,timeout=900):
  if argv[0]=='yosys':
   ys=Path(dest)/'build25k.ys';ys.write_text(ys.read_text().replace('synth_gowin ','synth_gowin -nolutram -nodsp '))
  return original_run(dest,argv,log,timeout=timeout)
 device_flow.run=board_run
 inputs={str(p.resolve()):sha(p) for p in [*SOURCES,UART,H/'jpeg_uart_25k.sv',H/'pixels.hex',H/'prepare.py',H/'build.py',ROOT/'cores/signal_processing/dsp_isp_library/board/tang25k/device_flow.py']}
 (H/'build_input_sha256.json').write_text(json.dumps(dict(files=inputs,before=inputs,status='BUILD_IN_PROGRESS',synthesis_options='synth_gowin -nolutram -nodsp -noalu -family gw5a'),indent=2)+'\n')
 with tempfile.TemporaryDirectory(prefix='jpeg_board_build_') as tmp:
  p=Path(tmp)
  for src in [*SOURCES,UART,H/'jpeg_uart_25k.sv']:shutil.copy2(src,p/src.name)
  try:
   summary=device_flow.build(p,top='jpeg_uart_25k',rtl=[x.name for x in [*SOURCES,UART,H/'jpeg_uart_25k.sv']],params={'CLK_HZ':50000000,'BAUD':115200,'BOOT_CYCLES':50000000},synth_timeout=900,pnr_timeout=900)
  finally:
   for src in p.iterdir():
    if src.is_file() and (src.suffix in ('.log','.fs','.cst','.ys') or src.name=='build_25k_summary.json'):shutil.copy2(src,H/src.name)
  print(summary)
 assert all(sha(ROOT/k)==v for k,v in gate['sources'].items())
 assert all(sha(Path(k))==v for k,v in inputs.items())
 (H/'build_input_sha256.json').write_text(json.dumps(dict(files=inputs,before=inputs,after=inputs,status='PASS_BUILD_INPUT_STABLE',synthesis_options='synth_gowin -nolutram -nodsp -noalu -family gw5a'),indent=2)+'\n')
if __name__=='__main__':main()
