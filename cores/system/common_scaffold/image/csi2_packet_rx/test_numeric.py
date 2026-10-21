"""Full 16-bit WC endpoint and invalid static parameter checks."""
from run_tests import HERE,RTL,simulate,good,case,header,ht,pt,execute
import hashlib,json,tempfile
from pathlib import Path
def main():
 payload=bytes((i*37+9)&255 for i in range(65535))
 rows=[simulate([good('full_word_count_65535',3,43,payload),good('zero_after_maximum',0,18,b'')],'numeric_maximum',65535),
       simulate([good('zero_only',2,16,b''),case('reject_one_above_zero_capacity',header(1,43,1),[],[],[pt(ht(1,43,1),code=5)],error=5)],'numeric_zero',0)]
 source_sha=hashlib.sha256(RTL.read_bytes()).hexdigest();invalid=[]
 for value in [-1,65536]:
  with tempfile.TemporaryDirectory(prefix='csi2_packet_numeric_') as temp:
   d=Path(temp);tb=f'''module tb;reg clk=0;always #5 clk=~clk;reg rst_n=0,ce=1,start_valid=0;
wire start_ready,done_valid,done_error;wire[7:0]error_code;
csi2_packet_rx #(.MAX_WORD_COUNT({value}))dut(.clk(clk),.rst_n(rst_n),.ce(ce),.start_valid(start_valid),.start_ready(start_ready),.cfg_check_sequence(1'b0),.abort(1'b0),.s_valid(1'b0),.s_data(8'd0),.s_last(1'b0),.h_ready(1'b1),.m_ready(1'b1),.p_ready(1'b1),.done_ready(1'b0),.done_valid(done_valid),.done_error(done_error),.error_code(error_code));
initial begin repeat(3)@(negedge clk);rst_n=1;start_valid=1;@(negedge clk);start_valid=0;repeat(3)@(negedge clk);
if(!done_valid||!done_error||error_code!=1||dut.s_ready||dut.p_valid||dut.h_valid||dut.m_valid)$fatal(1,"invalid parameter");
$display("CSI2 INVALID PARAM PASS {value}");$finish;end endmodule'''
   (d/'tb.sv').write_text(tb);name='numeric_invalid_'+str(value).replace('-','minus')
   execute(['iverilog','-g2012','-s','tb','-o',d/'sim.vvp',RTL,d/'tb.sv'],HERE,HERE/(name+'_compile.log'))
   out=execute(['vvp',d/'sim.vvp'],HERE,HERE/(name+'_simulation.log'));assert 'CSI2 INVALID PARAM PASS' in out;invalid.append(value)
 assert source_sha==hashlib.sha256(RTL.read_bytes()).hexdigest()
 (HERE/'numeric_evidence.json').write_text(json.dumps(dict(status='PASS',source_sha256=source_sha,profiles=rows,invalid_parameters=invalid),indent=2)+'\n')
 print('CSI2 numeric PASS max=65535 zero=0 invalid=-1,65536',flush=True)
if __name__=='__main__':main()
