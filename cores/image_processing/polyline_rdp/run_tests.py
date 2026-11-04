#!/usr/bin/env python3
"""Finite Icarus checks, exact rational recursive oracle; no hardware tools."""
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
SUITE=REPO/'tools/oss-cad-suite/oss-cad-suite'


def oracle(raw,epsilon,capacity):
    points=[(x,y) for x,y,keep in raw if keep]
    if len(points)>capacity:return [],1
    if len(points)<2:return list(enumerate(points)),0
    def distance2(p,a,b):
        dx=b[0]-a[0];dy=b[1]-a[1]
        ux=p[0]-a[0];uy=p[1]-a[1]
        norm=dx*dx+dy*dy
        dot=ux*dx+uy*dy
        if not norm or dot<=0:return Fraction(ux*ux+uy*uy)
        if dot>=norm:return Fraction((p[0]-b[0])**2+(p[1]-b[1])**2)
        return Fraction((ux*dy-uy*dx)**2,norm)
    # Direct recursive rational distances: no RTL normalized scores or DFS stack.
    def simplify(lo,hi):
        if hi-lo<2:return [lo] if lo==hi else [lo,hi]
        index=max(range(lo+1,hi),key=lambda i:(distance2(points[i],points[lo],points[hi]),-i))
        if distance2(points[index],points[lo],points[hi])<=epsilon*epsilon:return [lo,hi]
        return simplify(lo,index)[:-1]+simplify(index,hi)
    return [(i,points[i]) for i in simplify(0,len(points)-1)],0


