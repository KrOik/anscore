import tempfile,json,re
from pathlib import Path
from run_tests import HERE,SOURCES,execute,hashes
profiles=[(0,1),(33,1),(1,0),(1,33),(-1,1)];frozen=hashes()
for w,h in profiles:
 tb='''module tb;
 reg clk=0;always #5 clk=~clk;reg rst_n=0,start_valid=0;
 wire done_valid,done_error,m_valid,best_valid;wire[3:0]error_code;
 chamfer_match #(.WIDTH(W),.HEIGHT(H))dut(.clk(clk),.rst_n(rst_n),.ce(1'b1),.start_valid(start_valid),
 .cfg_template_width(4'd1),.cfg_template_height(4'd1),.t_valid(1'b0),.s_valid(1'b0),.m_valid(m_valid),.m_ready(1'b1),
 .done_valid(done_valid),.done_ready(1'b0),.done_error(done_error),.error_code(error_code),.best_valid(best_valid));
 initial begin @(negedge clk);rst_n=1;@(negedge clk);start_valid=1;@(negedge clk);start_valid=0;
 if(!done_valid||!done_error||error_code!=1||m_valid||best_valid)$fatal(1,"invalid geometry");$display("PASS");$finish;end endmodule'''
 for k,v in [('W',w),('H',h)]:tb=re.sub(r'\b'+k+r'\b',str(v),tb)
 with tempfile.TemporaryDirectory(prefix='chamfer_invalid_') as tmp:
  d=Path(tmp);(d/'tb.sv').write_text(tb)
  execute(['iverilog','-g2012','-s','tb','-o',d/'sim',*SOURCES,d/'tb.sv'],d,d/'compile.log')
  assert 'PASS' in execute(['vvp',d/'sim'],d,d/'run.log')
assert frozen==hashes()
(HERE/'invalid_parameters.json').write_text(json.dumps(dict(status='PASS',profiles=profiles,sources=frozen),indent=2)+'\n');print('PASS',profiles)
