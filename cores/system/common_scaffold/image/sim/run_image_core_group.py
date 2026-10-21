"""Small independent-reference group regression, not a release qualification.

Run after scripts/env.ps1. Tests command-frame filters together with AWB gain
solving. Build artifacts are append-only under image/build_core_group_<time>.
"""
from pathlib import Path
import datetime
import math
import json
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[1]


def rtl_sources():
    return sorted(p for p in ROOT.rglob('*.v') if not p.name.startswith('tb_')
                  and not any(s.startswith('build') or s in ('sim', 'evidence')
                              for s in p.relative_to(ROOT).parts[:-1]))


def sample(a, x, y):
    return a[min(len(a)-1, max(0, y))][min(len(a[0])-1, max(0, x))]


def morph(a, maximum, mask):
    sign = -1 if maximum else 1
    return [[(max if maximum else min)(sample(a, x+sign*(k%3-1), y+sign*(k//3-1))
             for k in range(9) if mask & (1 << k)) for x in range(len(a[0]))] for y in range(len(a))]


def nlm(a, pr=1, sr=1, h=30):
    out = []
    for y in range(len(a)):
        row = []
        for x in range(len(a[0])):
            sw = sp = 0
            for cy in range(-sr, sr+1):
                for cx in range(-sr, sr+1):
                    ssd = sum((sample(a, x+px, y+py)-sample(a, x+cx+px, y+cy+py))**2
                              for py in range(-pr, pr+1) for px in range(-pr, pr+1))
                    idx = min(255, ssd*16//((2*pr+1)**2*h*h))
                    weight = int(65535*math.exp(-idx/16)+0.5)
                    sw += weight
                    sp += weight*sample(a, x+cx, y+cy)
            row.append((sp+sw//2)//sw)
        out.append(row)
    return out


def canny(a, low=100, high=240):
    h, w = len(a), len(a[0])
    blur = [[(sum(sample(a, x+k%3-1, y+k//3-1)*[1,2,1,2,4,2,1,2,1][k]
                  for k in range(9))+8)//16 for x in range(w)] for y in range(h)]
    mag, dirs = [], []
    for y in range(h):
        mr, dr = [], []
        for x in range(w):
            p = [sample(blur, x+k%3-1, y+k//3-1) for k in range(9)]
            gx = -p[0]+p[2]-2*p[3]+2*p[5]-p[6]+p[8]
            gy = -p[0]-2*p[1]-p[2]+p[6]+2*p[7]+p[8]
            ax, ay = abs(gx), abs(gy)
            d = 0 if ay*256 <= ax*106 else 2 if ax*256 <= ay*106 else 1 if (gx<0)==(gy<0) else 3
            mr.append(ax+ay)
            dr.append(d)
        mag.append(mr)
        dirs.append(dr)
    labels = [[0]*w for _ in range(h)]
    for y in range(h):
        for x in range(w):
            dx,dy = [(1,0),(1,1),(0,1),(1,-1)][dirs[y][x]]
            m = mag[y][x]
            if m and m >= sample(mag,x-dx,y-dy) and m >= sample(mag,x+dx,y+dy):
                labels[y][x] = 2 if m >= high else 1 if m >= low else 0
    # Independent flood-fill rather than reproducing the RTL raster iterations.
    stack = [(x,y) for y in range(h) for x in range(w) if labels[y][x]==2]
    while stack:
        x,y = stack.pop()
        for dy in range(-1,2):
            for dx in range(-1,2):
                xx,yy = x+dx,y+dy
                if 0<=xx<w and 0<=yy<h and labels[yy][xx]==1:
                    labels[yy][xx]=2
                    stack.append((xx,yy))
    return [[255 if p==2 else 0 for p in row] for row in labels]


def truncdiv(n,d):
    return abs(n)//d * (-1 if n<0 else 1)


def guided(a, guide, r=1, eps=25):
    h,w=len(a),len(a[0]); n=(2*r+1)**2
    aa=[[0]*w for _ in range(h)]; bb=[[0]*w for _ in range(h)]
    for y in range(h):
        for x in range(w):
            v=[(sample(guide,x+dx,y+dy),sample(a,x+dx,y+dy)*128)
               for dy in range(-r,r+1) for dx in range(-r,r+1)]
            si,sp=sum(i for i,p in v),sum(p for i,p in v)
            a0=truncdiv((n*sum(i*p for i,p in v)-si*sp)<<16,
                        n*sum(i*i for i,p in v)-si*si+n*n*eps)
            aa[y][x]=a0
            bb[y][x]=truncdiv((sp<<16)-a0*si,n)
    out=[]
    for y in range(h):
        row=[]
        for x in range(w):
            sa=sum(sample(aa,x+dx,y+dy) for dy in range(-r,r+1) for dx in range(-r,r+1))
            sb=sum(sample(bb,x+dx,y+dy) for dy in range(-r,r+1) for dx in range(-r,r+1))
            q=max(0,min(32768,truncdiv(sa*guide[y][x]+sb,n<<16)))
            row.append(min(255,(q+64)>>7))
        out.append(row)
    return out


def frame_bench(name, module, a, expected, config, *, frames=1, guide=None, input_frames=None):
    h,w=len(a),len(a[0]); n=w*h
    av=[v for frame in (input_frames or [a]*frames) for row in frame for v in row]
    ev=[v for frame in expected for row in frame for v in row]
    gv=[v for row in (guide or a) for v in row]*frames
    common='''.clk(clk),.rst_n(rst_n),.clk_en(ce),.cmd_valid(cv),.cmd_ready(cr),.cmd_tag(tag),
        .cfg_width(16'dW),.cfg_height(16'dH),.rsp_valid(rv),.rsp_ready(rr),.rsp_tag(rt),.rsp_error(re),
        .s_data(sd),.s_valid(sv),.s_ready(sr),.s_sof(ss),.s_eol(se),
        .m_data(md),.m_valid(mv),.m_ready(mr),.m_sof(ms),.m_eol(me)'''.replace("16'dW",f"16'd{w}").replace("16'dH",f"16'd{h}")
    init='\n'.join(f'input_pixels[{i}]=8\'d{v}; guide_pixels[{i}]=8\'d{gv[i]};' for i,v in enumerate(av))
    init+='\n'+'\n'.join(f"expected[{i}]=8'd{v};" for i,v in enumerate(ev))
    return f'''
module case_{name}(input clk,rst_n, output reg done);
localparam W={w},H={h},N={n},FRAMES={frames};
reg ce=1,mr=1,rr=0,cv=0,sv=0,ss=0,se=0; reg [7:0] sd=0,gd=0,tag=0;
wire cr,sr,mv,ms,me,rv;wire [7:0] md,rt,re;
reg [7:0] input_pixels[0:N*FRAMES-1],guide_pixels[0:N*FRAMES-1],expected[0:N*FRAMES-1];
integer cycle=0,received=0,responses=0,i,f;reg held=0;reg [9:0] saved;
{module} #(.MAX_WIDTH(16),.MAX_HEIGHT(16)) dut({common},{config});
always @(negedge clk)if(rst_n)begin cycle=cycle+1;ce=(cycle%7!=0);mr=(cycle%5!=0 && cycle%5!=1);end
always @(posedge clk)if(rst_n)begin
    if(held && {{ms,me,md}}!==saved)$fatal(1,"{name} output changed under stall/CE");
    held=mv && (!ce || !mr);saved={{ms,me,md}};
    if(ce && mv && mr)begin
        if(received>=N*FRAMES || md!==expected[received])$fatal(1,"{name} pixel %0d actual=%0d expected=%0d",received,md,expected[received]);
        if(ms!==(received%N==0) || me!==(received%W==W-1))$fatal(1,"{name} output marker");
        received=received+1;
    end
    if(ce && rv && rr)begin
        if(re!==0 || rt!==responses || received!=(responses+1)*N)$fatal(1,"{name} premature/error response %h tag=%h count=%0d",re,rt,received);
        responses=responses+1;
    end
end
initial begin done=0;{init}
    wait(rst_n);
    for(f=0;f<FRAMES;f=f+1)begin
        @(negedge clk);cv=1;tag=f;
        do @(posedge clk);while(!ce || !cr);
        @(negedge clk);cv=0;
        for(i=0;i<N;i=i+1)begin
            @(negedge clk);sv=1;sd=input_pixels[f*N+i];gd=guide_pixels[f*N+i];ss=(i==0);se=(i%W==W-1);
            do @(posedge clk);while(!ce || !sr);
        end
        @(negedge clk);sv=0;
        wait(rv);repeat(3)@(negedge clk);rr=1;
        do @(posedge clk);while(!ce || !rv);
        @(negedge clk);rr=0;
    end
    if(received!=N*FRAMES)$fatal(1,"{name} missing output");
    $display("PASS {name} pixels=%0d",received);done=1;
end
endmodule
'''


def bilateral_bench():
    windows=[[20,40,60,80,100,120,140,160,180],[150,140,120,100,80,60,40,20,0],
             [33]*9,[0,255,0,255,128,255,0,255,0]]
    expected=[]
    for p in windows:
        sw=sp=0
        for k in range(9):
            idx=min(255,((k%3-1)**2+(k//3-1)**2)*8 + (p[k]-p[4])**2*8//900)
            weight=int(65535*math.exp(-idx/16)+0.5)
            sw+=weight;sp+=weight*p[k]
        expected.append((sp+sw//2)//sw)
    init='\n'.join(f"windows[{i}]=72'h{sum(v<<(k*8) for k,v in enumerate(p)):018x}; expected[{i}]=8'd{expected[i]};" for i,p in enumerate(windows))
    return '''
module case_bilateral(input clk,rst_n, output reg done);
reg ce=1,mr=1,cv=0,rr=0,sv=0;reg [71:0] taps=0;
wire cr,rv,sr,mv,ms,me;wire [7:0] md,rt,re;
reg [71:0] windows[0:3];reg [7:0] expected[0:3];integer i,received=0,cycle=0;
reg held=0;reg [9:0] saved;
img_filter_bilateral3x3 dut(.clk(clk),.rst_n(rst_n),.clk_en(ce),
    .cmd_valid(cv),.cmd_ready(cr),.cmd_tag(8'd37),.cfg_sigma_spatial_q8(16'd256),.cfg_sigma_range_q8(16'd7680),
    .rsp_valid(rv),.rsp_ready(rr),.rsp_tag(rt),.rsp_error(re),
    .s_taps(taps),.s_valid(sv),.s_ready(sr),.s_sof(1'b1),.s_eol(1'b1),
    .m_data(md),.m_valid(mv),.m_ready(mr),.m_sof(ms),.m_eol(me));
always @(negedge clk) if(rst_n)begin cycle=cycle+1;ce=(cycle%7!=0);mr=(cycle%5>1);end
always @(posedge clk)if(rst_n)begin
    if(held && {ms,me,md}!==saved)$fatal(1,"bilateral output unstable");
    held=mv && (!ce || !mr);saved={ms,me,md};
    if(ce && mv && mr)begin
        if(received>=4 || md!==expected[received] || !ms || !me)$fatal(1,"bilateral pixel %0d actual=%0d expected=%0d",received,md,expected[received]);
        received=received+1;
    end
end
initial begin done=0;INIT
    wait(rst_n);@(negedge clk);cv=1;
    do @(posedge clk);while(!ce || !cr);
    @(negedge clk);cv=0;wait(rv);repeat(3)@(negedge clk);
    if(re!==0 || rt!==37)$fatal(1,"bilateral command");rr=1;
    do @(posedge clk);while(!ce || !rv);
    @(negedge clk);rr=0;
    for(i=0;i<4;i=i+1)begin
        @(negedge clk);sv=1;taps=windows[i];
        do @(posedge clk);while(!ce || !sr);
    end
    @(negedge clk);sv=0;wait(received==4);$display("PASS bilateral windows=4");done=1;
end
endmodule
'''.replace('INIT',init)


def main():
    out=ROOT/('build_core_group_'+datetime.datetime.now().strftime('%Y%m%d_%H%M%S_%f'))
    out.mkdir()
    a=[[23,80,29,190,210],[65,45,180,220,31],[28,122,185,10,90],[44,35,230,144,3]]
    guide=[[10,20,30,140,160],[12,25,35,145,155],[18,28,40,150,170],[15,30,38,160,180]]
    mask=0b000010110  # nonsymmetric SE exercises reflected dilation
    cases=[]
    cases.append(frame_bench('opening','img_morph_open3x3',a,[morph(morph(a,False,mask),True,mask)],f".cfg_structuring_element(9'd{mask})"))
    cases.append(frame_bench('closing','img_morph_close3x3',a,[morph(morph(a,True,mask),False,mask)],f".cfg_structuring_element(9'd{mask})"))
    cases.append(frame_bench('nlm','img_filter_nlm',a,[nlm(a)],".cfg_patch_radius(8'd1),.cfg_search_radius(8'd1),.cfg_h_q8(16'd7680)"))
    edge=[[min(255,20+x*12+(100 if x>3+(y%3==0) else 0)) for x in range(9)]for y in range(7)]
    cases.append(frame_bench('canny','img_edge_canny',edge,[canny(edge)],".cfg_low(12'd100),.cfg_high(12'd240)"))
    cases.append(frame_bench('guided','img_filter_guided',a,[guided(a,guide)],".cfg_radius(8'd1),.cfg_epsilon_q8(24'd6400),.s_guide_data(gd),.s_guide_valid(sv),.s_guide_sof(ss),.s_guide_eol(se),.s_guide_ready()",guide=guide))
    a2=[[min(255,p+(20 if (x+y)%2 else 80)) for x,p in enumerate(row)]for y,row in enumerate(a)]
    temporal=[[p if abs(p-a[y][x])>50 else (p+a[y][x]+1)//2 for x,p in enumerate(row)] for y,row in enumerate(a2)]
    cases.append(frame_bench('temporal','img_filter_temporal_denoise',a,[a,temporal],".cfg_current_weight_q8(9'd128),.cfg_motion_threshold(8'd50),.cfg_history_valid(1'b1),.s_history_data(8'd0),.s_history_valid(1'b0),.s_history_sof(1'b0),.s_history_eol(1'b0),.s_history_ready()",frames=2,input_frames=[a,a2]))
    cases.append(bilateral_bench())
    names=['opening','closing','nlm','canny','guided','temporal','bilateral']
    top='`timescale 1ns/1ps\n'+''.join(cases)+'\nmodule tb;reg clk=0,rst_n=0;always #5 clk=~clk;wire ['+str(len(names)-1)+':0] done;\n'
    top+='\n'.join(f'case_{s} c_{s}(clk,rst_n,done[{i}]);'for i,s in enumerate(names))
    top+='\ninitial begin #21;rst_n=1;wait(&done);$display("PASS IMAGE CORE GROUP");$finish;end initial begin #20000000;$fatal(1,"group timeout");end endmodule\n'
    bench=out/'tb_image_core_group.v';bench.write_text(top)
    exe=out/'core.vvp'
    compile_cmd=['iverilog','-g2012','-s','tb','-o',str(exe),str(bench),*map(str,rtl_sources())]
    compiled=subprocess.run(compile_cmd,text=True,capture_output=True)
    (out/'compile.log').write_text(compiled.stdout+compiled.stderr)
    if compiled.returncode:
        print(compiled.stderr);return compiled.returncode
    run=subprocess.run(['vvp',str(exe)],text=True,capture_output=True,timeout=120)
    (out/'simulation.log').write_text(run.stdout+run.stderr)
    (out/'summary.json').write_text(json.dumps({'group':'image_core','compile_exit':compiled.returncode,
        'simulation_exit':run.returncode,'cases':names,'frames':7,'pixels':183,'windows':4,
        'synthesis':'not_run','board':'not_run','scope':'small-frame reference, CE, backpressure, markers, final response'},indent=2))
    print(run.stdout+run.stderr);print('Artifacts:',out)
    return run.returncode


if __name__=='__main__':
    sys.exit(main())
