from test_timing import *
TB=r'''module tb;
localparam W=@W@,H=@H@,HF=2,HS=1,HB=1,VF=1,VS=1,VB=1,HT=W+4,VT=H+3,N=W*H;
reg clk=0;always #5 clk=~clk;reg rst_n=0,ce=1,pixel_tick=0,start_valid=0,stop=0,abort=0,done_ready=0;
reg[15:0]cfg_h_active=W,cfg_h_front=HF,cfg_h_sync=HS,cfg_h_back=HB,cfg_v_active=H,cfg_v_front=VF,cfg_v_sync=VS,cfg_v_back=VB;
reg cfg_hsync_positive=1,cfg_vsync_positive=0;reg[23:0]s_pixel;reg s_valid=0,s_sof=0,s_eol=0,s_last=0;
wire start_ready,s_ready,running,done_valid,frame_error,hsync,vsync,de,sof,eol,eof,frame_end;wire[7:0]error_code;wire[15:0]h_count,v_count;wire[23:0]rgb;
video_rgb_scanout #(.FIFO_DEPTH(16),.PREBUFFER(4))dut(.*);
integer cyc=0,i,got=0,ticks=0,x,y,off=0,stalls=0;reg take,requested=0;reg[23:0]expected;
function[23:0]pixel;input integer n;begin pixel=(n*24'h010203)^24'habcdef;end endfunction
always @(negedge clk)begin #1;cyc=cyc+1;pixel_tick=cyc%3==0;ce=cyc%7<4;
if(start_valid)ce=1;if(got>N&&!requested)begin stop=1;requested=1;ce=1;end else stop=0;
if(cyc>30000000)$fatal(1,"timeout");end
always @(posedge clk)if(rst_n)begin
if(ce&&s_valid&&!s_ready)stalls=stalls+1;
if(running&&pixel_tick)begin
x=ticks%HT;y=(ticks/HT)%VT;
if(h_count!==x||v_count!==y||de!==(x<W&&y<H)||hsync!==(x>=W+HF&&x<W+HF+HS)||vsync!==(y<H+VF||y>=H+VF+VS))$fatal(1,"timing");
if(de)begin expected=pixel(got);if(rgb!==expected||sof!==(got%N==0)||eol!==(got%W==W-1)||eof!==(got%N==N-1))$fatal(1,"pixel %d got%h wanted%h qvalid%b count%d",got,rgb,expected,dut.qvalid,dut.count);got=got+1;if(!ce)off=off+1;end else if(rgb!=0)$fatal(1,"blanking RGB");ticks=ticks+1;end end
initial begin repeat(3)@(negedge clk);#2;rst_n=1;start_valid=1;ce=1;@(negedge clk);#2;start_valid=0;cfg_h_active=0;cfg_v_active=0;
for(i=0;i<2*N;i=i+1)begin s_valid=1;s_pixel=pixel(i);s_sof=i%N==0;s_eol=i%W==W-1;s_last=i%N==N-1;
do begin @(posedge clk);take=ce&&s_ready;@(negedge clk);#2;end while(!take);s_valid=0;end
wait(done_valid);#2;if(frame_error||error_code||running||got!=2*N||ticks!=2*HT*VT||off==0||(W>4&&stalls==0))$fatal(1,"report got%d ticks%d error%d",got,ticks,error_code);
$display("PASS SCANOUT frames=2 pixels=%d ticks=%d CEoffpixels=%d stalls=%d",got,ticks,off,stalls);$finish;end endmodule'''
def run(w,h):
 tb=TB.replace('@W@',str(w)).replace('@H@',str(h))
 with tempfile.TemporaryDirectory(prefix='video_scanout_') as tmp:
  p=Path(tmp);(p/'tb.sv').write_text(tb);execute(['iverilog','-g2012','-s','tb','-o',p/'sim',*SOURCES,p/'tb.sv'],p,p/'compile.log');out=execute(['vvp',p/'sim'],p,p/'run.log',timeout=300);print(out,flush=True)
 return dict(width=w,height=h,frames=2,pixels=2*w*h,output=out)
def main():
 frozen=hashes();rows=[run(*p) for p in [(4,3),(16,12),(64,32),(640,480)]];assert hashes()==frozen
 (HERE/'scanout_evidence.json').write_text(json.dumps(dict(status='PASS',sources=frozen,cases=rows),indent=2)+'\n')
if __name__=='__main__':main()
