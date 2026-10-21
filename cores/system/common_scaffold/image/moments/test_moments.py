from pathlib import Path
import sys,tempfile,json,random,hashlib
import numpy as np
import cv2
HERE=Path(__file__).resolve().parent
sys.path.insert(0,str(HERE.parents[1]))
from integration.tooling import execute
rng=random.Random(7821)
counts={'frames':0,'pixels':0,'cv2_audits':0}
def oracle(a,binary,mask):
 h,w=a.shape
 p=[[int(a[y,x]!=0) if binary else int(a[y,x]) for x in range(w)] for y in range(h)]
 if mask is not None:p=[[p[y][x]*int(mask[y,x]) for x in range(w)] for y in range(h)]
 raw=[sum(p[y][x]*x**i*y**j for y in range(h) for x in range(w)) for i,j in ((0,0),(1,0),(0,1),(2,0),(1,1),(0,2))]
 # Independent NumPy vector reductions and real OpenCV call, not a host-only stand-in.
 arr=np.array(p,dtype=np.float64); yy,xx=np.indices(a.shape,dtype=np.float64)
 nv=[int(np.sum(arr*xx**i*yy**j)) for i,j in ((0,0),(1,0),(0,1),(2,0),(1,1),(0,2))]
 cv=cv2.moments(arr,binaryImage=False)
 assert raw==nv==[int(cv[k]) for k in ('m00','m10','m01','m20','m11','m02')]
 counts['cv2_audits']+=1
 return raw+[0 if not raw[0] else (raw[1]<<16)//raw[0],0 if not raw[0] else (raw[2]<<16)//raw[0],int(raw[0]!=0)]
def run(w,h,bits,masked):
 top='tb'
 tb='''module tb;
 reg clk=0;always #5 clk=~clk;
 reg rst_n=0,ce=1,s_valid=0,s_sof=0,s_eol=0,binary_mode=0,s_mask=1,m_ready=0;
 reg [BITS-1:0] s_pixel=0;
 wire s_ready,busy,done,m_valid,centroid_valid;wire [3:0] error_code;
 wire [63:0] m00,m10,m01,m20,m11,m02;wire [31:0] centroid_x_q16,centroid_y_q16;
 image_spatial_moments #(.WIDTH(WIDTH),.HEIGHT(HEIGHT),.BITS(BITS),.MASK_ENABLE(MASKED)) dut(.*);
 task tick;begin @(posedge clk);#1;end endtask
 task low;begin @(negedge clk);end endtask
 task reset;begin low;rst_n=0;ce=0;tick;low;rst_n=1;ce=1;s_valid=0;m_ready=0;end endtask
 task pixel(input integer p, input integer mask, input integer sof,input integer eol,input integer mode,input integer pause);
 begin
 low;s_pixel=p;s_mask=mask;s_sof=sof;s_eol=eol;binary_mode=mode;s_valid=1;
 if(!s_ready)$fatal(1,"input unexpectedly blocked");
 if(pause)begin ce=0;tick;tick;low;ce=1;end
 tick;low;s_valid=0;
 end endtask
 task result(input [63:0] a,b,c,d,e,f,input [31:0] cx,cy,input cv);
 integer n;reg [450:0] held;
 begin
 n=0;
 while(!m_valid)begin low;ce=(n%4!=1);tick;n=n+1;if(n>400)$fatal(1,"timeout");end
 if({m00,m10,m01,m20,m11,m02,centroid_x_q16,centroid_y_q16,centroid_valid}!=={a,b,c,d,e,f,cx,cy,cv})$fatal(1,"numeric mismatch got %d %d %d %d %d %d c=%d %d",m00,m10,m01,m20,m11,m02,centroid_x_q16,centroid_y_q16);
 if(error_code!=0)$fatal(1,"unexpected error");
 held={m00,m10,m01,m20,m11,m02,centroid_x_q16,centroid_y_q16,centroid_valid};
 repeat(3)begin low;ce=1;tick;if(!m_valid || held!=={m00,m10,m01,m20,m11,m02,centroid_x_q16,centroid_y_q16,centroid_valid})$fatal(1,"stall unstable");end
 low;ce=0;m_ready=1;tick;if(!m_valid)$fatal(1,"CE transfer");
 low;ce=1;tick;if(m_valid || !done || busy)$fatal(1,"completion");
 low;m_ready=0;tick;if(done)$fatal(1,"done not pulse");
 end endtask
 initial begin
 reset;
'''
 tb=tb.replace('BITS',str(bits)).replace('WIDTH',str(w)).replace('HEIGHT',str(h)).replace('MASKED',str(masked)) if False else tb
 # Keep parameter identifiers in the instance; constants in localparams avoid text replacement.
 tb=tb.replace('module tb;','module tb;localparam WIDTH=%d,HEIGHT=%d,BITS=%d,MASKED=%d;'%(w,h,bits,masked))
 fixtures=[]
 for kind in range(12):
  a=np.zeros((h,w),dtype=np.int64)
  if kind==1:a[:]=(1<<bits)-1
  elif kind in (2,3):a[min(h-1,kind-2),min(w-1,kind-2)]=(1<<bits)-1
  elif kind==4:a[h//2,:]=1
  elif kind==5:a[:,w//2]=1
  elif kind==6:
   for y in range(h):
    for x in range(w):a[y,x]=(x+y)%2
  elif kind>=7:
   a=np.array([[rng.randrange(1<<bits) for x in range(w)] for y in range(h)],dtype=np.int64)
  for mode in (0,1):fixtures.append((a,mode))
 for fi,(a,mode) in enumerate(fixtures):
  mask=np.array([[rng.randrange(2) for _ in range(w)] for _ in range(h)]) if masked else None
  exp=oracle(a,mode,mask)
  for y in range(h):
   for x in range(w):
    # Change mode every later pixel: must retain the first-pixel snapshot.
    md=mode if x==0 and y==0 else 1-mode
    tb+=f'pixel({a[y,x]},{1 if mask is None else mask[y,x]},{int(x==0 and y==0)},{int(x==w-1)},{md},{int((x+y+fi)%7==0)});\n'
  tb+='result('+','.join((f"64'd{n}" if i<6 else f"32'd{n}" if i<8 else f"1'b{n}") for i,n in enumerate(exp))+');\n'
  counts['frames']+=1;counts['pixels']+=w*h
 # Marker abort, recovery, and reset overriding CE during partial capture.
 tb+='pixel(7,1,0,0,0,0); if(!done || error_code!=1 || busy || m_valid)$fatal(1,"bad SOF");\n'
 if w*h>1:
  tb+=f'pixel(9,1,1,{int(w==1)},0,0);reset;\n'
 # A complete frame after reset then reset while division/output is pending.
 for y in range(h):
  for x in range(w):tb+=f'pixel(3,1,{int(x==0 and y==0)},{int(x==w-1)},0,0);\n'
 tb+='tick;reset;if(m_valid || busy || done || error_code)$fatal(1,"reset leak");\n'
 # Reset while the output is held must withdraw it, even with CE low.
 for y in range(h):
  for x in range(w):tb+=f'pixel(1,1,{int(x==0 and y==0)},{int(x==w-1)},0,0);\n'
 tb+='while(!m_valid)begin tick;end reset;if(m_valid || busy || done)$fatal(1,"output reset leak");\n'
 # Bad EOL mid-frame then replay good frame.
 tb+=f'pixel(7,1,1,{int(w!=1)},0,0);if(!done || error_code!=1)$fatal(1,"bad EOL");\n'
 a=np.full((h,w),2,dtype=np.int64);exp=oracle(a,0,None)
 for y in range(h):
  for x in range(w):tb+=f'pixel(2,1,{int(x==0 and y==0)},{int(x==w-1)},0,0);\n'
 tb+='result('+','.join((f"64'd{n}" if i<6 else f"32'd{n}" if i<8 else f"1'b{n}") for i,n in enumerate(exp))+');\n'
 counts['frames']+=1;counts['pixels']+=w*h
 tb+='$display("MOMENTS PASS");$finish;end initial begin #100000000;$fatal(1,"watchdog");end endmodule\n'
 with tempfile.TemporaryDirectory(prefix='moments_') as td:
  td=Path(td);(td/'tb.sv').write_text(tb)
  execute(['iverilog','-g2012','-s','tb','-o',td/'sim',HERE/'image_spatial_moments.sv',td/'tb.sv'],td,td/'compile.log')
  out=execute(['vvp',td/'sim'],td,td/'sim.log',timeout=180)
  assert 'MOMENTS PASS' in out
 print(w,h,bits,masked,'PASS')
def capacity_and_guards():
 a=np.full((16,4096),4095,dtype=np.int64);exp=oracle(a,0,None)
 tb='''module tb;reg clk=0;always #5 clk=~clk;
 reg rst_n=0,ce=1,s_valid=0,s_sof=0,s_eol=0,binary_mode=0,s_mask=1,m_ready=0;
 reg [11:0] s_pixel=4095;wire s_ready,busy,done,m_valid,centroid_valid;wire [3:0] error_code;
 wire [63:0] m00,m10,m01,m20,m11,m02;wire [31:0] centroid_x_q16,centroid_y_q16;
 image_spatial_moments #(.WIDTH(4096),.HEIGHT(16),.BITS(12)) dut(.*);
 integer x,y;initial begin repeat(2)@(negedge clk);rst_n=1;
 for(y=0;y<16;y=y+1)for(x=0;x<4096;x=x+1)begin
 s_valid=1;s_sof=(x==0 && y==0);s_eol=(x==4095);@(negedge clk);end
 s_valid=0;while(!m_valid)@(negedge clk);
'''
 for name,n in zip(('m00','m10','m01','m20','m11','m02','centroid_x_q16','centroid_y_q16','centroid_valid'),exp):tb+=f'if({name}!=64\'d{n})$fatal(1,"capacity {name}");\n'
 tb+='$display("CAPACITY PASS");$finish;end endmodule'
 with tempfile.TemporaryDirectory(prefix='moments_capacity_') as td:
  td=Path(td);(td/'tb.sv').write_text(tb)
  execute(['iverilog','-g2012','-s','tb','-o',td/'sim',HERE/'image_spatial_moments.sv',td/'tb.sv'],td,td/'compile.log')
  assert 'CAPACITY PASS' in execute(['vvp',td/'sim'],td,td/'sim.log')
  for cfg in ('.WIDTH(0)','.WIDTH(4097)','.WIDTH(4096),.HEIGHT(17)','.BITS(7)','.BITS(13)','.MASK_ENABLE(2)'):
   (td/'bad.sv').write_text(f'module bad;image_spatial_moments #({cfg}) dut();initial begin #10;$fatal(1,"guard missing");end endmodule')
   execute(['iverilog','-g2012','-s','bad','-o',td/'bad',HERE/'image_spatial_moments.sv',td/'bad.sv'],td,td/'bad_compile.log')
   try:execute(['vvp',td/'bad'],td,td/'bad.log')
   except RuntimeError:
    assert 'invalid moments parameters' in (td/'bad.log').read_text()
   else:raise AssertionError('invalid accepted')
 counts['frames']+=1;counts['pixels']+=65536
 counts['invalid_parameter_cases']=6
 print('65536-pixel capacity and six guards PASS')
if __name__=='__main__':
 for cfg in [(1,1,8,0),(7,5,8,0),(8,6,12,1),(1,13,10,1),(17,1,12,0),(4096,1,12,0),(1,4096,12,0)]:run(*cfg)
 capacity_and_guards()
 evidence={'result':'PASS',**counts,'oracles':['Python arbitrary precision','NumPy exact-range float64','OpenCV '+cv2.__version__+' moments'],'board':False,'rtl_sha256':hashlib.sha256((HERE/'image_spatial_moments.sv').read_bytes()).hexdigest()}
 (HERE/'evidence.json').write_text(json.dumps(evidence,indent=2)+'\n')
 print(evidence)
