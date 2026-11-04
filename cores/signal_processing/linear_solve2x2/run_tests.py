#!/usr/bin/env python3
"""Finite independent-reference simulation, source compile; no synthesis."""
from datetime import datetime, timezone
from fractions import Fraction
import hashlib
import json
import os
from pathlib import Path
import random
import shutil
import subprocess
import tempfile

ROOT=Path(__file__).resolve().parent


def oracle(v,frac,result_w):
    """Fraction Gaussian elimination; does not use Cramer's numerators."""
    a,b,c,d,u,vb=v
    determinant=a*d-b*c
    if not determinant: return 0,0,0,1,0
    matrix=[[Fraction(a),Fraction(b),Fraction(u)],
            [Fraction(c),Fraction(d),Fraction(vb)]]
    for column in range(2):
        pivot=next(r for r in range(column,2) if matrix[r][column])
        matrix[column],matrix[pivot]=matrix[pivot],matrix[column]
        scale=matrix[column][column]
        matrix[column]=[x/scale for x in matrix[column]]
        for r in range(2):
            if r!=column:
                scale=matrix[r][column]
                matrix[r]=[x-scale*y for x,y in zip(matrix[r],matrix[column])]
    exact=[matrix[i][2] for i in range(2)]
    # Check the mathematical solution independently before quantization.
    assert a*exact[0]+b*exact[1]==u and c*exact[0]+d*exact[1]==vb
    raw=[int(x*(1<<frac)) for x in exact]
    lo=-(1<<(result_w-1)); hi=(1<<(result_w-1))-1
    flags=sum((not lo<=x<=hi)<<i for i,x in enumerate(raw))
    return *(max(lo,min(hi,x)) for x in raw),determinant,0,flags


def vectors(width):
    low=-(1<<(width-1)); high=(1<<(width-1))-1
    rng=random.Random(20261104+width)
    result=[(1,0,0,1,high,low),(0,1,1,0,low,high),
            (-1,0,0,-1,low,high),(0,0,0,0,0,0),(1,1,1,1,0,1),
            (high,low,low,high,low,high),(low,0,0,low,low,high),
            (high,high-1,1,1,low,high),(high,high-1,1,1,high,low),
            (1,-1,-1,1,high,low),(1,1,0,1,low,high),
            (1,0,0,1,1,-1),(1,1,1,0,high,low)]
    result += [tuple(rng.randrange(low,high+1) for _ in range(6)) for _ in range(15)]
    return result


