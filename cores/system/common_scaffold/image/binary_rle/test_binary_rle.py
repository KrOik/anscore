"""Exact row-run oracle, real RTL encoder-to-decoder loop and malformed tokens."""
from pathlib import Path
import os,tempfile,subprocess,json,random,math
ROOT=Path(__file__).resolve().parent
OSS=ROOT.parents[3]/'tools/oss-cad-suite/oss-cad-suite'
os.environ['PATH']=os.pathsep.join([str(OSS/'bin'),str(OSS/'lib'),os.environ.get('PATH','')])

def encode_frame(pixels,w,h):
 tokens=[]
 for y in range(h):
  x=0
  while x<w:
   value=pixels[y*w+x];end=x+1
   while end<w and pixels[y*w+end]==value:end+=1
   tokens.append((value,x,y,end-x,int(x==0 and y==0),int(end==w),int(end==w and y==h-1)))
   x=end
 return tokens

def execute(source,files,top='tb'):
 with tempfile.TemporaryDirectory(prefix='binary_rle_test_') as temporary:
  t=Path(temporary)
  for name,data in files.items():(t/name).write_text(data)
  (t/'tb.v').write_text(source)
  p=subprocess.run(['iverilog','-g2012','-s',top,'-o',str(t/'sim'),str(ROOT/'binary_rle_encoder.v'),str(ROOT/'binary_rle_decoder.v'),str(t/'tb.v')],capture_output=True,text=True)
  if p.returncode:raise RuntimeError(p.stderr)
  p=subprocess.run(['vvp',str(t/'sim')],cwd=t,capture_output=True,text=True,timeout=240)
  if p.returncode or 'PASS' not in p.stdout:raise RuntimeError(p.stdout+p.stderr)
  return p.stdout.strip()

