from pathlib import Path
import random,tempfile,sys,json
HERE=Path(__file__).resolve().parent;COMMON=HERE.parents[2];sys.path.insert(0,str(COMMON/'integration'));from tooling import execute
case=Path(sys.argv[1]).resolve();rng=random.Random(0xF051);N=2048
with tempfile.TemporaryDirectory(prefix='fusion_helper_stream_') as temp:
 folder=Path(temp);vectors=[]
 for i in range(N):
  a=rng.getrandbits(24);b=rng.getrandbits(24);w=[0,1,127,128,255,256,rng.randrange(257)][i%7];use=i%3!=0;err=0 if i%19 else 128;tag=rng.getrandbits(16);frame=rng.getrandbits(16);sof=i%31==0;eol=i%17==0
  out=0 if err else a if not use else sum((((((a>>k)&255)*(256-w)+((b>>k)&255)*w+128)>>8)&255)<<k for k in [0,8,16])
  vectors.append(a|(b<<24)|(w<<48)|(use<<57)|(sof<<58)|(eol<<59)|(tag<<60)|(frame<<76)|(err<<92)|(out<<100))
 (folder/'vectors.hex').write_text(''.join(f'{v:031x}\n' for v in vectors).replace('\\n','\n'))
 bench=r"""module tb;reg clk=0;always #5 clk=~clk;reg rst=0;integer sent=0,received=0,cycles=0,epoch;reg ce=0,mr=0;reg [123:0] data[0:2047];wire [123:0] v=data[sent<2048?sent:0];wire sr,mv,ms,me;wire [23:0] md;wire [15:0] mt,mf;wire [7:0] mer;reg blocked=0;reg [65:0] previous;wire [65:0] allout={md,ms,me,mt,mf,mer};
img_mf_rgb_blend_partial_pipe dut(.clk(clk),.rst_n(rst),.clk_en(ce),.s_valid(sent<2048),.s_ready(sr),.s_base(v[23:0]),.s_aux(v[47:24]),.s_weight(v[56:48]),.s_use_blend(v[57]),.s_sof(v[58]),.s_eol(v[59]),.s_tag(v[75:60]),.s_frameid(v[91:76]),.s_error(v[99:92]),.m_valid(mv),.m_ready(mr),.m_data(md),.m_sof(ms),.m_eol(me),.m_tag(mt),.m_frameid(mf),.m_error(mer));
always @(negedge clk)begin ce=(cycles%13!=3 && cycles%13!=4);mr=!(cycles%17>=5 && cycles%17<=9);end
always @(posedge clk)if(rst)begin
 cycles<=cycles+1;
 if(blocked && allout!==previous)$fatal(1,"hold stability");
 blocked<=mv && (!ce || !mr);previous<=allout;
 if(ce && sent<2048 && sr)sent<=sent+1;
 if(ce && mv && mr)begin
  if(received>=2048 || md!==data[received][123:100] || ms!==data[received][58] || me!==data[received][59] || mt!==data[received][75:60] || mf!==data[received][91:76] || mer!==data[received][99:92])$fatal(1,"stream mismatch %0d",received);
  received<=received+1;
 end
 if(cycles>200000)$fatal(1,"timeout sent=%0d received=%0d sr=%b mv=%b",sent,received,sr,mv);
end
initial begin $readmemh("vectors.hex",data);repeat(2)@(negedge clk);
 for(epoch=0;epoch<2;epoch=epoch+1)begin rst=0;repeat(3)@(negedge clk);sent=0;received=0;cycles=0;blocked=0;rst=1;wait(received==2048);@(negedge clk);end
 rst=0;repeat(3)@(negedge clk);$display("FUSION_HELPER_STREAM PASS records=4096 sidebands CE stall reset");$finish;end
endmodule"""
 (folder/'tb.v').write_text(bench)
 execute(['iverilog','-g2012','-s','tb','-o',folder/'sim.vvp',case/'source/img_mf_rgb_blend_partial_pipe.v',folder/'tb.v'],folder,case/'helper_stream_compile.log')
 result=execute(['vvp',folder/'sim.vvp'],folder,case/'helper_stream_simulation.log');print(result)
 (case/'helper_stream_summary.json').write_text(json.dumps({'status':'PASS','records':4096,'seed':0xF051,'scope':'independent whole-product oracle, mixed bypass/errors/weights, tags/frame IDs/markers, CE/output stalls, two reset/replay epochs'})+'\n')
