#!/usr/bin/env python3
"""Bounded syntax and finite deterministic RTL checks, with a brute-force oracle."""
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


def oracle(pixels,width,height):
    # Enumerate every possible rectangle using a summed-area image, not a stack.
    pref=[[0]*(width+1) for _ in range(height+1)]
    for y in range(height):
        for x in range(width):
            pref[y+1][x+1]=pixels[y*width+x]+pref[y][x+1]+pref[y+1][x]-pref[y][x]
    best_area=0
    best=(0,0,0,0)  # ymin,xmin,ymax,xmax
    for y0 in range(height):
        for x0 in range(width):
            for y1 in range(y0,height):
                for x1 in range(x0,width):
                    area=(y1-y0+1)*(x1-x0+1)
                    ones=pref[y1+1][x1+1]-pref[y0][x1+1]-pref[y1+1][x0]+pref[y0][x0]
                    coords=(y0,x0,y1,x1)
                    if ones==area and (area>best_area or (area==best_area and coords<best)):
                        best_area,best=area,coords
    return (best_area,*best)


def fixtures(w,h):
    n=w*h
    if (w,h)==(3,3):
        return [[(mask>>i)&1 for i in range(n)] for mask in range(1<<n)]
    r=random.Random(20261104+17*w+h)
    frames=[
        [0]*n,[1]*n,
        [(x+y)%2 for y in range(h) for x in range(w)],
        [int(x%2==0) for y in range(h) for x in range(w)],
        [int(y%2==0) for y in range(h) for x in range(w)],
        [int(y>=h-1-(x%h)) for y in range(h) for x in range(w)],
        [int(y>=h-1-((w-1-x)%h)) for y in range(h) for x in range(w)],
        [int((x in (0,w-1)) or (y in (0,h-1))) for y in range(h) for x in range(w)],
    ]
    frames += [[int(r.random()<density) for _ in range(n)] for density in [.2,.5,.8] for _ in range(8)]
    # Frame-marker errors must flag but still consume the entire fixed raster.
    return frames


def bench(w,h):
    frames=fixtures(w,h)
    assignments=[]; calls=[]
    for index,frame in enumerate(frames):
        area,ymin,xmin,ymax,xmax=oracle(frame,w,h)
        error=int(index in (1,3,7))
        assignments.append(f'ea[{index}]={area}; ey0[{index}]={ymin}; ex0[{index}]={xmin}; '
                           f'ey1[{index}]={ymax}; ex1[{index}]={xmax}; ee[{index}]={error};')
        for i,pixel in enumerate(frame):
            sof=int(i==0)
            eol=int(i%w==w-1)
            if index in (1,7) and i==0: sof^=1
            if index in (3,7) and i==len(frame)-1: eol^=1
            calls.append(f'put({pixel},{sof},{eol},{index%256 if i==0 else 255},{(i+index)%3});')
    tb=r'''
`timescale 1ns/1ps
module tb;
localparam W=__W__,H=__H__,F=__F__,XW=(W>1)?$clog2(W):1,YW=(H>1)?$clog2(H):1,AW=$clog2(W*H+1);
reg clk=0;always #5 clk=~clk;
reg rst=1,s_valid=0,s_pixel=0,s_sof=0,s_eol=0,m_ready=0;
reg [7:0] s_tag=0;
wire s_ready,m_valid,m_empty,m_error;
wire [AW-1:0] m_area;
wire [XW-1:0] m_xmin,m_xmax;wire [YW-1:0] m_ymin,m_ymax;
wire [7:0] m_tag;
max_binary_rectangle #(.WIDTH(W),.HEIGHT(H)) dut(.*);
integer ea[0:F-1],ex0[0:F-1],ex1[0:F-1],ey0[0:F-1],ey1[0:F-1],ee[0:F-1];
integer cycles=0,got=0,hold_count=0,stalls=0,input_waits=0;
reg checking=0,was_stalled=0;
reg [AW+2*XW+2*YW+10-1:0] previous;
wire [AW+2*XW+2*YW+10-1:0] record={m_area,m_xmin,m_xmax,m_ymin,m_ymax,m_empty,m_error,m_tag};
always @(negedge clk) begin
 if(rst) begin m_ready=0;hold_count=0;end
 else if(m_valid) begin
   if(hold_count<5) begin m_ready=0;hold_count=hold_count+1;end
   else m_ready=1;
 end else begin m_ready=0;hold_count=0;end
end
always @(posedge clk) begin
 cycles=cycles+1;
 if(cycles>300000) $fatal(1,"finite watchdog");
 if(rst) was_stalled=0;
 else if(checking) begin
   if(was_stalled && (!m_valid || record!==previous)) $fatal(1,"stalled record changed");
   was_stalled=m_valid&&!m_ready;previous=record;
   if(was_stalled) stalls=stalls+1;
   if(m_valid&&m_ready) begin
     if(got>=F) $fatal(1,"extra result");
     if(m_area!==ea[got] || m_xmin!==ex0[got] || m_xmax!==ex1[got] ||
        m_ymin!==ey0[got] || m_ymax!==ey1[got] || m_error!==ee[got] ||
        m_empty!==(ea[got]==0) || m_tag!==(got%256))
       $fatal(1,"frame %0d area=%0d exp=%0d box=(%0d,%0d,%0d,%0d) expected=(%0d,%0d,%0d,%0d) err=%0d tag=%0d",
           got,m_area,ea[got],m_ymin,m_xmin,m_ymax,m_xmax,ey0[got],ex0[got],ey1[got],ex1[got],m_error,m_tag);
     got=got+1;
   end
 end
end
task reset_core;
begin
 @(negedge clk);rst=1;s_valid=0;
 repeat(2) @(posedge clk);
 @(negedge clk);rst=0;
 if(m_valid) $fatal(1,"reset retained result");
end
endtask
task put(input integer pixel,sof,eol,tag,gap);
begin
 repeat(gap) @(negedge clk);
 @(negedge clk);s_valid=1;s_pixel=pixel;s_sof=sof;s_eol=eol;s_tag=tag;
 @(posedge clk);
 while(!s_ready) begin input_waits=input_waits+1;@(posedge clk);end
 @(negedge clk);s_valid=0;
end
endtask
integer i;
initial begin
 __EXPECT__
 reset_core;
 // Reset with a pixel read/height update in flight.
 put(1,1,W==1,9,0);reset_core;
 // Reset during row-sentinel draining, then during a held final result.
 for(i=0;i<W*H;i=i+1) put(1,i==0,(i%W)==W-1,8,0);
 wait(dut.scan_x==W && dut.state==2);reset_core;
 for(i=0;i<W*H;i=i+1) put(1,i==0,(i%W)==W-1,7,0);
 wait(m_valid);reset_core;
 checking=1;
 __SEND__
 wait(got==F);repeat(10) @(posedge clk);
 if(stalls<F*3 || input_waits==0) $fatal(1,"vacuous flow coverage");
 $display("PASS max_rectangle W=%0d H=%0d frames=%0d stalled=%0d input_wait=%0d",W,H,F,stalls,input_waits);
 $finish;
end
endmodule
'''
    for key,value in {'W':w,'H':h,'F':len(frames),'EXPECT':'\n'.join(assignments),'SEND':'\n'.join(calls)}.items():
        tb=tb.replace('__'+key+'__',str(value))
    return tb,len(frames)