def bench(width,frac,rw,tagw):
    values=vectors(width); expectations=[oracle(v,frac,rw) for v in values]
    init=[]; sends=[]
    for i,(v,e) in enumerate(zip(values,expectations)):
        x,y,det,singular,flags=e
        def lit(n,w): return f"{w}'h{n&((1<<w)-1):x}"
        init.append(f'ex[{i}]={lit(x,rw)};ey[{i}]={lit(y,rw)};ed[{i}]={lit(det,2*width+1)};es[{i}]={singular};ef[{i}]={flags};')
        sends.append('send_command('+','.join(lit(x,width) for x in v)+f',{lit(i,tagw)},{i%3});')
    code=r'''
`timescale 1ns/1ps
module tb;
localparam W=__W__,F=__F__,R=__R__,T=__T__,N=__N__;
reg clk=0;always #5 clk=~clk;
reg rst=1,s_valid=0,m_ready=0;
reg signed [W-1:0] s_a00=0,s_a01=0,s_a10=0,s_a11=0,s_b0=0,s_b1=0;
reg [T-1:0] s_tag=0;
wire s_ready,m_valid,m_singular;
wire signed [R-1:0] m_x,m_y;
wire signed [2*W:0] m_determinant;
wire [1:0] m_saturated;wire [T-1:0] m_tag;
linear_solve2x2 #(.W(W),.FRAC(F),.RESULT_W(R),.TAG_W(T)) dut(.*);
reg signed [R-1:0] ex[0:N-1],ey[0:N-1];
reg signed [2*W:0] ed[0:N-1];reg es[0:N-1];reg [1:0] ef[0:N-1];
localparam RECORD_W=2*R+2*W+1+1+2+T;
wire [RECORD_W-1:0] record={m_x,m_y,m_determinant,m_singular,m_saturated,m_tag};
reg [RECORD_W-1:0] previous;
reg was_stalled=0,checking=0;
integer cycles=0,received=0,stalls=0,input_waits=0,held=0;
always @(negedge clk) begin
 if(rst) begin m_ready=0;held=0;end
 else if(m_valid) begin
  if(held<4) begin m_ready=0;held=held+1;end else m_ready=1;
 end else begin m_ready=0;held=0;end
end
always @(posedge clk) begin
 cycles=cycles+1;if(cycles>100000) $fatal(1,"bounded watchdog");
 if(rst) was_stalled=0;
 else if(checking) begin
  if(was_stalled && (!m_valid || record!==previous)) $fatal(1,"stall instability");
  previous=record;was_stalled=m_valid&&!m_ready;
  if(was_stalled) stalls=stalls+1;
  if(m_valid&&m_ready) begin
   if(received>=N) $fatal(1,"extra result");
   if(m_x!==ex[received] || m_y!==ey[received] || m_determinant!==ed[received] ||
      m_singular!==es[received] || m_saturated!==ef[received] || m_tag!==T'(received))
    $fatal(1,"i=%0d x=%0d/%0d y=%0d/%0d det=%0d/%0d sing=%b/%b flags=%b/%b",
       received,m_x,ex[received],m_y,ey[received],m_determinant,ed[received],m_singular,es[received],m_saturated,ef[received]);
   received=received+1;
  end
 end
end
task reset_core;
 begin
  @(negedge clk);rst=1;s_valid=0;repeat(2) @(posedge clk);
  @(negedge clk);rst=0;if(m_valid) $fatal(1,"reset pending output");
 end
endtask
task send_command(input [W-1:0] a,b,c,d,u,v,input [T-1:0] tag,input integer gap);
 begin
  repeat(gap) @(negedge clk);
  @(negedge clk);s_valid=1;s_a00=a;s_a01=b;s_a10=c;s_a11=d;s_b0=u;s_b1=v;s_tag=tag;
  @(posedge clk);while(!s_ready) begin input_waits=input_waits+1;@(posedge clk);end
  @(negedge clk);s_valid=0;s_a00=0;s_a01=0;s_a10=0;s_a11=0;s_b0=0;s_b1=0;s_tag=0;
 end
endtask
initial begin
 __INIT__
 reset_core();
 // Cancel first multiplication, first division, then a held result.
 send_command(1,0,0,1,1,1,0,0);repeat(2) @(posedge clk);reset_core();
 send_command(1,0,0,1,1,1,0,0);wait(dut.state==4);repeat(2) @(posedge clk);reset_core();
 send_command(1,0,0,1,1,1,0,0);wait(m_valid);reset_core();
 checking=1;
 __SEND__
 wait(received==N);repeat(8) @(posedge clk);
 if(m_valid) $fatal(1,"extra valid");
 if(stalls<N*3 || input_waits==0) $fatal(1,"vacuous protocol coverage");
 $display("PASS solve2x2 W=%0d F=%0d R=%0d T=%0d commands=%0d stalls=%0d waits=%0d",W,F,R,T,N,stalls,input_waits);$finish;
end
endmodule
'''
    for key,value in {'W':width,'F':frac,'R':rw,'T':tagw,'N':len(values),'INIT':'\n'.join(init),'SEND':'\n'.join(sends)}.items():
        code=code.replace('__'+key+'__',str(value))
    return code,len(values)


