"""Independent fixed-point RGB radial correction oracle and real OpenCV comparison."""
from pathlib import Path
import sys,tempfile,random,json,hashlib
sys.dont_write_bytecode=True
HERE=Path(__file__).resolve().parent
sys.path.insert(0,str(HERE.parents[1]))
from integration.tooling import execute
import cv2,numpy as np
SOURCES=[HERE/'chromatic_aberration_frame.sv',HERE.parent/'lens_distortion/lens_distortion_map.sv',HERE.parent/'geometry/rtl/img_geo_frame_sampler.v']

def map_point(x,y,c):
    fx,fy,cx,cy,ix,iy,k1,k2,k3=c;overflow=False
    def sat(n):
        nonlocal overflow
        overflow|=n<-(1<<31) or n>(1<<31)-1
        return min((1<<31)-1,max(-(1<<31),n))
    def add(a,b):return sat(a+b)
    def mul(a,b,s=16):
        n=a*b
        return sat((-1 if n<0 else 1)*((abs(n)+(1<<(s-1)))>>s))
    xn=mul(add(x<<16,-cx),ix,30);yn=mul(add(y<<16,-cy),iy,30)
    xx=mul(xn,xn);yy=mul(yn,yn);mul(xn,yn);r2=add(xx,yy)
    radial=add(mul(add(mul(add(mul(k3,r2),k2),r2),k1),r2),65536)
    xd=mul(xn,radial);yd=mul(yn,radial)
    # Shared full Brown-Conrady microcode also evaluates tangent geometry even
    # with p1=p2=0; its intermediate saturation must contribute to overflow.
    add(r2,add(xx,xx));add(r2,add(yy,yy))
    sx=add(mul(fx,xd),cx);sy=add(mul(fy,yd),cy)
    return sx,sy,overflow

def pack_cal(c):return sum((v&0xffffffff)<<(32*i) for i,v in enumerate(c))

def sample(image,w,h,x,y,c,border):
    sx,sy,ov=map_point(x,y,c);oob=sx<0 or sy<0 or sx>(w-1)*65536 or sy>(h-1)*65536
    if oob or ov:return border,int(oob),int(ov)
    xx=sx>>8;yy=sy>>8;ix=xx>>8;iy=yy>>8;ax=xx&255;ay=yy&255
    x1=min(w-1,ix+1);y1=min(h-1,iy+1)
    n=image[iy*w+ix]*(256-ax)*(256-ay)+image[iy*w+x1]*ax*(256-ay)+image[y1*w+ix]*(256-ax)*ay+image[y1*w+x1]*ax*ay
    return (n+32768)>>16,0,0

