#!/usr/bin/env python3
"""Finite raster/hull-composition checks with exact vertical-ray oracle."""
from __future__ import annotations
from fractions import Fraction
import hashlib
import itertools
import json
import os
from pathlib import Path
import random
import shutil
import subprocess
import tempfile

ROOT=Path(__file__).resolve().parent
REPO=ROOT.parents[2]
HULL=ROOT.parent/'point_convex_hull/rtl/point_convex_hull.sv'
BASELINE='cf23435dbaca0dc895e2c0b5470418fb9e56c046'


def inside(vertices,x,y):
    """Independent exact vertical ray; RTL uses a horizontal ray and products."""
    px=Fraction(2*x+1,2);py=Fraction(2*y+1,2);parity=False
    for a,b in zip(vertices,vertices[1:]+vertices[:1]):
        if a[0]==b[0]:continue  # integer x cannot coincide with half-integer px
        t=(px-a[0])/(b[0]-a[0])
        intersection=Fraction(a[1])+t*(b[1]-a[1])
        if 0<=t<=1 and intersection==py:return 1
        if (a[0]>px)!=(b[0]>px) and intersection>py:parity=not parity
    return int(parity)


def gift_wrap(points):
    """Unordered-set composition oracle, independent of RTL's monotone chain."""
    points=sorted(set(points))
    if len(points)<2:return points
    def cross(a,b,c):return (b[0]-a[0])*(c[1]-a[1])-(b[1]-a[1])*(c[0]-a[0])
    def square(a,b):return (b[0]-a[0])**2+(b[1]-a[1])**2
    start=points[0];p=start;result=[]
    while True:
        result.append(p);q=next(v for v in points if v!=p)
        for c in points:
            turn=cross(p,q,c)
            if turn<0 or (turn==0 and square(p,c)>square(p,q)):q=c
        p=q
        if p==start:return result
        assert len(result)<=len(points)


def oracle(raw,capacity,width,height,composition):
    points=[(x,y) for x,y,keep,error in raw if keep]
    if composition:
        error=2 if len(points)>capacity else 0
        vertices=[] if error else gift_wrap(points)
    else:
        error=int(len(points)>capacity)|(int(any(e for x,y,k,e in raw))<<1)
        vertices=points[:capacity]
    return [(0 if error or len(vertices)<3 else inside(vertices,x,y))
            for y in range(height) for x in range(width)],len(vertices),error


def fixtures(bits,capacity,width,height,composition=False,default_geometry=False):
    lo=-(1<<(bits-1));hi=(1<<(bits-1))-1
    def clamp(v):return max(lo,min(hi,v))
    def wrap(points):return [(clamp(x),clamp(y),1,0) for x,y in points] or [(0,0,0,0)]
    frames=[]
    def add(points):frames.append(wrap(points))
    if default_geometry:
        add([(0,0),(width,0),(width,height),(0,height)]);add([])
        return frames
    add([]);add([(0,0)]);add([(0,0),(hi,hi)])
    add([(0,0),(width,0),(width,height),(0,height)])
    add([(0,0),(0,height),(width,height),(width,0)])
    add([(lo,lo),(hi,lo),(hi,hi),(lo,hi)])
    add([(0,0),(hi,hi),(0,hi),(hi,0)])  # self-crossing bow tie
    add([(0,0),(hi,0),(1,1),(hi,hi),(0,hi)])  # concavity
    add([(0,0),(hi,hi),(0,0)])  # zero area with centers exactly on boundary
    add([(hi,hi)]*capacity)
    add([(lo,lo)]*(capacity+1))
    frames.append(wrap([(0,0),(hi,0),(0,hi)])+[(lo,hi,0,0)]*3)
    frames.append([(lo,lo,0,0)]+wrap([(0,0),(hi,0),(hi,hi),(0,hi)]))
    frames.append(wrap([(lo,hi)]*capacity)+[(hi,lo,0,0)])
    if not composition:
        frames.append([(0,0,0,1)]+wrap([(0,0),(hi,0),(0,hi)]))
        frames.append(wrap([(0,0),(hi,0),(0,hi)])+[(0,0,0,1)])
        frames.append([(lo,lo,1,1)]*(capacity+1))
    if bits==4 and not composition:
        grid=list(itertools.product((-1,1,3),repeat=2))
        for points in itertools.product(grid,repeat=3):add(points)
        for points in itertools.permutations(((0,0),(3,0),(3,3),(0,3))):add(points)
    rng=random.Random(20261106+bits*71+capacity*3+composition)
    for k in range(24):
        n=rng.randrange(1,capacity+4)
        if k%3:
            raw=[(clamp(rng.randrange(-2,width+3)),clamp(rng.randrange(-2,height+3)),int(rng.randrange(5)!=0),0) for _ in range(n)]
        else:raw=[(rng.randrange(lo,hi+1),rng.randrange(lo,hi+1),int(rng.randrange(5)!=0),0) for _ in range(n)]
        frames.append(raw)
    return frames