def main():
    (ROOT/'verification.json').unlink(missing_ok=True)
    # LF is part of the package evidence contract, not just a Git display rule.
    for p in ROOT.rglob('*'):
        if p.is_file() and p.name!='verification.json' and b'\r' in p.read_bytes():
            raise RuntimeError('normalize package text to LF before testing: '+str(p))
    env=os.environ.copy();suite=ROOT.parents[2]/'tools/oss-cad-suite/oss-cad-suite'
    env['PATH']=str(suite/'bin')+os.pathsep+str(suite/'lib')+os.pathsep+env['PATH']
    iv=str(suite/'bin/iverilog.exe') if (suite/'bin/iverilog.exe').is_file() else shutil.which('iverilog')
    vvp=str(suite/'bin/vvp.exe') if (suite/'bin/vvp.exe').is_file() else shutil.which('vvp')
    if not iv or not vvp: raise SystemExit('NOT_RUN: requires Icarus Verilog and vvp')
    records=[];profiles=[(2,0,4,1),(3,4,8,3),(8,8,16,8),(16,16,32,8),(24,24,32,32),(8,0,64,8)]
    def run(cmd,cwd,expected_failure=False):
        p=subprocess.run(cmd,cwd=cwd,env=env,capture_output=True,text=True,timeout=15)
        records.append({'command':[str(x) for x in cmd],'returncode':p.returncode,'stdout':p.stdout.strip(),'stderr':p.stderr.strip()})
        if expected_failure:
            if not p.returncode or 'linear_solve2x2_invalid_parameter__see_README' not in p.stderr:
                raise RuntimeError('illegal parameters did not reject: '+p.stderr)
        elif p.returncode: raise RuntimeError(p.stdout+p.stderr)
        if p.stdout.strip(): print(p.stdout.splitlines()[0] if '-V' in cmd else p.stdout.strip())
        return p
    with tempfile.TemporaryDirectory(prefix='anscore_solve2x2_') as temp:
        tmp=Path(temp)
        version=run([iv,'-V'],tmp).stdout.splitlines()[0]
        run([iv,'-g2012','-Wall','-tnull','-s','solve_calibration2x2','-f','files.f','example/solve_calibration2x2.sv'],ROOT)
        for w,f,r,t in profiles:
            tb,n=bench(w,f,r,t);tbpath=tmp/'tb.sv';tbpath.write_bytes(tb.encode())
            exe=tmp/'test.vvp'
            run([iv,'-g2012','-Wall','-s','tb','-o',exe,str(ROOT/'rtl/linear_solve2x2.sv'),tbpath],tmp)
            result=run([vvp,exe],tmp)
            if 'PASS solve2x2' not in result.stdout: raise RuntimeError('missing simulation completion')
        invalids=[('W',1),('W',25),('FRAC',25),('RESULT_W',1),('RESULT_W',65),('TAG_W',0),('TAG_W',33)]
        for param,value in invalids:
            run([iv,'-g2012','-tnull','-s','linear_solve2x2',f'-Plinear_solve2x2.{param}={value}',str(ROOT/'rtl/linear_solve2x2.sv')],tmp,True)
    sources=[p for p in ROOT.rglob('*') if p.is_file() and p.name!='verification.json']
    result={'status':['LINT_PASS','UNIT_SIM_PASS','HW_UNVERIFIED'],'checked_at_utc':datetime.now(timezone.utc).isoformat(),
            'tool_version':version,'profiles':profiles,'commands_checked':len(vectors(2))*len(profiles),
            'per_process_timeout_seconds':15,'scope':'source compilation and finite deterministic numerical/protocol tests',
            'reproduce':'python -B cores/signal_processing/linear_solve2x2/run_tests.py',
            'source_sha256':{str(p.relative_to(ROOT)).replace('\\','/'):hashlib.sha256(p.read_bytes()).hexdigest() for p in sources},
            'commands':records,'not_run':['synthesis','PnR','STA','hardware']}
    (ROOT/'verification.json').write_bytes((json.dumps(result,indent=2)+'\n').encode())


if __name__=='__main__':main()
