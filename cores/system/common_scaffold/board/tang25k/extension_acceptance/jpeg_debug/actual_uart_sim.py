from pathlib import Path
import sys,tempfile
H=Path(__file__).resolve().parent;ORIGINAL=H.parent/'jpeg'
sys.path.insert(0,str(ORIGINAL))
from prepare import SOURCES,UART,SIM,execute
B=SIM.replace('.CLK_HZ(1000000),.BAUD(100000)','.CLK_HZ(50000000),.BAUD(115200)').replace('repeat(15)','repeat(651)').replace('repeat(10)','repeat(434)').replace('#50000000','#100000000')
with tempfile.TemporaryDirectory(prefix='jpeg_actual_baud_') as tmp:
 p=Path(tmp);(p/'tb.sv').write_text(B)
 execute(['iverilog','-g2012','-s','tb','-o',p/'sim',*SOURCES,UART,ORIGINAL/'jpeg_uart_25k.sv',p/'tb.sv'],p,H/'actual_uart_compile.log')
 out=execute(['vvp',p/'sim'],p,H/'actual_uart_simulation.log',timeout=240)
 actual=bytes(int(x,16) for x in (p/'uart.hex').read_text().split());assert actual==(ORIGINAL/'expected_uart.bin').read_bytes()
 print('PASS actual50MHz/115200 physical UART999bytes')