def main():
    # A failed or unavailable rerun must not leave an old PASS report behind.
    (ROOT/'verification.json').unlink(missing_ok=True)
    env=os.environ.copy()
    env['PATH']=str(SUITE/'bin')+os.pathsep+str(SUITE/'lib')+os.pathsep+env.get('PATH','')
    iv=str(SUITE/'bin/iverilog.exe') if (SUITE/'bin/iverilog.exe').exists() else shutil.which('iverilog')
    vvp=str(SUITE/'bin/vvp.exe') if (SUITE/'bin/vvp.exe').exists() else shutil.which('vvp')
    if not iv or not vvp: raise SystemExit('NOT_RUN: missing Icarus Verilog/vvp')
    results=[];profiles=[]
    with tempfile.TemporaryDirectory(prefix='anscore_max_rectangle_') as temporary:
        tmp=Path(temporary)
        def run(args,negative=False):
            result=subprocess.run([str(a) for a in args],cwd=ROOT,env=env,capture_output=True,text=True,timeout=20)
            text=result.stdout+result.stderr
            status='PASS' if (result.returncode==0 if not negative else result.returncode!=0 and 'invalid max_binary_rectangle parameters' in text) else 'FAIL'
            results.append({'command':[str(a).replace(str(tmp),'<temporary>') for a in args],
                            'exit_code':result.returncode,'status':status,'output':text.replace(str(tmp),'<temporary>').strip()})
            print(text.strip())
            if status!='PASS': raise RuntimeError('bounded check failed')
        run([iv,'-g2012','-Wall','-tnull','-s','max_rectangle_example','-f','files.f','example/max_rectangle_example.sv'])
        run([iv,'-g2012','-Wall','-tnull','-s','max_binary_rectangle','-Pmax_binary_rectangle.WIDTH=1024',
             '-Pmax_binary_rectangle.HEIGHT=1024','-Pmax_binary_rectangle.TAG_W=32','-f','files.f'])
        for w,h in [(1,1),(1,7),(7,1),(3,3),(8,6),(9,8)]:
            tb,n=bench(w,h)
            path=tmp/f'tb_{w}_{h}.sv';path.write_bytes(tb.encode())
            executable=tmp/f'sim_{w}_{h}.vvp'
            run([iv,'-g2012','-Wall','-s','tb','-o',executable,'-f','files.f',path])
            run([vvp,executable])
            profiles.append({'width':w,'height':h,'frames':n})
        for parameter,value in [('WIDTH',0),('WIDTH',1025),('HEIGHT',0),('HEIGHT',1025),('TAG_W',0),('TAG_W',33)]:
            executable=tmp/f'invalid_{parameter}_{value}.vvp'
            run([iv,'-g2012','-s','max_binary_rectangle',f'-Pmax_binary_rectangle.{parameter}={value}',
                 '-o',executable,'-f','files.f'])
            run([vvp,executable],negative=True)
    source_files=['rtl/max_binary_rectangle.sv','example/max_rectangle_example.sv','run_tests.py','files.f']
    report={'date':'2026-11-04','status':['LINT_PASS','UNIT_SIM_PASS','HW_UNVERIFIED'],
            'scope':'finite RTL/source checks; no synthesis, timing, implementation or hardware checks',
            'source_sha256':{p:hashlib.sha256((ROOT/p).read_bytes()).hexdigest() for p in source_files},
            'profiles':profiles,'frames':sum(p['frames'] for p in profiles),
            'exhaustive_3x3_patterns':512,'maximum_parameter_compile_only':[1024,1024,32],
            'checks':results}
    (ROOT/'verification.json').write_bytes((json.dumps(report,indent=2)+'\n').encode())


if __name__=='__main__':main()
