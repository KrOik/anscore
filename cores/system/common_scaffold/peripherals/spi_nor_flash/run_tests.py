from pathlib import Path
import sys,tempfile,json,hashlib
H=Path(__file__).resolve().parent
sys.path.insert(0,str(H.parents[1]))
from integration.tooling import execute
rows=[]
with tempfile.TemporaryDirectory(prefix='nor_test_') as td:
 p=Path(td)
 for mode,div,high in [(0,1,1),(3,1,1),(0,2,4),(3,3,4),(0,7,5),(3,7,5),(0,1,32),(3,2,32)]:
  execute(['iverilog','-g2012','-s','tb',f'-Ptb.MODE={mode}',f'-Ptb.DIV={div}',f'-Ptb.HIGH={high}','-o',p/'sim',H/'spi_nor_flash.sv',H/'nor_device_model.v',H/'tb_spi_nor_flash.sv'],H,p/'c.log')
  out=execute(['vvp',p/'sim'],H,p/'r.log');assert 'NOR PASS' in out
  rows.append(dict(mode=mode,divider=div,cs_high=high,status='PASS',output=out));print(out.strip(),flush=True)
 for key,value in [('CLOCK_DIV',0),('CLOCK_DIV',65536),('SPI_MODE',1),('SPI_MODE',2),('CS_HIGH_CYCLES',0),('CS_HIGH_CYCLES',65536),('HOST_TIMEOUT',0),('POLL_LIMIT',0)]:
  (p/'invalid.sv').write_text(f'module invalid;spi_nor_flash #(.{key}({value}))dut();initial #10 $finish;endmodule',encoding='utf-8')
  execute(['iverilog','-g2012','-s','invalid','-o',p/'bad',H/'spi_nor_flash.sv',p/'invalid.sv'],H,p/'ic.log')
  try:execute(['vvp',p/'bad'],H,p/'ir.log')
  except RuntimeError:
   if 'invalid NOR parameters' not in (p/'ir.log').read_text(encoding='utf-8'):raise
  else:raise RuntimeError('invalid parameters accepted')
  rows.append(dict(parameter=key,value=value,status='PASS'))
(H/'simulation_evidence.json').write_text(json.dumps(dict(status='PASS',source_sha256={n:hashlib.sha256((H/n).read_bytes()).hexdigest() for n in ['spi_nor_flash.sv','nor_device_model.v','tb_spi_nor_flash.sv','run_tests.py']},profiles=rows),indent=2)+'\n',encoding='utf-8')
