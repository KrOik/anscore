"""Exact independent RGB conversion/MCU packing oracle and real color libraries."""
import hashlib,json,os,subprocess,tempfile,time
from pathlib import Path
import numpy as np
import cv2
from PIL import Image,__version__ as PIL_VERSION
ROOT=Path(__file__).resolve().parent
OSS=ROOT.parents[3]/'tools/oss-cad-suite/oss-cad-suite'
os.environ['PATH']=os.pathsep.join([str(OSS/'bin'),str(OSS/'lib'),os.environ.get('PATH','')])
def convert(rgb):
 rgb=np.asarray(rgb,dtype=np.int64);r,g,b=rgb[...,0],rgb[...,1],rgb[...,2]
 return np.clip(np.stack(((19595*r+38470*g+7471*b+32768)//65536,(-11059*r-21709*g+32768*b+8421376)//65536,(32768*r-27439*g-5329*b+8421376)//65536),axis=-1),0,255).astype(np.uint8)
def tokens(rgb,s420):
 image=convert(rgb);h,w,_=image.shape;span=16 if s420 else 8
 blocks=[(0,0,0),(0,8,0),(0,0,8),(0,8,8),(1,0,0),(2,0,0)] if s420 else [(0,0,0),(1,0,0),(2,0,0)]
 cols=(w+span-1)//span;rows=(h+span-1)//span
 for my in range(rows):
  for mx in range(cols):
   mi=my*cols+mx
   for bi,(component,ox,oy) in enumerate(blocks):
    for i in range(64):
     sx=mx*span+ox+i%8;sy=my*span+oy+i//8
     if s420 and component:
      sx=mx*span+2*(i%8);sy=my*span+2*(i//8)
      value=(sum(int(image[min(sy+dy,h-1),min(sx+dx,w-1),component]) for dy in (0,1) for dx in (0,1))+2)//4
     else:value=int(image[min(sy,h-1),min(sx,w-1),component])
     mlast=bi==len(blocks)-1 and i==63;flast=mlast and mi==cols*rows-1
     yield (value<<38)|(component<<36)|(int(i==0)<<35)|(int(i==63)<<34)|(int(flast)<<33)|(int(mlast)<<32)|mi
def library_audit():
 rng=np.random.default_rng(603);rgb=rng.integers(0,256,(128,128,3),dtype=np.uint8)
 rgb[0,:8]=np.array([[0,0,0],[255,255,255],[255,0,0],[0,255,0],[0,0,255],[255,255,0],[0,255,255],[255,0,255]],dtype=np.uint8)
 own=convert(rgb).astype(np.int16)
 oc=cv2.cvtColor(rgb,cv2.COLOR_RGB2YCrCb)[...,[0,2,1]].astype(np.int16)
 pil=np.asarray(Image.fromarray(rgb).convert('YCbCr')).astype(np.int16)
 result=dict(opencv_version=cv2.__version__,pillow_version=PIL_VERSION,pixels=rgb.shape[0]*rgb.shape[1],opencv_max_abs=np.max(abs(own-oc),axis=(0,1)).tolist(),pillow_max_abs=np.max(abs(own-pil),axis=(0,1)).tolist(),opencv_different_channels=int(np.sum(own!=oc)),pillow_different_channels=int(np.sum(own!=pil)))
 assert max(result['opencv_max_abs'])<=1 and max(result['pillow_max_abs'])<=1,result
 return result
TB='''module tb;
localparam W=@W@,H=@H@,F=@F@,N=W*H,T=@T@;
reg clk=0;always #5 clk=~clk;reg rst_n=0,ce=1,start_valid=0,cfg_sampling_420=0,s_valid=0,s_sof=0,s_eol=0,m_ready=0,done_ready=0;
reg[23:0]s_rgb=0;wire start_ready,s_ready,m_valid,m_block_first,m_block_last,m_frame_last,m_mcu_last,done_valid,busy;wire[7:0]m_data;wire[1:0]m_component;wire[31:0]m_mcu_index;wire[3:0]error_code;
jpeg_color_mcu #(.WIDTH(W),.HEIGHT(H))dut(.*);
reg[23:0]inputs[0:F*N-1];reg[63:0]expected[0:T-1];reg modes[0:F-1],errors[0:F-1];
wire[63:0]payload={18'b0,m_data,m_component,m_block_first,m_block_last,m_frame_last,m_mcu_last,m_mcu_index};
reg held=0,dh=0;reg[63:0]last_payload;reg[3:0]last_error;integer cycle=0,index=0,f,i,frame_tokens=0;
always @(negedge clk)begin cycle=cycle+1;ce=cycle%11!=0;m_ready=cycle%7!=0;end
always @(posedge clk)if(!rst_n)begin held=0;dh=0;end else begin
 if(held&&(!m_valid||payload!==last_payload))$fatal(1,"stalled MCU sample changed");
 if(dh&&(!done_valid||error_code!==last_error))$fatal(1,"stalled DONE changed");
 held=m_valid&&(!ce||!m_ready);dh=done_valid&&(!ce||!done_ready);last_payload=payload;last_error=error_code;
 if(ce&&m_valid&&m_ready)begin if(index>=T||payload!==expected[index])$fatal(1,"sample %d got %h expected %h",index,payload,expected[index]);index=index+1;frame_tokens=frame_tokens+1;end
end
initial begin
 $readmemh("input.hex",inputs);$readmemh("expected.hex",expected);$readmemh("modes.hex",modes);$readmemh("errors.hex",errors);
 repeat(3)@(negedge clk);rst_n=1;
 for(f=0;f<F;f=f+1)begin
 frame_tokens=0;@(negedge clk);cfg_sampling_420=modes[f];start_valid=1;@(posedge clk);while(!start_ready)@(posedge clk);@(negedge clk);start_valid=0;cfg_sampling_420=!modes[f];
 for(i=0;i<N;i=i+1)begin
 @(negedge clk);s_valid=1;s_rgb=inputs[f*N+i];s_sof=i==0&&!errors[f];s_eol=i%W==W-1;
 @(posedge clk);while(!s_ready)@(posedge clk);@(negedge clk);s_valid=0;end
 wait(done_valid);#1;if(error_code!=errors[f]||(errors[f]&&frame_tokens!=0))$fatal(1,"frame status");
 repeat(4)@(negedge clk);done_ready=1;@(posedge clk);while(!ce)@(posedge clk);@(negedge clk);done_ready=0;
 end
 if(index!=T)$fatal(1,"sample count");$display("PASS samples=%0d",index);$finish;end
initial begin #2000000000;$fatal(1,"timeout");end endmodule'''
def run_profile(td,w,h,specs):
 started=time.perf_counter();n=w*h;count=0
 with (td/'input.hex').open('w') as fi,(td/'expected.hex').open('w') as fe:
  for rgb,s420,error in specs:
   fi.writelines(f'{(int(r)<<16)|(int(g)<<8)|int(b):06x}\n' for r,g,b in rgb.reshape(-1,3))
   if not error:
    for token in tokens(rgb,s420):fe.write(f'{token:016x}\n');count+=1
 (td/'modes.hex').write_text('\n'.join(str(mode) for _,mode,_ in specs));(td/'errors.hex').write_text('\n'.join(str(error) for _,_,error in specs))
 tb=TB
 for key,value in dict(W=w,H=h,F=len(specs),T=count).items():tb=tb.replace('@'+key+'@',str(value))
 (td/'tb.sv').write_text(tb)
 p=subprocess.run(['iverilog','-g2012','-s','tb','-o',str(td/'sim'),str(ROOT/'jpeg_color_mcu.v'),str(td/'tb.sv')],cwd=td,capture_output=True,text=True)
 if p.returncode:raise RuntimeError(p.stderr)
 p=subprocess.run(['vvp',str(td/'sim')],cwd=td,capture_output=True,text=True,timeout=360)
 if p.returncode:raise RuntimeError(p.stdout+p.stderr)
 result=dict(width=w,height=h,frames=len(specs),input_pixels=n*len(specs),samples=count,status='PASS',elapsed_seconds=round(time.perf_counter()-started,3));print(result,flush=True);return result
def main():
 started=time.perf_counter();audit=library_audit();rng=np.random.default_rng(884);results=[]
 with tempfile.TemporaryDirectory(prefix='jpeg_color_mcu_') as temporary:
  td=Path(temporary)
  for w,h in [(1,1),(1,17),(17,1),(7,9),(16,16),(17,19),(31,33)]:
   rgb=rng.integers(0,256,(h,w,3),dtype=np.uint8)
   specs=[(rgb,0,0),(rgb,1,0),(np.zeros_like(rgb),1,0),(np.full_like(rgb,255),0,0),(rgb,1,1),(rgb,0,0)]
   if w==1 and h==1:
    specs += [(np.full((1,1,3),color,dtype=np.uint8),mode,0) for color in ([255,0,0],[0,255,0],[0,0,255],[255,255,0],[0,255,255],[255,0,255]) for mode in (0,1)]
   results.append(run_profile(td,w,h,specs))
  w,h=65536,1;indices=np.arange(w,dtype=np.uint32)
  rgb=np.stack(((indices>>8)&255,(indices>>4)&255,((indices>>12)*17)&255),axis=-1).astype(np.uint8)[None,:,:]
  results.append(run_profile(td,w,h,[(rgb,0,0)]))
 from test_jpeg_color_protocol import main as protocol_main
 protocol_main()
 result=dict(status='PASS',elapsed_seconds=round(time.perf_counter()-started,3),profiles=results,color_library_audit=audit,source_sha256=hashlib.sha256((ROOT/'jpeg_color_mcu.v').read_bytes()).hexdigest(),test_sha256=hashlib.sha256(Path(__file__).read_bytes()).hexdigest(),board_verified=False)
 (ROOT/'test_result.json').write_text(json.dumps(result,indent=2)+'\n');print(result,flush=True)
if __name__=='__main__':main()
