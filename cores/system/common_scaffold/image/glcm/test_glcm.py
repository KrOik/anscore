"""Independent scalar and vectorized pair enumeration, actual skimage cross-check."""
from pathlib import Path
import os,tempfile,subprocess,json,random,math
import numpy as np
import skimage
from skimage.feature import graycomatrix,graycoprops
ROOT=Path(__file__).resolve().parent
OSS=ROOT.parents[3]/'tools/oss-cad-suite/oss-cad-suite'
os.environ['PATH']=os.pathsep.join([str(OSS/'bin'),str(OSS/'lib'),os.environ.get('PATH','')])

def oracle(frame,bits,levels,distance,symmetric):
 h,w=len(frame),len(frame[0]);lb=levels.bit_length()-1
 image=np.asarray(frame,dtype=np.uint16)>>(bits-lb)
 matrices=[];features=[]
 for direction,(dx,dy) in enumerate(((distance,0),(distance,distance),(0,distance),(-distance,distance))):
  matrix=[[0]*levels for _ in range(levels)]
  if distance:
   for y in range(h):
    for x in range(w):
     if 0<=x+dx<w and 0<=y+dy<h:
      a,b=int(image[y,x]),int(image[y+dy,x+dx]);matrix[a][b]+=1
      if symmetric:matrix[b][a]+=1
  # Vectorized oracle uses a coordinate grid and scatter, independent scalar traversal.
  yy,xx=np.indices(image.shape);mask=(xx+dx>=0)&(xx+dx<w)&(yy+dy>=0)&(yy+dy<h)&bool(distance)
  a=image[yy[mask],xx[mask]];b=image[(yy+dy)[mask],(xx+dx)[mask]]
  check=np.zeros((levels,levels),dtype=np.int64);np.add.at(check,(a,b),1)
  if symmetric:check=check+check.T
  assert np.array_equal(check,np.asarray(matrix))
  if distance:
   # skimage rounds radius*sin/cos. Diagonal integer offsets require sqrt(2)*d.
   radius=distance*(math.sqrt(2) if direction%2 else 1)
   sk=graycomatrix(image,[radius],[direction*math.pi/4],levels=levels,symmetric=symmetric,normed=False)[:,:,0,0]
   assert np.array_equal(sk,np.asarray(matrix))
  total=sum(map(sum,matrix))
  contrast=sum(matrix[i][j]*(i-j)**2 for i in range(levels) for j in range(levels))
  dissimilarity=sum(matrix[i][j]*abs(i-j) for i in range(levels) for j in range(levels))
  energy=sum(count*count for row in matrix for count in row)
  if distance and total:
   sk4=sk[:,:,None,None]
   for prop,expected in (('contrast',contrast/total),('dissimilarity',dissimilarity/total),('ASM',energy/(total*total)),('energy',math.sqrt(energy)/total)):
    assert math.isclose(float(graycoprops(sk4,prop)[0,0]),expected,rel_tol=1e-12,abs_tol=1e-12)
  matrices.append([count for row in matrix for count in row])
  features.append((contrast,dissimilarity,energy,total*total,total,int(total==0)))
 return matrices,features

