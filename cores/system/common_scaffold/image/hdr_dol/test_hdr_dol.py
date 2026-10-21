"""Independent radiometric reference and randomized actual-RTL regression."""
from pathlib import Path
import os,tempfile,subprocess,random,json
ROOT=Path(__file__).resolve().parent
OSS=ROOT.parents[3]/'tools/oss-cad-suite/oss-cad-suite'
os.environ['PATH']=os.pathsep.join([str(OSS/'bin'),str(OSS/'lib'),os.environ.get('PATH','')])

def reference(long,short,bits,config):
    ratio,bl,bs,low,shift,threshold,deghost=config
    # Exposure normalization and convex interpolation in rational Q8 units.
    a=max(0,long-bl); b=max(0,short-bs)
    b=min((1<<(bits+8))-1,(b*ratio+128)//256)
    motion=bool(deghost and abs(a-b)>threshold)
    fraction=max(0,min(256,(a-low)*256//(1<<shift)))
    value=a if motion and a<low+(1<<shift) else (a*(256-fraction)+b*fraction+128)//256
    return value,motion

def run():
 rng=random.Random(2026422);cases=0;pixels=0
 with tempfile.TemporaryDirectory(prefix='hdr_dol_') as temp:
  td=Path(temp)
  for bits in (8,10,12):
   for w,h in ((1,1),(2,3),(5,3),(8,4)):
    maxv=(1<<bits)-1; configs=[]; vectors=[];expected=[];seq=[]
    for f in range(6):
     shift=bits-2;low=(1<<shift)+f;cfg=((65535 if f==5 else 256+f*511),f*2,f*3,low,shift,f*17,f%2)
     configs.append(cfg);seq.append('configure('+','.join(map(str,cfg))+'); configure_bad;')
     for y in range(h):
      longs=[rng.randrange(maxv+1) for _ in range(w)];shorts=[rng.randrange(maxv+1) for _ in range(w)]
      if y==0:longs[0]=maxv;shorts[0]=maxv
      if w>1:
       longs[1]=min(maxv,low+cfg[1]);shorts[1]=0
      if w>2:
       longs[2]=min(maxv,low+(1<<shift)+cfg[1]);shorts[2]=maxv
      for phase,row in enumerate((longs,shorts)):
       for x,value in enumerate(row): seq.append(f'send_pixel({value},{phase},{int(x==0 and y==0 and phase==0)},{int(x==w-1)});')
      for a,b in zip(longs,shorts):
       v,m=reference(a,b,bits,cfg);expected.append(v|(int(m)<<(bits+8)))
     seq.append(f'while(count<{(f+1)*w*h}) @(negedge clk);')
    (td/'expected.hex').write_text('\n'.join(f'{v:x}' for v in expected))
    tb=TB.replace('@B@',str(bits)).replace('@W@',str(w)).replace('@H@',str(h)).replace('@N@',str(len(expected))).replace('@SEQ@','\n'.join(seq))
    (td/'tb.sv').write_text(tb)
    subprocess.run(['iverilog','-g2012','-s','tb','-o',str(td/'sim'),str(ROOT/'raw_hdr_dol.v'),str(td/'tb.sv')],check=True,capture_output=True)
    p=subprocess.run(['vvp',str(td/'sim')],cwd=td,text=True,capture_output=True)
    if p.returncode or 'PASS' not in p.stdout:raise RuntimeError(p.stdout+p.stderr)
    print(bits,w,h,p.stdout.splitlines()[0]);cases+=1;pixels+=len(expected)
  for module in ('raw_dol2_demux','raw_hdr2_merge'):
   for name,val in (('BITS',7),('WIDTH',0),('HEIGHT',0)):
    (td/'bad.sv').write_text(f'module tb;{module} #(.{name}({val})) d();endmodule')
    subprocess.run(['iverilog','-g2012','-s','tb','-o',str(td/'bad'),str(ROOT/'raw_hdr_dol.v'),str(td/'bad.sv')],check=True,capture_output=True)
    assert subprocess.run(['vvp',str(td/'bad')],capture_output=True).returncode
 (ROOT/'test_result.json').write_text(json.dumps({'status':'PASS','cases':cases,'pixels':pixels,'invalid_static_parameters':6,'seed':2026422},indent=2)+'\n')
TB=r'''
module tb;
localparam B=@B@,W=@W@,H=@H@,N=@N@;
reg clk=0;always #5 clk=~clk;
reg rst=1,ce=1,sv=0,su=0,se=0,ss=0,mr=0;reg[B-1:0] sd=0;
wire sr,dv,du,de,dr,db,derr;wire[2*B-1:0] dd;
reg cv=0;wire cr,cer;reg[15:0] ratio=256;reg[B-1:0] bl=0,bs=0,low=0;
reg[3:0] shift=0;reg[B+7:0] threshold=0;reg ghost=0;
reg inject_marker=0;
wire[B+7:0] md;wire mv,mu,me,mm,mer,mb;
raw_dol2_demux #(.BITS(B),.WIDTH(W),.HEIGHT(H)) d(clk,rst,ce,sd,sv,su,se,ss,sr,dd,dv,du,de,dr,db,derr);
raw_hdr2_merge #(.BITS(B),.WIDTH(W),.HEIGHT(H)) m(clk,rst,ce,cv,cr,ratio,bl,bs,low,shift,threshold,ghost,cer,dd,dv,(du^inject_marker),de,dr,md,mv,mu,me,mm,mr,mer,mb);
reg[B+8:0] exp[0:N-1];integer count=0,cycles=0;reg[31:0] random_state=32'h2918374;
reg held=0;reg[B+10:0] payload;
always @(negedge clk) begin
 random_state={random_state[30:0],random_state[31]^random_state[21]^random_state[1]^random_state[0]};
 ce=random_state[0]|random_state[4];mr=random_state[2]|random_state[5];
end
always @(posedge clk) if(!rst) begin
 cycles=cycles+1;if(cycles>1000000)$fatal(1,"timeout");
 if(held&&{mm,md,mu,me}!==payload)$fatal(1,"output unstable");
 held=mv&&!(ce&&mr);payload={mm,md,mu,me};
 if(ce&&mv&&mr) begin
 if(count>=N||{mm,md}!==exp[count])$fatal(1,"numeric %0d got %h expected %h",count,{mm,md},exp[count]);
 if(mu!==(count%(W*H)==0)||me!==(count%W==W-1))$fatal(1,"markers");
 count=count+1;
 end
end
 task configure(input integer r,b1,b2,l,sh,t,g);begin
 @(negedge clk);#1;ratio=r;bl=b1;bs=b2;low=l;shift=sh;threshold=t;ghost=g;cv=1;
 @(posedge clk);while(!cr)@(posedge clk);
 @(negedge clk);#1;cv=0;
 end endtask
 task configure_bad;reg[15:0] save;begin
 save=ratio;@(negedge clk);#1;ratio=0;cv=1;
 @(posedge clk);while(!cr)@(posedge clk);
 @(negedge clk);#1;cv=0;ratio=save;
 if(!cer)$fatal(1,"bad config");
 @(negedge clk);#1;shift=B+1;cv=1;
 @(posedge clk);while(!cr)@(posedge clk);
 @(negedge clk);#1;cv=0;shift=B-2;
 end endtask
 task send_pixel(input[B-1:0] value,input shortflag,sof,eol);begin
 repeat(value%3) @(negedge clk);
 #1;sd=value;ss=shortflag;su=sof;se=eol;sv=1;
 @(posedge clk);while(!sr)@(posedge clk);
 @(negedge clk);#1;sv=0;
 end endtask
 initial begin
 $readmemh("expected.hex",exp);
 repeat(3)@(negedge clk);#1;rst=0;
 @SEQ@
 if(count!=N||derr||mer)$fatal(1,"terminal status");
 inject_marker=1;
 begin: malformed
 integer ix;
 for(ix=0;ix<W;ix=ix+1) send_pixel(0,1,0,ix==W-1);
 for(ix=0;ix<W;ix=ix+1) send_pixel(0,1,0,ix==W-1);
 end
 while(!mer) @(negedge clk);
 if(!derr)$fatal(1,"bad DOL marker not flagged");
 if(!derr)$fatal(1,"bad DOL marker not flagged");
 #1;rst=1;@(negedge clk);#1;rst=0;
 if(db||mb||mv||dv||derr||mer||cer)$fatal(1,"reset abort");
 $display("PASS %0d HDR pixels",count);$finish;
 end
endmodule
'''
if __name__=='__main__':run()
