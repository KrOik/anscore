"""Independent rational statistics + exact integer correction, no RTL model reuse."""
from pathlib import Path
from fractions import Fraction
import hashlib,json,random,re,sys,tempfile
HERE=Path(__file__).resolve().parent
sys.path.insert(0,str(HERE.parents[1]/'integration'))
from tooling import execute
RTL=HERE/'raw_black_level.sv'
PATTERNS=['RGGB','GRBG','GBRG','BGGR']
def hashes():return {RTL.name:hashlib.sha256(RTL.read_bytes()).hexdigest()}
def pack(values,bits):return sum(v<<(i*bits) for i,v in enumerate(values))
def oracle(pixels,w,h,bits,pat,auto,black,target,roi):
    # Derive plane identity from textual 2x2 CFA, distinguishing row-green.
    tile={'RGGB':(0,1,2,3),'GRBG':(1,0,3,2),'GBRG':(2,3,0,1),'BGGR':(3,2,1,0)}[PATTERNS[pat]]
    plane=lambda x,y:tile[(y%2)*2+x%2]
    sums=[0]*4;counts=[0]*4;means=[0]*4
    rx,ry,rw,rh=roi
    if auto and (rw<=0 or rh<=0 or rx+rw>w or ry+rh>h):return dict(error=0x82)
    if auto:
        for y in range(ry,ry+rh):
            for x in range(rx,rx+rw):
                p=plane(x,y);sums[p]+=pixels[y*w+x];counts[p]+=1
        if min(counts)==0:return dict(error=0x83)
        for p in range(4):
            mean=Fraction(sums[p],counts[p]);means[p]=(mean+Fraction(1,2)).numerator//(mean+Fraction(1,2)).denominator
        black=means
    corrected=[pixels[y*w+x]-black[plane(x,y)]+target for y in range(h) for x in range(w)]
    peak=(1<<bits)-1
    return dict(error=0,output=[min(peak,max(0,v)) for v in corrected],sums=sums,counts=counts,means=means,black=black,
                clip_low=sum(v<0 for v in corrected),clip_high=sum(v>peak for v in corrected))
