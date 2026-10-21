"""Bit-exact comparison with actual pinned ProjectF RTL, temporary copy only."""
from run_tests import HERE,SOURCES,encoder_vectors,execute
from pathlib import Path
import json,hashlib,tempfile,subprocess,re
TB=r"""module tb;
localparam N=@N@;reg clk=0;always #5 clk=~clk;reg rst_n=0;reg[10:0]token=0;
wire[9:0]actual,reference_;wire valid_,ready_;wire signed[5:0]rd;
tmds_encoder dut(.clk(clk),.rst_n(rst_n),.ce(1'b1),.s_data(token[7:0]),.s_de(token[10]),.s_control(token[9:8]),.s_valid(1'b1),.s_ready(ready_),.m_symbol(actual),.m_valid(valid_),.m_ready(1'b1),.running_disparity(rd));
tmds_encoder_dvi reference_encoder(.i_clk(clk),.i_rst(!rst_n),.i_data(token[7:0]),.i_de(token[10]),.i_ctrl(token[9:8]),.o_tmds(reference_));
reg[10:0]inputs[0:N-1];integer i;
initial begin $readmemh("inputs.hex",inputs);repeat(3)@(negedge clk);rst_n=1;
for(i=0;i<N;i=i+1)begin token=inputs[i];@(posedge clk);#1;if(!valid_||actual!==reference_)$fatal(1,"ProjectF mismatch %d got %h ref %h",i,actual,reference_);@(negedge clk);end
$display("PASS TMDS actual pinned ProjectF reference tokens=%0d",N);$finish;end endmodule"""
def main():
 hashes={p.name:hashlib.sha256(p.read_bytes()).hexdigest() for p in SOURCES};reference=json.loads((HERE/'references.json').read_text())['sources'][0]
 downloaded=subprocess.check_output(['curl.exe','-fsSL','--ssl-revoke-best-effort','--connect-timeout','10','--max-time','30',reference['url']]);assert hashlib.sha256(downloaded).hexdigest()==reference['sha256']
 # Remove diagnostic $display statements only, to keep regression evidence small.
 temporary_reference=re.sub(r'^\s*\$display\([^\n]*\);\s*$','',downloaded.decode(),flags=re.M)
 values,_=encoder_vectors()
 with tempfile.TemporaryDirectory(prefix='tmds_projectf_') as tmp:
  d=Path(tmp);(d/'ref.v').write_text(temporary_reference);(d/'inputs.hex').write_text(''.join(f'{v:x}\n' for v in values));(d/'tb.sv').write_text(TB.replace('@N@',str(len(values))))
  execute(['iverilog','-g2012','-s','tb','-o',d/'sim',SOURCES[0],d/'ref.v',d/'tb.sv'],d,HERE/'reference_compile.log');out=execute(['vvp',d/'sim'],d,HERE/'reference_simulation.log',timeout=180);assert 'PASS TMDS' in out;print(out)
 assert hashes=={p.name:hashlib.sha256(p.read_bytes()).hexdigest() for p in SOURCES}
 (HERE/'reference_evidence.json').write_text(json.dumps(dict(status='PASS',sources=hashes,reference_url=reference['url'],reference_sha256=reference['sha256'],reference_temp_change='Diagnostic $display lines removed only; no functional statement changed.',tokens=len(values),scope='Actual ProjectF independent Verilog implementation, bit-exact 256byte x all reachable RD witnesses plus long data, all4controls. Download/code/simulator removed with TemporaryDirectory.'),indent=2)+'\n')
if __name__=='__main__':main()
