"""Run stream_stats tapped on real observed channels; independent counter oracle.

stream_stats is tapped on the slave and master handshakes of a live DUT
(stream_sync_fifo / stream_elastic) or, for the 'bare' case, on a single
directly driven wire connected to both tap groups. The same queue model as
test_stream.py still predicts every DUT output while the tap is attached,
which is the executable part of the no-influence gate; an independent integer
model predicts every counter and the registered readout port on every cycle.
Generated tb.sv, stimuli, traces and logs are frozen in a fresh evidence
directory under evidence/.
"""
import argparse,copy,datetime,hashlib,json,os,pathlib,random,shutil,subprocess
from model import StreamModel

ROOT=pathlib.Path(__file__).resolve().parent
REPO=ROOT.parents[3]
CAD=REPO/'tools/oss-cad-suite/oss-cad-suite'
os.environ['PATH']=str(CAD/'bin')+os.pathsep+str(CAD/'lib')+os.pathsep+os.environ['PATH']

MAXCNT=0xFFFFFFFF
NCYC=1500
# Directed control-register writes (cycle -> enable bit); all other writes to
# index 15 are redirected to a read-only index so directed windows stay live.
EN_WRITES={700:0,740:1,950:0,980:1,1200:0,1210:1}

def tools(name):
    local=REPO/'tools/oss-cad-suite/oss-cad-suite/bin'/f'{name}.exe'
    return str(local) if local.exists() else shutil.which(name) or name

class StatsModel:
    """Cycle-accurate mirror of stream_stats: 12 saturating counters, an
    enable bit (control register index 15) and registered index-addressable
    readout. All inputs are the channel values observed during the cycle."""
    def __init__(self):
        self.en=1;self.c=[0]*12;self.rd=0
    def _mux(self,addr):
        if addr==15:return self.en
        if addr<12:return self.c[addr]
        return 0
    def step(self,rst,clr,cwe,caddr,cwdata,poke,
             sv,sr,su,sl,mv,mr,mu,ml,err):
        if poke:self.c[0]=0xFFFFFFFE        # white-box saturation injection
        self.rd=0 if not rst else self._mux(caddr)
        if not rst:
            self.en=1;self.c=[0]*12;return
        en_old=self.en
        if cwe and caddr==15:self.en=cwdata&1
        if clr:self.c=[0]*12
        elif en_old:
            c=self.c
            def inc(i):
                if c[i]!=MAXCNT:c[i]+=1
            if sv and sr:inc(0)
            if mv and mr:inc(1)
            if sv and not sr:inc(2)
            if mv and not mr:inc(3)
            if sv and sr and sl:inc(4)
            if mv and mr and ml:inc(5)
            if sv and sr and su:inc(6)
            if mv and mr and mu:inc(7)
            if err:inc(8)
            inc(9)
            if sr and not sv:inc(10)
            if mr and not mv:inc(11)

def vectors(kind,depth,width,seed):
    """Per-cycle stimulus and golden trace rows.

    stim tuple: rst clr cfg_we cfg_addr cfg_wdata s_v s_d s_u s_l m_r err poke
    gold tuple: s_tready m_tvalid (data,user,last)|None level cfg_rdata
    """
    rng=random.Random(seed)
    model=None if kind=='bare' else StreamModel(None if kind=='elastic' else depth)
    stats=StatsModel();held=None;stim=[];gold=[]
    for c in range(NCYC):
        drain=1300<=c<1320;poke_phase=1320<=c<1340;sweep=c>=1400
        rst=int(c not in (0,1,263,264,1127))
        clr=int(c in (500,900,1250))
        if sweep:
            cwe=0;caddr=(c-1400)%16;cwdata=0
        else:
            cwe=int(rng.random()<.06)
            caddr=rng.choice((0,3,8,11,15,15)) if rng.random()<.5 else rng.randrange(16)
            cwdata=rng.getrandbits(31)            # %d input range is signed
            if cwe and caddr==15:caddr=rng.choice((0,5,9))   # keep en writes directed
        if c in EN_WRITES:cwe,caddr,cwdata=1,15,EN_WRITES[c]
        mr=0 if 180<=c<250 or 1070<=c<1127 else (1 if drain or poke_phase else int(rng.random()<.61))
        if not rst:held=None
        if held is None and not drain and c<1290 and (c<180 or rng.random()<.78):
            held=(rng.getrandbits(width),rng.getrandbits(3),rng.getrandbits(1))
        if poke_phase and held is None:
            held=(rng.getrandbits(width),rng.getrandbits(3),rng.getrandbits(1))
        beat=held or (0,0,0);sv=int(held is not None)
        err=int(rng.random()<.03 or 1180<=c<1185)
        poke=int(c==1325)
        stim.append((rst,clr,cwe,caddr,cwdata,sv,*beat,mr,err,poke))
        if kind=='bare':
            sr,mv,ob=mr,sv,beat if sv else None
            su_,sl_,mu_,ml_=beat[1],beat[2],beat[1],beat[2]
            lev=0
        else:
            sr,mv,ob=model.outputs(mr);lev=len(model.q) if kind=='fifo' else mv
            su_,sl_=beat[1],beat[2]
            mu_,ml_=(ob[1],ob[2]) if mv else (0,0)
        gold.append((sr,mv,ob,lev,stats.rd))
        stats.step(rst,clr,cwe,caddr,cwdata,poke,sv,sr,su_,sl_,mv,mr,mu_,ml_,err)
        if model is not None:model.step(rst,sv,beat,mr)
        if not rst or sr:held=None
    return stim,gold

