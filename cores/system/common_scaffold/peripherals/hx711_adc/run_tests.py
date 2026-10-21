from pathlib import Path
import sys,tempfile,json,hashlib
H=Path(__file__).resolve().parent
sys.path.insert(0,str(H.parents[1]))
from integration.tooling import execute
rows=[]
with tempfile.TemporaryDirectory(prefix='hx711_test_') as td:
 p=Path(td)
 for hz,hi,lo,depth in [(1000000,1000,1000,2),(10000000,200,200,3),(50000000,1000,1000,4),(250000000,200,200,16),(10000000,49000,1000,7)]:
  execute(['iverilog','-g2012','-s','tb',f'-Ptb.HZ={hz}',f'-Ptb.HIGH_NS={hi}',f'-Ptb.LOW_NS={lo}',f'-Ptb.DEPTH={depth}','-o',p/'sim',H/'hx711_adc.sv',H/'hx711_device_model.v',H/'tb_hx711_adc.sv'],H,p/'c.log')
  out=execute(['vvp',p/'sim'],H,p/'r.log');assert 'HX711 PASS' in out
  print(out.strip(),flush=True);rows.append(dict(hz=hz,high_ns=hi,low_ns=lo,depth=depth,status='PASS',output=out))
 for key,value in [('CLOCK_HZ',999999),('CLOCK_HZ',250000001),('SCK_HIGH_NS',199),('SCK_HIGH_NS',50000),('SCK_LOW_NS',199),('SCK_LOW_NS',1000001),('READY_GUARD_NS',99),('READY_GUARD_NS',1000001),('READY_TIMEOUT_US',0),('POWERDOWN_US',60),('POWERDOWN_US',1001),('WAKE_US',0),('WAKE_US',1000001),('FIFO_DEPTH',1),('FIFO_DEPTH',17)]:
  (p/'invalid.sv').write_text(f'module invalid;hx711_adc #(.{key}({value}))dut();initial #10 $finish;endmodule',encoding='utf-8')
  execute(['iverilog','-g2012','-s','invalid','-o',p/'bad',H/'hx711_adc.sv',p/'invalid.sv'],H,p/'ic.log')
  try:execute(['vvp',p/'bad'],H,p/'ir.log')
  except RuntimeError:
   if 'invalid HX711 parameters' not in (p/'ir.log').read_text(encoding='utf-8'):raise
  else:raise RuntimeError('invalid parameter accepted')
  rows.append(dict(parameter=key,value=value,status='PASS'))
 (p/'invalid.sv').write_text('module invalid;hx711_adc #(.CLOCK_HZ(250000000),.READY_TIMEOUT_US(20000000))dut();initial #10 $finish;endmodule',encoding='utf-8')
 execute(['iverilog','-g2012','-s','invalid','-o',p/'bad',H/'hx711_adc.sv',p/'invalid.sv'],H,p/'ic.log')
 try:execute(['vvp',p/'bad'],H,p/'ir.log')
 except RuntimeError:
  if 'invalid HX711 parameters' not in (p/'ir.log').read_text(encoding='utf-8'):raise
 else:raise RuntimeError('32bit timeout overflow accepted')
 rows.append(dict(parameter='timeout_cycle_overflow',status='PASS'))
(H/'simulation_evidence.json').write_text(json.dumps(dict(status='PASS',inputs={n:hashlib.sha256((H/n).read_bytes()).hexdigest() for n in ['hx711_adc.sv','hx711_device_model.v','tb_hx711_adc.sv','run_tests.py']},profiles=rows),indent=2)+'\n',encoding='utf-8')