def fixtures(bits,capacity):
    low=-(1<<(bits-1));high=(1<<(bits-1))-1;maxeps=(1<<bits)-1
    def clamp(v):return max(low,min(high,v))
    def wrap(points):return [(clamp(x),clamp(y),1) for x,y in points] or [(0,0,0)]
    frames=[]
    def add(points,epsilon=0):frames.append((wrap(points),epsilon))
    add([]);add([(low,high)]);add([(low,low),(high,high)])
    add([(0,0)]*capacity)
    add([(low,0),(high,0),(0,0)])  # projection outside the endpoint segment
    add([(0,0),(high,0),(low,0)])
    add([(0,0),(high,high),(0,0)])  # degenerate root, then nondegenerate children
    add([(low,low),(high,low),(high,high),(low,high),(low,low)])
    add([(0,0),(1,1),(2,0)],1)  # exact perpendicular threshold equality
    add([(0,0),(2,0),(1,0)],1)  # exact endpoint threshold equality
    add([(low,low),(high,high),(high,low),(low,high),(low,low)],maxeps)
    add([(low,high)]*(capacity+1),0)  # no prefix publication on overflow
    frames.append(([(low,high,0),(high,low,1),(low,low,0)],1))
    frames.append(([(low,high,0)]*(capacity+3),maxeps))
    add([(i-capacity//2,(i&1)*high) for i in range(capacity)],0)
    add([(low if i&1 else high,high if i&2 else low) for i in range(capacity)],1)
    add([(low+i*(high-low)//max(1,capacity-1),0) for i in range(capacity)],0)
    if bits==4:
        # All ordered 3-point paths on a signed 3x3 grid; closed paths included.
        grid=list(itertools.product((-1,0,1),repeat=2))
        for number,points in enumerate(itertools.product(grid,repeat=3)):
            add(points,number%3)
    rng=random.Random(20261105+bits*31+capacity)
    for k in range(28):
        n=rng.randrange(1,capacity+4)
        raw=[(rng.randrange(low,high+1),rng.randrange(low,high+1),int(rng.randrange(6)!=0)) for _ in range(n)]
        frames.append((raw,[0,1,maxeps,rng.randrange(maxeps+1)][k%4]))
    return frames


def pack(parts):
    out=0
    for value,width in parts:out=(out<<width)|(value&((1<<width)-1))
    return out


def testbench(bits,capacity,tagw,input_n,output_n):
    iw=max(1,(capacity-1).bit_length());cw=capacity.bit_length()
    inw=3*bits+tagw+2;outw=2*bits+iw+cw+4+tagw
    return f'''`timescale 1ns/1ps
module tb;
localparam W={bits},N={capacity},TW={tagw},IW={iw},CW={cw},INW={inw},OW={outw};
reg clk=0;always #5 clk=~clk;
reg rst=1,s_valid=0,s_keep=0,s_last=0,m_ready=0;
wire s_ready,m_valid;
reg signed [W-1:0] s_x=0,s_y=0;
reg [W-1:0] s_epsilon=0;reg [TW-1:0] s_tag=0;
wire signed [W-1:0] m_x,m_y;wire [IW-1:0] m_index;
wire [CW-1:0] m_count;wire m_first,m_last,m_empty,m_error;wire [TW-1:0] m_tag;
polyline_rdp #(.COORD_W(W),.MAX_POINTS(N),.TAG_W(TW)) dut(.*);
reg [INW-1:0] inputs[0:{input_n-1}];reg [OW-1:0] golden[0:{output_n-1}];
wire [OW-1:0] payload={{m_tag,m_error,m_empty,m_first,m_last,m_count,m_index,m_y,m_x}};
reg [OW-1:0] held;reg hold_check=0,checking=0;
integer sent=0,received=0,cycle=0,stalls=0,reset_cases=0,waited;
task reset_core;
begin
    @(negedge clk);rst=1;s_valid=0;m_ready=0;
    repeat(2) @(posedge clk);
    @(negedge clk);rst=0;
    @(posedge clk);#1;
    if(m_valid || !s_ready) $fatal(1,"reset did not clear pending work");
end endtask
task send_abort_point(input integer px,input integer py,input integer last_bit);
begin
    @(negedge clk);s_valid=1;s_keep=1;s_x=px;s_y=py;s_last=last_bit;s_epsilon=0;
    do @(posedge clk);while(!s_ready);
    @(negedge clk);s_valid=0;
end endtask
task abort_at(input integer target);
begin
    reset_core();
    if(target==0) send_abort_point(0,0,0);
    else begin
        send_abort_point(0,0,0);send_abort_point(1,1,0);send_abort_point(2,0,1);
        waited=0;
        while(dut.state!=target && waited<2000) begin @(negedge clk);waited=waited+1;end
        if(dut.state!=target) $fatal(1,"reset target not reached %0d",target);
    end
    reset_core();reset_cases=reset_cases+1;
end endtask
always @(posedge clk) if(checking && !rst) begin
    if(hold_check && (!m_valid || payload!==held)) $fatal(1,"output changed under backpressure");
    hold_check=m_valid&&!m_ready;held=payload;
    if(s_valid&&s_ready) sent=sent+1;
    if(m_valid&&!m_ready) stalls=stalls+1;
    if(m_valid&&m_ready) begin
        if(received>={output_n} || payload!==golden[received])
            $fatal(1,"mismatch token=%0d got=%h expected=%h state=%0d",received,payload,golden[received],dut.state);
        received=received+1;
    end
end
initial begin
    $readmemh("input.hex",inputs);$readmemh("golden.hex",golden);
    abort_at(0);
    if(N>=3) begin abort_at(dut.MULTIPLY);abort_at(dut.DOT_DONE);abort_at(dut.SPLIT);abort_at(dut.OUT_HOLD);end
    else begin send_abort_point(0,0,1);repeat(8) @(negedge clk);reset_core();reset_cases=reset_cases+1;end
    checking=1;
    while(received<{output_n} && cycle<2000000) begin
        @(negedge clk);cycle=cycle+1;
        m_ready=!(cycle%13<5 || cycle%7==1);
        if(!(s_valid&&!s_ready)) begin
            if(sent<{input_n} && cycle%5!=0) begin
                s_valid=1;{{s_tag,s_epsilon,s_keep,s_last,s_y,s_x}}=inputs[sent];
            end else s_valid=0;
        end
    end
    @(negedge clk);s_valid=0;m_ready=1;
    if(received!={output_n} || sent!={input_n}) $fatal(1,"timeout or input loss %0d %0d",received,sent);
    repeat(20) @(posedge clk);
    if(stalls<10) $fatal(1,"missing output stalls");
    $display("PASS RDP W=%0d N=%0d tokens=%0d inputs=%0d stalls=%0d resets=%0d cycles=%0d",W,N,received,sent,stalls,reset_cases,cycle);
    $finish;
end
initial begin #25000000;$fatal(1,"testbench timeout");end
endmodule
'''


def main():
    env=os.environ.copy();env['PATH']=os.pathsep.join((str(SUITE/'bin'),str(SUITE/'lib'),env.get('PATH','')))
    compiler=os.environ.get('IVERILOG') or shutil.which('iverilog',path=env['PATH'])
    runtime=shutil.which('vvp',path=env['PATH'])
    if not compiler or not runtime:raise RuntimeError('NOT_RUN: Icarus Verilog unavailable')
    records=[];profiles=[]
    def run(command,cwd,expected_failure=False):
        result=subprocess.run(command,cwd=cwd,env=env,capture_output=True,text=True,timeout=20)
        record={'command':[str(v) for v in command],'returncode':result.returncode,
                'stdout':result.stdout,'stderr':result.stderr,'timeout_seconds':20}
        # Temporary names are diagnostic context, never dependencies.
        records.append(record)
        if expected_failure:
            assert result.returncode>0 and 'invalid polyline_rdp parameters' in result.stdout+result.stderr,record
        else:assert result.returncode==0,record
        return result.stdout
    with tempfile.TemporaryDirectory(prefix='anscore_polyline_rdp_') as tmp:
        temporary=Path(tmp)
        rtl=ROOT/'rtl/polyline_rdp.sv';example=ROOT/'example/contour_simplify_example.sv'
        run([compiler,'-g2012','-Wall','-tnull','-s','polyline_rdp','-s','contour_simplify_example',str(rtl),str(example)],temporary)
        for bits,capacity,tagw in ((2,1,1),(2,8,1),(4,8,3),(8,16,8),(12,32,8),(16,64,32)):
            folder=temporary/f'w{bits}_n{capacity}';folder.mkdir()
            frames=fixtures(bits,capacity);inputs=[];golden=[];empty=errors=0
            iw=max(1,(capacity-1).bit_length());cw=capacity.bit_length()
            for number,(raw,epsilon) in enumerate(frames):
                tag=(number*19+3)&((1<<tagw)-1)
                for i,(x,y,keep) in enumerate(raw):
                    inputs.append(pack(((tag if i==0 else tag^((1<<tagw)-1),tagw),
                                        (epsilon if i==0 else epsilon^((1<<bits)-1),bits),
                                        (keep,1),(int(i==len(raw)-1),1),(y,bits),(x,bits))))
                output,error=oracle(raw,epsilon,capacity)
                empty+=not output;errors+=error
                if not output:output=[(0,(0,0))]
                # A zero-count frame is exactly an empty input or an overflow.
                is_empty=error or not any(p[2] for p in raw)
                count=0 if is_empty else len(output)
                for j,(index,(x,y)) in enumerate(output):
                    golden.append(pack(((tag,tagw),(error,1),(int(is_empty),1),(int(j==0),1),
                                        (int(j==len(output)-1),1),(count,cw),(index,iw),(y,bits),(x,bits))))
            (folder/'input.hex').write_text(''.join(f'{v:x}\n' for v in inputs),encoding='ascii',newline='\n')
            (folder/'golden.hex').write_text(''.join(f'{v:x}\n' for v in golden),encoding='ascii',newline='\n')
            (folder/'tb.sv').write_text(testbench(bits,capacity,tagw,len(inputs),len(golden)),encoding='utf-8',newline='\n')
            run([compiler,'-g2012','-Wall','-s','tb','-o','sim.vvp',str(rtl),'tb.sv'],folder)
            output=run([runtime,'sim.vvp'],folder)
            assert 'PASS RDP' in output,output
            profiles.append({'coord_w':bits,'max_points':capacity,'tag_w':tagw,'frames':len(frames),
                             'input_tokens':len(inputs),'output_tokens':len(golden),'empty_frames':empty,
                             'overflow_frames':errors,'status':'UNIT_SIM_PASS','result':output.strip()})
        for key,value in (('COORD_W',1),('COORD_W',17),('MAX_POINTS',0),('MAX_POINTS',65),('TAG_W',0),('TAG_W',33)):
            text=f'module invalid_tb;polyline_rdp #(.{key}({value})) dut();initial #1 $finish;endmodule\n'
            (temporary/'invalid.sv').write_text(text,encoding='ascii',newline='\n')
            run([compiler,'-g2012','-s','invalid_tb','-o','invalid.vvp',str(rtl),'invalid.sv'],temporary)
            run([runtime,'invalid.vvp'],temporary,True)
    sources=['.gitattributes','files.f','rtl/polyline_rdp.sv','example/contour_simplify_example.sv','run_tests.py','README.md','SOURCES.md']
    report={'baseline_commit':'cf9b62d545d5e741589daf1fe99c6533f3148316',
            'status':['LINT_PASS','UNIT_SIM_PASS','INTEGRATION_CANDIDATE','HW_UNVERIFIED'],
            'oracle':'independent recursive exact Fraction point-to-segment RDP',
            'profiles':profiles,'frames':sum(p['frames'] for p in profiles),
            'input_tokens':sum(p['input_tokens'] for p in profiles),
            'output_tokens':sum(p['output_tokens'] for p in profiles),
            'commands':records,
            'source_sha256':{p:hashlib.sha256((ROOT/p).read_bytes()).hexdigest() for p in sources},
            'resource_risk':{'default':'MEDIUM','maximum':'HIGH','measured':False},
            'prohibited_tools_run':False}
    (ROOT/'verification.json').write_text(json.dumps(report,indent=2)+'\n',encoding='utf-8',newline='\n')
    print(f"PASS polyline_rdp profiles={len(profiles)} frames={report['frames']} tokens={report['output_tokens']} commands={len(records)}")


if __name__=='__main__':main()