TB='''`timescale 1ns/1ps
module tb;
reg clk=0;always #5 clk=~clk;
reg rst_n=0,clr=0,cfg_we=0,s_tvalid=0,s_tlast=0,m_tready=0,err=0;
reg [3:0] cfg_addr=0;reg [31:0] cfg_wdata=0;
reg [TWIDTH-1:0] s_tdata=0;reg [2:0] s_tuser=0;
wire s_tready,m_tvalid,m_tlast;wire [TWIDTH-1:0] m_tdata;wire [2:0] m_tuser;
wire [31:0] cfg_rdata;
LEVELDECL
DUTDECL
stream_stats #(.USER_WIDTH(3)) stats(.clk(clk),.rst_n(rst_n),.clr(clr),
 .s_tvalid(s_tvalid),.s_tready(s_tready),.s_tlast(s_tlast),.s_tuser(s_tuser),
 .m_tvalid(m_tvalid),.m_tready(m_tready),.m_tlast(m_tlast),.m_tuser(m_tuser),
 .err(err),.cfg_addr(cfg_addr),.cfg_wdata(cfg_wdata),.cfg_we(cfg_we),.cfg_rdata(cfg_rdata));
integer f,o,rc,i,poke;reg [31:0] cw;
initial begin
f=$fopen("stim.txt","r");o=$fopen("trace.txt","w");
// Prime the synchronous reset before observing any control.
@(posedge clk);#1;
for(i=0;i<TNCYC;i=i+1)begin
@(negedge clk);rc=$fscanf(f,"%d %d %d %d %d %d %d %d %d %d %d %d\\n",
 rst_n,clr,cfg_we,cfg_addr,cw,s_tvalid,s_tdata,s_tuser,s_tlast,m_tready,err,poke);
if(rc!=12)$fatal(1,"bad stimulus");
cfg_wdata=cw;
// White-box saturation injection: preload the accepted-beat counter near its
// limit for one edge so saturation is observable in bounded simulation time.
if(poke) stats.c_accept=32'hFFFF_FFFE;
@(posedge clk);$fwrite(o,"%d %d %h %h %h %h %h\\n",s_tready,m_tvalid,m_tdata,m_tuser,m_tlast,level,cfg_rdata);
end
$fclose(o);$display("TRACE COMPLETE");$finish;end
endmodule
'''

