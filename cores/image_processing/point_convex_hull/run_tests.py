#!/usr/bin/env python3
"""Bounded source checks and exact gift-wrapping oracle; no hardware tools."""
from __future__ import annotations
import hashlib
import json
import os
from pathlib import Path
import random
import shutil
import subprocess
import tempfile

ROOT=Path(__file__).resolve().parent
REPO=ROOT.parents[2]
SUITE=REPO/'tools/oss-cad-suite/oss-cad-suite'


def cross(a,b,c):
    return (b[0]-a[0])*(c[1]-a[1])-(b[1]-a[1])*(c[0]-a[0])


def oracle(frame,capacity):
    selected=[(x,y) for x,y,keep in frame if keep]
    if len(selected)>capacity:return [],1
    points=sorted(set(selected))
    if len(points)<2:return points,0
    # Jarvis march is independent of the RTL's sorted lower/upper stack.
    def dist(a,b):return (b[0]-a[0])**2+(b[1]-a[1])**2
    start=points[0];p=start;hull=[]
    while True:
        hull.append(p)
        q=next(v for v in points if v!=p)
        for candidate in points:
            turn=cross(p,q,candidate)
            if turn<0 or (turn==0 and dist(p,candidate)>dist(p,q)):q=candidate
        p=q
        if p==start:break
        assert len(hull)<=len(points)
    return hull,0


