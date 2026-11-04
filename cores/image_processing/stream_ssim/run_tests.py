#!/usr/bin/env python3
"""Finite source compilation and deterministic unit simulation; no synthesis."""
from __future__ import annotations
import hashlib
import json
import os
from pathlib import Path
import random
import shutil
import subprocess
import tempfile
from fractions import Fraction

ROOT = Path(__file__).resolve().parent
REPO = ROOT.parents[2]
SUITE = REPO / 'tools/oss-cad-suite/oss-cad-suite'


def oracle(block, bits, capacity, q):
    kept = [(x, y) for x, y, mask in block if mask]
    overflow = len(kept) > capacity
    kept = kept[:capacity]
    n = len(kept)
    if not n:
        return 0, 0, 1, int(overflow)
    # Independently form rational population means, variances and covariance.
    mx = Fraction(sum(x for x, y in kept), n)
    my = Fraction(sum(y for x, y in kept), n)
    vx = sum((x-mx)**2 for x, y in kept) / n
    vy = sum((y-my)**2 for x, y in kept) / n
    cov = sum((x-mx)*(y-my) for x, y in kept) / n
    c1 = Fraction(((1 << bits)-1)**2, 10000)
    c2 = 9*c1
    metric = (2*mx*my+c1)*(2*cov+c2)/((mx*mx+my*my+c1)*(vx+vy+c2))
    assert -1 <= metric <= 1
    score = int(metric*(1 << q))  # signed truncation toward zero
    return score, n, 0, int(overflow)


