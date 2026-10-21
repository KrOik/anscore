"""Independent Python bit_count oracle; temporary simulation products auto-cleaned."""
from pathlib import Path
import sys,random,tempfile,json,hashlib
sys.dont_write_bytecode=True
HERE=Path(__file__).resolve().parent
sys.path.insert(0,str(HERE.parents[1]))
from integration.tooling import execute

HEADER=r'''
module tb;
reg clk=0;always #5 clk=~clk;
reg rst_n=0,ce=1,lv=0,lr=0,li=0,sv=0,rv=0,mr=0;
reg [D-1:0] ld=0;reg [47:0] lm=0;
reg [8:0] md=256,mg=0;reg re=0;reg [15:0] rn=4,rd=5;
wire lready,sready,rready,mv,done,err;wire [3:0] ec,reason;
wire [15:0] qc,rc,qi,ri;wire [47:0] qm,rm;wire [8:0] best,second;
descriptor_match #(.DESC_BITS(D),.CAPACITY(8)) dut(
.clk(clk),.rst_n(rst_n),.ce(ce),.load_valid(lv),.load_reference(lr),.load_descriptor(ld),.load_metadata(lm),.load_invalid(li),.load_ready(lready),
.start_valid(sv),.start_ready(sready),.max_distance(md),.min_gap(mg),.ratio_enable(re),.ratio_num(rn),.ratio_den(rd),
.release_valid(rv),.release_ready(rready),.query_count(qc),.reference_count(rc),.m_valid(mv),.m_ready(mr),
.m_query_index(qi),.m_reference_index(ri),.m_query_metadata(qm),.m_reference_metadata(rm),.m_best(best),.m_second(second),.m_reason(reason),.done(done),.error(err),.error_code(ec));
task tick;begin @(posedge clk);#1;@(negedge clk);end endtask
task load(input refsel,input [D-1:0] word,input [47:0] meta,input invalid);begin
 while(!lready)tick;lv=1;lr=refsel;ld=word;lm=meta;li=invalid;tick;lv=0;
end endtask
task launch(input [8:0] limit,input [8:0] gap,input ratio,input [15:0] num,den);begin
 md=limit;mg=gap;re=ratio;rn=num;rd=den;sv=1;tick;sv=0;
 // Mutate all live configuration while active: results must use snapshot.
 md=0;mg=511;re=1;rn=0;rd=0;
end endtask
task expect_result(input [15:0] eq,er,input [47:0] emq,emr,input [8:0] eb,es,input [3:0] why);reg [150:0] held;integer stalls;reg [31:0] counts;begin
 counts={qc,rc};stalls=0;lv=1;sv=1;rv=1;
 while(!mv)begin ce=stalls%5!=1;tick;stalls=stalls+1;if(lready||sready||rready||{qc,rc}!==counts)$fatal(1,"busy transaction isolation");end
 lv=0;sv=0;rv=0;ce=1;
 if({qi,ri,qm,rm,best,second,reason} !== {eq,er,emq,emr,eb,es,why})begin
 $display("actual q=%d r=%d qm=%h rm=%h b=%d s=%d reason=%h expected q=%d r=%d qm=%h rm=%h b=%d s=%d reason=%h",qi,ri,qm,rm,best,second,reason,eq,er,emq,emr,eb,es,why);$fatal(1,"oracle mismatch");end
 held={mv,qi,ri,qm,rm,best,second,reason};repeat(3)begin tick;if({mv,qi,ri,qm,rm,best,second,reason}!==held)$fatal(1,"backpressure");end
 ce=0;mr=1;repeat(3)begin tick;if({mv,qi,ri,qm,rm,best,second,reason}!==held)$fatal(1,"CE freeze");if(lready||sready||rready)$fatal(1,"CE ready");end
 ce=1;tick;mr=0;
end endtask
task release_frame;begin while(!rready)tick;rv=1;tick;rv=0;if(qc||rc)$fatal(1,"release counts");end endtask
initial begin #20000000;$fatal(1,"timeout");end
initial begin @(negedge clk);tick;if(lready||sready||rready)$fatal(1,"reset ready");rst_n=1;tick;
'''

def oracle(q,refs,limit,gap,re,num,den):
 ranked=sorted(((q[0]^r[0]).bit_count(),i,r[1]) for i,r in enumerate(refs) if not r[2])
 best,idx,meta=ranked[0] if ranked else (511,65535,0)
 second=ranked[1][0] if len(ranked)>1 else 511
 reason=int(q[2]) | (int(not ranked)<<1) | (int(best>limit)<<2)
 ambiguous=(gap!=0 and (len(ranked)<2 or second-best<gap)) or (re and (len(ranked)<2 or best*den>=second*num))
 return idx,meta,best,second,reason|(int(ambiguous)<<3)

