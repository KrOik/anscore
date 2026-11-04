#!/usr/bin/env python3
"""Finite topology checks using a graph flood-fill oracle, with no hardware tools."""
from __future__ import annotations
from collections import deque
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


def regions(pixels,w,h,value,conn):
    visited=set();total=holes=0
    neighbors=[(-1,0),(1,0),(0,-1),(0,1)]
    if conn==8:neighbors += [(-1,-1),(-1,1),(1,-1),(1,1)]
    for y in range(h):
        for x in range(w):
            if pixels[y*w+x]!=value or (x,y) in visited:continue
            total+=1;boundary=False
            pending=deque([(x,y)]);visited.add((x,y))
            while pending:
                px,py=pending.popleft()
                boundary |= px==0 or py==0 or px==w-1 or py==h-1
                for dx,dy in neighbors:
                    nx,ny=px+dx,py+dy
                    if 0<=nx<w and 0<=ny<h and pixels[ny*w+nx]==value and (nx,ny) not in visited:
                        pending.append((nx,ny));visited.add((nx,ny))
            if not boundary:holes+=1
    return total,holes


def oracle(pixels,w,h):
    fg4,_=regions(pixels,w,h,1,4)
    fg8,_=regions(pixels,w,h,1,8)
    _,holes4=regions(pixels,w,h,0,4)
    _,holes8=regions(pixels,w,h,0,8)
    perimeter=0
    for y in range(h):
        for x in range(w):
            if pixels[y*w+x]:
                for dx,dy in [(-1,0),(1,0),(0,-1),(0,1)]:
                    nx,ny=x+dx,y+dy
                    if not (0<=nx<w and 0<=ny<h) or not pixels[ny*w+nx]:perimeter+=1
    return fg4-holes8,fg8-holes4,sum(pixels),perimeter


def fixtures(w,h):
    n=w*h
    if (w,h) in [(2,2),(3,3)]:
        return [[(pattern>>i)&1 for i in range(n)] for pattern in range(1<<n)]
    r=random.Random(20261104+w*19+h)
    frames=[
        [0]*n,[1]*n,[(x+y)%2 for y in range(h) for x in range(w)],
        [int(x%2==0) for y in range(h) for x in range(w)],
        [int(y%2==0) for y in range(h) for x in range(w)],
        [int(x in (0,w-1) or y in (0,h-1)) for y in range(h) for x in range(w)],
        [int(not (x%2==1 and y%2==1 and 0<x<w-1 and 0<y<h-1)) for y in range(h) for x in range(w)],
        [int(x==y or x==w-y-1) for y in range(h) for x in range(w)],
    ]
    frames += [[int(r.random()<density) for _ in range(n)] for density in [.2,.5,.8] for _ in range(8)]
    return frames


def bench(w,h):
    frames=fixtures(w,h)
    expected=[];send=[]
    for f,frame in enumerate(frames):
        e4,e8,area,perim=oracle(frame,w,h)
        error=int(f in (1,3,7))
        expected.append(f'ee4[{f}]={e4};ee8[{f}]={e8};ea[{f}]={area};ep[{f}]={perim};err[{f}]={error};')
        for i,pixel in enumerate(frame):
            sof=int(i==0);eol=int(i%w==w-1)
            if f in (1,7) and i==0:sof^=1
            if f in (3,7) and i==len(frame)-1:eol^=1
            send.append(f'put({pixel},{sof},{eol},{f%256 if i==0 else 255},{(i+f)%3});')
    tb=r'''
`timescale 1ns/1ps
module tb;
localparam W=__W__,H=__H__,F=__F__,AW=(W*H>1)?$clog2(W*H+1):1,PW=$clog2(4*W*H+1),EW=AW+1;
reg clk=0;always #5 clk=~clk;
reg rst=1,s_valid=0,s_pixel=0,s_sof=0,s_eol=0,m_ready=0;
reg [7:0] s_tag=0;
wire s_ready,m_valid,m_empty,m_error;
wire signed [EW-1:0] m_euler4,m_euler8;
wire [AW-1:0] m_area;wire [PW-1:0] m_perimeter;wire [7:0] m_tag;
streaming_binary_topology #(.WIDTH(W),.HEIGHT(H)) dut(.*);
integer ee4[0:F-1],ee8[0:F-1],ea[0:F-1],ep[0:F-1],err[0:F-1];
integer cycle=0,got=0,held=0,stalls=0,input_wait=0;
reg checking=0,was_stalled=0;
reg [2*EW+AW+PW+10-1:0] previous;
wire [2*EW+AW+PW+10-1:0] record={m_euler4,m_euler8,m_area,m_perimeter,m_empty,m_error,m_tag};
always @(negedge clk) begin
 if(rst) begin m_ready=0;held=0;end
 else if(m_valid) begin
   if(held<5) begin m_ready=0;held=held+1;end else m_ready=1;
 end else begin m_ready=0;held=0;end
end
always @(posedge clk) begin
 cycle=cycle+1;
 if(cycle>300000) $fatal(1,"finite watchdog");
 if(rst) was_stalled=0;
 else if(checking) begin
   if(was_stalled && (!m_valid || record!==previous)) $fatal(1,"held output changed");
   was_stalled=m_valid&&!m_ready;previous=record;
   if(was_stalled) stalls=stalls+1;
   if(m_valid&&m_ready) begin
     if(got>=F) $fatal(1,"extra result");
     if($signed(m_euler4)!==ee4[got] || $signed(m_euler8)!==ee8[got] ||
        m_area!==ea[got] || m_perimeter!==ep[got] || m_error!==err[got] ||
        m_empty!==(ea[got]==0) || m_tag!==(got%256))
       $fatal(1,"frame %0d e4=%0d/%0d e8=%0d/%0d area=%0d/%0d perimeter=%0d/%0d err=%0d tag=%0d",
          got,$signed(m_euler4),ee4[got],$signed(m_euler8),ee8[got],m_area,ea[got],m_perimeter,ep[got],m_error,m_tag);
     got=got+1;
   end
 end
end
task put(input integer pixel,sof,eol,tag,gap);
begin
 repeat(gap) @(negedge clk);
 @(negedge clk);s_valid=1;s_pixel=pixel;s_sof=sof;s_eol=eol;s_tag=tag;
 @(posedge clk);while(!s_ready) begin input_wait=input_wait+1;@(posedge clk);end
 @(negedge clk);s_valid=0;
end
endtask
task reset_core;
begin
 @(negedge clk);rst=1;s_valid=0;
 repeat(2) @(posedge clk);
 @(negedge clk);rst=0;
 if(m_valid) $fatal(1,"reset retained valid");
end
endtask
integer i;
initial begin
 __EXPECT__
 reset_core;
 put(1,1,W==1,5,0);reset_core;
 for(i=0;i<W*H;i=i+1) put(1,i==0,(i%W)==W-1,6,0);
 wait(dut.state==4);reset_core;
 for(i=0;i<W*H;i=i+1) put(1,i==0,(i%W)==W-1,7,0);
 wait(m_valid);reset_core;
 checking=1;
 __SEND__
 wait(got==F);repeat(10) @(posedge clk);
 if(stalls<F*3 || input_wait==0) $fatal(1,"vacuous protocol coverage");
 $display("PASS binary_topology W=%0d H=%0d frames=%0d stalls=%0d input_wait=%0d",W,H,F,stalls,input_wait);
 $finish;
end
endmodule
'''
    for key,value in {'W':w,'H':h,'F':len(frames),'EXPECT':'\n'.join(expected),'SEND':'\n'.join(send)}.items():
        tb=tb.replace('__'+key+'__',str(value))
    return tb,len(frames)