def pack(parts):
    out=0
    for value,width in parts:out=(out<<width)|(value&((1<<width)-1))
    return out


def bench(bits,capacity,width,height,tagw,input_n,output_n,composition):
    xw=max(1,(width-1).bit_length());yw=max(1,(height-1).bit_length());cw=capacity.bit_length()
    inw=2*bits+3+tagw;outw=tagw+2+cw+3+yw+xw+1
    instance=('point_hull_mask #(.COORD_W(W),.MAX_POINTS(N),.WIDTH(X),.HEIGHT(Y),.TAG_W(TW)) dut(.*);'
              if composition else 'polygon_raster_mask #(.COORD_W(W),.MAX_VERTICES(N),.WIDTH(X),.HEIGHT(Y),.TAG_W(TW)) dut(.*);')
    core='dut.raster' if composition else 'dut'
    extra='''
    reset_core();put_probe(0,0,0);put_probe(1,0,0);put_probe(0,1,1);
    waited=0;
    while(dut.hull.state!=dut.hull.SORT_STEP && waited<2000) begin @(negedge clk);waited=waited+1;end
    if(dut.hull.state!=dut.hull.SORT_STEP) $fatal(1,"hull sort reset target not reached");
    reset_now();reset_cases=reset_cases+1;
''' if composition and capacity>=3 else ''
    return f'''`timescale 1ns/1ps
module tb;
localparam W={bits},N={capacity},X={width},Y={height},TW={tagw},XW={xw},YW={yw},CW={cw},INW={inw},OW={outw};
reg clk=0;always #5 clk=~clk;
reg rst=1,s_valid=0,s_keep=0,s_last=0,s_error=0,m_ready=0;
reg signed [W-1:0] s_x=0,s_y=0;reg [TW-1:0] s_tag=0;
wire s_ready,m_valid,m_pixel,m_sof,m_eol,m_last;
wire [XW-1:0] m_x;wire [YW-1:0] m_y;wire [CW-1:0] m_vertices;
wire [1:0] m_error;wire [TW-1:0] m_tag;
{instance}
reg [INW-1:0] inputs[0:{input_n-1}];reg [OW-1:0] golden[0:{output_n-1}];
wire [OW-1:0] payload={{m_tag,m_error,m_vertices,m_last,m_eol,m_sof,m_y,m_x,m_pixel}};
reg checking=0,hold_check=0;reg [OW-1:0] held;
integer sent=0,received=0,cycle=0,stalls=0,reset_cases=0,waited;
task reset_now;
begin
    rst=1;s_valid=0;m_ready=0;s_error=0;
    repeat(2) @(posedge clk);
    @(negedge clk);rst=0;
    @(posedge clk);#1;
    if(m_valid || !s_ready) $fatal(1,"reset did not rearm");
end endtask
task reset_core;
begin @(negedge clk);reset_now();end endtask
task put_probe(input integer px,input integer py,input integer tail);
begin
    @(negedge clk);s_valid=1;s_keep=1;s_x=px;s_y=py;s_last=tail;
    do @(posedge clk);while(!s_ready);
    @(negedge clk);s_valid=0;
end endtask
task abort_at(input integer target);
begin
    reset_core();
    if(target==0) put_probe(0,0,0);
    else begin
        put_probe(0,0,0);put_probe(1,0,0);put_probe(0,1,1);waited=0;
        while({core}.state!=target && waited<2000) begin @(negedge clk);waited=waited+1;end
        if({core}.state!=target) $fatal(1,"phase reset target not reached %0d",target);
    end
    // Immediate assertion at the boundary that observed the target phase.
    reset_now();reset_cases=reset_cases+1;
end endtask
always @(posedge clk) if(checking && !rst) begin
    if(hold_check && (!m_valid || held!==payload)) $fatal(1,"stalled output changed");
    hold_check=m_valid&&!m_ready;held=payload;
    if(s_valid&&s_ready) sent=sent+1;
    if(m_valid&&!m_ready) stalls=stalls+1;
    if(m_valid&&m_ready) begin
        if(received>={output_n} || payload!==golden[received])
            $fatal(1,"token %0d got %h expected %h",received,payload,golden[received]);
        received=received+1;
    end
end
initial begin
    $readmemh("input.hex",inputs);$readmemh("golden.hex",golden);
    abort_at(0);
    if(N>=3) begin
        abort_at({core}.EDGE_SETUP);abort_at({core}.MUL_FIRST);
        abort_at({core}.MUL_SECOND);abort_at({core}.OUT_HOLD);
    end else begin
        put_probe(0,0,1);waited=0;
        while({core}.state!={core}.OUT_HOLD && waited<2000) begin @(negedge clk);waited=waited+1;end
        if({core}.state!={core}.OUT_HOLD) $fatal(1,"degenerate output reset target not reached");
        reset_now();reset_cases=reset_cases+1;
    end
    {extra}
    checking=1;
    while(received<{output_n} && cycle<3000000) begin
        @(negedge clk);cycle=cycle+1;m_ready=!(cycle%13<5 || cycle%7==1);
        if(!(s_valid&&!s_ready)) begin
            if(sent<{input_n} && cycle%5!=0) begin
                s_valid=1;{{s_tag,s_error,s_keep,s_last,s_y,s_x}}=inputs[sent];
            end else s_valid=0;
        end
    end
    @(negedge clk);s_valid=0;m_ready=1;
    if(sent!={input_n} || received!={output_n}) $fatal(1,"timeout %0d %0d",sent,received);
    repeat(20) @(posedge clk);
    if(stalls<10) $fatal(1,"missing output stalls");
    $display("PASS polygon mode={int(composition)} W=%0d N=%0d raster=%0dx%0d inputs=%0d pixels=%0d stalls=%0d resets=%0d cycles=%0d",W,N,X,Y,sent,received,stalls,reset_cases,cycle);
    $finish;
end
initial begin #35000000;$fatal(1,"watchdog timeout");end
endmodule
'''


