"""Run real Icarus RTL against deterministic independent queue models."""
import argparse,copy,datetime,hashlib,json,os,pathlib,random,shutil,subprocess
from model import StreamModel,verify_transactions

ROOT=pathlib.Path(__file__).resolve().parent
REPO=ROOT.parents[3]
CAD=REPO/'tools/oss-cad-suite/oss-cad-suite'
os.environ['PATH']=str(CAD/'bin')+os.pathsep+str(CAD/'lib')+os.pathsep+os.environ['PATH']

def tools(name):
    local=REPO/'tools/oss-cad-suite/oss-cad-suite/bin'/f'{name}.exe'
    return str(local) if local.exists() else shutil.which(name) or name

def vectors(depth,width,seed):
    rng=random.Random(seed); model=StreamModel(depth); held=None; stim=[];gold=[]
    for c in range(2600):
        rst=int(c not in (0,1,263,264,1127,1921))
        ready=0 if 180<=c<250 or 1070<=c<1127 else (1 if c<180 or c>2400 else int(rng.random()<.61))
        if not rst: held=None
        if held is None and c<2400 and (c<180 or rng.random()<.78):
            held=(rng.getrandbits(width),rng.getrandbits(3),rng.getrandbits(1))
        beat=held or (0,0,0)
        sr,mv,ob=model.outputs(ready)
        stim.append((rst,int(held is not None),*beat,ready))
        gold.append((sr,mv,ob,len(model.q)))
        model.step(rst,held is not None,beat,ready)
        if not rst or sr:held=None
    return stim,gold

def run_case(out,depth,width,seed):
    tag=f'{"elastic" if depth is None else "fifo"+str(depth)}_w{width}_s{seed}'
    work=out/tag;work.mkdir()
    stim,gold=vectors(depth,width,seed)
    (work/'stim.txt').write_text(''.join(' '.join(map(str,x))+'\n' for x in stim))
    inst=('stream_elastic' if depth is None else 'stream_sync_fifo')
    params=f'.DATA_WIDTH({width}),.USER_WIDTH(3)'+('' if depth is None else f',.RAM_DEPTH({depth})')
    tb='''`timescale 1ns/1ps
module tb;
reg clk=0;always #5 clk=~clk;
reg rst_n=0,s_tvalid=0,s_tlast=0,m_tready=0;
reg [WIDTH-1:0] s_tdata=0;reg [2:0] s_tuser=0;
wire s_tready,m_tvalid,m_tlast;wire [WIDTH-1:0] m_tdata;wire [2:0] m_tuser;
LEVELDECL
INSTANCE #(PARAMS) dut(.clk(clk),.rst_n(rst_n),.s_tdata(s_tdata),.s_tuser(s_tuser),.s_tlast(s_tlast),.s_tvalid(s_tvalid),.s_tready(s_tready),.m_tdata(m_tdata),.m_tuser(m_tuser),.m_tlast(m_tlast),.m_tvalid(m_tvalid),.m_tready(m_tready)LEVELPORT);
integer f,o,rc,i;initial begin
f=$fopen("stim.txt","r");o=$fopen("trace.txt","w");
// Prime the synchronous reset before observing any control.
@(posedge clk);#1;
for(i=0;i<2600;i=i+1)begin
@(negedge clk);rc=$fscanf(f,"%d %d %d %d %d %d\\n",rst_n,s_tvalid,s_tdata,s_tuser,s_tlast,m_tready);
if(rc!=6)$fatal(1,"bad stimulus");
@(posedge clk);$fwrite(o,"%d %d %h %h %h %h\\n",s_tready,m_tvalid,m_tdata,m_tuser,m_tlast,level);
end
$fclose(o);$display("TRACE COMPLETE");$finish;end
endmodule
'''.replace('WIDTH',str(width)).replace('INSTANCE',inst).replace('PARAMS',params).replace('LEVELDECL','wire level=m_tvalid;' if depth is None else f'wire [$clog2({depth}+2)-1:0] level;').replace('LEVELPORT','' if depth is None else ',.level(level)')
    (work/'tb.sv').write_text(tb)
    commands=[[tools('iverilog'),'-g2012','-Wall','-s','tb','-o','sim.vvp',str(ROOT/f'{inst}.v'),'tb.sv'],[tools('vvp'),'sim.vvp']]
    logs=[]
    for cmd in commands:
        proc=subprocess.run(cmd,cwd=work,text=True,stdout=subprocess.PIPE,stderr=subprocess.STDOUT)
        logs.append('$ '+' '.join(cmd)+'\n'+proc.stdout)
        (work/'run.log').write_text('\n'.join(logs))
        assert proc.returncode==0,logs[-1]
    rows=[]
    for line in (work/'trace.txt').read_text().splitlines():
        a,b,*rest=line.split()
        rows.append((int(a),int(b),*[int(x,16) if 'x' not in x.lower() else None for x in rest]))
    for i,(row,expected) in enumerate(zip(rows,gold,strict=True)):
        sr,mv,beat,level=expected
        assert row[:2]==(sr,mv),(tag,i,row,expected)
        assert row[5]==level,(tag,i,'level',row,expected)
        if mv:assert row[2:5]==beat,(tag,i,row,expected)
    rows=[r[:5] for r in rows]
    counts=verify_transactions(stim,rows)
    # Full-speed region after startup: every clock must accept and emit.
    if depth==1:
        assert sum(r[1] for r in rows[6:180])==87,tag
    else:
        assert all(r[0] and r[1] for r in rows[5:180]),tag
    assert any(not r[0] for r in rows[200:250]),'full capacity not exercised'
    # Prove verifier rejects value, order, quantity and sideband corruption.
    indices=[i for i,(s,r) in enumerate(zip(stim,rows)) if s[0] and s[-1] and r[1]]
    for kind in ('data','order','count','sideband'):
        bad=copy.deepcopy(rows);i=indices[20];v=list(bad[i])
        if kind=='data':v[2]^=1
        elif kind=='sideband':v[3]^=1
        elif kind=='count':v[1]=0
        else:v[2:]=bad[indices[21]][2:]
        bad[i]=tuple(v)
        try:verify_transactions(stim,bad)
        except AssertionError:pass
        else:raise AssertionError('checker accepted '+kind)
    return dict(case=tag,cycles=len(rows),accepted=counts[0],emitted=counts[1],negative_checks=4,status='PASS')

