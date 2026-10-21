"""Actual affine RANSAC -> trajectory stabilizer; exact rational geometry."""
from fractions import Fraction as F
import hashlib
from pathlib import Path
import tempfile

from tooling import PACKAGE, ROOT, evidence_dir, execute, write_json

SOURCES = [PACKAGE/'image/affine_ransac/affine_ransac.sv',
           PACKAGE/'image/video_stabilization/affine_video_stabilizer.sv']
IDENTITY = ((F(1), F(0), F(0)), (F(0), F(1), F(0)), (F(0), F(0), F(1)))


def multiply(a, b):
    return tuple(tuple(sum(a[i][k]*b[k][j] for k in range(3)) for j in range(3)) for i in range(3))


def inverse(a):
    # Generic exact Gauss-Jordan elimination, independent of RTL's 2x2 formula.
    rows = [list(a[i])+list(IDENTITY[i]) for i in range(3)]
    for col in range(3):
        pivot = next(i for i in range(col, 3) if rows[i][col])
        rows[col], rows[pivot] = rows[pivot], rows[col]
        divisor = rows[col][col]
        rows[col] = [x/divisor for x in rows[col]]
        for i in range(3):
            if i != col:
                factor = rows[i][col]
                rows[i] = [x-factor*y for x, y in zip(rows[i], rows[col])]
    return tuple(tuple(row[3:]) for row in rows)


def matrix(values):
    return (tuple(map(F, values[:3])), tuple(map(F, values[3:])), IDENTITY[2])


def q16(value):
    value *= 65536
    assert value.denominator == 1 and -(1 << 31) <= value < (1 << 31)
    return int(value) & 0xffffffff


