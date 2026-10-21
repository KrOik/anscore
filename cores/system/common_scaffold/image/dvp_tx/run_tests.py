from pathlib import Path
import sys,tempfile,json,hashlib,random,re
H=Path(__file__).resolve().parent
sys.path.insert(0,str(H.parents[1]))
from integration.tooling import ROOT,execute
RTL=H/'dvp_tx.sv'
def oracle(w,h,mode,be,vp,hp,hb,vb,pixels):
 raw=[]
 for p in pixels:
  if mode:
   r,g,b=(p>>16)&255,(p>>8)&255,p&255;v=((r//8)<<11)|((g//4)<<5)|(b//8);raw.extend(v.to_bytes(2,'big' if be else 'little'))
  else:raw.append(p&255)
 out=[];at=0;wb=w*(2 if mode else 1)
 for y in range(h+2*vb):
  active=vb<=y<vb+h
  for x in range(wb+hb):
   valid=active and x>=hb;d=raw[at] if valid else 0
   if valid:at+=1
   out.append((int(not active if vp else active)<<9)|(int(valid if hp else not valid)<<8)|d)
 assert at==len(raw)
 return out
TB=r'''module tb;
reg clk=0;always #5 clk=~clk;reg rst_n=0,ce=1,start_valid=0,abort=0;reg[15:0]cfg_width=WW,cfg_height=HH;reg cfg_mode=MODE,cfg_big_endian=BE,cfg_vsync_active_high=VP,cfg_href_active_high=HP;
reg[15:0]cfg_hblank=HB,cfg_vblank_lines=VB,cfg_byte_period=PER;
reg[23:0]s_pixel=0;reg s_valid=0,s_sof=0,s_eol=0,s_last=0;wire s_ready,start_ready,done_valid,frame_error;wire[7:0]error_code,data;wire vsync,href,sample_valid;reg done_ready=0;
wire[15:0]image_width,image_height;wire image_mode;
dvp_tx #(.MAX_WIDTH(MW),.MAX_HEIGHT(MH),.FIFO_DEPTH(FD))dut(.*);
reg[23:0]pixels[0:NP-1];reg[9:0]expected[0:NT-1];integer cyc=0,got=0,i,last_tick=-1;
always @(negedge clk)begin cyc=cyc+1;if(FLOW)ce=cyc%13>2;if(cyc>6000000)$fatal(1,"timeout");end
always @(posedge clk)if(rst_n&&dut.push&&dut.read_en&&dut.wp==dut.rp)$fatal(1,"cross-port address collision");
always @(posedge clk)if(rst_n&&sample_valid)begin
 if(got>=NT||{vsync,href,data}!==expected[got])$fatal(1,"wave %d actual %h expected %h",got,{vsync,href,data},expected[got]);
 if(last_tick>=0&&cyc-last_tick!=PER)$fatal(1,"period changed");last_tick=cyc;got=got+1;
end
 task tick;begin @(negedge clk);#1;end endtask
 initial begin $readmemh("PIX",pixels);$readmemh("EXP",expected);repeat(3)tick;rst_n=1;tick;start_valid=1;while(!ce)tick;@(posedge clk);tick;start_valid=0;
 cfg_width=1;cfg_height=1;cfg_mode=!MODE;cfg_big_endian=!BE;cfg_vsync_active_high=!VP;cfg_href_active_high=!HP;cfg_hblank=1;cfg_vblank_lines=1;cfg_byte_period=1;
 for(i=0;i<NP;i=i+1)begin s_valid=1;s_pixel=pixels[i];s_sof=i==0;s_eol=i%WW==WW-1;s_last=i==NP-1;@(posedge clk);while(!(ce&&s_ready))@(posedge clk);tick;end
 s_valid=0;while(!done_valid)tick;tick;
 if(frame_error||error_code||got!=NT||image_width!=WW||image_height!=HH||image_mode!=MODE)$fatal(1,"done %h %d",error_code,got);
 repeat(7)tick;if(!done_valid||sample_valid||href===HP||vsync!==VP)$fatal(1,"done blank");$display("PASS DVP TX ticks=%d pixels=%d",got,NP);$finish;end
endmodule'''
def run_case(name,w,h,mode=0,be=False,vp=True,hp=True,hb=3,vb=2,period=3,flow=True,depth=1024,mw=640,mh=480,pixels=None):
 if pixels is None:pixels=[(i*7919^i<<13^0x89abef)&0xffffff for i in range(w*h)]
 exp=oracle(w,h,mode,be,vp,hp,hb,vb,pixels)
 with tempfile.TemporaryDirectory(prefix='dvp_tx_test_') as td:
  d=Path(td);tb=TB
  for token,seq in [('PIX',pixels),('EXP',exp)]:
   f=d/(token+'.hex');f.write_text('\n'.join(f'{v:x}' for v in seq));tb=tb.replace('"'+token+'"','"'+f.as_posix()+'"')
  for key,val in dict(WW=w,HH=h,MODE=mode,BE=int(be),VP=int(vp),HP=int(hp),HB=hb,VB=vb,PER=period,FLOW=int(flow),FD=depth,MW=mw,MH=mh,NP=len(pixels),NT=len(exp)).items():tb=re.sub(r'\b'+key+r'\b',str(val),tb)
  (d/'tb.sv').write_text(tb);execute(['iverilog','-g2012','-s','tb','-o',d/'a.vvp',RTL,d/'tb.sv'],ROOT,H/(name+'_compile.log'));out=execute(['vvp',d/'a.vvp'],ROOT,H/(name+'_simulation.log'),timeout=180);assert 'PASS DVP TX' in out
 return dict(name=name,width=w,height=h,mode=mode,big_endian=be,vsync_active_high=vp,href_active_high=hp,hblank=hb,vblank_lines=vb,byte_period=period,pixels=len(pixels),ticks=len(exp))
def main():
 rows=[]
 for mode in [0,1]:
  for be in [False,True]:
   for vp,hp in [(False,False),(True,True),(True,False),(False,True)]:rows.append(run_case(f'main_{mode}_{be}_{vp}_{hp}',16,12,mode,be,vp,hp))
 for w,h in [(320,240),(640,480)]:
  for mode in [0,1]:rows.append(run_case(f'camera_{w}_{h}_{mode}',w,h,mode,period=1,flow=False,hb=16,vb=2))
 (H/'evidence.json').write_text(json.dumps(dict(status='PASS',rtl_sha256=hashlib.sha256(RTL.read_bytes()).hexdigest(),cases=rows),indent=2)+'\n');print(json.dumps(rows))
if __name__=='__main__':main()
