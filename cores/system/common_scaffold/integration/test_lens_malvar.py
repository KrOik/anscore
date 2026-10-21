"""Real RAW mesh correction wired directly into full-frame MHC demosaicing."""
import hashlib
import tempfile
import numpy as np
from tooling import PACKAGE, ROOT, evidence_dir, execute, write_json

def lens_oracle(frame, mesh, pattern):
    height,width=frame.shape
    _,gh,gw=mesh.shape
    dy,dx=max(height-1,1),max(width-1,1)
    result=np.zeros_like(frame)
    saturated=[]
    for y in range(height):
        yy=y*(gh-1);iy=min(gh-2,yy//dy);ry=yy-iy*dy
        for x in range(width):
            xx=x*(gw-1);ix=min(gw-2,xx//dx);rx=xx-ix*dx
            rr=(y&1)^((pattern>>1)&1);cc=(x&1)^(pattern&1)
            channel=0 if (rr,cc)==(0,0) else 3 if (rr,cc)==(1,1) else 1 if rr==0 else 2
            weight=int(mesh[channel,iy,ix])*(dx-rx)*(dy-ry)+int(mesh[channel,iy,ix+1])*rx*(dy-ry)+int(mesh[channel,iy+1,ix])*(dx-rx)*ry+int(mesh[channel,iy+1,ix+1])*rx*ry
            denominator=dx*dy*4096
            value=(int(frame[y,x])*weight+denominator//2)//denominator
            saturated.append(int(value>4095));result[y,x]=min(value,4095)
    return result,saturated

def malvar_oracle(raw, pattern):
    # Standard MHC kernels expressed as exact integer numerators over 16.
    green=np.array([[0,0,-2,0,0],[0,0,4,0,0],[-2,4,8,4,-2],[0,0,4,0,0],[0,0,-2,0,0]])
    horizontal=np.array([[0,0,1,0,0],[0,-2,0,-2,0],[-2,8,10,8,-2],[0,-2,0,-2,0],[0,0,1,0,0]])
    cross=np.array([[0,0,-3,0,0],[0,4,0,4,0],[-3,0,12,0,-3],[0,4,0,4,0],[0,0,-3,0,0]])
    height,width=raw.shape
    def reflect(value,size):
        if size==1:return 0
        while value<0 or value>=size:value=-value if value<0 else 2*size-2-value
        return value
    pixels=[]
    for y in range(height):
        for x in range(width):
            window=np.array([[raw[reflect(y+j-2,height),reflect(x+i-2,width)] for i in range(5)] for j in range(5)])
            def filtered(kernel):return max(0,min(4095,(int(np.sum(window*kernel))+8)//16))
            rr=(y&1)^((pattern>>1)&1);cc=(x&1)^(pattern&1)
            if rr==0 and cc==0:rgb=(int(raw[y,x]),filtered(green),filtered(cross))
            elif rr==1 and cc==1:rgb=(filtered(cross),filtered(green),int(raw[y,x]))
            elif rr==0:rgb=(filtered(horizontal),int(raw[y,x]),filtered(horizontal.T))
            else:rgb=(filtered(horizontal.T),int(raw[y,x]),filtered(horizontal))
            pixels.append((rgb[0]<<24)|(rgb[1]<<12)|rgb[2])
    return pixels

TB=r'''module tb;
localparam W=@W@,H=@H@,N=W*H,F=6,GW=3,GH=3;
reg clk=0;always #5 clk=~clk;
reg rst_n=0,ce=1,cv=0,commit=0,start=0,sv=0,sof=0,eol=0,last=0,ack=0,mr=0;
reg[15:0]ci,cgain;reg[1:0]pattern;reg[11:0]raw;
wire cr,ccr,cerror,pending,lsr,sr,lv,lr,lsof,leol,llast,lsat,ldone,lerror;
wire[11:0]corrected;wire[2:0]lcode;
lens_shading #(.WIDTH(W),.HEIGHT(H),.BITS(12),.GRID_WIDTH(GW),.GRID_HEIGHT(GH)) lens(
.clk(clk),.rst_n(rst_n),.ce(ce),.cfg_valid(cv),.cfg_ready(cr),.cfg_index(ci),.cfg_gain(cgain),
.cfg_commit_valid(commit),.cfg_commit_ready(ccr),.cfg_error(cerror),.cfg_pending(pending),
.start_valid(start),.start_ready(lsr),.cfg_pattern(pattern),.s_data(raw),.s_valid(sv),.s_ready(sr),.s_sof(sof),.s_eol(eol),.s_last(last),
.m_data(corrected),.m_saturated(lsat),.m_valid(lv),.m_ready(lr),.m_sof(lsof),.m_eol(leol),.m_last(llast),
.done_valid(ldone),.done_ready(ack),.done_error(lerror),.error_code(lcode));
wire dsr,mv,ms,me,ml,ddone,derror,busy;wire[7:0]dcode;wire[35:0]rgb;
malvar_demosaic #(.WIDTH(W),.HEIGHT(H),.BITS(12)) demosaic(
.clk(clk),.rst_n(rst_n),.ce(ce),.start_valid(start),.start_ready(dsr),.cfg_pattern(pattern),.abort(1'b0),
.s_data(corrected),.s_valid(lv),.s_ready(lr),.s_sof(lsof),.s_eol(leol),.s_last(llast),
.m_data(rgb),.m_valid(mv),.m_ready(mr),.m_sof(ms),.m_eol(me),.m_last(ml),
.done_valid(ddone),.done_ready(ack),.done_error(derror),.error_code(dcode),.busy(busy));
reg[11:0]pixels[0:F*N-1];reg[15:0]meshes[0:F*36-1];reg[12:0]mid[0:F*N-1];reg[35:0]expected[0:F*N-1];
reg[1:0]patterns[0:F-1];integer i,f,got=0,paired=0,cycle=0;reg take,held=0,midheld=0;reg[38:0]token;reg[15:0]midtoken;reg[31:0]rng=34189;
always @(posedge clk)begin
cycle=cycle+1;if(cycle>2000000)$fatal(1,"timeout");
if(rst_n)begin
if(held&&(!mv||{rgb,ms,me,ml}!==token))$fatal(1,"RGB hold");held=mv&&!(ce&&mr);token={rgb,ms,me,ml};
if(midheld&&(!lv||{corrected,lsat,lsof,leol,llast}!==midtoken))$fatal(1,"corrected RAW hold");midheld=lv&&!(ce&&lr);midtoken={corrected,lsat,lsof,leol,llast};
if(ce&&lv&&lr)begin
if({lsat,corrected}!==mid[paired]||lsof!==(paired%N==0)||leol!==(paired%W==W-1)||llast!==(paired%N==N-1))$fatal(1,"corrected RAW %d",paired);paired=paired+1;end
if(ce&&mv&&mr)begin
if(rgb!==expected[got]||ms!==(got%N==0)||me!==(got%W==W-1)||ml!==(got%N==N-1))$fatal(1,"RGB %d got%h expected%h",got,rgb,expected[got]);got=got+1;end
end end
task tick;begin @(negedge clk);#1;rng=rng^(rng<<13);rng=rng^(rng>>17);rng=rng^(rng<<5);ce=rng[0]|rng[2];mr=rng[1]|rng[4];end endtask
initial begin
$readmemh("pixels.mem",pixels);$readmemh("meshes.mem",meshes);$readmemh("mid.mem",mid);$readmemh("expected.mem",expected);$readmemh("patterns.mem",patterns);
repeat(3)@(negedge clk);#1;rst_n=1;
for(f=0;f<F;f=f+1)begin
ce=1;for(i=0;i<36;i=i+1)begin cv=1;ci=i;cgain=meshes[f*36+i];#1;if(!cr)$fatal(1,"mesh load not ready");@(negedge clk);#1;end
cv=0;commit=1;#1;if(!ccr)$fatal(1,"commit not ready");@(negedge clk);#1;commit=0;
while(pending)begin @(negedge clk);#1;end
pattern=patterns[f];#1;if(cerror||!lsr||!dsr)$fatal(1,"start not ready");start=1;@(negedge clk);#1;start=0;
i=0;while(i<N)begin sv=1;raw=pixels[f*N+i];sof=i==0;eol=i%W==W-1;last=i==N-1;@(posedge clk);take=ce&&sr;if(take)i=i+1;tick;end sv=0;
while(!ldone||!ddone)tick;
if(got!=(f+1)*N||paired!=(f+1)*N||lerror||derror||lcode||dcode)$fatal(1,"completion");
ce=0;ack=1;repeat(3)@(negedge clk);#1;if(!ldone||!ddone)$fatal(1,"CE done hold");ce=1;@(negedge clk);#1;ack=0;
end
$display("PASS LENS_MALVAR frames=%d RGBpixels=%d",F,got);$finish;
end endmodule'''

def run(width,height):
    folder=evidence_dir('lens_malvar')
    rng=np.random.default_rng(width*31+height)
    frames=[];meshes=[];corrected=[];expected=[];patterns=[0,1,2,3,0,3];satcounts=[]
    for f,pattern in enumerate(patterns):
        frame=rng.integers(0,4096,(height,width),dtype=np.int64)
        if f==4:frame[:]=1377
        mesh=np.full((4,3,3),4096,dtype=np.int64) if f==4 else rng.integers(1024,24000,(4,3,3),dtype=np.int64)
        mapped,sat=lens_oracle(frame,mesh,pattern)
        frames.extend(frame.ravel());meshes.extend(mesh.ravel());corrected.extend((s<<12)|int(v) for v,s in zip(mapped.ravel(),sat))
        expected.extend(malvar_oracle(mapped,pattern));satcounts.append(sum(sat))
    with tempfile.TemporaryDirectory(prefix='lens_malvar_') as tmp:
        p=__import__('pathlib').Path(tmp)
        for name,values in [('pixels',frames),('meshes',meshes),('mid',corrected),('expected',expected),('patterns',patterns)]:
            (p/(name+'.mem')).write_text('\n'.join(f'{int(v):x}' for v in values))
        tb=TB.replace('@W@',str(width)).replace('@H@',str(height));(p/'tb.sv').write_text(tb)
        sources=[PACKAGE/'image/lens_shading/lens_shading.sv',PACKAGE/'image/malvar_demosaic/malvar_demosaic.sv']
        execute(['iverilog','-g2012','-s','tb','-o',p/'sim',*sources,p/'tb.sv'],ROOT,folder/'compile.log')
        execute(['vvp',p/'sim'],p,folder/'simulation.log',timeout=180)
    write_json(folder/'results.json',dict(status='PASS',width=width,height=height,frames=6,pixels=6*width*height,saturated_per_frame=satcounts,board_tested=False,
        sources={str(s.relative_to(ROOT)):hashlib.sha256(s.read_bytes()).hexdigest() for s in sources}))
    print(folder,flush=True)

if __name__=='__main__':
    for size in ((9,7),(1,5),(7,1)):run(*size)
