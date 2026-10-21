"""Independent sample-position reference, and executable randomized RTL regression."""
from pathlib import Path
import tempfile, subprocess, random, json, os
ROOT=Path(__file__).resolve().parent
OSS=ROOT.parents[4]/'tools/oss-cad-suite/oss-cad-suite'
os.environ['PATH']=os.pathsep.join([str(OSS/'bin'),str(OSS/'lib'),os.environ.get('PATH','')])

def reconstruct(words,w,siting,linear,bits):
    """Interpolate a sampled function at chroma coordinates 2*k + phase."""
    channels=[[p[1] for p in words],[p[3] for p in words]]
    result=[]
    for x in range(w):
        out=[words[x//2][2 if x%2 else 0]]
        for samples in channels:
            if not linear: value=samples[max(0,min(len(samples)-1,(2*x-(1 if siting else 0)+2)//4))]
            else:
                # Exact quarter-grid location; independent of RTL tap cases.
                location=2*x-(1 if siting else 0)
                lo=location//4; frac=location-4*lo
                a=samples[max(0,min(len(samples)-1,lo))]
                b=samples[max(0,min(len(samples)-1,lo+1))]
                value=((4-frac)*a+frac*b+2)//4
            out.append(value)
        result.append(out)
    return result

def run():
    rng=random.Random(422444); cases=0; pixels=0
    with tempfile.TemporaryDirectory(prefix='chroma422_') as td:
        td=Path(td)
        for bits in (8,10):
          for w,h in ((1,1),(2,3),(3,2),(7,5),(8,4)):
            frames=[]; expected=[]
            for siting,linear in ((0,0),(1,0),(0,1),(1,1)):
                rows=[[[rng.randrange(1<<bits) for _ in range(4)] for _ in range((w+1)//2)] for y in range(h)]
                frames.append(rows)
                expected += [sum(v << (bits*(2-i)) for i,v in enumerate(p)) for row in rows for p in reconstruct(row,w,siting,linear,bits)]
            (td/'expected.hex').write_text('\n'.join(f'{v:x}' for v in expected))
            seq=[]
            for fi,rows in enumerate(frames):
                seq.append(f'configure({fi//2}, {fi%2});')
                # frame ordering is nearest0,nearest1,linear0,linear1
                seq[-1]=f'configure({fi%2}, {fi//2}); configure(3, 0);'
                for y,row in enumerate(rows):
                    for k,p in enumerate(row):
                        value=sum(v << (bits*(3-i)) for i,v in enumerate(p))
                        seq.append(f'send_word({4*bits}\'h{value:x},{int(y==0 and k==0)},{int(k==len(row)-1)});')
                seq.append('while(busy) @(negedge clk);')
            tb=TB.replace('@BITS@',str(bits)).replace('@W@',str(w)).replace('@H@',str(h)).replace('@COUNT@',str(len(expected))).replace('@SEQ@','\n'.join(seq))
            (td/'tb.sv').write_text(tb)
            subprocess.run(['iverilog','-g2012','-s','tb','-o',str(td/'sim'),str(ROOT/'chroma_upsample422.v'),str(td/'tb.sv')],check=True)
            proc=subprocess.run(['vvp',str(td/'sim')],cwd=td,check=True,capture_output=True,text=True)
            if 'PASS' not in proc.stdout: raise RuntimeError(proc.stdout)
            print(bits,w,h,proc.stdout.strip());cases+=1;pixels+=len(expected)
        for param in ('BITS=7','WIDTH=0','HEIGHT=0'):
            name,val=param.split('=')
            (td/'bad.sv').write_text(f'module tb;chroma_upsample422 #(.{name}({val})) d();endmodule')
            subprocess.run(['iverilog','-g2012','-s','tb','-o',str(td/'bad'),str(ROOT/'chroma_upsample422.v'),str(td/'bad.sv')],check=True)
            bad=subprocess.run(['vvp',str(td/'bad')],capture_output=True)
            assert bad.returncode!=0
    report={'status':'PASS','numeric_cases':cases,'pixels':pixels,'invalid_parameters':3,'seed':422444}
    (ROOT/'test_result.json').write_text(json.dumps(report,indent=2)+'\n')
TB=r'''
module tb;
localparam B=@BITS@,W=@W@,H=@H@,N=@COUNT@;
reg clk=0;always #5 clk=~clk;
reg rst=1,ce=1,cv=0,lin=0,sv=0,su=0,sl=0,mr=0;reg[1:0] sit=0;
reg[4*B-1:0] sd=0;wire sr,cr,err,busy,me,mv,mu,ml;wire[3*B-1:0] md;
reg[3*B-1:0] expected[0:N-1];integer count=0,cycles=0;reg[31:0] random_state=32'h726494;
reg held=0;reg[3*B+1:0] hold_data;
chroma_upsample422 #(.BITS(B),.WIDTH(W),.HEIGHT(H)) d(clk,rst,ce,cv,sit,lin,cr,err,sd,sv,su,sl,sr,md,mv,mu,ml,mr,busy,me);
always @(negedge clk) begin
 random_state={random_state[30:0],random_state[31]^random_state[21]^random_state[1]^random_state[0]};
 ce=random_state[0]|random_state[3];mr=random_state[2]|random_state[5];
end
always @(posedge clk) if(!rst) begin
 cycles=cycles+1;if(cycles>200000) $fatal(1,"timeout");
 if(held && {md,mu,ml}!==hold_data) $fatal(1,"stall instability");
 held=mv&&!(ce&&mr);hold_data={md,mu,ml};
 if(ce&&mv&&mr) begin
 if(count>=N || md!==expected[count]) $fatal(1,"numeric %0d got %h expected %h",count,md,expected[count]);
 if(mu!==(count%(W*H)==0)||ml!==(count%W==W-1)) $fatal(1,"markers");
 count=count+1;
 end
end
 task configure(input[1:0] s,input l);begin
 @(negedge clk);#1;cv=1;sit=s;lin=l;
 @(posedge clk);while(!cr) @(posedge clk);
 @(negedge clk);#1;cv=0;
 end endtask
 task send_word(input[4*B-1:0] v,input u,input last);begin
 repeat((v%3)) @(negedge clk);
 #1;sd=v;su=u;sl=last;sv=1;
 @(posedge clk);while(!sr) @(posedge clk);
 @(negedge clk);#1;sv=0;
 end endtask
 initial begin
 $readmemh("expected.hex",expected);
 repeat(3) @(negedge clk);#1;rst=0;
 configure(3,1);if(!err) $fatal(1,"illegal configuration not flagged");
 @SEQ@
 if(count!=N||me) $fatal(1,"count or marker error");
 // Malformed SOF/EOL is sticky, then reset aborts the partial frame.
 send_word(0,0,0);
 if(!me || !busy || cr) $fatal(1,"malformed input or busy config");
 // Reset is an explicit frame abort and clears diagnostics.
 @(negedge clk);#1;rst=1;@(negedge clk);#1;rst=0;
 if(busy||me||err||mv) $fatal(1,"reset");
 $display("PASS %0d pixels",count);$finish;
 end
endmodule
'''
if __name__=='__main__':run()