def fixtures():
    transforms = [(1,0,3,0,1,-2), (0,-1,1,1,0,2), (1,1,-1,0,1,0),
                  (2,0,0,0,1,1), (1,0,9,0,1,8), (1,0,4,0,1,2),
                  (1,0,-2,0,1,4), (1,0,1,0,1,1), (1,0,7,0,1,8)]
    trajectory = smooth = IDENTITY
    result = []
    for index, values in enumerate(transforms):
        a = matrix(values)
        alpha = F(0) if index < 5 else F(1, 2)
        scene_cut = index in (4, 8)
        low_inliers = index == 7
        if scene_cut:
            trajectory = smooth = IDENTITY
            c = w = IDENTITY
        elif not low_inliers:
            trajectory = multiply(a, trajectory)
            smooth = tuple(tuple(old+alpha*(new-old) for old, new in zip(sr,tr))
                           for sr,tr in zip(smooth,trajectory))
            c = multiply(smooth, inverse(trajectory))
            w = multiply(trajectory, inverse(smooth))
            assert multiply(c, w) == IDENTITY
            # The compensation must map current-camera points to smooth-camera points.
            assert multiply(c, trajectory) == smooth
        else:
            c = w = tuple((F(0),)*3 for _ in range(3))
        points = []
        for i in range(24):
            x, y = ((i % 6)*4, (i // 6)*5)
            u = values[0]*x+values[1]*y+values[2]
            v = values[3]*x+values[4]*y+values[5]
            if i >= 18:
                u, v = 2000+i*i*3, -3000+i*i*7
            points.append((x,y,u,v))
        expected = sum(q16(value) << (32*i) for i,value in enumerate(c[0]+c[1]+w[0]+w[1]))
        expected |= int(not low_inliers) << 384
        expected |= int(low_inliers) << 385
        result.append(dict(points=points,expected=expected,alpha=int(alpha*65536),
                           minimum=32 if low_inliers else 12,scene_cut=int(scene_cut)))
    return result


TB = r'''
module tb;
reg clk=0;always #5 clk=~clk;
reg rst_n=0,ce=1,s_valid=0,s_first=0,s_last=0,m_ready=0;
reg signed[15:0]s_x=0,s_y=0,s_u=0,s_v=0;
wire s_ready,rvalid,rready,rmodel,rdone,rbusy;
wire signed[39:0]a00,a01,a02,a10,a11,a12;
wire[6:0]best_count;wire[63:0]best_residual;wire[3:0]rerror;
affine_ransac #(.CAPACITY(32),.FRAC(8)) ransac(
 .clk(clk),.rst_n(rst_n),.ce(ce),.s_x(s_x),.s_y(s_y),.s_u(s_u),.s_v(s_v),
 .s_first(s_first),.s_last(s_last),.s_valid(s_valid),.s_ready(s_ready),
 .cfg_count(7'd24),.cfg_iterations(16'd48),.cfg_seed(32'h15283647),.cfg_threshold(32'd0),
 .a00(a00),.a01(a01),.a02(a02),.a10(a10),.a11(a11),.a12(a12),
 .best_count(best_count),.best_residual(best_residual),.model_valid(rmodel),
 .m_valid(rvalid),.m_ready(rready),.done(rdone),.busy(rbusy),.error_code(rerror));
// This fixture adapter is exact only for its checked, representable Q8 models.
wire signed[31:0]s_a00=a00<<<8,s_a01=a01<<<8,s_a02=a02<<<8;
wire signed[31:0]s_a10=a10<<<8,s_a11=a11<<<8,s_a12=a12<<<8;
reg[16:0]cfg_alpha=0;reg[6:0]cfg_min_inliers=12;wire[63:0]cfg_min_det=0;
reg s_scene_cut=0;wire[6:0]s_inliers=best_count;
wire m_valid,m_model_valid,busy,done;wire[3:0]error_code;
wire signed[31:0]m_c00,m_c01,m_c02,m_c10,m_c11,m_c12;
wire signed[31:0]m_w00,m_w01,m_w02,m_w10,m_w11,m_w12;
affine_video_stabilizer stabilizer(.clk(clk),.rst_n(rst_n),.ce(ce),
 .s_a00(s_a00),.s_a01(s_a01),.s_a02(s_a02),.s_a10(s_a10),.s_a11(s_a11),.s_a12(s_a12),
 .s_inliers(s_inliers),.s_scene_cut(s_scene_cut),.s_valid(rvalid),.s_ready(rready),
 .cfg_alpha(cfg_alpha),.cfg_min_inliers(cfg_min_inliers),.cfg_min_det(cfg_min_det),
 .m_c00(m_c00),.m_c01(m_c01),.m_c02(m_c02),.m_c10(m_c10),.m_c11(m_c11),.m_c12(m_c12),
 .m_w00(m_w00),.m_w01(m_w01),.m_w02(m_w02),.m_w10(m_w10),.m_w11(m_w11),.m_w12(m_w12),
 .m_model_valid(m_model_valid),.m_valid(m_valid),.m_ready(m_ready),.busy(busy),.done(done),.error_code(error_code));
reg[63:0]points[0:215];reg[388:0]expected[0:8];
wire[388:0]actual={error_code,m_model_valid,m_w12,m_w11,m_w10,m_w02,m_w01,m_w00,m_c12,m_c11,m_c10,m_c02,m_c01,m_c00};
reg[388:0]held;reg hold_valid=0;
reg[31:0]rng=32'h12892341;integer output_count=0,estimates=0,frame,i;
always @(negedge clk)if(rst_n)begin
 rng={rng[30:0],rng[31]^rng[21]^rng[1]^rng[0]};
 ce=rng[2:0]!=0;m_ready=rng[6:3]==0;
end
always @(posedge clk)if(rst_n)begin
 if(hold_valid&&(!m_valid||actual!==held))$fatal(1,"stabilizer output stability");
 hold_valid=m_valid&&(!ce||!m_ready);held=actual;
 if(ce&&rvalid&&rready)begin
  if(!rmodel||rerror!=0||best_count!=18||best_residual!=0)$fatal(1,"RANSAC actual consensus");
  if((a00>>>23)!=(a00[39]?-1:0)||(a01>>>23)!=(a01[39]?-1:0)||
     (a02>>>23)!=(a02[39]?-1:0)||(a10>>>23)!=(a10[39]?-1:0)||
     (a11>>>23)!=(a11[39]?-1:0)||(a12>>>23)!=(a12[39]?-1:0))$fatal(1,"Q8 adapter range");
  estimates=estimates+1;
 end
 if(ce&&m_valid&&m_ready)begin
  if(output_count>=9||actual!==expected[output_count])begin
   $display("frame %d actual %h expected %h",output_count,actual,expected[output_count]);
   $fatal(1,"rational trajectory oracle");
  end
  output_count=output_count+1;
 end
end
task tick;begin @(posedge clk);#1;@(negedge clk);#1;end endtask
task point(input integer n);begin
 {s_v,s_u,s_y,s_x}=points[n];s_first=(n%24==0);s_last=(n%24==23);
 while(!s_ready||!ce)tick;
 s_valid=1;tick;s_valid=0;
end endtask
initial begin #1000000000;$fatal(1,"watchdog");end
initial begin
 $readmemh("points.hex",points);$readmemh("expected.hex",expected);
 tick;rst_n=1;tick;
 @BODY@
 if(estimates!=9||output_count!=9)$fatal(1,"coverage");
 $display("RANSAC_STABILIZATION PASS 9 matrices 216 matches");$finish;
end
endmodule
'''


def main():
    folder = evidence_dir('ransac_stabilization')
    frozen = {str(p.relative_to(PACKAGE)):hashlib.sha256(p.read_bytes()).hexdigest() for p in SOURCES}
    cases = fixtures()
    with tempfile.TemporaryDirectory(prefix='ransac_stabilization_') as temporary:
        td = Path(temporary)
        packed = [sum((z&65535) << (16*i) for i,z in enumerate(point))
                  for case in cases for point in case['points']]
        (td/'points.hex').write_text(''.join(f'{x:x}\n' for x in packed),encoding='utf-8')
        (td/'expected.hex').write_text(''.join(f"{c['expected']:x}\n" for c in cases),encoding='utf-8')
        body = ''
        for index,c in enumerate(cases):
            body += f"cfg_alpha=17'd{c['alpha']};cfg_min_inliers=7'd{c['minimum']};s_scene_cut=1'b{c['scene_cut']};\n"
            body += f'for(i={index*24};i<{(index+1)*24};i=i+1)point(i);while(output_count<{index+1})tick;\n'
        (td/'tb.sv').write_text(TB.replace('@BODY@',body),encoding='utf-8')
        execute(['iverilog','-g2012','-s','tb','-o',td/'sim',*SOURCES,td/'tb.sv'],ROOT,folder/'compile.log')
        output = execute(['vvp',td/'sim'],td,folder/'simulation.log',timeout=180)
        assert 'RANSAC_STABILIZATION PASS' in output
    assert frozen == {str(p.relative_to(PACKAGE)):hashlib.sha256(p.read_bytes()).hexdigest() for p in SOURCES}, 'RTL changed during pipeline test'
    write_json(folder/'results.json',dict(status='PASS',frames=9,matches=216,
        hypotheses=432,outliers_per_frame=6,board_tested=False,
        sources_sha256=frozen,
        scope='Actual RANSAC Q8 to stabilizer Q16; exact representable noncommuting affine transforms, rational inverse/EMA, cuts, low-inlier error, CE and backpressure. Fixture adapter only; no general overflow-safe reusable adapter claim.'))
    print(output.strip());print(folder)


if __name__ == '__main__':
    main()
