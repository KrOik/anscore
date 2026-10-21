"""Directed arithmetic-domain limits, separate from geometrically realized frames."""
import tempfile,json
from pathlib import Path
from run_tests import HERE,SOURCES,execute,hashes
rows=[]
for count in range(1,65):
 for total in [1922*count,1922*count-1,count//2]:rows.append((count,total,(total*256+count//2)//count))
calls='\n'.join(f'check({c},{s},{q});' for c,s,q in rows)
tb='''module tb;
 reg clk=0;always #5 clk=~clk;reg rst_n=0;
 wire m_valid;wire[31:0]m_score,m_sum_squared;
 chamfer_match #(.WIDTH(32),.HEIGHT(32))dut(.clk(clk),.rst_n(rst_n),.ce(1'b1),.start_valid(1'b0),.t_valid(1'b0),.s_valid(1'b0),.m_ready(1'b0),.done_ready(1'b0),.m_valid(m_valid),.m_score(m_score),.m_sum_squared(m_sum_squared));
 task check;input integer c,s,q;begin
 @(negedge clk);dut.state=9;dut.edge_count=c;dut.sum_squared=s;dut.image_invalid=0;dut.wx=0;dut.wy=0;dut.tw=1;dut.th=1;dut.m_valid=0;
 @(negedge clk);while(!m_valid)@(negedge clk);
 if(m_score!==q||m_sum_squared!==s)$fatal(1,"numeric bound c=%d s=%d got=%d expected=%d",c,s,m_score,q);
 end endtask
 initial begin @(negedge clk);rst_n=1;CALLS $display("PASS numeric192");$finish;end endmodule'''.replace('CALLS',calls)
frozen=hashes()
with tempfile.TemporaryDirectory(prefix='chamfer_numeric_') as tmp:
 d=Path(tmp);(d/'tb.sv').write_text(tb)
 execute(['iverilog','-g2012','-s','tb','-o',d/'sim',*SOURCES,d/'tb.sv'],d,d/'compile.log')
 assert 'PASS numeric192' in execute(['vvp',d/'sim'],d,d/'run.log')
assert frozen==hashes()
(HERE/'numeric_result.json').write_text(json.dumps(dict(status='PASS',arithmetic_domain_cases=len(rows),maximum_sum=123008,maximum_q8_score=492032,not_claimed_geometric_frames=True,sources=frozen),indent=2)+'\n');print('PASS',len(rows))