def cases(bits, capacity):
    peak = (1 << bits)-1
    r = random.Random(20261104+bits+capacity)
    alternating = [(0 if i%2 else peak, peak if i%2 else 0, 1)
                   for i in range(capacity)]
    result = [
        [(0, 0, 1)], [(peak, peak, 1)], [(0, peak, 1)],
        [(peak, 0, 1)], [(peak, peak//2, 1)]*capacity,
        [(i% (peak+1), i% (peak+1), 1) for i in range(capacity)],
        alternating,
        [(peak, 0, 0)]*3,
        [(peak, peak, 1)]*(capacity+3),
        [(peak, peak, 1)]*capacity+[(0, peak, 0)]*2,
    ]
    for j in range(12):
        size = r.randrange(1, capacity+6)
        result.append([(r.randrange(peak+1), r.randrange(peak+1), r.randrange(4)!=0)
                       for _ in range(size)])
    return result


def testbench(bits, capacity, q):
    frames = cases(bits, capacity)
    expected = [oracle(b, bits, capacity, q) for b in frames]
    assignments = []
    send = []
    for i, (block, exp) in enumerate(zip(frames, expected)):
        score, n, empty, ov = exp
        assignments.append(f'exp_score[{i}]={score}; exp_n[{i}]={n}; '
                           f'exp_empty[{i}]={empty}; exp_ov[{i}]={ov};')
        for j, (x,y,mask) in enumerate(block):
            send.append(f'send_pair({x},{y},{int(mask)},{int(j==len(block)-1)},'
                        f'{i if j==0 else 255},{(j+i)%3});')
    template = r'''
`timescale 1ns/1ps
module tb;
localparam B=__BITS__,CAP=__CAP__,Q=__Q__,CW=$clog2(CAP+1),F=__FRAMES__;
reg clk=0; always #5 clk=~clk;
reg rst=1,s_valid=0,s_mask=0,s_last=0,m_ready=0;
reg [B-1:0] s_x=0,s_y=0;
reg [7:0] s_tag=0;
wire s_ready,m_valid,m_empty,m_overflow;
wire signed [Q+1:0] m_score;
wire [CW-1:0] m_count; wire [7:0] m_tag;
stream_ssim #(.BITS(B),.MAX_SAMPLES(CAP),.Q_BITS(Q)) dut(.*);
integer exp_score[0:F-1],exp_n[0:F-1],exp_empty[0:F-1],exp_ov[0:F-1];
integer received=0,cycles=0,held=0,stall_cycles=0,input_waits=0;
reg check_enable=0,was_stalled=0;
reg [Q+1+CW+2+8:0] previous;
wire [Q+1+CW+2+8:0] record={m_score,m_count,m_empty,m_overflow,m_tag};
always @(negedge clk) begin
 if(rst) begin m_ready=0; held=0; end
 else if(m_valid) begin
   if(held<5) begin m_ready=0; held=held+1; end
   else m_ready=1;
 end else begin m_ready=0; held=0; end
end
always @(posedge clk) begin
 cycles=cycles+1;
 if(cycles>100000) $fatal(1,"bounded watchdog");
 if(rst) was_stalled=0;
 else if(check_enable) begin
   if(was_stalled && (!m_valid || record!==previous))
      $fatal(1,"held output changed");
   was_stalled=m_valid&&!m_ready; previous=record;
   if(was_stalled) stall_cycles=stall_cycles+1;
   if(m_valid&&m_ready) begin
     if(received>=F) $fatal(1,"extra output");
     if($signed(m_score)!==exp_score[received] || m_count!==exp_n[received] ||
        m_empty!==exp_empty[received] || m_overflow!==exp_ov[received] ||
        m_tag!==received)
       $fatal(1,"block %0d score=%0d expected=%0d n=%0d empty=%0d ov=%0d tag=%0d",
              received,$signed(m_score),exp_score[received],m_count,m_empty,m_overflow,m_tag);
     received=received+1;
   end
 end
end
task send_pair(input integer x,y,mask,last,tag,gap);
 begin
   repeat(gap) @(negedge clk);
   @(negedge clk); s_valid=1;s_x=x;s_y=y;s_mask=mask;s_last=last;s_tag=tag;
   @(posedge clk);
   while(!s_ready) begin input_waits=input_waits+1; @(posedge clk); end
   @(negedge clk);s_valid=0;
 end
endtask
task reset_dut;
 begin
   @(negedge clk);rst=1;s_valid=0;
   repeat(2) @(posedge clk);
   @(negedge clk);rst=0;
   if(m_valid) $fatal(1,"reset output valid");
 end
endtask
initial begin
 __ASSIGN__
 reset_dut;
 // Abort a partially captured block.
 send_pair(1,0,1,0,7,0); reset_dut;
 // Abort in the shared wide multiplication stage.
 send_pair(1,0,1,1,8,0); repeat(15) @(posedge clk); reset_dut;
 // Abort a result that is held by the sink, before enabling scoreboard.
 send_pair(1,1,1,1,9,0); wait(m_valid); reset_dut;
 check_enable=1;
 __SEND__
 wait(received==F); repeat(10) @(posedge clk);
 if(stall_cycles<F*3 || input_waits==0) $fatal(1,"vacuous flow coverage");
 $display("PASS SSIM B=%0d CAP=%0d Q=%0d blocks=%0d stalls=%0d input_wait=%0d",
           B,CAP,Q,F,stall_cycles,input_waits);
 $finish;
end
endmodule
'''
    for key, val in {'BITS':bits, 'CAP':capacity, 'Q':q, 'FRAMES':len(frames),
                     'ASSIGN':'\n'.join(assignments), 'SEND':'\n'.join(send)}.items():
        template=template.replace('__'+key+'__', str(val))
    return template, len(frames)


def main():
    env=os.environ.copy()
    env['PATH']=str(SUITE/'bin')+os.pathsep+str(SUITE/'lib')+os.pathsep+env['PATH']
    iv = str(SUITE/'bin/iverilog.exe') if (SUITE/'bin/iverilog.exe').exists() else shutil.which('iverilog')
    vvp = str(SUITE/'bin/vvp.exe') if (SUITE/'bin/vvp.exe').exists() else shutil.which('vvp')
    if not iv or not vvp:
        raise SystemExit('NOT_RUN: Icarus Verilog and vvp are required')
    records=[]
    with tempfile.TemporaryDirectory(prefix='anscore_ssim_') as tmp:
        tmp=Path(tmp)
        def run(args, expected_failure=False):
            p=subprocess.run(args,cwd=ROOT,env=env,text=True,capture_output=True,timeout=20)
            records.append({'command':[str(a) for a in args], 'returncode':p.returncode,
                            'stdout':p.stdout.strip(),'stderr':p.stderr.strip()})
            print(p.stdout.strip(),p.stderr.strip())
            if expected_failure:
                if not p.returncode or 'invalid stream_ssim parameters' not in p.stdout+p.stderr:
                    raise RuntimeError('invalid parameter guard did not reject profile')
            elif p.returncode: raise RuntimeError('lightweight check failed')
        run([iv,'-g2012','-Wall','-tnull','-s','ssim_block_example','-f','files.f',
             'example/ssim_block_example.sv'])
        run([iv,'-g2012','-Wall','-tnull','-s','stream_ssim',
             '-Pstream_ssim.BITS=12','-Pstream_ssim.MAX_SAMPLES=4096',
             '-Pstream_ssim.Q_BITS=24','-Pstream_ssim.TAG_W=32','-f','files.f'])
        for bits,capacity,q in [(1,1,3),(8,64,15),(12,5,12)]:
            bench,n=testbench(bits,capacity,q)
            tb=tmp/f'tb_{bits}.sv';tb.write_text(bench,encoding='utf-8')
            exe=tmp/f'sim_{bits}.vvp'
            run([iv,'-g2012','-Wall','-s','tb','-o',exe,'-f','files.f',tb])
            run([vvp,exe])
        invalids={'BITS':13,'MAX_SAMPLES':4097,'Q_BITS':25,'TAG_W':33}
        for param,value in invalids.items():
            exe=tmp/f'invalid_{param}.vvp'
            run([iv,'-g2012','-s','stream_ssim',f'-Pstream_ssim.{param}={value}',
                 '-o',exe,'-f','files.f'])
            run([vvp,exe],expected_failure=True)
    hashes={str(p.relative_to(ROOT)).replace('\\','/'):hashlib.sha256(p.read_bytes()).hexdigest()
            for p in [ROOT/'rtl/stream_ssim.sv',ROOT/'example/ssim_block_example.sv',ROOT/'run_tests.py',ROOT/'files.f']}
    result={'status':['LINT_PASS','UNIT_SIM_PASS','HW_UNVERIFIED'],
            'date':'2026-11-04','profiles':[[1,1,3],[8,64,15],[12,5,12]],
            'maximum_parameter_compile':[12,4096,24,32],
            'invalid_parameter_rejections':[f'{p}={v}' for p,v in invalids.items()],
            'blocks':66,'scope':'finite deterministic block metric/protocol checks; no hardware checks',
            'source_sha256':hashes,'commands':records}
    (ROOT/'verification.json').write_text(json.dumps(result,indent=2)+'\n',encoding='utf-8')


if __name__=='__main__': main()
