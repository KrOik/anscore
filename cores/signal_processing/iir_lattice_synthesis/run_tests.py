#!/usr/bin/env python3
"""Finite integer-vector synthesis-lattice checks; no implementation tools."""
from datetime import datetime,timezone
import hashlib,json,os,random,shutil,subprocess,tempfile
from pathlib import Path
ROOT=Path(__file__).resolve().parent


class Oracle:
    def __init__(self,order,frac,state_w):
        self.order=order;self.scale=1<<frac;self.low=-(1<<(state_w-1));self.high=(1<<(state_w-1))-1
        self.k=None;self.history=[0]*order
    def configure(self,k):
        if any(abs(x)>=self.scale for x in k):return 1
        self.k=k[:];self.history=[0]*self.order;return 0
    def sample(self,value):
        old=self.history[:];new=old[:];f=value;clipped=False
        def tz(x):return (-1 if x<0 else 1)*(abs(x)//self.scale)
        def sat(x):
            nonlocal clipped
            clipped|=not self.low<=x<=self.high
            return max(self.low,min(self.high,x))
        for m in range(self.order,0,-1):
            f=sat(f-tz(self.k[m-1]*old[m-1]))
            if m<self.order:new[m]=sat(old[m-1]+tz(self.k[m-1]*f))
        new[0]=f;self.history=new
        return f,int(clipped)


def bench(w,sw,f,o,t):
    scale=1<<f;hi=(1<<(w-1))-1;lo=-(1<<(w-1));rng=random.Random(20261104+w*100+o+f)
    oracle=Oracle(o,f,sw);calls=[];expected=[];configurations=0
    def lit(x,width):return f"{width}'h{x&((1<<width)-1):x}"
    def configure(k):
        nonlocal configurations
        error=oracle.configure(k);configurations+=1
        for i,x in enumerate(k):calls.append(f'put_coefficient({lit(x,f+1)});')
        calls.append(f'finish_configuration({error});')
    def sample(x):
        index=len(expected);y,clip=oracle.sample(x);expected.append((y,clip))
        last=index%7==6;tag=index&((1<<t)-1)
        calls.append(f'put_sample({lit(x,w)},{int(last)},{lit(tag,t)},{index%3});')
        calls.append(f'get_sample({lit(y,sw)},{clip},{int(last)},{lit(tag,t)},{index%5});')
    # Reject an invalid initial bank and require data still blocked.
    configure([-scale]+[0]*(o-1));calls.append('if(configured || s_ready) $fatal(1,"invalid first bank enabled input");')
    k=[((-1)**i)*(scale//2 if i==0 else scale//4) for i in range(o)]
    configure(k)
    for x in [hi,0,0,lo,0,1,-1]+[rng.randrange(lo,hi+1) for _ in range(18)]:sample(x)
    # Failed reconfiguration must preserve both current coefficients and history.
    configure([0]*(o-1)+[-scale])
    for x in [0,0,hi,lo,0]:sample(x)
    # Successful identity bank clears history; last metadata does not reset it.
    configure([0]*o)
    for x in [0,lo,hi,-1,1,0]:sample(x)
    # Near-unit first reflection; repeated negative input forces clipping even
    # when STATE_W includes eight guard bits, and tests signed minimum products.
    configure([-scale+1]+[0]*(o-1))
    for _ in range(350):sample(lo)
    configure([scale-1]+[0]*(o-1))
    for x in [lo,hi]*8:sample(x)
    code=r'''
`timescale 1ns/1ps
module tb;
localparam W=__W__,SW=__SW__,F=__F__,O=__O__,T=__T__;
reg clk=0;always #5 clk=~clk;
reg rst=1,c_valid=0,s_valid=0,m_ready=0;
reg signed [F:0] c_k=0;wire c_ready,c_done,c_error,configured;
reg signed [W-1:0] s_data=0;reg s_last=0;reg [T-1:0] s_tag=0;
wire s_ready,m_valid,m_last,m_clipped;wire signed [SW-1:0] m_data;wire [T-1:0] m_tag;
iir_lattice_synthesis #(.DATA_W(W),.STATE_W(SW),.FRAC(F),.ORDER(O),.TAG_W(T)) dut(.*);
integer cycles=0,samples=0,stalls=0,clipped_count=0,config_count=0;
always @(posedge clk) begin cycles=cycles+1;if(cycles>2000000) $fatal(1,"bounded watchdog");end
task reset_core;
 begin
  @(negedge clk);rst=1;c_valid=0;s_valid=0;m_ready=0;
  repeat(2) @(posedge clk);@(negedge clk);rst=0;
  if(m_valid || configured) $fatal(1,"reset retained active state");
 end
endtask
task put_coefficient(input [F:0] value);
 integer watchdog;
 begin
  @(negedge clk);c_valid=1;c_k=value;watchdog=0;
  @(posedge clk);while(!c_ready) begin @(posedge clk);watchdog=watchdog+1;if(watchdog>O+5) $fatal(1,"configuration blocked");end
  @(negedge clk);c_valid=0;c_k=0;
 end
endtask
task finish_configuration(input bit error);
 integer watchdog;
 begin
  watchdog=0;
  while(!c_done) begin @(negedge clk);watchdog=watchdog+1;if(watchdog>O+3) $fatal(1,"configuration completion timeout");end
  if(c_error!==error) $fatal(1,"configuration error mismatch");
  config_count=config_count+1;
  @(negedge clk);if(c_done) $fatal(1,"configuration done not a pulse");
 end
endtask
task put_sample(input [W-1:0] value,input bit last,input [T-1:0] tag,input integer gap);
 begin
  repeat(gap) @(negedge clk);@(negedge clk);s_valid=1;s_data=value;s_last=last;s_tag=tag;
  @(posedge clk);if(!s_ready) $fatal(1,"configured idle input unexpectedly blocked");
  @(negedge clk);s_valid=0;s_data=~value;s_last=~last;s_tag=~tag;
 end
endtask
task get_sample(input [SW-1:0] expected,input bit clip,last,input [T-1:0] tag,input integer stall);
 integer watchdog;
 begin
  watchdog=0;
  while(!m_valid) begin @(negedge clk);watchdog=watchdog+1;if(watchdog>(2*O-1)*(F+1)+5) $fatal(1,"sample timeout");end
  repeat(stall+1) begin
   if(!m_valid || {m_data,m_clipped,m_last,m_tag}!=={expected,clip,last,tag})
    $fatal(1,"sample=%0d value=%0d/%0d clip=%b/%b last=%b/%b tag=%h/%h",samples,m_data,$signed(expected),m_clipped,clip,m_last,last,m_tag,tag);
   if(s_ready || c_ready) $fatal(1,"admitted during held result");
   stalls=stalls+1;@(negedge clk);
  end
  m_ready=1;@(posedge clk);@(negedge clk);m_ready=0;
  if(m_valid) $fatal(1,"duplicate result");samples=samples+1;if(clip)clipped_count=clipped_count+1;
 end
endtask
integer j;
initial begin
 reset_core();
 // Data is blocked until a complete successful configuration.
 s_valid=1;repeat(3) begin @(negedge clk);if(s_ready || m_valid) $fatal(1,"unconfigured admission");end s_valid=0;
 // Reset a partial bank, then reset an arithmetic transaction and held result.
 put_coefficient(0);reset_core();
 for(j=0;j<O;j=j+1)put_coefficient(0);finish_configuration(0);
 put_sample(1,0,0,0);wait(dut.state==4);reset_core();
 for(j=0;j<O;j=j+1)put_coefficient(0);finish_configuration(0);
 put_sample(1,0,0,0);wait(m_valid);reset_core();
 // Simultaneous coefficient/sample offers grant configuration first.
 @(negedge clk);c_valid=1;c_k=0;s_valid=1;s_data=0;
 @(posedge clk);if(!c_ready || s_ready) $fatal(1,"configuration priority");
 @(negedge clk);c_valid=0;s_valid=0;
 for(j=1;j<O;j=j+1)put_coefficient(0);finish_configuration(0);
 reset_core();config_count=0;
 __CALLS__
 if(samples!=__SAMPLES__ || clipped_count!=__CLIPS__) $fatal(1,"arithmetic coverage mismatch");
 $display("PASS lattice W=%0d SW=%0d F=%0d O=%0d T=%0d samples=%0d clips=%0d stalls=%0d configs=%0d",W,SW,F,O,T,samples,clipped_count,stalls,config_count);$finish;
end
endmodule
'''
    for key,value in {'W':w,'SW':sw,'F':f,'O':o,'T':t,'CALLS':'\n'.join(calls),'SAMPLES':len(expected),'CLIPS':sum(c for _,c in expected)}.items():code=code.replace('__'+key+'__',str(value))
    return code,{'data_w':w,'state_w':sw,'frac':f,'order':o,'tag_w':t,'samples':len(expected),'clipped_samples':sum(c for _,c in expected),'configurations':configurations}


def main():
    (ROOT/'verification.json').unlink(missing_ok=True)
    for p in ROOT.rglob('*'):
        if p.is_file() and b'\r' in p.read_bytes():raise RuntimeError('LF source required: '+str(p))
    suite=ROOT.parents[2]/'tools/oss-cad-suite/oss-cad-suite';env=os.environ.copy()
    env['PATH']=str(suite/'bin')+os.pathsep+str(suite/'lib')+os.pathsep+env['PATH']
    iv=str(suite/'bin/iverilog.exe') if (suite/'bin/iverilog.exe').is_file() else shutil.which('iverilog')
    vv=str(suite/'bin/vvp.exe') if (suite/'bin/vvp.exe').is_file() else shutil.which('vvp')
    if not iv or not vv:raise SystemExit('NOT_RUN: requires Icarus Verilog/vvp')
    records=[];profiles=[]
    def run(cmd,cwd,negative=False):
        p=subprocess.run(cmd,cwd=cwd,env=env,capture_output=True,text=True,timeout=15)
        records.append({'command':[str(x) for x in cmd],'returncode':p.returncode,'stdout':p.stdout.strip(),'stderr':p.stderr.strip()})
        if negative:
            if not p.returncode or 'iir_lattice_synthesis_invalid_parameter__see_README' not in p.stderr:raise RuntimeError(p.stderr)
        elif p.returncode:raise RuntimeError(p.stdout+p.stderr)
        if p.stdout.strip():print(p.stdout.splitlines()[0] if '-V' in cmd else p.stdout.strip())
        return p
    with tempfile.TemporaryDirectory(prefix='anscore_lattice_') as temp:
        tmp=Path(temp);version=run([iv,'-V'],tmp).stdout.splitlines()[0]
        run([iv,'-g2012','-Wall','-tnull','-s','lpc4_synthesis_example','-f','files.f','example/lpc4_synthesis_example.sv'],ROOT)
        for w,sw,f,o,t in [(2,2,1,1,1),(8,8,4,2,3),(16,24,16,4,8),(24,32,20,8,32),(8,16,1,8,8)]:
            tb,profile=bench(w,sw,f,o,t);path=tmp/'tb.sv';path.write_bytes(tb.encode());exe=tmp/'test.vvp'
            run([iv,'-g2012','-Wall','-s','tb','-o',exe,str(ROOT/'rtl/iir_lattice_synthesis.sv'),path],tmp)
            p=run([vv,exe],tmp)
            if 'PASS lattice' not in p.stdout:raise RuntimeError('no completion marker')
            profiles.append(profile)
        chain=tmp/'chain.vvp'
        run([iv,'-g2012','-Wall','-s','tb_lpc4_analysis_synthesis','-o',chain,'-f','integration.f','sim/tb_lpc4_analysis_synthesis.sv'],ROOT)
        p=run([vv,chain],tmp)
        if 'PASS LPC analysis/synthesis' not in p.stdout:raise RuntimeError('integration completion missing')
        for key,value in [('DATA_W',1),('DATA_W',25),('STATE_W',15),('STATE_W',33),('FRAC',0),('FRAC',21),('ORDER',0),('ORDER',9),('TAG_W',0),('TAG_W',33)]:
            run([iv,'-g2012','-tnull','-s','iir_lattice_synthesis',f'-Piir_lattice_synthesis.{key}={value}',str(ROOT/'rtl/iir_lattice_synthesis.sv')],tmp,True)
    files=[p for p in ROOT.rglob('*') if p.is_file() and p.name!='verification.json']
    report={'status':['LINT_PASS','UNIT_SIM_PASS','HW_UNVERIFIED'],'checked_at_utc':datetime.now(timezone.utc).isoformat(),
            'tool_version':version,'profiles':profiles,'commands':records,'per_process_timeout_seconds':15,
            'scope':'finite fixed-point numerical/configuration/protocol checks',
            'source_sha256':{str(p.relative_to(ROOT)).replace('\\','/'):hashlib.sha256(p.read_bytes()).hexdigest() for p in files},
            'integration_dependency_sha256':{'../levinson_durbin/rtl/levinson_durbin.sv':hashlib.sha256((ROOT.parent/'levinson_durbin/rtl/levinson_durbin.sv').read_bytes()).hexdigest()},
            'reproduce':'python -B cores/signal_processing/iir_lattice_synthesis/run_tests.py','not_run':['synthesis','PnR','STA','hardware']}
    (ROOT/'verification.json').write_bytes((json.dumps(report,indent=2)+'\n').encode())


if __name__=='__main__':main()
