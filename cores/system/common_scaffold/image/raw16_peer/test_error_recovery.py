"""Independent narrow RAW16 marker/error recovery oracle, not a codec loopback."""
from pathlib import Path
import hashlib,json,tempfile,sys
HERE=Path(__file__).resolve().parent;OWNER=HERE.parent/'raw16_codec'
sys.path.insert(0,str(HERE.parents[1]/'integration'))
from tooling import execute
TB=r'''
`timescale 1ns/1ps
module tb;
reg clk=0;always #5 clk=~clk;reg rst_n=0,ce=1,sv=0,ss=0,se=0,mr=0,er=0;
reg[@IW@-1:0]sd=0;wire sr,mv,ms,me,pe,ev;wire[@OW@-1:0]md;wire[7:0]ec;wire[31:0]cnt;
@MODULE@ #(.BIG_ENDIAN(@BE@))d(clk,rst_n,ce,sd,sv,ss,se,sr,md,mv,ms,me,mr,pe,ev,er,ec,cnt);
task automatic token;input[15:0]data;input sof,eol;begin
 @(negedge clk);sd=data;ss=sof;se=eol;sv=1;
 @(posedge clk);while(!sr)@(posedge clk);
 @(negedge clk);sv=0;#1;
end endtask
task automatic err;input integer code,count;begin
 if(!ev||!pe||ec!=code||cnt!=count)$fatal(1,"error mismatch code%0d count%0d expected%0d/%0d",ec,cnt,code,count);
end endtask
initial begin
 repeat(4)@(negedge clk);rst_n=1;repeat(3)@(negedge clk);
 @BODY@
 $display("PASS independent RAW16 recovery mode=@MODE@ BE=@BE@");$finish;
end
initial begin #100000;$fatal(1,"recovery watchdog");end
endmodule
'''
UNPACK=r'''
 token('haa,0,0);err(4,1);if(mv)$fatal(1,"orphan byte emitted");
 token('hbb,1,1);err(4,2);if(mv)$fatal(1,"odd line emitted");
 ce=0;er=1;repeat(6)@(negedge clk);#1;err(4,2);if(sr)$fatal(1,"CE0 ready");
 ce=1;token('hcc,1,1);er=0;err(2,3);
 @(negedge clk);er=1;@(negedge clk);er=0;#1;if(ev||cnt!=3||!pe)$fatal(1,"error acknowledgment semantics");
 token('h34,1,0);if(mv)$fatal(1,"half pixel visible");
 token('h78,1,0);err(3,4);if(mv)$fatal(1,"midSOF emitted old partial");
 token('h56,0,1);
 if(!mv||md!=@PIXEL@||!ms||!me)$fatal(1,"same-token reanchor recovery pixel%h",md);
 ce=0;mr=1;repeat(8)@(negedge clk);#1;
 if(!mv||md!=@PIXEL@||!ms||!me||sr)$fatal(1,"held pixel CE0");
 ce=1;@(negedge clk);mr=0;#1;if(mv)$fatal(1,"output not consumed exactly once");
 // Test-only counter preload avoids billions of cycles; no owner source changes.
 @(negedge clk);d.error_count=32'hfffffffe;
 token('h11,1,1);if(cnt!=32'hffffffff)$fatal(1,"counter did not reach saturation");
 token('h22,1,1);if(cnt!=32'hffffffff)$fatal(1,"counter wrapped");
'''
PACK=r'''
 token('habcd,0,0);err(4,1);if(mv)$fatal(1,"unanchored pixel emitted");
 token('h1234,1,1);
 if(!mv||md!=@FIRST@||!ms||me)$fatal(1,"single-pixel frame first byte");
 ce=0;mr=1;repeat(7)@(negedge clk);#1;
 if(!mv||md!=@FIRST@||!ms||me||sr)$fatal(1,"pack held CE0");
 ce=1;@(negedge clk);mr=0;#1;
 if(!mv||md!=@SECOND@||ms||!me)$fatal(1,"single-pixel frame final byte");
 repeat(8)@(negedge clk);#1;if(md!=@SECOND@||!mv||!me)$fatal(1,"pack stalled final byte");
 mr=1;@(negedge clk);mr=0;#1;if(mv)$fatal(1,"pack output retained after consume");
 rst_n=0;@(negedge clk);rst_n=1;repeat(3)@(negedge clk);d.error_count=32'hfffffffe;
 token('h1,0,0);if(cnt!=32'hffffffff)$fatal(1,"counter saturation limit");
 token('h2,0,0);if(cnt!=32'hffffffff)$fatal(1,"counter wrapped");
'''
def main():
 freeze=json.loads((OWNER/'source_freeze.json').read_text(encoding='utf-8'));sha=lambda p:hashlib.sha256(p.read_bytes()).hexdigest();freeze_sha=sha(OWNER/'source_freeze.json');rows=[]
 for n,h in freeze.items():assert sha(OWNER/n)==h
 for mode in ('pack','unpack'):
  for be in (0,1):
   tb=TB;body=PACK if mode=='pack' else UNPACK
   args=dict(MODULE='raw16_'+mode,MODE=mode,BE=be,IW=16 if mode=='pack' else 8,OW=8 if mode=='pack' else 16,BODY=body,PIXEL="16'h7856" if be else "16'h5678",FIRST="8'h12" if be else "8'h34",SECOND="8'h34" if be else "8'h12")
   for _ in range(2):
    for k,v in args.items():tb=tb.replace('@'+k+'@',str(v))
   with tempfile.TemporaryDirectory(prefix='raw16_error_peer_') as tmp:
    p=Path(tmp);(p/'tb.sv').write_text(tb,encoding='utf-8')
    execute(['iverilog','-g2012','-s','tb','-o',p/'sim',OWNER/('raw16_'+mode+'.sv'),p/'tb.sv'],p,p/'compile.log')
    out=execute(['vvp',p/'sim'],p,p/'run.log');assert 'PASS independent RAW16' in out
    (HERE/(mode+'_'+str(be)+'.log')).write_text(out,encoding='utf-8');rows.append(dict(mode=mode,big_endian=be,output=out));print(out.strip(),flush=True)
 for n,h in freeze.items():assert sha(OWNER/n)==h
 assert freeze_sha==sha(OWNER/'source_freeze.json')
 (HERE/'recovery_evidence.json').write_text(json.dumps(dict(status='PASS',source_freeze_sha256=freeze_sha,owner_frozen_inputs=freeze,reviewer_script_sha256=sha(Path(__file__)),profiles=rows,scope='Independent narrow marker/error/CE recovery simulation; counter saturation uses explicit testbench register preload, not formal or board evidence.'),indent=2)+'\n',encoding='utf-8')
if __name__=='__main__':main()
