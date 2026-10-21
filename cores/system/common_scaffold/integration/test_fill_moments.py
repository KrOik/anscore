"""Real hole-fill -> image-moments RTL, checked directly from raw masks."""
import hashlib
from pathlib import Path
import random
import tempfile

from test_fill_components import oracle as fill_oracle
from tooling import PACKAGE, ROOT, evidence_dir, execute, write_json

SOURCES = [PACKAGE/'image/hole_fill/binary_hole_fill.sv',
           PACKAGE/'image/moments/image_spatial_moments.sv']


def expected_moments(image,width):
    points = [(i % width,i // width) for i,pixel in enumerate(image) if pixel]
    area = len(points)
    values = [area,sum(x for x,y in points),sum(y for x,y in points),
              sum(x*x for x,y in points),sum(x*y for x,y in points),
              sum(y*y for x,y in points)]
    values += [(values[1] << 16)//area if area else 0,
               (values[2] << 16)//area if area else 0,int(area != 0)]
    packed = 0
    for value,bits in zip(values,[64]*6+[32,32,1]):
        assert 0 <= value < (1 << bits)
        packed = (packed << bits) | value
    return packed


def profile(width,height,eight,folder):
    rng = random.Random(47041+width*height+eight)
    n = width*height
    ring = [int(width>4 and height>4 and 1<=x<width-1 and 1<=y<height-1 and
                (x in (1,width-2) or y in (1,height-2)))
            for y in range(height) for x in range(width)]
    leak = ring.copy()
    if width>4 and height>4:
        leak[width+1] = 0
    images = [[0]*n,[1]*n,ring,leak]
    images += [[rng.randrange(2) for _ in range(n)] for _ in range(3)]
    masks = [fill_oracle(image,width,height,eight)[0] for image in images]
    expected = [expected_moments(mask,width) for mask in masks]
    label = f'{width}x{height}_c{8 if eight else 4}'
    with tempfile.TemporaryDirectory(prefix='fill_moments_') as temporary:
        td = Path(temporary)
        (td/'input.hex').write_text(''.join(f'{v:x}\n' for image in images for v in image),encoding='utf-8')
        (td/'expected.hex').write_text(''.join(f'{v:x}\n' for v in expected),encoding='utf-8')
        tb = TB
        for key,value in dict(W=width,H=height,E=eight,F=len(images)).items():
            tb = tb.replace('@'+key+'@',str(value))
        (td/'tb.sv').write_text(tb,encoding='utf-8')
        execute(['iverilog','-g2012','-s','tb','-o',td/'sim',*SOURCES,td/'tb.sv'],
                td,folder/f'{label}_compile.log')
        output = execute(['vvp',td/'sim'],td,folder/f'{label}_simulation.log',timeout=120)
        assert 'FILL_MOMENTS PASS' in output,output
    print(label,len(images),'frames',n*len(images),'pixels, moments/centroids PASS',flush=True)
    return dict(width=width,height=height,connectivity=8 if eight else 4,
                frames=len(images),pixels=n*len(images),moment_records=len(images),status='PASS')


TB = r'''
module tb;
localparam W=@W@,H=@H@,E=@E@,F=@F@,N=W*H;
reg clk=0;always #5 clk=~clk;
reg rst_n=0,ce=1,pixel=0,sv=0,sof=0,eol=0,mr=0;
wire sr,hpixel,hole,hv,hs,he,hr,hd,hbusy,mv,md,mbusy,centroid_valid;
wire[31:0] filled_count,cx,cy;wire[3:0] herror,merror;
wire[63:0] m00,m10,m01,m20,m11,m02;
wire[448:0] payload={m00,m10,m01,m20,m11,m02,cx,cy,centroid_valid};
binary_hole_fill #(.WIDTH(W),.HEIGHT(H),.CONNECT8(E)) fill(
 .clk(clk),.rst_n(rst_n),.ce(ce),.s_pixel(pixel),.s_valid(sv),.s_sof(sof),.s_eol(eol),.s_ready(sr),
 .m_pixel(hpixel),.m_hole(hole),.m_valid(hv),.m_sof(hs),.m_eol(he),.m_ready(hr),
 .busy(hbusy),.done(hd),.filled_count(filled_count),.error_code(herror));
image_spatial_moments #(.WIDTH(W),.HEIGHT(H),.BITS(8),.MASK_ENABLE(1)) moments(
 .clk(clk),.rst_n(rst_n),.ce(ce),.binary_mode(1'b1),
 .s_pixel({7'b0,hpixel}),.s_mask(1'b1),.s_valid(hv),.s_sof(hs),.s_eol(he),.s_ready(hr),
 .m00(m00),.m10(m10),.m01(m01),.m20(m20),.m11(m11),.m02(m02),
 .centroid_x_q16(cx),.centroid_y_q16(cy),.centroid_valid(centroid_valid),
 .m_valid(mv),.m_ready(mr),.busy(mbusy),.done(md),.error_code(merror));
reg input_bits[0:F*N-1];reg[448:0] expected[0:F-1];
integer f=0,i,received=0,transferred=0,cycles=0;
reg hseen=0,take,held=0;reg[448:0] held_payload;reg[31:0] random_state=32'h71345ab9;
always @(posedge clk)begin
 cycles=cycles+1;if(cycles>1000000)$fatal(1,"timeout");
 if(rst_n)begin
  if(held&&(!mv||payload!==held_payload))$fatal(1,"moments stalled payload changed");
  held=mv&&(!ce||!mr);held_payload=payload;
  if(ce&&hv&&hr)transferred=transferred+1;
  if(ce&&mv&&mr)begin
   if(received>=F)$fatal(1,"extra moments record");
   if(payload!==expected[received]||merror)$fatal(1,"moments record mismatch frame=%0d",received);
   received=received+1;
  end
  if(ce&&hd)begin if(herror)$fatal(1,"fill error");hseen=1;end
 end
end
task tick;begin
 @(negedge clk);#1;
 random_state=random_state^(random_state<<13);random_state=random_state^(random_state>>17);random_state=random_state^(random_state<<5);
 ce=random_state[0]|random_state[1];mr=random_state[2]|random_state[4];
end endtask
initial begin
 $readmemh("input.hex",input_bits);$readmemh("expected.hex",expected);
 repeat(3)@(negedge clk);#1;rst_n=1;
 for(f=0;f<F;f=f+1)begin
  i=0;hseen=0;
  while(i<N)begin
   pixel=input_bits[f*N+i];sof=i==0;eol=i%W==W-1;sv=1;
   @(posedge clk);take=ce&&sv&&sr;if(take)i=i+1;tick;
  end
  sv=0;
  while(!hseen||received!=f+1)tick;
  if(transferred!=(f+1)*N)$fatal(1,"interstage pixel count");
  repeat(3)tick;
 end
 $display("FILL_MOMENTS PASS frames=%0d pixels=%0d records=%0d",F,transferred,received);$finish;
end
endmodule
'''


if __name__ == '__main__':
    folder = evidence_dir('fill_moments')
    results = [profile(w,h,eight,folder) for w,h in ((11,9),(1,7),(7,1)) for eight in (0,1)]
    write_json(folder/'results.json',dict(status='PASS',results=results,board_tested=False,
        oracle_source_sha256=hashlib.sha256(Path(__file__).with_name('test_fill_components.py').read_bytes()).hexdigest(),
        rtl_sha256={str(path.relative_to(ROOT)):hashlib.sha256(path.read_bytes()).hexdigest()
                    for path in SOURCES}))
    print(folder,flush=True)
