from pathlib import Path
import hashlib,json,random,sys,tempfile
HERE=Path(__file__).resolve().parent
sys.path.insert(0,str(HERE.parents[1]/'integration'))
from tooling import execute
SOURCES=[HERE/'video_stream_to_axis.sv',HERE/'axis_to_video_stream.sv']
def hashes():return {p.name:hashlib.sha256(p.read_bytes()).hexdigest() for p in SOURCES}
TB=r'''module tb;
localparam W=@W@,H=@H@,DW=@DW@,N=W*H,F=4;
reg clk=0;always #5 clk=~clk;
reg rst_n=0,ce=1,start_valid=0,abort=0;reg[15:0]cfg_width=W,cfg_height=H;
reg[DW-1:0]s_pixel;reg s_valid=0,s_sof=0,s_eol=0,s_last=0,m_ready=0,done_ready=0;
wire er,dr,s_ready,av,ar,au,al,m_valid,m_sof,m_eol,m_last,ed,dd,ee,de;
wire[7:0]ec,dc;wire[DW-1:0]ad,m_pixel;
video_stream_to_axis #(.WIDTH(W),.HEIGHT(H),.DATA_WIDTH(DW))enc(.clk(clk),.rst_n(rst_n),.ce(ce),.start_valid(start_valid),.start_ready(er),.cfg_width(cfg_width),.cfg_height(cfg_height),.abort(abort),.s_pixel(s_pixel),.s_valid(s_valid),.s_sof(s_sof),.s_eol(s_eol),.s_last(s_last),.s_ready(s_ready),.m_axis_tdata(ad),.m_axis_tvalid(av),.m_axis_tready(ar),.m_axis_tuser(au),.m_axis_tlast(al),.done_valid(ed),.done_ready(done_ready),.frame_error(ee),.error_code(ec));
axis_to_video_stream #(.WIDTH(W),.HEIGHT(H),.DATA_WIDTH(DW))dec(.clk(clk),.rst_n(rst_n),.ce(ce),.start_valid(start_valid),.start_ready(dr),.cfg_width(cfg_width),.cfg_height(cfg_height),.abort(abort),.s_axis_tdata(ad),.s_axis_tvalid(av),.s_axis_tready(ar),.s_axis_tuser(au),.s_axis_tlast(al),.m_pixel(m_pixel),.m_valid(m_valid),.m_ready(m_ready),.m_sof(m_sof),.m_eol(m_eol),.m_last(m_last),.done_valid(dd),.done_ready(done_ready),.frame_error(de),.error_code(dc));
reg[DW-1:0]pixels[0:F*N-1];integer f,i,got=0,ax=0,offhand=0,cyc=0;reg take,ah=0,ph=0;reg[DW+1:0]at;reg[DW+2:0]pt;reg[31:0]rng=123917;
task tick;begin @(negedge clk);#1;rng=rng^(rng<<13);rng=rng^(rng>>17);rng=rng^(rng<<5);ce=rng[0]|rng[2];m_ready=rng[1];end endtask
always @(posedge clk)if(rst_n)begin
cyc=cyc+1;if(cyc>1000000)$fatal(1,"timeout");
if(ah&&(!av||{ad,au,al}!==at))$fatal(1,"AXI hold");ah=av&&!ar;at={ad,au,al};
if(ph&&(!m_valid||{m_pixel,m_sof,m_eol,m_last}!==pt))$fatal(1,"pixel hold");ph=m_valid&&!(ce&&m_ready);pt={m_pixel,m_sof,m_eol,m_last};
if(av&&ar)begin if(ad!==pixels[ax]||au!==(ax%N==0)||al!==(ax%W==W-1))$fatal(1,"AXI oracle %d",ax);ax=ax+1;if(!ce)offhand=offhand+1;end
if(ce&&m_valid&&m_ready)begin if(m_pixel!==pixels[got]||m_sof!==(got%N==0)||m_eol!==(got%W==W-1)||m_last!==(got%N==N-1))$fatal(1,"pixel oracle %d",got);got=got+1;end
end
initial begin $readmemh("pixels.hex",pixels);repeat(3)@(negedge clk);#1;rst_n=1;
for(f=0;f<F;f=f+1)begin ce=1;cfg_width=W;cfg_height=H;start_valid=1;@(negedge clk);#1;start_valid=0;cfg_width=0;cfg_height=0;
for(i=0;i<N;i=i+1)begin s_pixel=pixels[f*N+i];s_valid=1;s_sof=i==0;s_eol=i%W==W-1;s_last=i==N-1;do begin @(posedge clk);take=ce&&s_ready;tick;end while(!take);s_valid=0;if(i==0)begin ce=0;tick;end end
while(!ed||!dd)tick;
if(ee||de||ec||dc||got!=(f+1)*N||ax!=got)$fatal(1,"done");
ce=0;done_ready=1;repeat(3)@(negedge clk);#1;if(!ed||!dd)$fatal(1,"done hold");ce=1;@(negedge clk);#1;done_ready=0;if(!er||!dr)$fatal(1,"ready");end
if(N>4&&offhand==0)$fatal(1,"no CEoff AXI handshake exercised");
$display("PASS frames=%d pixels=%d CEoffAXI=%d",F,got,offhand);$finish;end endmodule'''
def case(w,h,dw):
 rng=random.Random(w*147+h+dw);values=[rng.getrandbits(dw) for _ in range(4*w*h)]
 with tempfile.TemporaryDirectory(prefix='axi_video_') as tmp:
  d=Path(tmp);(d/'pixels.hex').write_text('\n'.join(f'{v:x}' for v in values));tb=TB.replace('@W@',str(w)).replace('@H@',str(h)).replace('@DW@',str(dw));(d/'tb.sv').write_text(tb)
  execute(['iverilog','-g2012','-s','tb','-o',d/'sim',*SOURCES,d/'tb.sv'],d,d/'compile.log');out=execute(['vvp',d/'sim'],d,d/'run.log');print(out,flush=True)
 return dict(width=w,height=h,data_width=dw,frames=4,pixels=4*w*h,output=out)
def main():
 frozen=hashes();rows=[case(*p) for p in [(1,1,1),(7,5,8),(16,12,24),(64,32,32),(4096,1,64)]];assert hashes()==frozen
 (HERE/'evidence.json').write_text(json.dumps(dict(status='PASS',sources=frozen,cases=rows),indent=2)+'\n')
if __name__=='__main__':main()
