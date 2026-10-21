import tempfile,json,re
from pathlib import Path
from run_tests import HERE,SOURCES,execute,hashes
profiles=[(0,1,1),(33,1,1),(1,0,1),(1,33,1),(-1,1,1),(8,8,0),(8,8,7),(8,8,91)]
frozen=hashes()
for w,h,step in profiles:
 tb='''module tb;
 reg clk=0;always #5 clk=~clk;reg rst_n=0,ce=1,start_valid=0;
 wire done_valid,done_error,m_valid;wire[7:0]error_code;wire[4:0]detected_candidates;wire[9:0]emitted_segments;
 hough_segment_pipeline #(.WIDTH(W),.HEIGHT(H),.THETA_STEP(S))dut(.clk(clk),.rst_n(rst_n),.ce(ce),.start_valid(start_valid),
 .cfg_threshold(11'd1),.cfg_max_candidates(5'd1),.cfg_theta_nms(7'd0),.cfg_rho_nms(7'd0),.cfg_rho_tolerance(2'd0),
 .cfg_max_gap(6'd0),.cfg_min_length(6'd1),.cfg_min_support(6'd2),.cfg_max_segments(6'd1),
 .s_valid(1'b0),.s_edge(1'b0),.s_sof(1'b0),.s_eol(1'b0),.s_last(1'b0),.m_valid(m_valid),.m_ready(1'b1),
 .done_valid(done_valid),.done_ready(1'b0),.done_error(done_error),.error_code(error_code),.detected_candidates(detected_candidates),.emitted_segments(emitted_segments));
 initial begin @(negedge clk);rst_n=1;@(negedge clk);start_valid=1;@(negedge clk);start_valid=0;
 if(!done_valid||!done_error||error_code!=1||m_valid||detected_candidates||emitted_segments)$fatal(1,"invalid dimensions");$display("PASS");$finish;end endmodule'''
 for k,v in [('W',w),('H',h),('S',step)]:tb=re.sub(r'\b'+k+r'\b',str(v),tb)
 with tempfile.TemporaryDirectory(prefix='pipeline_invalid_') as tmp:
  d=Path(tmp);(d/'tb.sv').write_text(tb);(d/'trig.mem').write_bytes((HERE/'trig.mem').read_bytes())
  execute(['iverilog','-g2012','-s','tb','-o',d/'sim',*SOURCES,d/'tb.sv'],d,d/'compile.log')
  assert 'PASS' in execute(['vvp',d/'sim'],d,d/'run.log')
assert frozen==hashes()
(HERE/'invalid_parameters.json').write_text(json.dumps(dict(status='PASS',profiles=profiles,sources=frozen),indent=2)+'\n');print('PASS',profiles)
