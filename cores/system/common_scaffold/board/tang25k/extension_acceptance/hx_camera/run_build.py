"""Build only: never opens JTAG or UART. Freezes simulation/build common inputs."""
from pathlib import Path
import sys,json,hashlib,tempfile,shutil
H=Path(__file__).resolve().parent;P=H.parents[3];ROOT=P.parents[1]
sys.path.insert(0,str(P/'integration'));from tooling import execute
FLOW=ROOT/'cores/signal_processing/dsp_isp_library/board/tang25k';sys.path.insert(0,str(FLOW));import device_flow
SOURCE=[P/'peripherals/hx711_adc/hx711_adc.sv',P/'peripherals/camera_register_sequencer/camera_register_sequencer.sv',P/'peripherals/i2c_eeprom/i2c_eeprom_phy.sv',H/'hx_camera_acceptance.sv']
def sha(p):return hashlib.sha256(p.read_bytes()).hexdigest()
def main():
 dest=H/'build';dest.mkdir(exist_ok=True)
 if (dest/'top25k.json').exists():raise RuntimeError('existing build preserved')
 original={str(p.relative_to(ROOT)).replace('\\','/'):sha(p) for p in SOURCE}
 for p in SOURCE:shutil.copy2(p,dest/p.name);assert sha(dest/p.name)==sha(p)
 shutil.copy2(H/'expected_uart.txt',dest/'expected_uart.txt');device_flow.write_cst(dest)
 copied={p.name:sha(dest/p.name) for p in SOURCE};copied.update({n:sha(dest/n) for n in ['expected_uart.txt','tang25k.cst']})
 frozen=dict(status='FROZEN',production_sources=original,build_sources=copied,testbench_sha256=sha(H/'tb_hx_camera_acceptance.sv'),runner_sha256=sha(Path(__file__)))
 (dest/'build_input_sha256.json').write_text(json.dumps(frozen,indent=2)+'\n',encoding='utf-8')
 with tempfile.TemporaryDirectory(prefix='hx_camera_board_sim_') as tmp:
  w=Path(tmp)
  execute(['iverilog','-g2012','-s','tb','-o',w/'sim',*[dest/p.name for p in SOURCE],H/'tb_hx_camera_acceptance.sv'],w,dest/'simulation_compile.log')
  out=execute(['vvp',w/'sim'],w,dest/'simulation.log');assert 'PASS UART_DECODE HX_CAMERA' in out
 summary=device_flow.build(dest,top='hx_camera_acceptance',rtl=[p.name for p in SOURCE],gate=dict(lut4=15000,dff=18400,bsram=44,mult12=4))
 for n,d in copied.items():assert sha(dest/n)==d,n
 assert original=={str(p.relative_to(ROOT)).replace('\\','/'):sha(p) for p in SOURCE}
 final=dict(status='BUILD_PASS_NOT_BOARD',build_summary_sha256=sha(dest/'build_25k_summary.json'),build_input_sha256=sha(dest/'build_input_sha256.json'),simulation_sha256=sha(dest/'simulation.log'),expected_uart='PASS HX_CAMERA N=3 C=2\r\n',board_tested=False,scope='HX711 3 physical serial24bit words/nextmode and camera I2C16+SCCB8 WRITE+maskedVERIFY using synthesizable on-FPGA digital slaves; no external peripherals')
 (dest/'acceptance_manifest.json').write_text(json.dumps(final,indent=2)+'\n',encoding='utf-8');print(json.dumps(summary))
if __name__=='__main__':main()
