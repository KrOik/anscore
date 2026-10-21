from pathlib import Path
import hashlib,json,sys,tempfile
HERE=Path(__file__).resolve().parent
sys.path.insert(0,str(HERE.parents[1]/'integration'))
from tooling import execute
SOURCES=[HERE/'video_timing_generator.sv',HERE/'video_rgb_scanout.sv']
def hashes():return {p.name:hashlib.sha256(p.read_bytes()).hexdigest() for p in SOURCES}
TB=r'''module tb;
localparam HA=@HA@,HF=@HF@,HS=@HS@,HB=@HB@,VA=@VA@,VF=@VF@,VS=@VS@,VB=@VB@,HP=@HP@,VP=@VP@,HT=HA+HF+HS+HB,VT=VA+VF+VS+VB,FRAME=HT*VT;
reg clk=0;always #5 clk=~clk;reg rst_n=0,ce=1,pixel_tick=1,start_valid=0,stop=0,abort=0,done_ready=0;
reg[15:0]cfg_h_active=HA,cfg_h_front=HF,cfg_h_sync=HS,cfg_h_back=HB,cfg_v_active=VA,cfg_v_front=VF,cfg_v_sync=VS,cfg_v_back=VB;
reg cfg_hsync_positive=HP,cfg_vsync_positive=VP;wire start_ready,running,done_valid,frame_error,hsync,vsync,de,sof,eol,eof,frame_end;wire[7:0]error_code;wire[15:0]h_count,v_count;
video_timing_generator dut(.*);
integer cyc=0,n=0,x,y,active=0,ends=0,off=0;reg eh,ev,ed,freezece=0;
always @(negedge clk)begin #1;cyc=cyc+1;if(freezece)ce=0;else if(start_valid||stop)ce=1;else ce=cyc%7<3;pixel_tick=cyc%9!=0;end
always @(posedge clk)if(rst_n&&running&&pixel_tick)begin
x=n%HT;y=(n/HT)%VT;ed=x<HA&&y<VA;eh=x>=HA+HF&&x<HA+HF+HS?HP:!HP;ev=y>=VA+VF&&y<VA+VF+VS?VP:!VP;
if(h_count!==x||v_count!==y||de!==ed||hsync!==eh||vsync!==ev||sof!==(ed&&x==0&&y==0)||eol!==(ed&&x==HA-1)||eof!==(ed&&x==HA-1&&y==VA-1)||frame_end!==(x==HT-1&&y==VT-1))$fatal(1,"timing tick %d xy %d,%d",n,h_count,v_count);
if(de)active=active+1;if(frame_end)ends=ends+1;if(!ce)off=off+1;n=n+1;end
initial begin repeat(3)@(negedge clk);#2;rst_n=1;start_valid=1;ce=1;@(negedge clk);#2;start_valid=0;cfg_h_active=0;cfg_v_active=0;cfg_hsync_positive=!HP;cfg_vsync_positive=!VP;
wait(n>=FRAME);@(negedge clk);#2;stop=1;ce=1;@(negedge clk);#2;stop=0;
wait(done_valid);#1;if(running||frame_error||error_code||n!=FRAME*2||active!=HA*VA*2||ends!=2||off==0)$fatal(1,"end n%0d active%0d end%0d",n,active,ends);
freezece=1;ce=0;done_ready=1;repeat(3)@(negedge clk);#2;if(!done_valid)$fatal(1,"done cehold");freezece=0;ce=1;@(negedge clk);#2;$display("PASS TIMING ticks=%0d active=%0d CEoff=%0d",n,active,off);$finish;end
initial begin #200000000;$fatal(1,"timeout");end endmodule'''
def run(profile):
 keys=['HA','HF','HS','HB','VA','VF','VS','VB','HP','VP'];tb=TB
 for k,v in zip(keys,profile):tb=tb.replace('@'+k+'@',str(v))
 with tempfile.TemporaryDirectory(prefix='video_timing_') as tmp:
  p=Path(tmp);(p/'tb.sv').write_text(tb);execute(['iverilog','-g2012','-s','tb','-o',p/'sim',*SOURCES,p/'tb.sv'],p,p/'compile.log');out=execute(['vvp',p/'sim'],p,p/'run.log',timeout=300);print(out,flush=True)
 return dict(profile=dict(zip(keys,profile)),frames=2,output=out)
def main():
 frozen=hashes();rows=[run(p) for p in [(1,0,1,0,1,0,1,0,0,1),(640,16,96,48,480,10,2,33,0,0),(1280,110,40,220,720,5,5,20,1,1),(1920,88,44,148,1080,4,5,36,1,1)]];assert hashes()==frozen
 (HERE/'timing_evidence.json').write_text(json.dumps(dict(status='PASS',sources=frozen,cases=rows),indent=2)+'\n')
if __name__=='__main__':main()