def main():
    p=argparse.ArgumentParser();p.add_argument('--out',type=pathlib.Path);a=p.parse_args()
    out=a.out or ROOT/'evidence'/datetime.datetime.now().strftime('%Y%m%d_%H%M%S_%f')
    out.mkdir(parents=True,exist_ok=False)
    results=[]
    for depth in (None,1,2,3,16):
        for width in (1,8,32):
            result=run_case(out,depth,width,0x51A7+width)
            results.append(result);print(result['case'],'PASS')
    illegal=[]
    for module,param in [('stream_elastic','DATA_WIDTH'),('stream_elastic','USER_WIDTH'),('stream_sync_fifo','RAM_DEPTH')]:
        work=out/f'invalid_{module}_{param}';work.mkdir()
        (work/'tb.sv').write_text(f'module tb; {module} #(.{param}(0)) dut(); initial #1 $finish; endmodule\n')
        cp=subprocess.run([tools('iverilog'),'-g2012','-s','tb','-o','sim.vvp',str(ROOT/f'{module}.v'),'tb.sv'],cwd=work,capture_output=True,text=True)
        assert cp.returncode==0,cp.stderr
        rp=subprocess.run([tools('vvp'),'sim.vvp'],cwd=work,capture_output=True,text=True)
        (work/'run.log').write_text(cp.stdout+cp.stderr+rp.stdout+rp.stderr)
        assert rp.returncode!=0 and 'invalid' in rp.stdout,'illegal parameter was not rejected'
        illegal.append(module+'.'+param+'=0 rejected')
    hashes={p.name:hashlib.sha256(p.read_bytes()).hexdigest() for p in ROOT.iterdir() if p.suffix in ('.v','.py')}
    (out/'summary.json').write_text(json.dumps(dict(status='PASS',cases=results,illegal_parameters=illegal,source_sha256=hashes,synthesis='NOT RUN',board='NOT RUN'),indent=2))
    print('PASS',len(results),'cases;',out)
if __name__=='__main__':main()