def fixtures(bits,capacity):
    lo=-(1<<(bits-1));hi=(1<<(bits-1))-1
    r=random.Random(20261104+bits*13+capacity)
    def wrap(points):return [(x,y,1) for x,y in points] or [(0,0,0)]
    frames=[
        [(0,0,0)],wrap([(lo,lo)]),wrap([(hi,hi)]),wrap([(0,0)]*capacity),
        wrap([(lo,lo),(hi,hi)]),wrap([(lo,hi),(hi,lo)]),
        wrap([(lo,lo),(hi,lo),(hi,hi),(lo,hi)]),
        wrap([(lo,0),(0,lo),(hi,0),(0,hi),(0,0)]),
        wrap([(i-capacity//2,(i-capacity//2)**2) for i in range(capacity)]),
        wrap([(hi,lo)]*(capacity+1)),
        wrap([(lo,hi)]*capacity)+[(hi,lo,0)]*3,
        [(lo,lo,0),(hi,hi,1),(lo,hi,0)],
    ]
    # Parabola fixture must fit the actual signed coordinate range.
    frames[8]=[(max(lo,min(hi,x)),max(lo,min(hi,y)),keep) for x,y,keep in frames[8]]
    for _ in range(20):
        n=r.randrange(1,capacity+4)
        frames.append([(r.randrange(lo,hi+1),r.randrange(lo,hi+1),r.randrange(5)!=0) for _ in range(n)])
    if (bits,capacity)==(8,16):
        grid=[(x,y) for y in (-1,0,1) for x in (-1,0,1)]
        for pattern in range(512):
            points=[p for i,p in enumerate(grid) if (pattern>>i)&1]
            r.shuffle(points);frames.append(wrap(points))
    return frames


def bench(bits,capacity,tag_w):
    frames=fixtures(bits,capacity);cw=max(1,capacity.bit_length())
    assignments=[];send=[];token=0;empty_count=error_count=0;max_hull=0
    for f,frame in enumerate(frames):
        hull,error=oracle(frame,capacity)
        max_hull=max(max_hull,len(hull));empty_count+=not hull;error_count+=error
        count=len(hull)
        for j,(x,y) in enumerate(hull or [(0,0)]):
            assignments.append(f'ex[{token}]={x};ey[{token}]={y};ec[{token}]={count};'
                               f'ei[{token}]={j};el[{token}]={int(j==max(count,1)-1)};'
                               f'ee[{token}]={error};et[{token}]={f% (1<<tag_w)};')
            token+=1
        for j,(x,y,mask) in enumerate(frame):
            send.append(f'put({x},{y},{int(mask)},{int(j==len(frame)-1)},'
                        f'{f%(1<<tag_w) if j==0 else 0},{(f+j)%3});')
    tb=r'''
`timescale 1ns/1ps
module tb;
localparam B=__B__,CAP=__CAP__,TW=__TW__,CW=(CAP>1)?$clog2(CAP+1):1,F=__F__,TOKENS=__TOKENS__;
reg clk=0;always #5 clk=~clk;
reg rst=1,s_valid=0,s_mask=0,s_last=0,m_ready=0;
reg signed [B-1:0] s_x=0,s_y=0;reg [TW-1:0] s_tag=0;
wire s_ready,m_valid,m_first,m_last,m_empty,m_error;
wire signed [B-1:0] m_x,m_y;wire [CW-1:0] m_index,m_count;wire [TW-1:0] m_tag;
point_convex_hull #(.COORD_W(B),.MAX_POINTS(CAP),.TAG_W(TW)) dut(.*);
integer ex[0:TOKENS-1],ey[0:TOKENS-1],ec[0:TOKENS-1],ei[0:TOKENS-1];
integer el[0:TOKENS-1],ee[0:TOKENS-1],et[0:TOKENS-1];
integer cycles=0,got=0,held=0,stalls=0,input_waits=0;
reg checking=0,was_stalled=0;
localparam RW=2*B+2*CW+4+TW;
reg [RW-1:0] previous;
wire [RW-1:0] record={m_x,m_y,m_index,m_count,m_first,m_last,m_empty,m_error,m_tag};
always @(negedge clk) begin
 if(rst) begin m_ready=0;held=0;end
 else if(m_valid) begin
   if(held<5) begin m_ready=0;held=held+1;end
   else m_ready=cycles%7!=0;
 end else begin m_ready=0;held=0;end
end
always @(posedge clk) begin
 cycles=cycles+1;if(cycles>1000000) $fatal(1,"finite watchdog");
 if(rst) was_stalled=0;
 else if(checking) begin
  if(was_stalled && (!m_valid || record!==previous)) $fatal(1,"stalled vertex changed");
  was_stalled=m_valid&&!m_ready;previous=record;if(was_stalled) stalls=stalls+1;
  if(m_valid&&m_ready) begin
    if(got>=TOKENS) $fatal(1,"extra vertex");
    if($signed(m_x)!==ex[got] || $signed(m_y)!==ey[got] || m_count!==ec[got] ||
       m_index!==ei[got] || m_first!==(ei[got]==0) || m_last!==el[got] ||
       m_empty!==(ec[got]==0) || m_error!==ee[got] || m_tag!==TW'(et[got]))
      $fatal(1,"token %0d xy=(%0d,%0d)/(%0d,%0d) count=%0d/%0d index=%0d/%0d last=%0d/%0d error=%0d/%0d tag=%0d/%0d",
         got,$signed(m_x),$signed(m_y),ex[got],ey[got],m_count,ec[got],m_index,ei[got],m_last,el[got],m_error,ee[got],m_tag,et[got]);
    got=got+1;
  end
 end
end
task reset_core;
begin
 @(negedge clk);rst=1;s_valid=0;repeat(2) @(posedge clk);@(negedge clk);rst=0;
 if(m_valid) $fatal(1,"reset retained valid");
end
endtask
task put(input integer x,y,mask,last,tag,gap);
begin
 repeat(gap) @(negedge clk);
 @(negedge clk);s_valid=1;s_x=x;s_y=y;s_mask=mask;s_last=last;s_tag=tag;
 @(posedge clk);while(!s_ready) begin input_waits=input_waits+1;@(posedge clk);end
 @(negedge clk);s_valid=0;
end
endtask
initial begin
 __EXPECT__
 reset_core;put(0,0,1,0,1,0);reset_core;
 if(CAP>1) begin
   put(1,0,1,0,2,0);put(0,1,1,1,2,0);
   wait(dut.state==3);reset_core;
   if(CAP>2) begin
     put(0,0,1,0,3,0);put(1,0,1,0,3,0);put(0,1,1,1,3,0);
     wait(dut.state==9);reset_core;
   end
 end
 put(0,0,1,1,4,0);wait(m_valid);reset_core;
 checking=1;
 __SEND__
 wait(got==TOKENS);repeat(10) @(posedge clk);
 if(m_valid || stalls<F*3 || input_waits==0) $fatal(1,"vacuous flow/extra output");
 $display("PASS convex_hull B=%0d CAP=%0d TAG=%0d blocks=%0d tokens=%0d stalls=%0d waits=%0d",B,CAP,TW,F,TOKENS,stalls,input_waits);
 $finish;
end
endmodule
'''
    for key,value in {'B':bits,'CAP':capacity,'TW':tag_w,'F':len(frames),'TOKENS':token,
                      'EXPECT':'\n'.join(assignments),'SEND':'\n'.join(send)}.items():
        tb=tb.replace('__'+key+'__',str(value))
    return tb,{'coord_w':bits,'max_points':capacity,'tag_w':tag_w,'blocks':len(frames),
               'tokens':token,'empty_or_error_blocks':empty_count,'overflow_blocks':error_count,
               'maximum_hull_vertices':max_hull}


def main():
    (ROOT/'verification.json').unlink(missing_ok=True)
    env=os.environ.copy();env['PATH']=str(SUITE/'bin')+os.pathsep+str(SUITE/'lib')+os.pathsep+env.get('PATH','')
    iv=str(SUITE/'bin/iverilog.exe') if (SUITE/'bin/iverilog.exe').exists() else shutil.which('iverilog')
    vvp=str(SUITE/'bin/vvp.exe') if (SUITE/'bin/vvp.exe').exists() else shutil.which('vvp')
    if not iv or not vvp:raise SystemExit('NOT_RUN: Icarus Verilog/vvp are required')
    checks=[];profiles=[]
    with tempfile.TemporaryDirectory(prefix='anscore_point_hull_') as temporary:
        tmp=Path(temporary)
        def run(args,negative=False):
            result=subprocess.run([str(a) for a in args],cwd=ROOT,env=env,capture_output=True,text=True,timeout=20)
            output=result.stdout+result.stderr
            passed=(result.returncode!=0 and 'invalid point_convex_hull parameters' in output) if negative else result.returncode==0
            checks.append({'command':[str(a).replace(str(tmp),'<temporary>') for a in args],
                           'exit_code':result.returncode,'status':'PASS' if passed else 'FAIL',
                           'output':output.replace(str(tmp),'<temporary>').strip()})
            print(output.strip())
            if not passed:raise RuntimeError('bounded check failed')
        run([iv,'-g2012','-Wall','-tnull','-s','feature_hull_example','-f','files.f','example/feature_hull_example.sv'])
        for bits,cap,tag in [(2,1,1),(4,3,3),(8,16,8),(16,32,8),(24,64,32)]:
            tb,profile=bench(bits,cap,tag);path=tmp/f'tb_{bits}.sv';path.write_bytes(tb.encode());exe=tmp/f'sim_{bits}.vvp'
            run([iv,'-g2012','-Wall','-s','tb','-o',exe,'-f','files.f',path]);run([vvp,exe]);profiles.append(profile)
        for parameter,value in [('COORD_W',1),('COORD_W',25),('MAX_POINTS',0),('MAX_POINTS',65),('TAG_W',0),('TAG_W',33)]:
            exe=tmp/f'invalid_{parameter}_{value}.vvp'
            run([iv,'-g2012','-s','point_convex_hull',f'-Ppoint_convex_hull.{parameter}={value}','-o',exe,'-f','files.f'])
            run([vvp,exe],negative=True)
    files=['.gitattributes','files.f','rtl/point_convex_hull.sv','example/feature_hull_example.sv','run_tests.py']
    report={'date':'2026-11-04','status':['LINT_PASS','UNIT_SIM_PASS','HW_UNVERIFIED'],
            'scope':'finite source checks and deterministic exact integer point-set tests; no hardware tools',
            'source_sha256':{p:hashlib.sha256((ROOT/p).read_bytes()).hexdigest() for p in files},
            'profiles':profiles,'blocks':sum(p['blocks'] for p in profiles),
            'tokens':sum(p['tokens'] for p in profiles),'exhaustive_3x3_subsets':512,'checks':checks}
    (ROOT/'verification.json').write_bytes((json.dumps(report,indent=2)+'\n').encode())


if __name__=='__main__':main()
