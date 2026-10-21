"""Real BRIEF RTL output is loaded as query and reference; no descriptor substitution."""
from pathlib import Path
import sys,tempfile,hashlib,json
sys.dont_write_bytecode=True
HERE=Path(__file__).resolve().parent
sys.path.insert(0,str(HERE.parents[1]))
from integration.tooling import execute
from test_descriptor_match import HEADER

def main():
 for d in (128,256):
  tb=HEADER.replace('module tb;',f'module tb;localparam D={d};')
  # Remove HEADER's main initial block; retain matcher declarations and tasks.
  tb=tb[:tb.index('initial begin @(negedge clk);')]
  tb+=r'''
reg pv=0,cv=0,spv=0,sof=0,eol=0,kv=0,br=0,bready=0;
reg [7:0] pi=0,sp=0;reg signed [7:0] ax=0,ay=0,bx=0,by=0;
wire pr,cr,cd,ce_cfg,spr,kr,brr,fa,bv,bi;wire [D-1:0] bd;wire [15:0] xx,yy,id;wire [3:0] bec;
reg [D-1:0] captured;integer k;
brief_descriptor #(.WIDTH(3),.HEIGHT(3),.BITS(8),.DESC_BITS(D),.RADIUS(1)) brief(
.clk(clk),.rst_n(rst_n),.ce(ce),.pattern_valid(pv),.pattern_ready(pr),.pattern_index(pi),.pattern_ax(ax),.pattern_ay(ay),.pattern_bx(bx),.pattern_by(by),
.cfg_valid(cv),.cfg_ready(cr),.cfg_done(cd),.cfg_error(ce_cfg),.s_pixel(sp),.s_valid(spv),.s_sof(sof),.s_eol(eol),.s_ready(spr),
.kp_valid(kv),.kp_ready(kr),.kp_x(16'd1),.kp_y(16'd1),.kp_id(16'h1234),.release_valid(br),.release_ready(brr),.frame_available(fa),
.m_descriptor(bd),.m_invalid(bi),.m_valid(bv),.m_x(xx),.m_y(yy),.m_id(id),.m_ready(bready),.error_code(bec));
initial begin @(negedge clk);tick;rst_n=1;tick;
 for(k=0;k<D;k=k+1)begin
  pv=1;pi=k;ax=(k%2)?1:-1;ay=0;bx=0;by=0;while(!pr)tick;tick;pv=0;
 end
 cv=1;tick;cv=0;while(!cd)tick;if(ce_cfg)$fatal(1,"BRIEF config");
 for(k=0;k<9;k=k+1)begin
  while(!spr)tick;sp=k*13;sof=k==0;eol=k%3==2;spv=1;tick;spv=0;
 end
 while(!kr)tick;kv=1;tick;kv=0;while(!bv)tick;
 if(bi||{id,yy,xx}!==48'h123400010001)$fatal(1,"BRIEF metadata");
 captured=bd;
 // Ramp and alternating offsets imply even comparison bits 1, odd bits 0.
 for(k=0;k<D;k=k+1)if(bd[k] !== (k%2==0))$fatal(1,"BRIEF comparison oracle");
 load(0,bd,{id,yy,xx},bi);
 load(1,~captured,48'h000a000b000c,0);
 load(1,captured,48'h000d000e000f,0);
 bready=1;tick;bready=0;
 launch(D,1,1,4,5);
 expect_result(0,1,48'h123400010001,48'h000d000e000f,0,D,0);
 release_frame;$display("PASS BRIEF matcher chain");$finish;end
endmodule
'''
  with tempfile.TemporaryDirectory(prefix='brief_match_chain_') as td:
   w=Path(td);(w/'tb.sv').write_text(tb)
   execute(['iverilog','-g2012','-s','tb','-o',w/'sim.vvp',HERE/'descriptor_match.sv',HERE.parent/'brief/brief_descriptor.sv',w/'tb.sv'],w,HERE/f'chain_compile_{d}.log')
   output=execute(['vvp',w/'sim.vvp'],w,HERE/f'chain_{d}.log')
   assert 'PASS BRIEF matcher chain' in output
 e={'status':'PASS','descriptor_bits':[128,256],'mapping':'metadata={id,y,x}; descriptor bit i unchanged; invalid propagated','brief_sha256':hashlib.sha256((HERE.parent/'brief/brief_descriptor.sv').read_bytes()).hexdigest()}
 (HERE/'chain_evidence.json').write_text(json.dumps(e,indent=2)+'\n');print(e)
if __name__=='__main__':main()
