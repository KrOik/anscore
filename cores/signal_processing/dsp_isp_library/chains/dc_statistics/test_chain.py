"""Check composed arithmetic and atomic configuration with independent core models."""
import argparse, datetime, hashlib, json, os, random, shutil, subprocess, sys
from pathlib import Path
HERE=Path(__file__).resolve().parent
LIB=HERE.parents[1]; ROOT=LIB.parents[1]
sys.path.insert(0,str(LIB/'dsp/dc/models'))
from dc_reference import Config as DCConfig, FixedReference
sys.path.insert(0,str(LIB/'dsp/statistics/models'))
from reference import Config as StatsConfig, IntegerModel, pack

def main():
    parser=argparse.ArgumentParser()
    parser.add_argument('--dc-source',type=Path)
    parser.add_argument('--dc-latency',type=int,choices=(1,2))
    parser.add_argument('--statistics-source',type=Path)
    parser.add_argument('--stats-latency',type=int,choices=(1,5,17),default=17)
    args=parser.parse_args()
    latency=args.dc_latency or json.loads((LIB/'dsp/dc/ip_manifest.json').read_text())['latency_cycles']
    out=HERE/'evidence'/('sim_'+datetime.datetime.now().strftime('%Y%m%d_%H%M%S_%f'))
    out.mkdir(parents=True)
    tool=ROOT/'tools/oss-cad-suite/oss-cad-suite'
    env=os.environ.copy();env['PATH']=str(tool/'bin')+os.pathsep+str(tool/'lib')+os.pathsep+env['PATH']
    sources=[HERE/'dc_statistics_stream.v',(args.dc_source or LIB/'dsp/dc/rtl/dc_stream.sv').resolve(),(args.statistics_source or LIB/'dsp/statistics/rtl/statistics_stream.sv').resolve()]
    for p in sources+[Path(__file__),LIB/'dsp/dc/models/dc_reference.py',LIB/'dsp/statistics/models/reference.py']:
        shutil.copy2(p,out/p.name)
    (out/'hashes.json').write_text(json.dumps({str(p):hashlib.sha256(p.read_bytes()).hexdigest() for p in sources},indent=2))
    rng=random.Random(20260925); rows=[]; pending=source=None
    dc=FixedReference();stats=IntegerModel();slots=[None]*latency;stats_slots=[None]*args.stats_latency;done=error=0
    transfers=accepted=cfgcount=rejects=0; blocked_cfg=0;reset_occupied=0
    configs=[(mode,pole,lg,block,sl,scale,threshold)
             for mode,pole,lg,block,sl,scale,threshold in
             [(0,65024,4,0,4,0,0x10000000),(1,65024,8,0,6,0,0),
              (1,65024,3,1,3,-1,49),(2,65535,0,1,0,15,0xffffffff),
              (0,0,0,0,0,-8,0),(1,65024,0,0,1,0,0),
              (3,65024,4,0,2,0,0),(0,65024,9,0,2,0,0),
              (0,65024,4,0,7,0,0),(0,65024,4,0,2,-9,0)]]
    for cycle in range(34000):
        rst=int(cycle%17000 not in (0,1,16980))
        ready=int(cycle%500<200 or (cycle%500>320 and rng.random()<.75))
        if cycle%1600==7 and pending is None:pending=configs[(cycle//1600)%len(configs)]
        cv=int(pending is not None);mode,pole,lg,block,sl,scale,threshold=pending or configs[0]
        if source is None and (cycle%500<200 or rng.random()<.7):
            source=rng.choice([0,-32768,32767,-1,1,rng.randrange(-32768,32768)])
        sv=int(source is not None);sd=source or 0
        dv=slots[-1] is not None
        ov=stats_slots[-1] is not None;od,ou=stats_slots[-1] if ov else (0,0)
        cr=int(rst and all(value is None for value in slots+stats_slots))
        stats_stage_ready=[False]*args.stats_latency
        for i in reversed(range(args.stats_latency)):
            stats_stage_ready[i]=stats_slots[i] is None or (ready if i==args.stats_latency-1 else stats_stage_ready[i+1])
        stats_ready=int(rst and stats_stage_ready[0])
        stage_ready=[False]*latency
        for i in reversed(range(latency)):
            stage_ready[i]=slots[i] is None or (stats_ready if i==latency-1 else stage_ready[i+1])
        sr=int(rst and not cv and stage_ready[0])
        rows.append(f'{rst} {cv} {mode} {pole:x} {lg} {block} {sl} {scale&31:x} {threshold:x} {sv} {sd&65535:x} {ready} {sr} {cr} {int(ov)} {od:032x} {ou:x} {done} {error}')
        done=error=0
        if not rst:
            reset_occupied+=int(any(value is not None for value in slots+stats_slots))
            dc=FixedReference();stats=IntegerModel();slots=[None]*latency;stats_slots=[None]*args.stats_latency
            continue
        if cv and not cr:blocked_cfg+=1
        if ov and ready:transfers+=1
        new_stats=None
        if dv and stats_ready:
            new_stats=pack(stats.step(slots[-1]))
        if cv and cr:
            done=1;cfgcount+=1;pending=None
            if mode>2 or lg>8 or sl>6 or scale<-8:error=1;rejects+=1
            else:
                dc=FixedReference(DCConfig(('blocker','mean','baseline')[mode],pole,lg))
                stats=IntegerModel(StatsConfig(bool(block),sl,scale,threshold))
        new_value=None
        if sv and sr:
            new_value,_=dc.step(sd);source=None;accepted+=1
        previous=slots.copy()
        for i in range(latency):
            if stage_ready[i]:slots[i]=new_value if i==0 else previous[i-1]
        previous=stats_slots.copy()
        for i in range(args.stats_latency):
            if stats_stage_ready[i]:stats_slots[i]=new_stats if i==0 else previous[i-1]
    fixture='\n'.join(rows)+'\n';(out/'vectors.txt').write_text(fixture)
    tb=r'''module tb;
reg clk=0;always #5 clk=~clk;
reg rst_n=0,cv=0,sv=0,mr=0,cb=0;
reg [1:0] mode=0;reg [15:0] pole=0,sd=0;reg [3:0] dl=0,sl=0;
reg signed [4:0] scale=0;reg [31:0] th=0;
wire sr,cr,mv,cd,ce;wire [127:0] md;wire [1:0] mu;
dc_statistics_stream dut(clk,rst_n,sd,sv,sr,md,mu,mv,mr,cv,cr,mode,pole,dl,cb,sl,scale,th,cd,ce);
integer f,n,row,rr,cc,mm,ll,bb,ss,vv,ready,esr,ecr,ev,ed,ee;
reg [15:0] pp,data;reg [4:0] sc;reg [31:0] threshold;reg [127:0] expected;reg [1:0] user;
initial begin
f=$fopen("vectors.txt","r");row=0;@(posedge clk);#1;
while(!$feof(f))begin
 @(negedge clk);
 n=$fscanf(f,"%d %d %d %h %d %d %d %h %h %d %h %d %d %d %d %h %h %d %d\n",rr,cc,mm,pp,ll,bb,ss,sc,threshold,vv,data,ready,esr,ecr,ev,expected,user,ed,ee);
 if(n!=19)$fatal(1,"fixture");
 rst_n=rr;cv=cc;mode=mm;pole=pp;dl=ll;cb=bb;sl=ss;scale=sc;th=threshold;sv=vv;sd=data;mr=ready;#1;
 if({sr,cr,mv,cd,ce} !== {esr[0],ecr[0],ev[0],ed[0],ee[0]})$fatal(1,"control row=%0d got=%b expected=%b",row,{sr,cr,mv,cd,ce},{esr[0],ecr[0],ev[0],ed[0],ee[0]});
 if(mv && {md,mu} !== {expected,user})$fatal(1,"numeric row=%0d got=%h expected=%h",row,md,expected);
 @(posedge clk);#1;row=row+1;
end
$display("PASS rows=%0d",row);$finish;
end
endmodule
'''
    (out/'tb.sv').write_text(tb)
    def run(cmd,name,fail=False):
        p=subprocess.run(cmd,cwd=out,env=env,capture_output=True,text=True)
        (out/name).write_text(p.stdout+p.stderr)
        assert (p.returncode!=0)==fail,(name,p.stdout,p.stderr)
    run([str(tool/'bin/iverilog.exe'),'-g2012','-Wall','-s','tb','-o','test.vvp',*[p.name for p in sources],'tb.sv'],'compile.log')
    run([str(tool/'bin/vvp.exe'),'test.vvp'],'simulation.log')
    negatives=[]
    for field,label in [(15,'numeric'),(14,'valid_count'),(16,'flags'),(12,'ready'),(17,'config'),(18,'error')]:
        bad=rows.copy();index=next(i for i,r in enumerate(rows) if i>100 and r.split()[14]=='1')
        cells=bad[index].split();cells[field]=format(int(cells[field],16)^1,'x');bad[index]=' '.join(cells)
        (out/'vectors.txt').write_text('\n'.join(bad)+'\n')
        run([str(tool/'bin/vvp.exe'),'test.vvp'],'negative_'+label+'.log',True);negatives.append(label)
    (out/'vectors.txt').write_text(fixture)
    assert rejects>=4 and blocked_cfg>0 and reset_occupied>0
    summary=dict(status='PASS',dc_latency=latency,stats_latency=args.stats_latency,sliding_latency=latency+args.stats_latency,cycles=len(rows),accepted=accepted,output_transfers=transfers,configs=cfgcount,invalid_configs=rejects,blocked_config_cycles=blocked_cfg,reset_with_occupied_slots=reset_occupied,mutations=negatives,scope='isolated composed RTL; P&R/physical qualification pending')
    (out/'summary.json').write_text(json.dumps(summary,indent=2));print(out);print(json.dumps(summary,indent=2))

if __name__=='__main__':main()
