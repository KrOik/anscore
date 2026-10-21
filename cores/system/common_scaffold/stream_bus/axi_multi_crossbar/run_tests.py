from pathlib import Path
import sys,json,tempfile,hashlib
H=Path(__file__).resolve().parent
sys.path.insert(0,str(H.parents[1]))
from integration.tooling import execute
from port_schema import PORT_SCHEMA as schema
def bench(m,t,w):
 s=f'module tb; localparam MASTERS={m},TARGETS={t},DATA_WIDTH={w},ADDR_WIDTH=32,ID_WIDTH=4; reg clk=0; always #5 clk=~clk; reg rst_n=0,ce=1; wire protocol_error;\n'
 pins=['.clk(clk)','.rst_n(rst_n)','.ce(ce)','.protocol_error(protocol_error)']; ins=[]
 for side,count in [('s','MASTERS'),('m','TARGETS')]:
  for name,(width,direction) in schema.items():
   inp=(direction=='f')==(side=='s'); n=f'{side}_axi_{name}'
   s+=f'{"reg" if inp else "wire"} [{count}*({width})-1:0] {n};\n'
   pins.append(f'.{n}({n})')
   if inp:ins.append(n+'=0;')
 s+='axi_multi_crossbar #(.MASTERS(MASTERS),.TARGETS(TARGETS),.DATA_WIDTH(DATA_WIDTH)) dut('+','.join(pins)+');\n'
 s+='initial begin '+''.join(ins)+' end\n'
 s+=(H/'tb_protocol_body.vh').read_text(encoding='utf-8')
 return s
results=[]
with tempfile.TemporaryDirectory(prefix='axi_xbar_test_') as td:
 p=Path(td)
 for m,t,w in [(2,2,32),(3,3,32),(4,4,64)]:
  tb=p/'tb.sv';tb.write_text(bench(m,t,w),encoding='utf-8');log=p/'c.log'
  execute(['iverilog','-g2012','-s','tb','-o',p/'sim',H/'axi_multi_crossbar.sv',tb],H,log)
  out=execute(['vvp',p/'sim'],H,p/'v.log')
  if 'PROTOCOL PASS' not in out:raise RuntimeError(out)
  results.append(dict(masters=m,targets=t,data_width=w,status='PASS',output=out.strip()));print(out.strip(),flush=True)
 for key,value in [('MASTERS',1),('MASTERS',5),('TARGETS',1),('TARGETS',5),('DATA_WIDTH',16),('DATA_WIDTH',128),('ADDR_WIDTH',24),('ID_WIDTH',0),('ID_WIDTH',9),('REGION_ADDR_BITS',7),('REGION_ADDR_BITS',29)]:
  tb=p/'invalid.sv';tb.write_text(f'module invalid; axi_multi_crossbar #(.{key}({value})) dut(); initial #10 $finish; endmodule',encoding='utf-8')
  try:execute(['iverilog','-g2012','-s','invalid','-o',p/'bad',H/'axi_multi_crossbar.sv',tb],H,p/'bad_compile.log')
  except RuntimeError:
   if (key,value)!=('ID_WIDTH',0):raise
   results.append(dict(parameter=key,value=value,status='PASS',rejection='elaboration zero-width indexed select'));continue
  try: execute(['vvp',p/'bad'],H,p/'bad_run.log')
  except RuntimeError:
   if 'invalid AXI crossbar parameters' not in (p/'bad_run.log').read_text(encoding='utf-8'):raise
  else:raise RuntimeError('invalid parameter accepted')
  results.append(dict(parameter=key,value=value,status='PASS'))
(H/'protocol_evidence.json').write_text(json.dumps(dict(rtl_sha256=hashlib.sha256((H/'axi_multi_crossbar.sv').read_bytes()).hexdigest(),profiles=results),indent=2)+'\n',encoding='utf-8')