def main():
    (ROOT/'verification.json').unlink(missing_ok=True)
    env=os.environ.copy()
    env['PATH']=str(SUITE/'bin')+os.pathsep+str(SUITE/'lib')+os.pathsep+env.get('PATH','')
    iv=str(SUITE/'bin/iverilog.exe') if (SUITE/'bin/iverilog.exe').exists() else shutil.which('iverilog')
    vvp=str(SUITE/'bin/vvp.exe') if (SUITE/'bin/vvp.exe').exists() else shutil.which('vvp')
    if not iv or not vvp:raise SystemExit('NOT_RUN: Icarus Verilog/vvp are required')
    checks=[];profiles=[]
    with tempfile.TemporaryDirectory(prefix='anscore_binary_topology_') as temporary:
        tmp=Path(temporary)
        def run(args,negative=False):
            result=subprocess.run([str(a) for a in args],cwd=ROOT,env=env,capture_output=True,text=True,timeout=20)
            output=result.stdout+result.stderr
            passed=(result.returncode!=0 and 'invalid streaming_binary_topology parameters' in output) if negative else result.returncode==0
            checks.append({'command':[str(a).replace(str(tmp),'<temporary>') for a in args],
                           'exit_code':result.returncode,'status':'PASS' if passed else 'FAIL',
                           'output':output.replace(str(tmp),'<temporary>').strip()})
            print(output.strip())
            if not passed:raise RuntimeError('bounded check failed')
        run([iv,'-g2012','-Wall','-tnull','-s','binary_topology_example','-f','files.f','example/binary_topology_example.sv'])
        run([iv,'-g2012','-Wall','-tnull','-s','streaming_binary_topology',
             '-Pstreaming_binary_topology.WIDTH=1024','-Pstreaming_binary_topology.HEIGHT=1024',
             '-Pstreaming_binary_topology.TAG_W=32','-f','files.f'])
        for w,h in [(1,1),(1,7),(7,1),(2,2),(3,3),(8,6),(9,8)]:
            tb,n=bench(w,h);path=tmp/f'tb_{w}_{h}.sv';path.write_bytes(tb.encode())
            executable=tmp/f'sim_{w}_{h}.vvp'
            run([iv,'-g2012','-Wall','-s','tb','-o',executable,'-f','files.f',path])
            run([vvp,executable]);profiles.append({'width':w,'height':h,'frames':n})
        for parameter,value in [('WIDTH',0),('WIDTH',1025),('HEIGHT',0),('HEIGHT',1025),('TAG_W',0),('TAG_W',33)]:
            executable=tmp/f'invalid_{parameter}_{value}.vvp'
            run([iv,'-g2012','-s','streaming_binary_topology',f'-Pstreaming_binary_topology.{parameter}={value}',
                 '-o',executable,'-f','files.f'])
            run([vvp,executable],negative=True)
    files=['.gitattributes','files.f','rtl/streaming_binary_topology.sv','example/binary_topology_example.sv','run_tests.py']
    report={'date':'2026-11-04','status':['LINT_PASS','UNIT_SIM_PASS','HW_UNVERIFIED'],
            'scope':'finite source and deterministic RTL checks; hardware tools NOT_RUN',
            'source_sha256':{p:hashlib.sha256((ROOT/p).read_bytes()).hexdigest() for p in files},
            'profiles':profiles,'frames':sum(p['frames'] for p in profiles),
            'exhaustive_2x2_patterns':16,'exhaustive_3x3_patterns':512,
            'maximum_parameter_compile_only':[1024,1024,32],'checks':checks}
    (ROOT/'verification.json').write_bytes((json.dumps(report,indent=2)+'\n').encode())


if __name__=='__main__':main()