def profile(w,h,bits):
    rng=random.Random(w*119+h*871+bits);maximum=(1<<bits)-1
    base=[8<<16,16<<16,(w-1)*32768,(h-1)*32768,1<<27,1<<26,0,0,0]
    cases=[(base,base)]
    for _ in range(8):
        cs=[]
        for channel in range(2):
            c=base.copy();c[2]+=rng.randint(-2,2)*16384;c[3]+=rng.randint(-2,2)*16384
            c[6:]=[rng.randint(-120000,120000) for _ in range(3)];cs.append(c)
        cases.append(tuple(cs))
    cases.append(([65536,65536,0,0,1<<30,1<<30,*([2147483647]*3)],base))
    cases.append(([65536,65536,-150*65536,0,1<<30,1<<30,0,0,0],base))
    cases.append(cases[-1])
    frames=[];expected=[];configs=[];borders=[];mismatch=[];oob_count=ov_count=0
    for frame,(red,blue) in enumerate(cases):
        rgb=[[rng.randint(0,maximum) for _ in range(w*h)] for _ in range(3)]
        if frame==0:rgb=[[i% (maximum+1) for i in range(w*h)], [maximum//2]*(w*h),[maximum]*(w*h)]
        border=[maximum//3,maximum//2,maximum//4];borders.append((border[0]<<(2*bits))|(border[1]<<bits)|border[2])
        frames.extend((rgb[0][i]<<(2*bits))|(rgb[1][i]<<bits)|rgb[2][i] for i in range(w*h))
        configs.append((pack_cal(red),pack_cal(blue)))
        values=[[],[]]
        for y in range(h):
            for x in range(w):
                i=y*w+x;r,ro,rv=sample(rgb[0],w,h,x,y,red,border[0]);b,bo,bv=sample(rgb[2],w,h,x,y,blue,border[2])
                values[0].append(r);values[1].append(b);oob_count+=ro+bo;ov_count+=rv+bv
                word=(r<<(2*bits))|(rgb[1][i]<<bits)|b
                word|=(ro|(bo<<1))<<(3*bits);word|=(rv|(bv<<1))<<(3*bits+2)
                word|=(int(i==0)|(int(x==w-1)<<1)|(int(i==w*h-1)<<2))<<(3*bits+4)
                expected.append(word)
        if frame<9:
            for channel,c,out in zip((0,2),(red,blue),values):
                fx,fy,cx,cy,ix,iy,k1,k2,k3=c
                K=np.array([[fx/65536,0,cx/65536],[0,fy/65536,cy/65536],[0,0,1]],np.float64)
                D=np.array([k1,k2,0,0,k3],np.float64)/65536
                mx,my=cv2.initUndistortRectifyMap(K,D,None,K,(w,h),cv2.CV_32FC1)
                image=np.array(rgb[channel],np.uint16).reshape(h,w)
                reference=cv2.remap(image,mx,my,cv2.INTER_LINEAR,borderMode=cv2.BORDER_CONSTANT,borderValue=border[channel])
                for y in range(h):
                    for x in range(w):
                        sx,sy,ov=map_point(x,y,c)
                        if not ov and 0<=sx<=(w-1)*65536 and 0<=sy<=(h-1)*65536:
                            mismatch.append(out[y*w+x]-int(reference[y,x]))
    body=''
    for f,(red,blue) in enumerate(configs):
        if f==len(configs)-1:
            body+='saved_red=red;red[31:0]=0;while(!cr)tick;cv=1;tick;cv=0;if(!cd||!cerr)$fatal(1,"retain invalid");red=saved_red;begin_frame;\n'
        else:
            body+=f"red=288'h{red:072x};blue=288'h{blue:072x};border_rgb={3*bits}'h{borders[f]:x};configure;begin_frame;\n"
        body+=f"for(j=0;j<N;j=j+1)send(input_data[{f}*N+j],j==0,(j%W==W-1)^{int(f==3)});\n"
        if f==4:
            body+='saved_red=red;red[31:0]=0;cv=1;repeat(7)begin tick;if(cr||cd)$fatal(1,"mid-frame config");end\n'
        body+=f"while(!dv)tick;if(de!==1'b{int(f==3)})$fatal(1,\"frame error\");repeat(3)tick;while(!ce)tick;dr=1;tick;dr=0;\n"
        if f==4:
            body+='while(!cr)tick;tick;cv=0;if(!cd||!cerr)$fatal(1,"pending config");red=saved_red;\n'
        if f==1:
            # Invalid config must retain the accepted calibration for later transactions.
            body+='saved_red=red;red[31:0]=0;while(!cr)tick;cv=1;tick;cv=0;if(!cd||!cerr||ec!=2)$fatal(1,"invalid cfg");red=saved_red;\n'
    body+='begin_frame;repeat(5)tick;ce_override=1;rst_n=0;tick;if(mv||dv||sr||cr)$fatal(1,"reset");rst_n=1;ce_override=0;tick;while(!str)tick;start=1;tick;start=0;if(ec!=1)$fatal(1,"reset configured");\n'
    prelude=f"red=288'h{configs[0][0]:072x};blue=288'h{configs[0][1]:072x};border_rgb={3*bits}'h{borders[0]:x};configure;begin_frame;for(j=0;j<N;j=j+1)send(input_data[j],j==0,j%W==W-1);repeat(20)tick;reset_now;\n"
    prelude+=f"red=288'h{configs[0][0]:072x};blue=288'h{configs[0][1]:072x};configure;mr_override=1;begin_frame;for(j=0;j<N;j=j+1)send(input_data[j],j==0,j%W==W-1);while(!mv)tick;repeat(5)tick;reset_now;mr_override=0;\n"
    tb=TB.replace('@BODY@',prelude+body)
    for key,value in dict(W=w,H=h,B=bits,F=len(cases)).items():tb=tb.replace('@'+key+'@',str(value))
    with tempfile.TemporaryDirectory(prefix='chromatic_') as temporary:
        td=Path(temporary);(td/'tb.sv').write_text(tb,encoding='utf-8')
        for name,values in [('input',frames),('expected',expected)]:
            (td/(name+'.hex')).write_text(''.join(f'{v:x}\n' for v in values),encoding='utf-8')
        execute(['iverilog','-g2012','-s','tb','-o',td/'sim',*SOURCES,td/'tb.sv'],td,td/'compile.log')
        output=execute(['vvp',td/'sim'],td,td/'simulation.log',timeout=180)
        assert 'CHROMATIC PASS' in output,output
    maxerror=max(map(abs,mismatch),default=0)
    assert maxerror <= max(2,maximum/16),('OpenCV interpolation error',maxerror)
    result=dict(width=w,height=h,bits=bits,frames=len(cases),pixels=len(expected),oob_channel_samples=oob_count,overflow_channel_samples=ov_count,status='PASS',opencv_compared_channel_samples=len(mismatch),opencv_max_abs_lsb=maxerror,opencv_rmse_lsb=float(np.sqrt(np.mean(np.square(np.array(mismatch,dtype=np.float64))))))
    print(result,flush=True);return result

TB=r"""
module tb;
localparam W=@W@,H=@H@,B=@B@,F=@F@,N=W*H;
reg clk=0;always #5 clk=~clk;
reg rst_n=0,ce=1,cv=0,start=0,sv=0,sof=0,eol=0,mr=0,dr=0,ce_override=0,mr_override=0;
reg [287:0] red,blue,saved_red;reg [3*B-1:0] border_rgb,pixel;
wire cr,str,sr,cd,cerr,mv,dv,de,busy,ms,me,ml;wire [3:0] ec;wire [3*B-1:0] rgb;wire [1:0] oob,ov;
chromatic_aberration_frame #(.WIDTH(W),.HEIGHT(H),.BITS(B)) dut(.clk(clk),.rst_n(rst_n),.ce(ce),.cfg_valid(cv),.cfg_ready(cr),.cfg_red(red),.cfg_blue(blue),.cfg_border(border_rgb),.cfg_done(cd),.cfg_error(cerr),.error_code(ec),.start_valid(start),.start_ready(str),.s_rgb(pixel),.s_valid(sv),.s_sof(sof),.s_eol(eol),.s_ready(sr),.m_rgb(rgb),.m_valid(mv),.m_ready(mr),.m_oob(oob),.m_overflow(ov),.m_sof(ms),.m_eol(me),.m_last(ml),.done_valid(dv),.done_ready(dr),.done_error(de),.busy(busy));
reg [3*B-1:0] input_data[0:F*N-1];reg [3*B+6:0] expected[0:F*N-1];
reg [31:0] lfsr=32'ha86572f1;integer count=0,j;
reg held_valid=0;reg [3*B+6:0] held;
always @(negedge clk)if(rst_n)begin
 lfsr={lfsr[30:0],lfsr[31]^lfsr[21]^lfsr[1]^lfsr[0]};
 ce=ce_override?0:lfsr[2:0]!=0;mr=mr_override?0:lfsr[6:3]==0;
end
always @(posedge clk)if(rst_n)begin
 if(held_valid&&(!mv||{ml,me,ms,ov,oob,rgb}!==held))$fatal(1,"output stable");
 held_valid=mv&&(!ce||!mr);held={ml,me,ms,ov,oob,rgb};
 if(ce&&mv&&mr)begin
  if(count>=F*N||{ml,me,ms,ov,oob,rgb}!==expected[count])begin $display("idx=%d got=%h expected=%h",count,{ml,me,ms,ov,oob,rgb},expected[count]);$fatal(1,"oracle");end
  count=count+1;
 end
end
always @(negedge rst_n)held_valid=0;
task tick;begin @(posedge clk);#1;@(negedge clk);#1;end endtask
task reset_now;begin ce_override=1;rst_n=0;tick;if(mv||dv||sr||cr)$fatal(1,"reset outputs");rst_n=1;ce_override=0;tick;end endtask
task configure;begin
 while(!cr)tick;cv=1;start=1;#1;if(str)$fatal(1,"priority");tick;cv=0;start=0;if(!cd||cerr)$fatal(1,"config");
end endtask
task begin_frame;begin while(!str)tick;start=1;tick;start=0;end endtask
task send(input [3*B-1:0] p,input fs,le);begin
 repeat(lfsr[8:7])tick;while(!sr)tick;pixel=p;sof=fs;eol=le;sv=1;tick;sv=0;
end endtask
initial begin #100000000;$fatal(1,"timeout");end
initial begin
 $readmemh("input.hex",input_data);$readmemh("expected.hex",expected);
 @(negedge clk);tick;rst_n=1;tick;begin_frame;if(ec!=1)$fatal(1,"unconfigured");
 @BODY@
 if(count!=F*N)$fatal(1,"count");$display("CHROMATIC PASS frames=%d pixels=%d",F,count);$finish;
end
endmodule
"""

def invalid_parameters():
    rejected=0
    for w,h,b in [(0,5,8),(7,0,8),(4097,1,8),(257,256,8),(7,5,7),(7,5,13)]:
        with tempfile.TemporaryDirectory(prefix='chromatic_invalid_') as temporary:
            td=Path(temporary)
            (td/'tb.sv').write_text(f'module tb; chromatic_aberration_frame #(.WIDTH({w}),.HEIGHT({h}),.BITS({b})) dut();initial begin #20;$finish;end endmodule',encoding='utf-8')
            execute(['iverilog','-g2012','-s','tb','-o',td/'sim',*SOURCES,td/'tb.sv'],td,td/'compile.log')
            try:execute(['vvp',td/'sim'],td,td/'simulation.log')
            except RuntimeError as error:
                assert 'invalid chromatic aberration parameters' in str(error) or 'invalid lens distortion geometry' in str(error)
                rejected+=1
            else:raise AssertionError(('invalid parameters accepted',w,h,b))
    return rejected

def main():
    results=[profile(w,h,b) for w,h,b in [(1,1,8),(1,7,10),(7,1,12),(7,5,8),(9,7,12)]]
    evidence=dict(status='PASS',profiles=results,invalid_parameter_cases=invalid_parameters(),opencv_version=cv2.__version__,opencv_note='OpenCV uses 1/32 interpolation tables versus RTL 1/256 coordinates, so pixel comparisons are bounded, not bit exact. Only in-domain samples compared; exact full-border policy independently checked.',source_sha256={str(p.relative_to(HERE.parent.parent)):hashlib.sha256(p.read_bytes()).hexdigest() for p in SOURCES})
    (HERE/'test_evidence.json').write_text(json.dumps(evidence,indent=2)+'\n',encoding='utf-8')
if __name__=='__main__':main()