def main():
    suite=REPO/'tools/oss-cad-suite/oss-cad-suite';env=os.environ.copy()
    env['PATH']=os.pathsep.join((str(suite/'bin'),str(suite/'lib'),env.get('PATH','')))
    iv=os.environ.get('IVERILOG') or shutil.which('iverilog',path=env['PATH']);vv=shutil.which('vvp',path=env['PATH'])
    if not iv or not vv:raise RuntimeError('NOT_RUN: Icarus Verilog unavailable')
    records=[];profiles=[]
    def run(command,cwd,negative=False):
        result=subprocess.run([str(v) for v in command],cwd=cwd,env=env,capture_output=True,text=True,timeout=20)
        rec={'command':[str(v) for v in command],'returncode':result.returncode,'stdout':result.stdout,
             'stderr':result.stderr,'timeout_seconds':20};records.append(rec)
        if negative:assert result.returncode>0 and 'invalid polygon_raster_mask parameters' in result.stdout+result.stderr,rec
        else:assert result.returncode==0 and not result.stderr,rec
        return result.stdout
    with tempfile.TemporaryDirectory(prefix='anscore_polygon_raster_') as tmp:
        temp=Path(tmp);rtl=ROOT/'rtl/polygon_raster_mask.sv';wrapper=ROOT/'example/point_hull_mask.sv'
        run([iv,'-g2012','-Wall','-tnull','-s','polygon_raster_mask','-s','point_hull_mask',rtl,HULL,wrapper],temp)
        for width,height in ((1024,64),(64,1024)):
            run([iv,'-g2012','-Wall','-tnull','-s','polygon_raster_mask','-Ppolygon_raster_mask.COORD_W=16',
                 f'-Ppolygon_raster_mask.WIDTH={width}',f'-Ppolygon_raster_mask.HEIGHT={height}',rtl],temp)
        configurations=[(2,1,1,1,1,False,False),(2,8,2,2,1,False,False),
                        (4,8,3,3,3,False,False),(8,16,7,5,8,False,False),
                        (12,32,1,9,8,False,False),(16,64,9,1,32,False,False),
                        (12,32,64,64,8,False,True),(4,8,3,3,3,True,False),
                        (8,16,7,5,8,True,False)]
        for number,(bits,capacity,width,height,tagw,composition,default_geometry) in enumerate(configurations):
            folder=temp/f'profile_{number}';folder.mkdir()
            frames=fixtures(bits,capacity,width,height,composition,default_geometry);inputs=[];expected=[]
            xw=max(1,(width-1).bit_length());yw=max(1,(height-1).bit_length());cw=capacity.bit_length()
            errors=filled=0
            for index,raw in enumerate(frames):
                tag=(index*17+3)&((1<<tagw)-1)
                for i,(x,y,keep,error) in enumerate(raw):
                    inputs.append(pack(((tag if i==0 else tag^((1<<tagw)-1),tagw),
                                        (error,1),(keep,1),(int(i==len(raw)-1),1),(y,bits),(x,bits))))
                mask,n,error=oracle(raw,capacity,width,height,composition);errors+=bool(error);filled+=sum(mask)
                for p,value in enumerate(mask):
                    y,x=divmod(p,width)
                    expected.append(pack(((tag,tagw),(error,2),(n,cw),(int(p==width*height-1),1),
                                          (int(x==width-1),1),(int(p==0),1),(y,yw),(x,xw),(value,1))))
            (folder/'input.hex').write_text(''.join(f'{v:x}\n' for v in inputs),encoding='ascii',newline='\n')
            (folder/'golden.hex').write_text(''.join(f'{v:x}\n' for v in expected),encoding='ascii',newline='\n')
            (folder/'tb.sv').write_text(bench(bits,capacity,width,height,tagw,len(inputs),len(expected),composition),encoding='ascii',newline='\n')
            run([iv,'-g2012','-Wall','-s','tb','-o','sim.vvp',rtl,HULL,wrapper,'tb.sv'],folder)
            output=run([vv,'sim.vvp'],folder);assert 'PASS polygon' in output,output
            profiles.append({'coord_w':bits,'max_vertices':capacity,'width':width,'height':height,'tag_w':tagw,
                             'composition':composition,'frames':len(frames),'input_tokens':len(inputs),
                             'pixels':len(expected),'filled_pixels':filled,'error_frames':errors,
                             'status':'UNIT_SIM_PASS','result':output.strip()})
        invalid=[{'COORD_W':1,'WIDTH':1,'HEIGHT':1},{'COORD_W':17},{'MAX_VERTICES':0},{'MAX_VERTICES':65},
                 {'WIDTH':0},{'HEIGHT':0},{'WIDTH':1025},{'HEIGHT':1025},{'WIDTH':512,'HEIGHT':512},
                 {'COORD_W':4,'WIDTH':9,'HEIGHT':1},{'TAG_W':0},{'TAG_W':33}]
        for parameters in invalid:
            settings=','.join(f'.{key}({value})' for key,value in parameters.items())
            (temp/'invalid.sv').write_text(f'module invalid_tb;polygon_raster_mask #({settings}) dut();initial #1 $finish;endmodule\n',encoding='ascii',newline='\n')
            run([iv,'-g2012','-s','invalid_tb','-o','invalid.vvp',rtl,'invalid.sv'],temp)
            run([vv,'invalid.vvp'],temp,True)
    files=['.gitattributes','files.f','integration.f','rtl/polygon_raster_mask.sv','example/point_hull_mask.sv',
           'run_tests.py','README.md','SOURCES.md']
    for name in files:assert b'\r' not in (ROOT/name).read_bytes(),name
    report={'baseline_commit':BASELINE,'status':['LINT_PASS','UNIT_SIM_PASS','INTEGRATION_CANDIDATE','HW_UNVERIFIED'],
            'oracle':'exact Fraction vertical-ray polygon membership; independent Jarvis hull for composition',
            'profiles':profiles,'frames':sum(p['frames'] for p in profiles),'pixels':sum(p['pixels'] for p in profiles),
            'input_tokens':sum(p['input_tokens'] for p in profiles),'commands':records,'invalid_parameter_rejections':len(invalid),
            'source_sha256':{p:hashlib.sha256((ROOT/p).read_bytes()).hexdigest() for p in files},
            'dependency_sha256':{'../point_convex_hull/rtl/point_convex_hull.sv':hashlib.sha256(HULL.read_bytes()).hexdigest()},
            'resource_risk':{'default':'MEDIUM','maximum':'HIGH','measured':False},
            'not_run':['synthesis','PnR','STA','hardware','full regression']}
    (ROOT/'verification.json').write_text(json.dumps(report,indent=2)+'\n',encoding='utf-8',newline='\n')
    print(f"PASS polygon profiles={len(profiles)} frames={report['frames']} pixels={report['pixels']} commands={len(records)}")


if __name__=='__main__':main()
