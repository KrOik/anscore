"""Exact rational normal-vector Hough oracle and actual RTL regression."""
from pathlib import Path
from fractions import Fraction
import os,tempfile,subprocess,json,random,math
ROOT=Path(__file__).resolve().parent
OSS=ROOT.parents[3]/'tools/oss-cad-suite/oss-cad-suite'
os.environ['PATH']=os.pathsep.join([str(OSS/'bin'),str(OSS/'lib'),os.environ.get('PATH','')])
NORMALS=((Fraction(1),Fraction(0)),(Fraction(181,256),Fraction(181,256)),(Fraction(0),Fraction(1)),(-Fraction(181,256),Fraction(181,256)))
def oracle(image,cw):
    h=len(image);w=len(image[0]);r=w+h-2;sat=(1<<cw)-1
    counts={(angle,rho):0 for angle in range(4) for rho in range(-r,r+1)};overflow=False
    for y,row in enumerate(image):
        for x,edge in enumerate(row):
            if edge:
                for angle,(nx,ny) in enumerate(NORMALS):
                    rho=math.floor(nx*x+ny*y+Fraction(1,2));key=(angle,rho)
                    if counts[key]==sat:overflow=True
                    else:counts[key]+=1
    peak=min(counts,key=lambda key:(-counts[key],key))
    return list(counts.items()),peak,counts[peak],overflow

