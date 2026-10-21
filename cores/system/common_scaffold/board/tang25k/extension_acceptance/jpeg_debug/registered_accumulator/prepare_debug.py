from pathlib import Path
import sys,tempfile,json,hashlib
H=Path(__file__).resolve().parent;ORIGINAL=H.parents[1]/'jpeg';sys.path.insert(0,str(ORIGINAL))
from prepare import SOURCES,UART,SIM,execute,ROOT
REPLACE={'jpeg_baseline_symbols.v':'jpeg_baseline_symbols_fast.v','dct8x8_serial.sv':'dct8x8_serial_diag.sv','jpeg_quant_zigzag.sv':'jpeg_quant_zigzag_diag.sv','img_raster_blocks.v':'img_raster_blocks_diag.v','jpeg_grayscale_scan.sv':'jpeg_grayscale_scan_diag.sv','jpeg_gray_encoder.sv':'jpeg_gray_encoder_diag.sv'}
SOURCES=[H/REPLACE[x.name] if x.name in REPLACE else x for x in SOURCES]
TOP=H/'jpeg_debug_uart_25k.sv'
def sha(p):return hashlib.sha256(p.read_bytes()).hexdigest()
def main():
 source_sha={str(p.resolve()):sha(p) for p in [*SOURCES,UART,TOP]}
 base=SIM.replace('jpeg_uart_25k','jpeg_debug_uart_25k')
 actual=base.replace('.CLK_HZ(1000000),.BAUD(100000)','.CLK_HZ(50000000),.BAUD(115200)').replace('repeat(15)','repeat(651)').replace('repeat(10)','repeat(434)').replace('#50000000','#100000000')
 diag=base.replace('if(count!=999)','if(count!=49)').replace('wait(done)','wait(dut.diag_index==49);wait(!dut.txbusy)').replace('initial begin #50000000;', 'initial begin wait(dut.rst_n);@(negedge clk);dut.state=9;end\ninitial begin #50000000;')
 with tempfile.TemporaryDirectory(prefix='jpeg_diag_sim_') as tmp:
  p=Path(tmp)
  for label,tb in [('healthy_actual_baud',actual),('forced_diagnostic',diag)]:
   (p/'tb.sv').write_text(tb)
   execute(['iverilog','-g2012','-s','tb','-o',p/'sim',*SOURCES,UART,TOP,p/'tb.sv'],p,H/f'{label}_compile.log')
   execute(['vvp',p/'sim'],p,H/f'{label}_simulation.log',timeout=240)
   data=bytes(int(x,16) for x in (p/'uart.hex').read_text().split())
   if label=='healthy_actual_baud':assert data==(ORIGINAL/'expected_uart.bin').read_bytes()
   else:
    assert len(data)==49 and data.startswith(b'\r\nJDBG ') and data.endswith(b'\r\n');int(data[7:47],16)
    (H/'forced_diagnostic.txt').write_bytes(data)
 assert all(sha(Path(k))==v for k,v in source_sha.items())
 (H/'simulation_gate.json').write_text(json.dumps(dict(status='SIMULATION_PASS_NOT_BOARD',files=source_sha,expected_uart_sha256=sha(ORIGINAL/'expected_uart.bin'),healthy_50MHz_115200_bytes=999,forced_diagnostic_bytes=49),indent=2)+'\n')
 print('PASS diag healthy999 actualbaud and forced49-byte snapshot')
if __name__=='__main__':main()