def make_tb(kind,depth,width):
    tb=TB.replace('TWIDTH',str(width)).replace('TNCYC',str(NCYC))
    if kind=='bare':
        tb=tb.replace('LEVELDECL','wire [3:0] level=0;')
        tb=tb.replace('DUTDECL',
          'assign s_tready=m_tready;assign m_tvalid=s_tvalid;\n'
          'assign m_tdata=s_tdata;assign m_tuser=s_tuser;assign m_tlast=s_tlast;')
    elif kind=='elastic':
        tb=tb.replace('LEVELDECL','wire level=m_tvalid;')
        tb=tb.replace('DUTDECL',
          f'stream_elastic #(.DATA_WIDTH({width}),.USER_WIDTH(3)) dut(.clk(clk),.rst_n(rst_n),'
          '.s_tdata(s_tdata),.s_tuser(s_tuser),.s_tlast(s_tlast),.s_tvalid(s_tvalid),.s_tready(s_tready),'
          '.m_tdata(m_tdata),.m_tuser(m_tuser),.m_tlast(m_tlast),.m_tvalid(m_tvalid),.m_tready(m_tready));')
    else:
        tb=tb.replace('LEVELDECL',f'wire [$clog2({depth}+2)-1:0] level;')
        tb=tb.replace('DUTDECL',
          f'stream_sync_fifo #(.DATA_WIDTH({width}),.USER_WIDTH(3),.RAM_DEPTH({depth})) dut(.clk(clk),.rst_n(rst_n),'
          '.s_tdata(s_tdata),.s_tuser(s_tuser),.s_tlast(s_tlast),.s_tvalid(s_tvalid),.s_tready(s_tready),'
          '.m_tdata(m_tdata),.m_tuser(m_tuser),.m_tlast(m_tlast),.m_tvalid(m_tvalid),.m_tready(m_tready),.level(level));')
    return tb

def goldens(kind,depth,stim):
    """Replay the recorded stimulus through both models; deterministic."""
    model=None if kind=='bare' else StreamModel(None if kind=='elastic' else depth)
    stats=StatsModel();gold=[]
    for st in stim:
        rst,clr,cwe,caddr,cwdata,sv,sd,su,sl,mr,err,poke=st
        if kind=='bare':
            sr,mv,ob=mr,sv,(sd,su,sl) if sv else None
            mu_,ml_=su,sl;lev=0
        else:
            sr,mv,ob=model.outputs(mr);lev=len(model.q) if kind=='fifo' else mv
            mu_,ml_=(ob[1],ob[2]) if mv else (0,0)
        gold.append((sr,mv,ob,lev,stats.rd))
        stats.step(rst,clr,cwe,caddr,cwdata,poke,sv,sr,su,sl,mv,mr,mu_,ml_,err)
        if model is not None:model.step(rst,sv,(sd,su,sl),mr)
    return gold,stats

def check_rows(kind,depth,stim,rows):
    """Per-cycle comparison of every traced field; raises AssertionError."""
    gold,stats=goldens(kind,depth,stim)
    assert len(rows)==len(gold),'trace length mismatch'
    for i,(row,g) in enumerate(zip(rows,gold,strict=True)):
        sr,mv,ob,lev,rd=g
        assert row[0]==sr and row[1]==mv,(i,'handshake',row,g)
        assert row[5]==lev,(i,'level',row,g)
        assert row[6]==rd,(i,'cfg_rdata',row,g)
        if mv:assert row[2:5]==ob,(i,'payload',row,g)
    return gold,stats

def parse_hex(x):
    return None if 'x' in x.lower() else int(x,16)

