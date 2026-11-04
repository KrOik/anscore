#!/usr/bin/env python3
"""Bounded source checks and deterministic integer/Fraction LPC references."""
from datetime import datetime,timezone
from fractions import Fraction
import hashlib,json,os,random,shutil,subprocess,tempfile
from pathlib import Path
ROOT=Path(__file__).resolve().parent


def trunc_div(n,d):
    assert d>0
    return (-1 if n<0 else 1)*(abs(n)//d)


def oracle(r,frac):
    """List-based mathematical fixed-point recursion, with exact integer products."""
    order=len(r)-1;scale=1<<frac
    if r[0]<=0:return [0]*order,[0]*order,0,1
    energy=r[0]*scale;a=[];ks=[]
    for m in range(1,order+1):
        residual=r[m]*scale+sum(coef*r[m-j] for j,coef in enumerate(a,1))
        k=trunc_div(-residual*scale,energy)
        if abs(k)>=scale:return [0]*order,[0]*order,0,2
        a=[old+trunc_div(k*reverse,scale) for old,reverse in zip(a,reversed(a))]+[k]
        energy-=energy*k*k//(scale*scale)
        assert energy>0
        ks.append(k)
    return a,ks,energy,0


def exact_toeplitz(r):
    """Independent Fraction Gaussian elimination for unquantized LPC comparison."""
    n=len(r)-1
    a=[[Fraction(r[abs(i-j)]) for j in range(n)]+[Fraction(-r[i+1])] for i in range(n)]
    for c in range(n):
        rows=[i for i in range(c,n) if a[i][c]]
        if not rows:return None
        p=rows[0];a[c],a[p]=a[p],a[c];d=a[c][c];a[c]=[x/d for x in a[c]]
        for i in range(n):
            if i!=c:
                f=a[i][c];a[i]=[x-f*y for x,y in zip(a[i],a[c])]
    return [a[i][-1] for i in range(n)]


def fixtures(width,order):
    hi=(1<<(width-1))-1;lo=-(1<<(width-1));rng=random.Random(20261104+width*100+order)
    result=[[hi]+[0]*order,[1]+[0]*order,[0]*(order+1),[lo]+[hi]*order,
            [hi,hi]+[0]*(order-1),[1,lo]+[0]*(order-1),
            [hi]+[int(hi/2**i) for i in range(1,order+1)],
            [hi]+[int(hi/(-2)**i) for i in range(1,order+1)]]
    if order>1:result.append([hi,0,hi]+[0]*(order-2))
    if hi>=1<<order:
        result += [[1<<order]+[((-1)**i if sign<0 else 1)*(1<<(order-i)) for i in range(1,order+1)] for sign in (1,-1)]
    for _ in range(10):
        samples=[rng.randrange(-2,3) for _ in range(24)]
        r=[sum(samples[i]*samples[i+k] for i in range(len(samples)-k)) for k in range(order+1)]
        divisor=max(1,(max(abs(x) for x in r)+hi-1)//hi)
        r=[trunc_div(x,divisor) for x in r];r[0]=max(1,r[0]);result.append(r)
    result += [[rng.randrange(lo,hi+1) for _ in range(order+1)] for _ in range(3)]
    return result


def bench(w,f,o,t):
    frames=fixtures(w,o);cw=f+o+2;ew=w+f+1
    init=[];send=[];exact_errors=[]
    for frame,r in enumerate(frames):
        a,k,energy,error=oracle(r,f)
        exact=exact_toeplitz(r)
        if not error and exact:
            exact_errors.append(float(max(abs(Fraction(x,1<<f)-v) for x,v in zip(a,exact))))
        for j in range(o):
            i=frame*o+j
            init.append(f'ea[{i}]={cw}\'h{a[j]&((1<<cw)-1):x};ek[{i}]={f+1}\'h{k[j]&((1<<(f+1))-1):x};ee[{i}]={ew}\'h{energy:x};ef[{i}]={error};')
        for j,value in enumerate(r):
            send.append(f'put({w}\'h{value&((1<<w)-1):x},{t}\'h{(frame if j==0 else 0)&((1<<t)-1):x},{(frame+j)%3});')
    code=r'''
`timescale 1ns/1ps
module tb;
localparam W=__W__,F=__F__,O=__O__,T=__T__,CW=F+O+2,IW=$clog2(O+1),EW=W+F+1,N=__N__,TOTAL=N*O;
reg clk=0;always #5 clk=~clk;
reg rst=1,s_valid=0,m_ready=0;reg signed [W-1:0] s_r=0;reg [T-1:0] s_tag=0;
wire s_ready,m_valid,m_last;wire signed [CW-1:0] m_a;wire signed [F:0] m_reflection;
wire [IW-1:0] m_index;wire [EW-1:0] m_energy;wire [1:0] m_error;wire [T-1:0] m_tag;
levinson_durbin #(.DATA_W(W),.FRAC(F),.ORDER(O),.TAG_W(T)) dut(.*);
reg signed [CW-1:0] ea[0:TOTAL-1];reg signed [F:0] ek[0:TOTAL-1];
reg [EW-1:0] ee[0:TOTAL-1];reg [1:0] ef[0:TOTAL-1];
localparam RW=CW+F+1+IW+1+EW+2+T;
wire [RW-1:0] record={m_a,m_reflection,m_index,m_last,m_energy,m_error,m_tag};
reg [RW-1:0] previous;reg stalled=0,checking=0;
integer cycles=0,received=0,stalls=0,input_waits=0,held=0;
always @(negedge clk) begin
 if(rst) begin m_ready=0;held=0;end
 else if(m_valid) begin
  if(held<4) begin m_ready=0;held=held+1;end else m_ready=1;
 end else begin m_ready=0;held=0;end
end
always @(posedge clk) begin
 cycles=cycles+1;if(cycles>2000000) $fatal(1,"bounded watchdog");
 if(rst) stalled=0;
 else if(checking) begin
  if(stalled && (!m_valid || record!==previous)) $fatal(1,"stalled output changed");
  stalled=m_valid&&!m_ready;previous=record;if(stalled) stalls=stalls+1;
  if(m_valid&&m_ready) begin
   if(received>=TOTAL) $fatal(1,"extra output");
   if(m_a!==ea[received] || m_reflection!==ek[received] || m_energy!==ee[received] || m_error!==ef[received] ||
      m_index!==IW'(received%O+1) || m_last!==(received%O==O-1) || m_tag!==T'(received/O))
    $fatal(1,"token=%0d a=%0d/%0d k=%0d/%0d E=%0d/%0d error=%0d/%0d index=%0d tag=%0d",received,
      m_a,ea[received],m_reflection,ek[received],m_energy,ee[received],m_error,ef[received],m_index,m_tag);
   received=received+1;
  end
 end
end
task reset_core;
 begin
  @(negedge clk);rst=1;s_valid=0;repeat(2) @(posedge clk);@(negedge clk);rst=0;
  if(m_valid) $fatal(1,"reset retained output");
 end
endtask
task put(input [W-1:0] value,input [T-1:0] tag,input integer gap);
 begin
  repeat(gap) @(negedge clk);@(negedge clk);s_valid=1;s_r=value;s_tag=tag;
  @(posedge clk);while(!s_ready) begin input_waits=input_waits+1;@(posedge clk);end
  @(negedge clk);s_valid=0;s_r=0;s_tag=0;
 end
endtask
task simple_frame;
 integer j;
 begin put(1,0,0);for(j=1;j<=O;j=j+1)put(0,0,0);end
endtask
initial begin
 __INIT__
 reset_core();put(1,0,0);reset_core();
 simple_frame();wait(dut.state==7);repeat(2) @(posedge clk);reset_core();
 simple_frame();wait(dut.state==5);repeat(2) @(posedge clk);reset_core();
 simple_frame();wait(m_valid);reset_core();
 checking=1;
 __SEND__
 wait(received==TOTAL);repeat(8) @(posedge clk);
 if(m_valid) $fatal(1,"duplicate output");
 if(stalls<N*3 || input_waits==0) $fatal(1,"vacuous flow coverage");
 $display("PASS Levinson W=%0d F=%0d O=%0d T=%0d blocks=%0d tokens=%0d stalls=%0d waits=%0d",W,F,O,T,N,received,stalls,input_waits);$finish;
end
endmodule
'''
    for key,value in {'W':w,'F':f,'O':o,'T':t,'N':len(frames),'INIT':'\n'.join(init),'SEND':'\n'.join(send)}.items():
        code=code.replace('__'+key+'__',str(value))
    return code,{'data_w':w,'frac':f,'order':o,'tag_w':t,'blocks':len(frames),'tokens':len(frames)*o,
                 'max_coefficient_difference_to_exact_unquantized_toeplitz':max(exact_errors,default=0),
                 'error_blocks':sum(oracle(r,f)[-1]!=0 for r in frames)}


def main():
    (ROOT/'verification.json').unlink(missing_ok=True)
    for p in ROOT.rglob('*'):
        if p.is_file() and b'\r' in p.read_bytes():raise RuntimeError('LF required: '+str(p))
    suite=ROOT.parents[2]/'tools/oss-cad-suite/oss-cad-suite';env=os.environ.copy()
    env['PATH']=str(suite/'bin')+os.pathsep+str(suite/'lib')+os.pathsep+env['PATH']
    iv=str(suite/'bin/iverilog.exe') if (suite/'bin/iverilog.exe').is_file() else shutil.which('iverilog')
    vv=str(suite/'bin/vvp.exe') if (suite/'bin/vvp.exe').is_file() else shutil.which('vvp')
    if not iv or not vv:raise SystemExit('NOT_RUN: Icarus Verilog and vvp required')
    records=[];profiles=[]
    def run(cmd,cwd,negative=False):
        p=subprocess.run(cmd,cwd=cwd,env=env,text=True,capture_output=True,timeout=15)
        records.append({'command':[str(x) for x in cmd],'returncode':p.returncode,'stdout':p.stdout.strip(),'stderr':p.stderr.strip()})
        if negative:
            if not p.returncode or 'levinson_durbin_invalid_parameter__see_README' not in p.stderr:raise RuntimeError(p.stderr)
        elif p.returncode:raise RuntimeError(p.stdout+p.stderr)
        if p.stdout.strip():print(p.stdout.splitlines()[0] if '-V' in cmd else p.stdout.strip())
        return p
    with tempfile.TemporaryDirectory(prefix='anscore_levinson_') as temp:
        tmp=Path(temp);version=run([iv,'-V'],tmp).stdout.splitlines()[0]
        run([iv,'-g2012','-Wall','-tnull','-s','lpc4_example','-f','files.f','example/lpc4_example.sv'],ROOT)
        for w,f,o,t in [(2,1,1,1),(8,4,2,3),(16,16,4,8),(24,20,8,32),(8,1,8,8),(2,1,8,2)]:
            tb,profile=bench(w,f,o,t);path=tmp/'tb.sv';path.write_bytes(tb.encode());exe=tmp/'test.vvp'
            run([iv,'-g2012','-Wall','-s','tb','-o',exe,str(ROOT/'rtl/levinson_durbin.sv'),path],tmp)
            result=run([vv,exe],tmp)
            if 'PASS Levinson' not in result.stdout:raise RuntimeError('simulation completion missing')
            profiles.append(profile)
        for key,value in [('DATA_W',1),('DATA_W',25),('FRAC',0),('FRAC',21),('ORDER',0),('ORDER',9),('TAG_W',0),('TAG_W',33)]:
            run([iv,'-g2012','-tnull','-s','levinson_durbin',f'-Plevinson_durbin.{key}={value}',str(ROOT/'rtl/levinson_durbin.sv')],tmp,True)
    files=[p for p in ROOT.rglob('*') if p.is_file() and p.name!='verification.json']
    result={'status':['LINT_PASS','UNIT_SIM_PASS','HW_UNVERIFIED'],'checked_at_utc':datetime.now(timezone.utc).isoformat(),
            'tool_version':version,'per_process_timeout_seconds':15,'profiles':profiles,'commands':records,
            'scope':'finite fixed-point numerical/protocol checks; exact-Toeplitz comparison is descriptive, not a bit-equivalence claim',
            'source_sha256':{str(p.relative_to(ROOT)).replace('\\','/'):hashlib.sha256(p.read_bytes()).hexdigest() for p in files},
            'reproduce':'python -B cores/signal_processing/levinson_durbin/run_tests.py','not_run':['synthesis','PnR','STA','hardware']}
    (ROOT/'verification.json').write_bytes((json.dumps(result,indent=2)+'\n').encode())


if __name__=='__main__':main()
