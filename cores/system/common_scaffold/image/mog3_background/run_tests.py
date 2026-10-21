"""Independent integer MOG3 state oracle, floating variant, actual RTL transactions."""
from pathlib import Path
import random,json,tempfile,sys,hashlib,math
sys.dont_write_bytecode=True
HERE=Path(__file__).resolve().parent
sys.path.insert(0,str(HERE.parents[1]))
from integration.tooling import execute

def rounded(v,shift):return (-1 if v<0 else 1)*((abs(v)+(1<<(shift-1)))>>shift)
def sort_models(models):
    # Stable three-comparison network; compare scores by exact integer products.
    for a,b in ((0,1),(1,2),(0,1)):
        if models[a][0]**2*models[b][2] < models[b][0]**2*models[a][2]:models[a],models[b]=models[b],models[a]
    return models

def update(models,pixel,cfg):
    shift,sigma,threshold,initial,minimum,reset=cfg
    if models is None:return [[256,pixel<<8,initial],[0,pixel<<8,initial],[0,pixel<<8,initial]],0,pixel,0
    m=sort_models([[w,mu,max(minimum,var)] for w,mu,var in models])
    prefix=0;cum=m[0][0]
    while cum<threshold and prefix<2:prefix+=1;cum+=m[prefix][0]
    match=next((i for i,(w,mu,var) in enumerate(m) if w and ((pixel<<8)-mu)**2<=sigma*var*65536),3)
    fg=int(match==3 or match>prefix);bg=(m[0][1]+128)>>8
    distances=[(((pixel<<8)-mu)**2+32768)>>16 for w,mu,var in m]
    for i,row in enumerate(m):row[0]=max(0,min(256,row[0]+rounded((256 if match==i else 0)-row[0],shift)))
    if match==3:m[2]=[rounded(256,shift),pixel<<8,initial]
    else:
        m[match][1]=max(0,min(65280,m[match][1]+rounded((pixel<<8)-m[match][1],shift)))
        m[match][2]=max(minimum,min(65025,m[match][2]+rounded(distances[match]-m[match][2],shift)))
    total=sum(row[0] for row in m);largest=max(range(3),key=lambda i:m[i][0])
    weights=[row[0]*256//total for row in m];weights[largest]+=256-sum(weights)
    for row,w in zip(m,weights):row[0]=w
    m=sort_models(m)
    assert sum(row[0] for row in m)==256
    return m,fg,bg,match

def float_update(models,pixel,cfg):
    shift,sigma,threshold,initial,minimum,reset=cfg;alpha=2.0**(-shift)
    if models is None:return [[1.,float(pixel),float(initial)],[0.,float(pixel),float(initial)],[0.,float(pixel),float(initial)]],0,float(pixel)
    m=sorted([[w,mu,max(float(minimum),v)] for w,mu,v in models],key=lambda r:r[0]**2/r[2],reverse=True)
    prefix=0;cum=m[0][0]
    while cum<threshold/256 and prefix<2:prefix+=1;cum+=m[prefix][0]
    match=next((i for i,(w,mu,var) in enumerate(m) if w>0 and (pixel-mu)**2<=sigma*var),3)
    fg=int(match==3 or match>prefix);bg=m[0][1]
    distances=[(pixel-row[1])**2 for row in m]
    for i,row in enumerate(m):row[0]=(1-alpha)*row[0]+(alpha if i==match else 0)
    if match==3:m[2]=[alpha,float(pixel),float(initial)]
    else:
        m[match][1]+=alpha*(pixel-m[match][1]);m[match][2]=max(float(minimum),min(65025.,m[match][2]+alpha*(distances[match]-m[match][2])))
    total=sum(row[0] for row in m)
    for row in m:row[0]/=total
    return sorted(m,key=lambda r:r[0]**2/r[2],reverse=True),fg,bg

def pack_model(models):return sum((w|(mu<<9)|(var<<25))<<(41*i) for i,(w,mu,var) in enumerate(models))

def profile(w,h,frames=64):
    n=w*h;rng=random.Random(91217+w*31+h);integer=[None]*n;floating=[None]*n
    inputs=[];expected=[];states=[];body='';differences=[];fg_disagreements=0;active_three=0
    for f in range(frames):
        cfg=(4,9,180,64,4,int(f in (0,47)))
        if f>=56:cfg=(1+(f-56),1+(f-56)*3,1+(f-56)*36,100,1,int(f==56))
        if cfg[-1]:integer=[None]*n;floating=[None]*n
        shift,sigma,threshold,initial,minimum,reset=cfg
        body+=f"ls=4'd{shift};sigma=5'd{sigma};threshold=9'd{threshold};initial_var=16'd{initial};min_var=16'd{minimum};clear_models=1'b{reset};begin_frame;\n"
        for y in range(h):
            for x in range(w):
                i=y*w+x;base=45+(x*3+y*2)%9
                if 8<=f<32:base=base if f%2==0 else 155+(x+y)%7
                if 20<=f<40 and (x+f)%max(2,w)<max(1,w//3):base=225
                if 32<=f<47:base=min(250,base+(f-32)*5)
                p=max(0,min(255,base+rng.randint(-2,2)))
                if f==55:p=(x*71+y*37)%256
                models,fg,bg,match=update(integer[i],p,cfg);integer[i]=models
                floating[i],ffg,fbg=float_update(floating[i],p,cfg)
                differences.append(abs(bg-fbg));fg_disagreements+=fg!=ffg;active_three+=all(r[0]>0 for r in models)
                inputs.append(p);states.append(pack_model(models))
                expected.append(fg|(bg<<1)|(match<<9)|(int(i==0)<<11)|(int(x==w-1)<<12)|(int(i==n-1)<<13))
                wrong_sof=int(f==7 and i==0);wrong_eol=int(f==8 and i==0)
                body+=f"send(8'd{p},1'b{int(i==0)^wrong_sof},1'b{int(x==w-1)^wrong_eol});check(14'h{expected[-1]:04x},123'h{states[-1]:031x});\n"
        body+=f"finish_frame(1'b{int(f in (7,8))});\n"
        if f in (7,8):integer=[None]*n;floating=[None]*n
        if f in (5,10,25):
            body+='saved_shift=ls;ls=0;clear_models=1;begin_frame;finish_invalid;ls=saved_shift;clear_models=0;\n'
    # Reset at disabled CE during capture, serial arithmetic and held output.
    body+='begin_frame;repeat(3)tick;reset_now;begin_frame;send(99,1,0);repeat(5)tick;reset_now;begin_frame;send(88,1,0);while(!mv)tick;reset_now;\n'
    body+='begin_frame;\n'
    cold_model=pack_model([[256,121<<8,100],[0,121<<8,100],[0,121<<8,100]])
    # Explicit parameters here also cover the short maximum-capacity profile.
    body=body.rsplit('begin_frame;\n',1)[0]+'ls=4;sigma=9;threshold=180;initial_var=100;min_var=1;clear_models=0;begin_frame;\n'
    for y in range(h):
        for x in range(w):
            i=y*w+x;word=(121<<1)|(int(i==0)<<11)|(int(x==w-1)<<12)|(int(i==n-1)<<13)
            body+=f"send(121,1'b{int(i==0)},1'b{int(x==w-1)});check(14'h{word:04x},123'h{cold_model:031x});\n"
    body+='finish_frame(0);\n'
    for override in ['ls=0','ls=9','sigma=0','sigma=26','threshold=0','threshold=257','initial_var=0','initial_var=65026','min_var=0','min_var=101','min_var=65026']:
        body+='ls=4;sigma=9;threshold=180;initial_var=100;min_var=1;clear_models=1;'+override+';begin_frame;finish_invalid;\n'
    tb=TB.replace('@BODY@',body).replace('@W@',str(w)).replace('@H@',str(h))
    with tempfile.TemporaryDirectory(prefix='mog3_') as temporary:
        td=Path(temporary);(td/'tb.sv').write_text(tb,encoding='utf-8')
        execute(['iverilog','-g2012','-s','tb','-o',td/'sim',HERE/'mog3_background_frame.sv',td/'tb.sv'],td,td/'compile.log')
        output=execute(['vvp',td/'sim'],td,td/'simulation.log',timeout=180)
        assert 'MOG3 PASS' in output,output
    if frames>=32:assert active_three>0
    assert fg_disagreements/(frames*n)<=0.01, 'Floating FG comparison exceeds one percent on these fixtures'
    assert max(differences)<=4.0 and sum(differences)/len(differences)<=1.0, 'Floating background comparison exceeds fixture tolerance'
    result=dict(width=w,height=h,frames=frames,pixels=frames*n,recovery_pixels=n,three_active_model_outputs=active_three,float_foreground_disagreements=fg_disagreements,float_foreground_disagreement_fraction=fg_disagreements/(frames*n),float_background_max_abs= max(differences),float_background_mean_abs=sum(differences)/len(differences),invalid_configuration_cases=11+sum(f in (5,10,25) for f in range(frames)),status='PASS')
    print(result,flush=True);return result

TB=r"""
module tb;
localparam W=@W@,H=@H@,N=W*H;
reg clk=0;always #5 clk=~clk;
reg rst_n=0,ce=1,start=0,clear_models=0,sv=0,sof=0,eol=0,mr=0,dr=0;
reg [3:0] ls=4,saved_shift;reg [4:0] sigma=9;reg [8:0] threshold=180;reg [15:0] initial_var=64,min_var=4;reg [7:0] pixel=0;
wire str,sr,mv,ms,me,ml,dv,de,busy,fg;wire [7:0] bg;wire [1:0] match;wire [3:0] error;
mog3_background_frame #(.WIDTH(W),.HEIGHT(H)) dut(.clk(clk),.rst_n(rst_n),.ce(ce),.start_valid(start),.start_ready(str),.cfg_learning_shift(ls),.cfg_match_sigma2(sigma),.cfg_background_threshold(threshold),.cfg_initial_variance(initial_var),.cfg_min_variance(min_var),.cfg_reset_models(clear_models),.s_gray(pixel),.s_valid(sv),.s_sof(sof),.s_eol(eol),.s_ready(sr),.m_foreground(fg),.m_background(bg),.m_match(match),.m_valid(mv),.m_ready(mr),.m_sof(ms),.m_eol(me),.m_last(ml),.done_valid(dv),.done_ready(dr),.done_error(de),.error_code(error),.busy(busy));
reg [31:0] rng=32'h925ea31d;reg random_enable=1;integer cycles=0;
always @(negedge clk)if(rst_n&&random_enable)begin rng={rng[30:0],rng[31]^rng[21]^rng[1]^rng[0]};ce=rng[2:0]!=0;end
always @(posedge clk)begin cycles=cycles+1;if(cycles>10000000)$fatal(1,"global timeout");end
task tick;begin @(posedge clk);#1;@(negedge clk);#1;end endtask
task begin_frame;begin while(!str)tick;start=1;tick;start=0;end endtask
task send(input [7:0] p,input fs,le);begin repeat(rng[4:3])tick;while(!sr)tick;pixel=p;sof=fs;eol=le;sv=1;tick;sv=0;end endtask
task check(input [13:0] expected,input [122:0] model);reg [13:0] held;begin
 while(!mv)tick;
 if({ml,me,ms,match,bg,fg}!==expected||dut.model_mem[dut.pixel_index]!==model)begin $display("pixel=%d got=%h expected=%h model=%h expectedmodel=%h",dut.pixel_index,{ml,me,ms,match,bg,fg},expected,dut.model_mem[dut.pixel_index],model);$fatal(1,"integer oracle/state");end
 if(dut.weight[0]+dut.weight[1]+dut.weight[2]!=256)$fatal(1,"normalization");
 held={ml,me,ms,match,bg,fg};repeat(3)begin tick;if(!mv||{ml,me,ms,match,bg,fg}!==held)$fatal(1,"backpressure");end
 random_enable=0;ce=0;mr=1;repeat(2)begin tick;if(!mv||{ml,me,ms,match,bg,fg}!==held||sr||str)$fatal(1,"CE freeze");end
 ce=1;tick;mr=0;random_enable=1;
end endtask
task finish_frame(input failed);begin
 if(!dv||de!==failed||error!==(failed?4'd2:4'd0))$fatal(1,"frame terminal");
 start=1;sv=1;repeat(3)begin tick;if(!dv||str||sr||mv||de!==failed)$fatal(1,"done hold");end start=0;sv=0;
 while(!ce)tick;dr=1;tick;dr=0;
end endtask
task finish_invalid;begin
 if(!dv||!de||error!=1||mv)$fatal(1,"invalid cfg");while(!ce)tick;dr=1;tick;dr=0;
end endtask
task reset_now;begin
 random_enable=0;ce=0;rst_n=0;tick;if(mv||dv||str||sr||de||error||busy)$fatal(1,"reset");rst_n=1;clear_models=0;ce=1;tick;random_enable=1;
end endtask
initial begin
 @(negedge clk);tick;rst_n=1;tick;
 @BODY@
 $display("MOG3 PASS");$finish;
end
endmodule
"""

def boundary_profile():
    scenarios=[
        (100,(8,1,256,100,1,1)),(110,(8,1,256,100,1,0)),
        (111,(8,1,256,100,1,0)),(111,(8,1,255,100,1,0)),(111,(8,1,256,100,1,0)),
        (0,(8,25,256,65025,65025,1)),(255,(8,25,256,65025,65025,0)),
        (0,(1,25,256,65025,65025,0)),
        (100,(8,25,256,4,1,1)),(110,(8,25,256,4,1,0)),(111,(8,25,256,4,1,0))]
    models=None;body='';decisions=[]
    for pixel,cfg in scenarios:
        shift,sigma,threshold,initial,minimum,reset=cfg
        if reset:models=None
        models,fg,bg,match=update(models,pixel,cfg);decisions.append([fg,match])
        word=fg|(bg<<1)|(match<<9)|(1<<11)|(1<<12)|(1<<13)
        body+=f"ls={shift};sigma={sigma};threshold={threshold};initial_var={initial};min_var={minimum};clear_models={reset};begin_frame;send({pixel},1,1);check(14'h{word:04x},123'h{pack_model(models):031x});finish_frame(0);\n"
    assert decisions[:5]==[[0,0],[0,0],[1,3],[1,1],[0,1]],decisions
    assert decisions[8:]==[[0,0],[0,0],[1,3]],decisions
    with tempfile.TemporaryDirectory(prefix='mog3_boundary_') as temporary:
        td=Path(temporary);(td/'tb.sv').write_text(TB.replace('@W@','1').replace('@H@','1').replace('@BODY@',body),encoding='utf-8')
        execute(['iverilog','-g2012','-s','tb','-o',td/'sim',HERE/'mog3_background_frame.sv',td/'tb.sv'],td,td/'compile.log')
        output=execute(['vvp',td/'sim'],td,td/'simulation.log',timeout=120)
        assert 'MOG3 PASS' in output,output
    result=dict(status='PASS',frames=len(scenarios),pixels=len(scenarios),decisions=decisions,coverage=['distance equality sigma1 variance100','next integer input beyond equality','background prefix threshold256 versus255','maximum variance65025 sigma25 threshold256','distance equality sigma25 variance4'])
    print(result,flush=True);return result

def main():
    results=[profile(w,h) for w,h in [(1,1),(1,7),(7,5)]]+[profile(32,32,3)]
    (HERE/'test_evidence.json').write_text(json.dumps(dict(status='PASS',profiles=results,boundary_profile=boundary_profile(),float_fixture_assertions={'foreground_disagreement_max_fraction':0.01,'background_max_abs_limit':4.0,'background_mean_abs_limit':1.0},rtl_sha256=hashlib.sha256((HERE/'mog3_background_frame.sv').read_bytes()).hexdigest(),note='Exact complete model words and stream outputs checked. Floating same-algorithm variant is a numerical comparison, not bit-exact MOG2 validation.'),indent=2)+'\n',encoding='utf-8')
if __name__=='__main__':main()
