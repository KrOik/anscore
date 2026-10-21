import tempfile,json,re,hashlib
from pathlib import Path
from run_tests import HERE,execute
profiles=[(0,1),(33,1),(1,0),(1,33)]
for w,h in profiles:
 tb='''module tb;
 reg clk=0;always #5 clk=~clk;reg rst_n=0,ce=1,start_valid=0;
 wire start_ready,done_valid,done_error,m_valid;wire[3:0]error_code;
 hough_segments #(.WIDTH(W),.HEIGHT(H))dut(.clk(clk),.rst_n(rst_n),.ce(ce),.start_valid(start_valid),.start_ready(start_ready),
 .cfg_theta(8'd0),.cfg_rho(8'sd0),.cfg_rho_tolerance(2'd0),.cfg_max_gap(6'd0),.cfg_min_length(6'd1),.cfg_min_support(6'd2),.cfg_max_segments(6'd1),
 .s_valid(1'b0),.s_edge(1'b0),.s_sof(1'b0),.s_eol(1'b0),.s_last(1'b0),.m_valid(m_valid),.m_ready(1'b1),.done_valid(done_valid),.done_ready(1'b0),.done_error(done_error),.error_code(error_code));
 initial begin @(negedge clk);rst_n=1;@(negedge clk);start_valid=1;@(negedge clk);start_valid=0;
 if(!done_valid||!done_error||error_code!=1||m_valid)$fatal(1,"invalid parameter");$display("PASS");$finish;end endmodule'''
 for key,value in [('W',w),('H',h)]:tb=re.sub(r'\b'+key+r'\b',str(value),tb)
 with tempfile.TemporaryDirectory(prefix='segment_invalid_') as tmp:
  d=Path(tmp);(d/'tb.sv').write_text(tb);(d/'trig.mem').write_bytes((HERE/'trig.mem').read_bytes())
  execute(['iverilog','-g2012','-s','tb','-o',d/'sim',HERE/'hough_segments.sv',d/'tb.sv'],d,d/'compile.log')
  assert 'PASS' in execute(['vvp',d/'sim'],d,d/'run.log')
(HERE/'invalid_parameters.json').write_text(json.dumps(dict(status='PASS',profiles=profiles,rtl_sha256=hashlib.sha256((HERE/'hough_segments.sv').read_bytes()).hexdigest()),indent=2)+'\n');print('PASS',profiles)