def run():
 rng=random.Random(2026475);results=[]
 for w,h in ((1,1),(1,7),(7,1),(9,5),(257,2),(4096,1),(65535,1)):
  n=w*h;xw=max(1,(w-1).bit_length());yw=max(1,(h-1).bit_length());lw=w.bit_length()
  frames=[[0]*n,[1]*n,[(x+y)%2 for y in range(h) for x in range(w)],
          [int(x>=w//2) for y in range(h) for x in range(w)],
          [(x//7)%2 for y in range(h) for x in range(w)],
          [rng.randrange(2) for _ in range(n)],
          [int(x in (0,w//2,w-1)) for y in range(h) for x in range(w)],
          [int(x==w-1) for y in range(h) for x in range(w)],[0]*n]
  tokens=[];ends=[]
  for frame in frames:tokens.extend(encode_frame(frame,w,h));ends.append(len(tokens))
  packed=[]
  for value,x,y,length,sof,eol,last in tokens:
   result=value
   for field,width in ((x,xw),(y,yw),(length,lw),(sof,1),(eol,1),(last,1)):result=(result<<width)|field
   packed.append(result)
  files={'pixels.hex':'\n'.join(str(v) for frame in frames for v in frame)+'\n',
         'tokens.hex':'\n'.join(f'{v:x}' for v in packed)+'\n',
         'ends.hex':'\n'.join(f'{v:x}' for v in ends)+'\n'}
  source=ROUNDTRIP.replace('@PARAM@',f'W={w},H={h},XW={xw},YW={yw},LW={lw},NF={len(frames)},NP={n*len(frames)},NT={len(tokens)}')
  output=execute(source,files);print(w,h,output,flush=True)
  results.append({'width':w,'height':h,'frames':len(frames),'pixels':n*len(frames),'tokens':len(tokens),'maximum_run_length':max(token[3] for token in tokens)})
 bad=run_bad_tokens()
 invalid=[('WIDTH',0),('WIDTH',65536),('HEIGHT',0),('HEIGHT',65536)]
 with tempfile.TemporaryDirectory(prefix='binary_rle_invalid_') as temporary:
  t=Path(temporary)
  for module in ('binary_rle_encoder','binary_rle_decoder'):
   for parameter,value in invalid:
    (t/'tb.v').write_text(f'module tb;{module} #(.{parameter}({value})) dut();initial #1 $finish;endmodule')
    p=subprocess.run(['iverilog','-g2012','-s','tb','-o',str(t/'sim'),str(ROOT/(module+'.v')),str(t/'tb.v')],capture_output=True,text=True)
    if p.returncode:continue
    p=subprocess.run(['vvp',str(t/'sim')],capture_output=True,text=True)
    if p.returncode==0:raise AssertionError(f'invalid {module} {parameter}={value} accepted')
 (ROOT/'test_result.json').write_text(json.dumps({'status':'PASS','cases':results,'bad_token_cases':bad,'invalid_static_parameters':2*len(invalid),'seed':2026475},indent=2)+'\n')

def run_bad_tokens():
 # Tuples value,start,y,length,sof,eol,last; expected code is an exact bitmask.
 prefix=[(0,0,0,2,1,0,0)]
 cases=[([], (0,0,0,0,1,0,0),1),([], (0,1,0,1,0,0,0),2),
        ([], (0,0,0,6,1,0,0),4),([], (0,0,0,5,0,1,0),8),
        ([], (0,0,0,5,1,0,0),8),([], (0,0,0,5,1,1,1),8),
        ([], (0,7,0,1,0,0,0),22),([], (0,0,3,5,0,1,0),18),
        (prefix,(0,2,0,3,0,1,0),32),(prefix,(1,1,0,2,0,0,0),2),
        (prefix,(1,2,0,3,1,1,0),8),
        ([(0,0,0,5,1,1,0)],(1,0,0,5,1,1,0),2),
        ([(0,0,0,5,1,1,0),(1,0,1,5,0,1,0)],(0,0,2,5,0,1,0),8)]
 expected=[];seq=[]
 def send(token):seq.append('send_token('+','.join(map(str,token))+');')
 for prefixes,bad,error in cases:
  for token in prefixes:send(token);expected.extend([token[0]]*token[3])
  send(bad);seq.append(f'finish_case({len(expected)},{error});')
  # Recover after every error using equal values across rows (which is legal).
  for y in range(3):send((1,0,y,5,int(y==0),1,int(y==2)));expected.extend([1]*5)
  seq.append(f'finish_case({len(expected)},0);')
 source=BAD.replace('@COUNT@',str(len(expected))).replace('@SEQ@','\n'.join(seq))
 print(execute(source,{'expected.hex':'\n'.join(str(v) for v in expected)+'\n'}),flush=True)
 return len(cases)

ROUNDTRIP=r'''
module tb;
localparam @PARAM@;
localparam TW=1+XW+YW+LW+3;
reg clk=0;always #5 clk=~clk;
reg rst=1,ce=1,sv=0,sof=0,eol=0,value=0,mr=0,dr=0,pause=0,hold_output=0,checking=1;
wire sr,tv,tr,tvalue,tsof,teol,tlast,edone,eerror,ebusy;
wire[XW-1:0] tx;wire[YW-1:0] ty;wire[LW-1:0] tlength;
wire mv,mvalue,ms,me,ml,ddone,dbusy;wire[5:0] error;wire[XW-1:0] x;wire[YW-1:0] y;
binary_rle_encoder #(.WIDTH(W),.HEIGHT(H)) encoder(
.clk(clk),.rst(rst),.ce(ce),.s_value(value),.s_valid(sv),.s_sof(sof),.s_eol(eol),.s_ready(sr),.m_valid(tv),.m_ready(tr),.m_value(tvalue),.m_start_x(tx),.m_y(ty),.m_length(tlength),.m_sof(tsof),.m_eol(teol),.m_last(tlast),.done_valid(edone),.done_ready(dr),.frame_error(eerror),.busy(ebusy));
binary_rle_decoder #(.WIDTH(W),.HEIGHT(H)) decoder(
.clk(clk),.rst(rst),.ce(ce),.s_value(tvalue),.s_valid(tv),.s_start_x(tx),.s_y(ty),.s_length(tlength),.s_sof(tsof),.s_eol(teol),.s_last(tlast),.s_ready(tr),.m_valid(mv),.m_ready(mr),.m_value(mvalue),.m_x(x),.m_y(y),.m_sof(ms),.m_eol(me),.m_last(ml),.done_valid(ddone),.done_ready(dr),.error(error),.busy(dbusy));
reg pixels[0:NP-1];reg[TW-1:0] tokens[0:NT-1];reg[31:0] ends[0:NF-1];
reg[31:0] random_state=32'hab341c71;integer received=0,token_received=0,cycles=0,fi,i,index;
reg held=0,theld=0;reg[127:0] payload,tpayload;
always @(negedge clk)begin
random_state=random_state^(random_state<<13);random_state=random_state^(random_state>>17);random_state=random_state^(random_state<<5);
ce=pause?0:random_state[3:0]!=0;mr=hold_output?0:random_state[6:4]!=0;
end
always @(posedge clk)if(!rst)begin
cycles=cycles+1;if(cycles>10000000)$fatal(1,"timeout");
if(held&&(!mv||{mvalue,x,y,ms,me,ml}!==payload))$fatal(1,"pixel stall");
held=mv&&!(ce&&mr);payload={mvalue,x,y,ms,me,ml};
if(theld&&(!tv||{tvalue,tx,ty,tlength,tsof,teol,tlast}!==tpayload))$fatal(1,"token stall");
theld=tv&&!(ce&&tr);tpayload={tvalue,tx,ty,tlength,tsof,teol,tlast};
if(checking&&ce&&tv&&tr)begin
if(token_received>=NT||{tvalue,tx,ty,tlength,tsof,teol,tlast}!==tokens[token_received])$fatal(1,"token%0d got%h expected%h",token_received,{tvalue,tx,ty,tlength,tsof,teol,tlast},tokens[token_received]);
token_received=token_received+1;
end
if(checking&&ce&&mv&&mr)begin
if(received>=NP||mvalue!==pixels[received]||error!==0)$fatal(1,"lossless pixel%0d",received);
index=received%(W*H);
if(x!==index%W||y!==index/W||ms!==(index==0)||me!==(index%W==W-1)||ml!==(index==W*H-1))$fatal(1,"pixel metadata");
received=received+1;
end
end
task send_pixel(input v,input first,lastpixel);begin
repeat(v)@(negedge clk);#1;value=v;sof=first;eol=lastpixel;sv=1;
@(posedge clk);while(!sr)@(posedge clk);
@(negedge clk);#1;sv=0;
end endtask
task finish_frame(input integer count,nt,expected_error);begin
while(!edone||!ddone)@(negedge clk);#1;
if(received!=count||token_received!=nt||error!==0||eerror!=expected_error)$fatal(1,"terminal pixels%0d tokens%0d eerr%0d derr%0d",received,token_received,eerror,error);
repeat(5)begin @(negedge clk);#1;if(!edone||!ddone||eerror!=expected_error||error!==0)$fatal(1,"DONE stall");end
dr=1;@(posedge clk);while(!ce)@(posedge clk);
@(negedge clk);#1;dr=0;
end endtask
task reset_dut;begin
@(negedge clk);#1;pause=1;rst=1;sv=0;repeat(2)@(negedge clk);#1;rst=0;held=0;theld=0;
if(mv||tv||edone||ddone||eerror||error!==0)$fatal(1,"reset");pause=0;
end endtask
initial begin
$readmemh("pixels.hex",pixels);$readmemh("tokens.hex",tokens);$readmemh("ends.hex",ends);
repeat(3)@(negedge clk);#1;rst=0;
for(fi=0;fi<NF;fi=fi+1)begin
if(fi==NF-1)begin
checking=0;hold_output=1;
send_pixel(0,1,W==1);
if(W*H>1)send_pixel(1,W==1,W<=2);
while(!mv)@(negedge clk);repeat(5)@(negedge clk);reset_dut;hold_output=0;checking=1;
end
for(i=0;i<W*H;i=i+1)send_pixel(pixels[fi*W*H+i],i==0&&fi!=6,i%W==W-1&&fi!=7);
finish_frame((fi+1)*W*H,ends[fi],fi==6||fi==7);
end
$display("PASS %0d true RTL roundtrip pixels and %0d exact canonical tokens",received,token_received);$finish;
end
endmodule
'''

BAD=r'''
module tb;
reg clk=0;always #5 clk=~clk;
reg rst=1,ce=1,sv=0,value=0,sof=0,eol=0,last=0,mr=0,dr=0;
reg[2:0] sx=0,length=0;reg[1:0] sy=0;
wire sr,mv,ov,os,oe,ol,done,busy;wire[2:0] x;wire[1:0] y;wire[5:0] error;
binary_rle_decoder #(.WIDTH(5),.HEIGHT(3)) decoder(
.clk(clk),.rst(rst),.ce(ce),.s_value(value),.s_valid(sv),.s_start_x(sx),.s_y(sy),.s_length(length),.s_sof(sof),.s_eol(eol),.s_last(last),.s_ready(sr),
.m_valid(mv),.m_ready(mr),.m_value(ov),.m_x(x),.m_y(y),.m_sof(os),.m_eol(oe),.m_last(ol),.done_valid(done),.done_ready(dr),.error(error),.busy(busy));
reg expected[0:@COUNT@-1];reg[31:0] random_state=32'h19bc43af;integer received=0,cycles=0;
always @(negedge clk)begin
random_state=random_state^(random_state<<13);random_state=random_state^(random_state>>17);random_state=random_state^(random_state<<5);
ce=random_state[3:0]!=0;mr=random_state[6:4]!=0;
end
always @(posedge clk)if(!rst)begin
cycles=cycles+1;if(cycles>100000)$fatal(1,"timeout");
if(ce&&mv&&mr)begin
if(received>=@COUNT@||ov!==expected[received])$fatal(1,"bad token emitted pixels");received=received+1;
end
end
task send_token(input v,input integer a,b,n,input first,lastrow,lastframe);begin
@(negedge clk);#1;value=v;sx=a;sy=b;length=n;sof=first;eol=lastrow;last=lastframe;sv=1;
@(posedge clk);while(!sr)@(posedge clk);
@(negedge clk);#1;sv=0;
end endtask
task finish_case(input integer count,expected_error);begin
while(!done)@(negedge clk);#1;
if(received!=count||error!==expected_error||mv||sr)$fatal(1,"bad case pixels%0d expected%0d error%0d expected%0d",received,count,error,expected_error);
repeat(5)begin @(negedge clk);#1;if(!done||error!==expected_error||sr||mv)$fatal(1,"error hold");end
dr=1;@(posedge clk);while(!ce)@(posedge clk);
@(negedge clk);#1;dr=0;if(error!==0)$fatal(1,"error recovery");
end endtask
initial begin
$readmemh("expected.hex",expected);repeat(3)@(negedge clk);#1;rst=0;
@SEQ@
$display("PASS 13 malformed token cases and 13 full recovery frames, %0d valid prefix/recovery pixels",received);$finish;
end
endmodule
'''
if __name__=='__main__':run()