def run():
 rng=random.Random(2026473);results=[]
 for bits,w,h,levels in ((8,1,1,16),(8,1,5,16),(8,6,1,16),(8,6,5,16),(10,5,4,32),(12,4,3,32)):
  d=(1<<bits)-1;n=w*h;cw=(2*n).bit_length();lb=levels.bit_length()-1;fw=2*cw+2*lb+1
  frames=[[[0]*w for _ in range(h)],[[d]*w for _ in range(h)],
          [[d*(y*w+x)//max(1,n-1) for x in range(w)] for y in range(h)],
          [[d if (x+y)%2 else 0 for x in range(w)] for y in range(h)],
          [[rng.randrange(d+1) for x in range(w)] for y in range(h)],
          [[d if x==y else d//3 for x in range(w)] for y in range(h)],
          [[0]*w for _ in range(h)],[[d//2]*w for _ in range(h)]]
  distances=[1,1,2,1,1,1,4095,0];symmetries=[0,1,0,1,0,1,1,0]
  matrices=[];features=[];seq=[]
  for fi,(frame,distance,symmetric) in enumerate(zip(frames,distances,symmetries)):
   if fi==7:
    seq+=['send_pixel(1,1,0);reset_dut;']
    seq+=['cfg_distance=1;cfg_symmetric=1;']
    for ii in range(n):seq.append(f'send_pixel(1,{int(ii==0)},{int(ii%w==w-1)});')
    seq+=[f'while(dut.state!={12 if w>1 else 10})@(negedge clk);reset_dut;']
    if bits==8 and w==6 and h==5:
     seq+=['hold_outputs=1;cfg_distance=1;cfg_symmetric=1;']
     for ii in range(n):seq.append(f'send_pixel(1,{int(ii==0)},{int(ii%w==w-1)});')
     seq+=['while(!mv)@(negedge clk);repeat(5)@(negedge clk);reset_dut;hold_outputs=0;']
   mat,feat=oracle(frame,bits,levels,distance,symmetric);matrices.extend(mat);features.extend(feat)
   seq.append(f'cfg_distance={distance};cfg_symmetric={symmetric};')
   for y,row in enumerate(frame):
    for x,pixel in enumerate(row):
     seq.append(f'send_pixel({pixel},{int(x==0 and y==0 and fi!=5)},{int(x==w-1 and fi!=6)});')
     if x==0 and y==0:seq.append(f'cfg_distance={0 if distance else 7};cfg_symmetric={1-symmetric};')
   seq.append(f'finish_frame({(fi+1)*4*levels*levels},{(fi+1)*4},{int(fi in (5,6))},{int(distance==0)});')
  with tempfile.TemporaryDirectory(prefix='glcm_test_') as temporary:
   t=Path(temporary)
   (t/'matrix.hex').write_text('\n'.join(f'{value:x}' for matrix in matrices for value in matrix)+'\n')
   packed=[]
   for contrast,dissim,energy,den,total,zero in features:
    value=contrast
    for field,width in ((dissim,fw),(energy,fw),(den,fw),(total,cw),(zero,1)):value=(value<<width)|field
    packed.append(value)
   (t/'features.hex').write_text('\n'.join(f'{v:x}' for v in packed)+'\n')
   (t/'totals.hex').write_text('\n'.join(f'{v[4]:x}' for v in features)+'\n')
   (t/'tb.v').write_text(TB.replace('@PARAM@',f'B={bits},W={w},H={h},L={levels},CW={cw},FW={fw},LB={lb},N={len(matrices)*levels*levels},NF={len(features)}').replace('@SEQ@','\n'.join(seq)))
   p=subprocess.run(['iverilog','-g2012','-s','tb','-o',str(t/'sim'),str(ROOT/'glcm_frame.v'),str(t/'tb.v')],capture_output=True,text=True)
   if p.returncode:raise RuntimeError(p.stderr)
   p=subprocess.run(['vvp',str(t/'sim')],cwd=t,capture_output=True,text=True,timeout=240)
   if p.returncode or 'PASS' not in p.stdout:raise RuntimeError(p.stdout+p.stderr)
   print(bits,w,h,levels,p.stdout.strip(),flush=True)
  results.append({'bits':bits,'width':w,'height':h,'levels':levels,'frames':len(frames),'matrix_values':len(matrices)*levels*levels,'feature_records':len(features),'zero_pair_records':sum(feature[5] for feature in features),'actual_skimage_checked_records':sum(4 for distance in distances if distance),'actual_graycoprops_feature_records':sum(not feature[5] for feature in features)})
 with tempfile.TemporaryDirectory(prefix='glcm_invalid_') as temporary:
  t=Path(temporary);invalid=[('BITS',7),('BITS',13),('WIDTH',0),('HEIGHT',4097),('LEVELS',8),('LEVELS',64),('CW',1),('LB',3),('FW',1)]
  for parameter,value in invalid:
   (t/'tb.v').write_text(f'module tb;glcm_frame #(.{parameter}({value})) dut();initial #1 $finish;endmodule')
   p=subprocess.run(['iverilog','-g2012','-s','tb','-o',str(t/'sim'),str(ROOT/'glcm_frame.v'),str(t/'tb.v')],capture_output=True,text=True)
   if p.returncode:continue
   p=subprocess.run(['vvp',str(t/'sim')],capture_output=True,text=True)
   if p.returncode==0:raise AssertionError(f'invalid {parameter}={value} accepted')
 (ROOT/'test_result.json').write_text(json.dumps({'status':'PASS','skimage_version':skimage.__version__,'cases':results,'invalid_parameters':len(invalid),'seed':2026473},indent=2)+'\n')

TB=r'''
module tb;
localparam @PARAM@;
reg clk=0;always #5 clk=~clk;
reg rst=1,ce=1,sv=0,sof=0,eol=0,mr=0,fr=0,dr=0,pause=0,hold_outputs=0;
reg[11:0] cfg_distance=1;reg cfg_symmetric=0;reg[B-1:0] gray=0;
wire sr,mv,ml,mdl,fv,zp,fl,done,marker,configerror,arithmetic,busy;
wire[CW-1:0] count,mt,ft;wire[LB-1:0] row,column;wire[1:0] direction,fd;
wire[FW-1:0] contrast,dissim,energy,den;
glcm_frame #(.BITS(B),.WIDTH(W),.HEIGHT(H),.LEVELS(L)) dut(
.clk(clk),.rst(rst),.ce(ce),.cfg_distance(cfg_distance),.cfg_symmetric(cfg_symmetric),.s_gray(gray),.s_valid(sv),.s_sof(sof),.s_eol(eol),.s_ready(sr),
.m_valid(mv),.m_ready(mr),.m_count(count),.m_row(row),.m_column(column),.m_direction(direction),.m_pair_total(mt),.m_direction_last(mdl),.m_last(ml),
.feature_valid(fv),.feature_ready(fr),.contrast_numerator(contrast),.dissimilarity_numerator(dissim),.energy_numerator(energy),.energy_denominator(den),
.feature_pair_total(ft),.feature_direction(fd),.zero_pairs(zp),.feature_last(fl),.done_valid(done),.done_ready(dr),.marker_error(marker),.config_error(configerror),.arithmetic_error(arithmetic),.busy(busy));
reg[CW-1:0] expected[0:N-1],totals[0:NF-1];reg[4*FW+CW:0] expected_features[0:NF-1];
reg[31:0] random_state=32'h741bc923;integer received=0,feature_received=0,cycles=0,index;
reg held=0,fheld=0;reg[255:0] payload;reg[511:0] fpayload;
always @(negedge clk)begin
random_state=random_state^(random_state<<13);random_state=random_state^(random_state>>17);random_state=random_state^(random_state<<5);
ce=pause?0:random_state[3:0]!=0;mr=hold_outputs?0:random_state[6:4]!=0;fr=hold_outputs?0:random_state[9:7]!=0;
end
always @(posedge clk)if(!rst)begin
cycles=cycles+1;if(cycles>15000000)$fatal(1,"timeout state%0d",dut.state);
if(held&&(!mv||{count,row,column,direction,mt,mdl,ml}!==payload))$fatal(1,"matrix stall");
held=mv&&!(ce&&mr);payload={count,row,column,direction,mt,mdl,ml};
if(fheld&&(!fv||{contrast,dissim,energy,den,ft,fd,zp,fl}!==fpayload))$fatal(1,"feature stall");
fheld=fv&&!(ce&&fr);fpayload={contrast,dissim,energy,den,ft,fd,zp,fl};
if(ce&&mv&&mr)begin
if(received>=N||count!==expected[received])$fatal(1,"count%0d got%0d expected%0d",received,count,expected[received]);
index=received%(L*L);
if(row!==index/L||column!==index%L||direction!==((received/(L*L))%4)||mt!==totals[received/(L*L)]||mdl!==(index==L*L-1)||ml!==(index==L*L-1&&direction==3))$fatal(1,"matrix metadata");
received=received+1;
end
if(ce&&fv&&fr)begin
if(feature_received>=NF||{contrast,dissim,energy,den,ft,zp}!==expected_features[feature_received])$fatal(1,"feature%0d got%h expected%h",feature_received,{contrast,dissim,energy,den,ft,zp},expected_features[feature_received]);
if(fd!==feature_received%4||fl!==(feature_received%4==3))$fatal(1,"feature metadata");
feature_received=feature_received+1;
end
end
task send_pixel(input[B-1:0] v,input first,lastpixel);begin
repeat(v%2)@(negedge clk);#1;gray=v;sof=first;eol=lastpixel;sv=1;
@(posedge clk);while(!sr)@(posedge clk);
@(negedge clk);#1;sv=0;
end endtask
task finish_frame(input integer expected_count,expected_features,expected_marker,expected_config);begin
while(!done)@(negedge clk);#1;
if(received!=expected_count||feature_received!=expected_features||marker!=expected_marker||configerror!=expected_config||arithmetic)$fatal(1,"terminal count%0d features%0d marker%0d config%0d arithmetic%0d",received,feature_received,marker,configerror,arithmetic);
repeat(5)begin @(negedge clk);#1;if(!done||marker!=expected_marker||configerror!=expected_config||arithmetic)$fatal(1,"DONE stall");end
dr=1;@(posedge clk);while(!ce)@(posedge clk);
@(negedge clk);#1;dr=0;
end endtask
task reset_dut;begin
@(negedge clk);#1;pause=1;rst=1;sv=0;repeat(2)@(negedge clk);#1;rst=0;held=0;fheld=0;
if(mv||fv||done||marker||configerror||arithmetic)$fatal(1,"reset");pause=0;
end endtask
initial begin
$readmemh("matrix.hex",expected);$readmemh("features.hex",expected_features);$readmemh("totals.hex",totals);
repeat(3)@(negedge clk);#1;rst=0;
@SEQ@
$display("PASS %0d matrix counts, %0d exact feature records",received,feature_received);$finish;
end
endmodule
'''
if __name__=='__main__':run()