def cases(d):
 rng=random.Random(812+d);mask=(1<<d)-1
 result=[]
 for refs in ([],[(0,11,False)],[(0,11,False),(mask,22,False)],[(0,11,False),(0,22,False)],[(mask,11,True)]):
  for cfg in ((d,0,False,4,5),(d,1,True,4,5),(0,0,True,0,1)):
   result.append(([(0,101,False),(mask,202,False),(mask>>1,303,True)],refs,cfg))
 # Exact ratio boundary 2/4: strict '<' must reject equality, allow 3/4.
 for num in (1,2,3):result.append(([(0,99,False)],[(3,1,False),(15,2,False)],(d,2,True,num,4)))
 result.append(([(0,2**48-1,False)],[(mask,0,False),(mask>>1,1,False)],(d,0,True,65535,65535)))
 for n in range(65):
  queries=[(rng.getrandbits(d),rng.getrandbits(48),rng.random()<.1) for _ in range(rng.randrange(1,9))]
  refs=[(rng.getrandbits(d),rng.getrandbits(48),rng.random()<.15) for _ in range(rng.randrange(9))]
  result.append((queries,refs,(rng.randrange(d+1),rng.randrange(6),bool(n%2),rng.randrange(6),rng.randrange(1,6))))
 return result

def main():
 counts=[]
 for d in (128,256):
  lines=[f'localparam D={d};'] # localparam must be inside module
  tb=HEADER.replace('module tb;','module tb;\n'+lines[0]);n=0
  for queries,refs,cfg in cases(d):
   for refsel,items in ((0,queries),(1,refs)):
    for word,meta,invalid in items:tb+=f"load(1'b{refsel},{d}'h{word:x},48'h{meta:x},1'b{int(invalid)});\n"
   tb+=f"launch(9'd{cfg[0]},9'd{cfg[1]},1'b{int(cfg[2])},16'd{cfg[3]},16'd{cfg[4]});\n"
   for i,q in enumerate(queries):
    idx,meta,b,s,why=oracle(q,refs,*cfg);n+=1
    tb+=f"expect_result(16'd{i},16'd{idx},48'h{q[1]:x},48'h{meta:x},9'd{b},9'd{s},4'd{why});\n"
   tb+='release_frame;\n'
  tb+=r'''
 // Capacity overflow must not overwrite the accepted table or change count.
 repeat(8)load(0,0,0,0);load(0,1,1,0);if(!err||ec!=1||qc!=8)$fatal(1,"overflow");
 // Bad ratio request rejected, transaction remains loadable.
 re=1;rd=0;sv=1;tick;sv=0;if(!err||ec!=2||!sready)$fatal(1,"ratio config error");
 // Reset cancels loaded state; no outputs or retained counts.
 ce=0;rst_n=0;tick;if(mv||qc||rc||lready)$fatal(1,"reset");rst_n=1;ce=1;tick;
 launch(256,0,0,0,1);if(!done||!rready||mv)$fatal(1,"empty query set");release_frame;
 // Reset abort during computation, then abort a backpressured result.
 load(0,0,9,0);load(1,0,7,0);launch(256,0,0,0,1);tick;
 rst_n=0;tick;rst_n=1;tick;if(qc||rc||mv||!lready)$fatal(1,"active abort");
 load(0,0,9,0);load(1,0,7,0);launch(256,0,0,0,1);while(!mv)tick;
 rst_n=0;tick;rst_n=1;tick;if(qc||rc||mv||!lready)$fatal(1,"output abort");
 $display("PASS matcher");$finish;end
endmodule
'''
  with tempfile.TemporaryDirectory(prefix='descriptor_match_') as td:
   work=Path(td);(work/'tb.sv').write_text(tb)
   execute(['iverilog','-g2012','-s','tb','-o',work/'sim.vvp',HERE/'descriptor_match.sv',work/'tb.sv'],work,HERE/f'compile_{d}.log')
   output=execute(['vvp',work/'sim.vvp'],work,HERE/f'test_{d}.log')
   assert 'PASS matcher' in output
  counts.append({'descriptor_bits':d,'transactions':len(cases(d)),'queries':n,'status':'PASS'})
 print(counts)
 (HERE/'evidence.json').write_text(json.dumps({'tests':counts,'rtl_sha256':hashlib.sha256((HERE/'descriptor_match.sv').read_bytes()).hexdigest(),'board_validated':False},indent=2)+'\n')
 import test_brief_chain
 test_brief_chain.main()
if __name__=='__main__':main()