def run_case(out,kind,depth,width,seed):
    tag=f'{kind}{"" if depth is None else depth}_w{width}_s{seed:x}'
    work=out/tag;work.mkdir()
    stim,gold=vectors(kind,depth,width,seed)
    (work/'stim.txt').write_text(''.join(' '.join(map(str,x))+'\n' for x in stim))
    (work/'tb.sv').write_text(make_tb(kind,depth,width))
    sources=[str(ROOT/'stream_stats.v')]
    if kind=='elastic':sources.append(str(ROOT/'stream_elastic.v'))
    if kind=='fifo':sources.append(str(ROOT/'stream_sync_fifo.v'))
    commands=[[tools('iverilog'),'-g2012','-Wall','-s','tb','-o','sim.vvp',*sources,'tb.sv'],[tools('vvp'),'sim.vvp']]
    logs=[]
    for cmd in commands:
        proc=subprocess.run(cmd,cwd=work,text=True,stdout=subprocess.PIPE,stderr=subprocess.STDOUT)
        logs.append('$ '+' '.join(cmd)+'\n'+proc.stdout)
        (work/'run.log').write_text('\n'.join(logs))
        assert proc.returncode==0,logs[-1]
    assert 'TRACE COMPLETE' in logs[-1]
    rows=[]
    for line in (work/'trace.txt').read_text().splitlines():
        a,b,*rest=line.split()
        rows.append((int(a),int(b),*[parse_hex(x) for x in rest]))
    gold,stats=check_rows(kind,depth,stim,rows)
    c=stats.c
    assert c[0]==MAXCNT,'saturation injection did not reach the limit'
    assert c[2]>0 and c[3]>0,'stall windows not exercised'
    assert c[8]>0,'error strobes not exercised'
    assert c[9]>0,'counted-cycle denominator not exercised'
    # The 701..739 counting-disable window must have frozen every counter.
    m=None if kind=='bare' else StreamModel(None if kind=='elastic' else depth)
    s2=StatsModel();snap=None
    for i,st in enumerate(stim):
        rst,clr,cwe,caddr,cwdata,sv,sd,su,sl,mr,err,poke=st
        if kind=='bare':sr,mv=mr,sv;mu_,ml_=su,sl
        else:
            sr,mv,ob=m.outputs(mr);mu_,ml_=(ob[1],ob[2]) if mv else (0,0)
        s2.step(rst,clr,cwe,caddr,cwdata,poke,sv,sr,su,sl,mv,mr,mu_,ml_,err)
        if m is not None:m.step(rst,sv,(sd,su,sl),mr)
        if i==702:snap=list(s2.c)
        if i==739:assert s2.c==snap,'counters moved while disabled'
    # Negative checks: corrupt the observed trace; the oracle must reject it.
    emi=[i for i,g in enumerate(gold) if g[1]]
    assert len(emi)>200,'insufficient emitted coverage'
    i=emi[100]
    for name in ('data','sideband','count','valid'):
        bad=copy.deepcopy(rows);row=list(bad[i])
        if name=='data':row[2]=(row[2] or 0)^1
        elif name=='sideband':row[3]=(row[3] or 0)^1
        elif name=='count':row[6]=(gold[i][4] or 0)^0x5A5A5A5A
        else:row[1]=0
        bad[i]=tuple(row)
        try:check_rows(kind,depth,stim,bad)
        except AssertionError:pass
        else:raise AssertionError('oracle accepted '+name+' corruption')
    return dict(case=tag,cycles=len(rows),accepted=c[0],emitted=c[1],
                source_stall=c[2],sink_stall=c[3],s_last=c[4],m_last=c[5],
                s_user=c[6],m_user=c[7],errors=c[8],counted_cycles=c[9],
                saturation='PASS',disable_window='PASS',negative_checks=4,
                status='PASS')

def main():
    p=argparse.ArgumentParser();p.add_argument('--out',type=pathlib.Path);a=p.parse_args()
    out=a.out or ROOT/'evidence'/('stats_'+datetime.datetime.now().strftime('%Y%m%d_%H%M%S_%f'))
    out.mkdir(parents=True,exist_ok=False)
    results=[]
    cases=[('fifo',16,8),('fifo',1,8),('fifo',3,16),('elastic',None,8),('bare',None,8)]
    for kind,depth,width in cases:
        result=run_case(out,kind,depth,width,0x51A7+width+(depth or 0))
        results.append(result);print(result['case'],'PASS')
    illegal=[]
    work=out/'invalid_USER_WIDTH';work.mkdir()
    (work/'tb.sv').write_text('module tb; stream_stats #(.USER_WIDTH(0)) dut(); initial #1 $finish; endmodule\n')
    cp=subprocess.run([tools('iverilog'),'-g2012','-s','tb','-o','sim.vvp',str(ROOT/'stream_stats.v'),'tb.sv'],cwd=work,capture_output=True,text=True)
    assert cp.returncode==0,cp.stderr
    rp=subprocess.run([tools('vvp'),'sim.vvp'],cwd=work,capture_output=True,text=True)
    (work/'run.log').write_text(cp.stdout+cp.stderr+rp.stdout+rp.stderr)
    assert rp.returncode!=0 and 'invalid' in rp.stdout,'illegal parameter was not rejected'
    illegal.append('stream_stats.USER_WIDTH=0 rejected')
    hashes={p.name:hashlib.sha256(p.read_bytes()).hexdigest() for p in ROOT.iterdir() if p.suffix in ('.v','.py')}
    (out/'summary.json').write_text(json.dumps(dict(
        status='PASS',cases=results,illegal_parameters=illegal,
        monitor='passive: every stream-facing port is an input; DUT outputs matched the queue model with the tap attached',
        saturation='white-box c_accept preload to 0xFFFFFFFE inside generated tb.sv',
        source_sha256=hashes,synthesis='see synth_stats.py evidence',board='NOT RUN'),indent=2))
    print('PASS',len(results),'cases;',out)
if __name__=='__main__':main()