def run():
    rng=random.Random(2026450);cases=[]
    with tempfile.TemporaryDirectory(prefix='hough_lines_') as temp:
        td=Path(temp)
        for w,h,cw in ((1,1,8),(1,5,8),(6,1,8),(5,7,8),(8,6,8),(7,7,2),(3,2,1)):
            images=[[[0]*w for y in range(h)],[[int(x==w//2) for x in range(w)] for y in range(h)],[[int(y==h//2) for x in range(w)] for y in range(h)],[[int(x==y) for x in range(w)] for y in range(h)],[[int(x==0 or y==0 or x+y==min(w,h)-1) for x in range(w)] for y in range(h)],[[rng.randrange(2) for x in range(w)] for y in range(h)],[[1]*w for y in range(h)]]
            sequence=[];expected=[];peaks=[];flags=[]
            # Final blank frame follows an interrupted edge frame and proves RAM clear on reset.
            for fi,image in enumerate(images+[[[0]*w for y in range(h)]]):
                bins,peak,pc,overflow=oracle(image,cw);expected += [(angle,rho,value) for (angle,rho),value in bins];peaks.append((*peak,pc));flags.append((int(overflow),int(fi in (4,5))))
                if fi==len(images):sequence.append('send_pixel(1,1,W==1); reset_dut;')
                for y,row in enumerate(image):
                    for x,value in enumerate(row):sequence.append(f'send_pixel({value},{int(x==0 and y==0) if fi!=4 else 0},{int(x==w-1) if not (fi==5 and x==0 and y==0) else int(x!=w-1)});')
                sequence.append(f'finish_frame({fi});')
            (td/'counts.hex').write_text('\n'.join(f'{v:x}' for a,r,v in expected))
            (td/'peak_count.hex').write_text('\n'.join(f'{v:x}' for a,r,v in peaks))
            (td/'peak_theta.hex').write_text('\n'.join(f'{a:x}' for a,r,v in peaks))
            (td/'peak_rho.hex').write_text('\n'.join(f'{r&65535:x}' for a,r,v in peaks))
            (td/'flags.hex').write_text('\n'.join(f'{overflow|(marker<<1):x}' for overflow,marker in flags))
            tb=TB.replace('@W@',str(w)).replace('@H@',str(h)).replace('@CW@',str(cw)).replace('@N@',str(len(expected))).replace('@SEQ@','\n'.join(sequence))
            (td/'tb.sv').write_text(tb)
            subprocess.run(['iverilog','-g2012','-s','tb','-o',str(td/'sim'),str(ROOT/'hough_lines4.v'),str(td/'tb.sv')],check=True,capture_output=True)
            p=subprocess.run(['vvp',str(td/'sim')],cwd=td,text=True,capture_output=True)
            if p.returncode or 'PASS' not in p.stdout:raise RuntimeError(f'{w}x{h}/{cw}\n'+p.stdout+p.stderr)
            print(w,h,cw,p.stdout.splitlines()[0]);cases.append({'width':w,'height':h,'count_bits':cw,'frames':8,'bins':len(expected)})
        for name,value in (('WIDTH',0),('HEIGHT',0),('WIDTH',4097),('COUNT_W',0),('COUNT_W',25)):
            (td/'bad.sv').write_text(f'module tb;hough_lines4 #(.{name}({value})) d();endmodule')
            compiled=subprocess.run(['iverilog','-g2012','-s','tb','-o',str(td/'bad'),str(ROOT/'hough_lines4.v'),str(td/'bad.sv')],capture_output=True)
            if compiled.returncode==0:assert subprocess.run(['vvp',str(td/'bad')],capture_output=True).returncode
    (ROOT/'test_result.json').write_text(json.dumps({'status':'PASS','cases':cases,'invalid_parameters':5,'seed':2026450},indent=2)+'\n')
TB=r'''
module tb;
localparam W=@W@,H=@H@,CW=@CW@,R=W+H-2,BINS=2*R+1,TOTAL=4*BINS,N=@N@,RW=R<1?1:$clog2(R+1)+1;
reg clk=0;always #5 clk=~clk;
reg rst=1,ce=1,edgebit=0,sv=0,sof=0,eol=0,mr=0,pr=0;
wire sr,mv,last,pv,overflow,marker,busy;wire[1:0] theta,pt;wire signed[RW-1:0] rho,peakrho;wire[CW-1:0] count,peakcount;
hough_lines4 #(.WIDTH(W),.HEIGHT(H),.COUNT_W(CW)) d(clk,rst,ce,edgebit,sv,sof,eol,sr,mv,mr,theta,rho,count,last,pv,pr,pt,peakrho,peakcount,overflow,marker,busy);
reg[CW-1:0] expected[0:N-1],pc[0:7];reg[1:0] pa[0:7],flags[0:7];reg signed[15:0] pp[0:7];
integer received=0,cycles=0;reg[31:0] random_state=32'h1819454;reg held=0;reg[CW+RW+2:0] held_bin;
always @(negedge clk)begin
 random_state={random_state[30:0],random_state[31]^random_state[21]^random_state[1]^random_state[0]};
 ce=random_state[0]|random_state[2];mr=random_state[3]|random_state[5];
end
always @(posedge clk)if(!rst)begin
 cycles=cycles+1;if(cycles>1000000)$fatal(1,"timeout");
 if(held&&(!mv||{theta,rho,count,last}!==held_bin))$fatal(1,"bin stall");
 held=mv&&!(ce&&mr);held_bin={theta,rho,count,last};
 if(ce&&mv&&mr)begin
 if(received>=N||count!==expected[received])$fatal(1,"bin %0d got%0d expected%0d",received,count,expected[received]);
 if(theta!==((received%TOTAL)/BINS)||$signed(rho)!==((received%BINS)-R)||last!==(received%TOTAL==TOTAL-1))$fatal(1,"bin address metadata");
 received=received+1;
 end
end
 task send_pixel(input value,f,l);begin
 repeat(value+1)@(negedge clk);#1;edgebit=value;sof=f;eol=l;sv=1;
 @(posedge clk);while(!sr)@(posedge clk);
 @(negedge clk);#1;sv=0;
 end endtask
 task finish_frame(input integer i);reg[CW+RW+3:0] snapshot;begin
 while(!pv)@(negedge clk);#1;
 if(received!=(i+1)*TOTAL||pt!==pa[i]||$signed(peakrho)!==$signed(pp[i])||peakcount!==pc[i]||{marker,overflow}!==flags[i])$fatal(1,"peak/flags frame%0d got angle%0d rho%0d count%0d flags%b",i,pt,$signed(peakrho),peakcount,{marker,overflow});
 snapshot={pt,peakrho,peakcount,marker,overflow};
 repeat(6)begin @(negedge clk);#1;if(!pv||snapshot!=={pt,peakrho,peakcount,marker,overflow})$fatal(1,"peak stall");end
 pr=1;@(posedge clk);while(!ce)@(posedge clk);
 @(negedge clk);#1;pr=0;
 end endtask
 task reset_dut;begin
 @(negedge clk);#1;rst=1;sv=0;@(negedge clk);#1;rst=0;held=0;
 if(mv||pv||overflow||marker)$fatal(1,"reset");
 end endtask
 initial begin
 $readmemh("counts.hex",expected);$readmemh("peak_count.hex",pc);$readmemh("peak_theta.hex",pa);$readmemh("peak_rho.hex",pp);$readmemh("flags.hex",flags);
 repeat(3)@(negedge clk);#1;rst=0;
 @SEQ@
 if(received!=N)$fatal(1,"terminal count");
 $display("PASS %0d Hough bins + 8 peaks/flags",N);$finish;
 end
endmodule
'''
if __name__=='__main__':run()
