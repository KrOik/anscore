from run_tests import HERE,RTL,run,execute
from pathlib import Path
import hashlib,json,tempfile

def main():
 rows=[]
 rows.append(run('max_width',(32766,1,2,65540,1,0,1),32766,1))
 rows.append(run('max_lines',(2,32767,65535,12,32767,0,32767),2,32767))
 rows.append(run('max_line_bytes',(2,1,2,131070,1,0,1),2,1))
 for mw,mn in [(1,1),(32767,1),(2,0),(2,32768)]:
  with tempfile.TemporaryDirectory(prefix='bt656_tx_invalid_') as tmp:
   d=Path(tmp)
   tb=f"""module tb;reg clk=0;always #5 clk=~clk;reg rst_n=0;wire done_valid;wire[7:0]error_code;
   bt656_tx #(.MAX_WIDTH({mw}),.MAX_FIELD_LINES({mn}))dut(.clk(clk),.rst_n(rst_n),.ce(1'b1),.start_valid(1'b1),.abort(1'b0),.cfg_width(16'd2),.cfg_field_lines(16'd1),.cfg_total_lines(16'd2),.cfg_field1_start(16'd1),.cfg_active0_start(16'd0),.cfg_active1_start(16'd1),.cfg_line_bytes(17'd12),.s_valid(1'b0),.m_ready(1'b1),.done_ready(1'b0),.done_valid(done_valid),.error_code(error_code));
   initial begin repeat(3)@(negedge clk);rst_n=1;repeat(3)@(negedge clk);if(!done_valid||error_code!=1)$fatal(1,"invalid parameter");$display("PASS static invalid");$finish;end endmodule"""
   (d/'tb.sv').write_text(tb);name=f'invalid_{mw}_{mn}'
   execute(['iverilog','-g2012','-s','tb','-o',d/'sim',RTL,d/'tb.sv'],d,HERE/(name+'_compile.log'))
   out=execute(['vvp',d/'sim'],d,HERE/(name+'_simulation.log'));assert 'PASS' in out
 (HERE/'numeric_evidence.json').write_text(json.dumps(dict(status='PASS',source_sha256=hashlib.sha256(RTL.read_bytes()).hexdigest(),profiles=rows,invalid_static_profiles=4),indent=2)+'\n')
if __name__=='__main__':main()
