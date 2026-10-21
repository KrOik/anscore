"""Real Icarus numerical/protocol regression with an independent queue oracle."""
import argparse, datetime, hashlib, itertools, json, os, random, subprocess
from pathlib import Path
from csc_model import bit_exact
from gen_csc_coeffs import generate

HERE=Path(__file__).resolve().parent
ROOT=HERE.parents[2]

def packed(p,b):
    p=tuple(p)+(0,)*(3-len(p))
    return (p[0]<<(2*b))|(p[1]<<b)|p[2]

def vectors(bits,latency=4):
    rng=random.Random(709+bits); m=(1<<bits)-1
    cycles=[]; expected=[]; out=None; pipeline=[None]*latency;active=0; pending=None; err=0; count=0
    def step(reset=1,src=None,ready=1,cfg=None):
        nonlocal out,pipeline,active,pending,err,count
        sr=out is None or ready
        commit=bool(src and sr and src[1] and pending is not None)
        cr=pending is None or commit
        ov=out or (0,0,0)
        expected.append((int(sr),int(out is not None),*ov,int(cr),err))
        pix,user,last=src or (0,0,0)
        cycles.append((reset,int(src is not None),pix,user,last,ready,int(cfg is not None),cfg or 0))
        if not reset: out=None;pipeline=[None]*latency;active=0;pending=None;err=0;return sr,cr
        config=pending if src and src[1] and pending is not None else active
        if commit: active=pending;pending=None
        err=0
        if cfg is not None and cr:
            if cfg>>2==3: err=1
            else: pending=cfg
        if sr:
            if src:
                p=((pix>>(2*bits))&m,(pix>>bits)&m,pix&m)
                result=bit_exact(p,bits,('601','709')[(config>>1)&1],bool(config&1),('forward','inverse','gray')[config>>2])
                out=(packed(result,bits),user,last);count+=1
            else: out=None
            pipeline=[out]+pipeline[:-1];out=pipeline[-1]
        return sr,cr
    step(0);step(0)
    # All 12 configurations per width, multiple frames, including full-rate sections.
    for config in range(12):
        while not step(cfg=config)[1]: pass
        pixels=list(itertools.product((0,1,m//2,m-1,m),repeat=3))+[(v,v,v) for v in range(m+1)]
        pixels += [tuple(rng.randrange(m+1) for _ in range(3)) for _ in range(128)]
        for i,p in enumerate(pixels):
            src=(packed(p,bits),int(i==0 or i==128),int(i%16==15 or i==len(pixels)-1))
            if i<128 and rng.random()<.3: step(ready=int(rng.random()<.7))
            while True:
                ready=1 if i>=128 else int(rng.random()<.7)
                if step(src=src,ready=ready,cfg=12 if i==30 else None)[0]: break
        # long output hold, invalid config rejection, pending replacement and reset cancellation
        for _ in range(35): step(ready=0)
        step();step()
    # Pending config cannot commit on a non-SOF beat, then reset drops output/config.
    step(cfg=5);step(src=(0,0,1));step(ready=0);step(0,ready=0)
    step(src=(packed((m,0,0),bits),1,1));step();step()
    # Simultaneous commit and new cfg, new cfg applies only to subsequent SOF.
    step(cfg=1);step(src=(0,1,1),cfg=6);step(src=(0,0,1));step(src=(0,1,1));step();step()
    step(cfg=2)
    for _ in range(10): step(src=(0,0,1),cfg=9)
    step(src=(0,1,1),cfg=9);step(src=(0,1,1));step();step()
    for _ in range(latency+2):step()
    return cycles,expected,count

TB='''module tb;
parameter BITS=8; reg clk=0;always #5 clk=~clk;
reg rst_n=0,s_tvalid=0,s_tuser=0,s_tlast=0,m_tready=0,cfg_valid=0;
reg [3*BITS-1:0] s_tdata=0;reg [3:0] cfg=0;
wire s_tready,m_tvalid,m_tuser,m_tlast,cfg_ready,cfg_error;wire [3*BITS-1:0] m_tdata;
csc_stream #(.BITS(BITS)) dut(.clk(clk),.rst_n(rst_n),.s_tdata(s_tdata),.s_tvalid(s_tvalid),.s_tready(s_tready),.s_tuser(s_tuser),.s_tlast(s_tlast),.m_tdata(m_tdata),.m_tvalid(m_tvalid),.m_tready(m_tready),.m_tuser(m_tuser),.m_tlast(m_tlast),.cfg_valid(cfg_valid),.cfg_ready(cfg_ready),.cfg_mode(cfg[3:2]),.cfg_standard(cfg[1]),.cfg_limited(cfg[0]),.cfg_error(cfg_error));
integer f,g,n,cycle=0;reg [1023:0] stim,trace;
initial begin
if(!$value$plusargs("stim=%s",stim)) $fatal;
if(!$value$plusargs("trace=%s",trace)) $fatal;
f=$fopen(stim,"r");g=$fopen(trace,"w");
// Initialize synchronous state before tracing.
@(posedge clk); @(negedge clk);
while(!$feof(f)) begin
n=$fscanf(f,"%d %d %h %d %d %d %d %h\\n",rst_n,s_tvalid,s_tdata,s_tuser,s_tlast,m_tready,cfg_valid,cfg);
if(n==8) begin
@(posedge clk);
$fwrite(g,"%d %d %h %d %d %d %d\\n",s_tready,m_tvalid,m_tdata,m_tuser,m_tlast,cfg_ready,cfg_error);
@(negedge clk);cycle=cycle+1;
end
end
$fclose(f);$fclose(g);$display("PASS trace cycles=%0d",cycle);$finish;
end
endmodule
'''

def verify(actual,expected):
    if len(actual)!=len(expected): raise AssertionError('count')
    for i,(a,e) in enumerate(zip(actual,expected)):
        # Payload can retain any previous value while invalid.
        indices=(0,1,5,6)+( (2,3,4) if e[1] else () )
        if any(a[j]!=e[j] for j in indices): raise AssertionError((i,a,e))

def main():
    parser=argparse.ArgumentParser();parser.add_argument('--source',type=Path,default=HERE/'csc_stream.v');parser.add_argument('--latency',type=int,choices=(1,4),default=4);args=parser.parse_args();source=args.source.resolve()
    generate()
    dest=HERE/'evidence'/datetime.datetime.now().strftime('%Y%m%d_%H%M%S_%f');dest.mkdir(parents=True)
    bindir=ROOT/'tools/oss-cad-suite/oss-cad-suite/bin';env=os.environ.copy();env['PATH']=str(bindir)+os.pathsep+str(bindir.parent/'lib')+os.pathsep+env['PATH']
    results=[]
    for bits in (8,10):
        cycles,expected,count=vectors(bits,args.latency)
        stim=dest/f'stim{bits}.txt';trace=dest/f'trace{bits}.txt';tb=dest/f'tb{bits}.v';exe=dest/f'csc{bits}.vvp'
        stim.write_text(''.join(f'{r} {v} {p:x} {u} {l} {ready} {cv} {c:x}\n' for r,v,p,u,l,ready,cv,c in cycles));tb.write_text(TB)
        commands=[[str(bindir/'iverilog.exe'),'-g2012','-Wall','-I',str(HERE),'-s','tb',f'-Ptb.BITS={bits}','-o',str(exe),str(source),str(tb)], [str(bindir/'vvp.exe'),str(exe),f'+stim={stim}',f'+trace={trace}']]
        for i,cmd in enumerate(commands):
            p=subprocess.run(cmd,env=env,capture_output=True,text=True);(dest/f'{bits}_{i}.log').write_text(p.stdout+p.stderr)
            if p.returncode: raise RuntimeError(p.stdout+p.stderr)
        actual=[tuple(int(x,16 if j==2 else 10) for j,x in enumerate(line.split())) for line in trace.read_text().splitlines()]
        verify(actual,expected)
        idx=next(i for i,a in enumerate(actual) if a[1]);mutations=[]
        for name,field in [('data',2),('SOF',3),('EOL',4),('valid',1)]:
            bad=actual.copy();row=list(bad[idx]);row[field]^=1;bad[idx]=tuple(row);mutations.append((name,bad))
        mutations.append(('count',actual[:-1])); bad=actual.copy();j=next(i for i in range(idx+1,len(bad)) if bad[i][1] and bad[i][2]!=bad[idx][2]);bad[idx],bad[j]=bad[j],bad[idx];mutations.append(('order',bad))
        for name,bad in mutations:
            try: verify(bad,expected)
            except AssertionError: pass
            else: raise AssertionError('mutation accepted '+name)
        results.append(dict(bits=bits,cycles=len(cycles),accepted=count,configurations=12,mutations_rejected=len(mutations),status='PASS'))
    invalid=dest/'invalid.vvp'
    p=subprocess.run([str(bindir/'iverilog.exe'),'-g2012','-I',str(HERE),'-s','csc_stream','-Pcsc_stream.BITS=9','-o',str(invalid),str(source)],env=env,capture_output=True,text=True)
    if p.returncode: raise RuntimeError(p.stderr)
    p=subprocess.run([str(bindir/'vvp.exe'),str(invalid)],env=env,capture_output=True,text=True)
    (dest/'invalid.log').write_text(p.stdout+p.stderr)
    assert p.returncode != 0 and 'BITS must be 8 or 10' in p.stdout
    hashes={p.name:hashlib.sha256(p.read_bytes()).hexdigest() for p in (source,HERE/'csc_coeffs.vh',HERE/'csc_model.py',HERE/'test_csc_rtl.py')}
    (dest/'summary.json').write_text(json.dumps(dict(status='PASS',source=str(source),latency=args.latency,results=results,sha256=hashes),indent=2)+'\n')
    print('PASS',dest,results)

if __name__=='__main__':main()