TB=r'''module tb;
reg clk=0;always #5 clk=~clk;reg rst_n=0,ce=1,start_valid=0,cfg_auto=AA,abort=0;
reg[1:0]cfg_pattern=PP;reg[4*BB-1:0]cfg_black_levels=BLACK;reg[BB-1:0]cfg_target_pedestal=TARGET;
reg[15:0]cfg_roi_x=RX,cfg_roi_y=RY,cfg_roi_width=RW,cfg_roi_height=RH;
reg[BB-1:0]s_data=0;reg s_valid=0,s_sof=0,s_eol=0,s_last=0,m_ready=0,done_ready=0;
wire start_ready,s_ready,m_valid,m_sof,m_eol,m_last,done_valid,done_error,busy;wire[BB-1:0]m_data;
wire[7:0]error_code;wire[127:0]stats_sums,stats_counts;wire[4*BB-1:0]stats_mean_levels,applied_black_levels;wire[31:0]clip_low_count,clip_high_count;
raw_black_level #(.WIDTH(WW),.HEIGHT(HH),.BITS(BB))dut(.*);
reg[BB-1:0]pixels[0:NN-1],expected[0:NN-1];integer cyc=0,i,rep,got=0;reg stalled=0;reg[BB+2:0]held;
wire[BB+2:0]token={m_last,m_eol,m_sof,m_data};
task tick;begin @(negedge clk);#1;end endtask
always @(negedge clk)begin cyc=cyc+1;ce=cyc%13>1;m_ready=cyc%9<4;if(cyc>2000000)$fatal(1,"timeout state %d",dut.state);end
always @(posedge clk)if(rst_n)begin
if(stalled&&(!m_valid||token!==held))$fatal(1,"stability");stalled=m_valid&&!(ce&&m_ready);held=token;
if(ce&&m_valid&&m_ready)begin
 if(ERR!=0||got>=2*NN||m_data!==expected[got%NN])$fatal(1,"pixel %d %h != %h",got,m_data,expected[got%NN]);
 if(m_sof!==(got%NN==0)||m_eol!==((got%NN)%WW==WW-1)||m_last!==(got%NN==NN-1))$fatal(1,"markers");got=got+1;
end end
initial begin $readmemh("PIXFILE",pixels);$readmemh("EXPFILE",expected);repeat(3)tick;rst_n=1;tick;
for(rep=0;rep<2;rep=rep+1)begin
cfg_pattern=PP;cfg_auto=AA;cfg_black_levels=BLACK;cfg_target_pedestal=TARGET;cfg_roi_x=RX;cfg_roi_y=RY;cfg_roi_width=RW;cfg_roi_height=RH;
start_valid=1;while(!start_ready)tick;@(posedge clk);#1;tick;start_valid=0;
cfg_pattern=(PP+1)%4;cfg_auto=!AA;cfg_black_levels=0;cfg_target_pedestal=0;cfg_roi_x=65535;cfg_roi_width=0;cfg_roi_y=65535;cfg_roi_height=0;
if(ERR!=130)begin
for(i=0;i<NN;i=i+1)begin s_data=pixels[i];s_valid=1;s_sof=i==0;s_eol=i%WW==WW-1;s_last=i==NN-1;while(!s_ready)tick;@(posedge clk);#1;tick;end
end
s_valid=0;while(!done_valid)tick;
if(done_error!==(ERR!=0)||error_code!==ERR)$fatal(1,"done error %h expected %h",error_code,ERR);
if(ERR==0)begin
if(got!=(rep+1)*NN||stats_sums!==SUMS||stats_counts!==COUNTS||stats_mean_levels!==MEANS||applied_black_levels!==APPLIED||clip_low_count!==LOW||clip_high_count!==HIGH)
$fatal(1,"stats sums %h counts %h means %h applied %h clips %d %d",stats_sums,stats_counts,stats_mean_levels,applied_black_levels,clip_low_count,clip_high_count);
end
repeat(9)tick;if(!done_valid||error_code!==ERR)$fatal(1,"done unstable");
done_ready=1;while(!ce)tick;@(posedge clk);#1;tick;done_ready=0;
end
$display("PASS raw_black_level");$finish;end endmodule
'''
def run_case(name,w,h,bits,pat,auto,black,target,roi,pixels):
    answer=oracle(pixels,w,h,bits,pat,auto,black,target,roi)
    with tempfile.TemporaryDirectory(prefix='raw_blc_') as tmp:
        d=Path(tmp);(d/'pix.hex').write_text('\n'.join(f'{v:x}' for v in pixels)+'\n');(d/'exp.hex').write_text('\n'.join(f'{v:x}' for v in answer.get('output',[0]*(w*h)))+'\n')
        replace={'PIXFILE':(d/'pix.hex').as_posix(),'EXPFILE':(d/'exp.hex').as_posix(),'BB':bits,'WW':w,'HH':h,'NN':w*h,'PP':pat,'AA':int(auto),
                 'BLACK':f"{4*bits}'h{pack(black,bits):x}",'TARGET':target,'RX':roi[0],'RY':roi[1],'RW':roi[2],'RH':roi[3],'ERR':f"8'h{answer['error']:02x}",
                 'SUMS':f"128'h{pack(answer.get('sums',[0]*4),32):x}",'COUNTS':f"128'h{pack(answer.get('counts',[0]*4),32):x}",
                 'MEANS':f"{4*bits}'h{pack(answer.get('means',[0]*4),bits):x}",'APPLIED':f"{4*bits}'h{pack(answer.get('black',[0]*4),bits):x}",
                 'LOW':answer.get('clip_low',0),'HIGH':answer.get('clip_high',0)}
        tb=re.sub(r'\b('+'|'.join(replace)+r')\b',lambda m:str(replace[m[0]]),TB);(d/'tb.sv').write_text(tb)
        execute(['iverilog','-g2012','-s','tb','-o',d/'a.vvp',RTL,d/'tb.sv'],HERE,d/'compile.log')
        text=execute(['vvp',d/'a.vvp'],HERE,d/'sim.log',timeout=180);assert 'PASS raw_black_level' in text
    return dict(name=name,geometry=[w,h],bits=bits,pattern=PATTERNS[pat],auto=auto,expected_error=answer['error'],pixels=2*w*h if not answer['error'] else 0,
                statistics={k:v for k,v in answer.items() if k!='output'} if not answer['error'] else None)
def main():
    frozen=hashes();rng=random.Random(972);rows=[]
    def run(*args):
        row=run_case(*args);rows.append(row);print({k:v for k,v in row.items() if k!='statistics'},flush=True)
    for bits in [8,10,12]:
        peak=(1<<bits)-1
        for pat in range(4):
            for mode in [False,True]:
                run('random_roi',9,7,bits,pat,mode,[peak//8,peak//6,peak//4,peak//3],peak//10,(1,1,5,3),[rng.randrange(peak+1) for _ in range(63)])
            run('max_auto',8,6,bits,pat,True,[0]*4,peak,(0,0,8,6),[peak]*48)
            run('clip_both',4,4,bits,pat,False,[peak,0,peak,0],peak//2,(65535,65535,0,0),[0,peak]*8)
            run('half_up',4,4,bits,pat,True,[0]*4,7,(0,0,4,4),[0]*8+[1]*8)
    for w,h in [(1,1),(1,7),(7,1),(2,2),(2,9),(9,2),(32,24)]:
        for pat in range(4):
            pix=[rng.randrange(256) for _ in range(w*h)]
            run('thin_manual',w,h,8,pat,False,[7,19,31,43],13,(0,0,0,0),pix)
            run('thin_auto',w,h,8,pat,True,[0]*4,0,(0,0,w,h),pix)
    for roi in [(0,0,0,2),(0,0,2,0),(3,0,2,2),(0,3,2,2),(65535,0,2,2),(0,65535,2,2),(1,1,1,1),(1,0,1,4),(0,1,4,1)]:
        run('bad_roi',4,4,8,3,True,[0]*4,0,roi,list(range(16)))
    run('maximum_geometry_accumulator',256,256,12,0,True,[0]*4,4095,(0,0,256,256),[4095]*65536)
    assert hashes()==frozen
    (HERE/'evidence.json').write_text(json.dumps(dict(status='PASS',sources=frozen,cases=rows),indent=2)+'\n')
if __name__=='__main__':main()
