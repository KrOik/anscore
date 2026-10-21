"""Actual hole-fill -> binary RLE encode/decode -> spatial moments chain."""
import hashlib
from pathlib import Path
import random
import tempfile

from test_fill_components import oracle as fill_oracle
from test_fill_moments import expected_moments
from tooling import PACKAGE, ROOT, evidence_dir, execute, write_json

SOURCES = [PACKAGE/'image/hole_fill/binary_hole_fill.sv',
           PACKAGE/'image/binary_rle/binary_rle_encoder.v',
           PACKAGE/'image/binary_rle/binary_rle_decoder.v',
           PACKAGE/'image/moments/image_spatial_moments.sv']


def runs(image, width, height):
    result = []
    xw, yw, lw = max(1, (width-1).bit_length()), max(1, (height-1).bit_length()), width.bit_length()
    for y in range(height):
        x = 0
        while x < width:
            first = x
            value = image[y*width+x]
            while x < width and image[y*width+x] == value:
                x += 1
            fields = [(value,1),(first,xw),(y,yw),(x-first,lw),
                      (int(first==0 and y==0),1),(int(x==width),1),
                      (int(x==width and y==height-1),1)]
            packed = 0
            for field,bits in fields:
                packed = (packed << bits) | field
            result.append(packed)
    return result


def profile(width,height,eight,folder):
    rng = random.Random(98417+width*height+eight)
    n = width*height
    ring = [int(width>4 and height>4 and 1<=x<width-1 and 1<=y<height-1 and
                (x in (1,width-2) or y in (1,height-2)))
            for y in range(height) for x in range(width)]
    leak = ring.copy()
    if width>4 and height>4:
        leak[width+1] = 0
    images = [[0]*n,[1]*n,ring,leak,
              [(x+y)%2 for y in range(height) for x in range(width)]]
    images += [[rng.randrange(2) for _ in range(n)] for _ in range(3)]
    masks = [fill_oracle(image,width,height,eight)[0] for image in images]
    tokens = [token for mask in masks for token in runs(mask,width,height)]
    label = f'{width}x{height}_c{8 if eight else 4}'
    with tempfile.TemporaryDirectory(prefix='fill_rle_moments_') as temporary:
        td = Path(temporary)
        for name,values in [('input',[v for image in images for v in image]),
                            ('pixels',[v for mask in masks for v in mask]),
                            ('tokens',tokens),
                            ('moments',[expected_moments(mask,width) for mask in masks])]:
            (td/(name+'.hex')).write_text(''.join(f'{v:x}\n' for v in values),encoding='utf-8')
        tb = TB
        for key,value in dict(W=width,H=height,E=eight,F=len(images),T=len(tokens)).items():
            tb = tb.replace('@'+key+'@',str(value))
        (td/'tb.sv').write_text(tb,encoding='utf-8')
        execute(['iverilog','-g2012','-s','tb','-o',td/'sim',*SOURCES,td/'tb.sv'],
                td,folder/f'{label}_compile.log')
        output = execute(['vvp',td/'sim'],td,folder/f'{label}_simulation.log',timeout=120)
        assert 'FILL_RLE_MOMENTS PASS' in output,output
    print(label,len(images),'frames',n*len(images),'pixels',len(tokens),'runs PASS',flush=True)
    return dict(width=width,height=height,connectivity=8 if eight else 4,
                frames=len(images),pixels=n*len(images),runs=len(tokens),status='PASS')


TB = r'''
module tb;
localparam W=@W@,H=@H@,E=@E@,F=@F@,T=@T@,N=W*H;
localparam XW=W<2?1:$clog2(W),YW=H<2?1:$clog2(H),LW=$clog2(W+1),TW=1+XW+YW+LW+3;
reg clk=0;always #5 clk=~clk;
reg rst_n=0,ce=1,pixel=0,sv=0,sof=0,eol=0,mr=0;
wire sr,hpixel,hole,hv,hs,he,hr,hd,hbusy,mv,md,mbusy,centroid_valid;
wire[31:0] filled_count,cx,cy;wire[3:0] herror,merror;
wire[63:0] m00,m10,m01,m20,m11,m02;
wire[448:0] payload={m00,m10,m01,m20,m11,m02,cx,cy,centroid_valid};
wire tv,tr,tvalue,tsof,teol,tlast,edone,eerror;
wire[XW-1:0] tx;wire[YW-1:0] ty;wire[LW-1:0] length;
wire dv,dr,dvalue,dsof,deol,dlast,ddone;wire[5:0] derror;
wire[XW-1:0] dx;wire[YW-1:0] dy;
wire[TW-1:0] token={tvalue,tx,ty,length,tsof,teol,tlast};
binary_hole_fill #(.WIDTH(W),.HEIGHT(H),.CONNECT8(E)) fill(
 .clk(clk),.rst_n(rst_n),.ce(ce),.s_pixel(pixel),.s_valid(sv),.s_sof(sof),.s_eol(eol),.s_ready(sr),
 .m_pixel(hpixel),.m_hole(hole),.m_valid(hv),.m_sof(hs),.m_eol(he),.m_ready(hr),
 .busy(hbusy),.done(hd),.filled_count(filled_count),.error_code(herror));
binary_rle_encoder #(.WIDTH(W),.HEIGHT(H)) encoder(
 .clk(clk),.rst(!rst_n),.ce(ce),.s_value(hpixel),.s_valid(hv),.s_sof(hs),.s_eol(he),.s_ready(hr),
 .m_value(tvalue),.m_start_x(tx),.m_y(ty),.m_length(length),.m_sof(tsof),.m_eol(teol),.m_last(tlast),
 .m_valid(tv),.m_ready(tr),.done_valid(edone),.done_ready(1'b1),.frame_error(eerror));
binary_rle_decoder #(.WIDTH(W),.HEIGHT(H)) decoder(
 .clk(clk),.rst(!rst_n),.ce(ce),.s_value(tvalue),.s_start_x(tx),.s_y(ty),.s_length(length),
 .s_sof(tsof),.s_eol(teol),.s_last(tlast),.s_valid(tv),.s_ready(tr),
 .m_value(dvalue),.m_x(dx),.m_y(dy),.m_sof(dsof),.m_eol(deol),.m_last(dlast),
 .m_valid(dv),.m_ready(dr),.done_valid(ddone),.done_ready(1'b1),.error(derror));
image_spatial_moments #(.WIDTH(W),.HEIGHT(H),.BITS(8),.MASK_ENABLE(1)) moments(
 .clk(clk),.rst_n(rst_n),.ce(ce),.binary_mode(1'b1),
 .s_pixel({7'b0,dvalue}),.s_mask(1'b1),.s_valid(dv),.s_sof(dsof),.s_eol(deol),.s_ready(dr),
 .m00(m00),.m10(m10),.m01(m01),.m20(m20),.m11(m11),.m02(m02),
 .centroid_x_q16(cx),.centroid_y_q16(cy),.centroid_valid(centroid_valid),
 .m_valid(mv),.m_ready(mr),.busy(mbusy),.done(md),.error_code(merror));
reg input_bits[0:F*N-1],expected_pixels[0:F*N-1];
reg[TW-1:0] expected_tokens[0:T-1];reg[448:0] expected_moments[0:F-1];
integer f=0,i,received=0,transferred=0,tokens=0,decoded=0,cycles=0,ep=0,dp=0;
reg hseen=0,take,held=0;reg[448:0] held_payload;reg[31:0] random_state=32'h941ab329;
always @(posedge clk)begin
 cycles=cycles+1;if(cycles>2000000)$fatal(1,"timeout");
 if(rst_n)begin
  if(held&&(!mv||payload!==held_payload))$fatal(1,"moments stalled payload changed");
  held=mv&&(!ce||!mr);held_payload=payload;
  if(ce&&hv&&hr)transferred=transferred+1;
  if(ce&&tv&&tr)begin
   if(tokens>=T||token!==expected_tokens[tokens])$fatal(1,"run token mismatch at %0d",tokens);
   tokens=tokens+1;
  end
  if(ce&&dv&&dr)begin
   if(decoded>=F*N||dvalue!==expected_pixels[decoded]||dx!==decoded%W||dy!==((decoded%N)/W)||
      dsof!==(decoded%N==0)||deol!==(decoded%W==W-1)||dlast!==(decoded%N==N-1))
      $fatal(1,"decoded pixel mismatch %0d",decoded);
   decoded=decoded+1;
  end
  if(ce&&edone)begin if(eerror)$fatal(1,"encoder error");ep=ep+1;end
  if(ce&&ddone)begin if(derror)$fatal(1,"decoder error");dp=dp+1;end
  if(ce&&mv&&mr)begin
   if(received>=F||payload!==expected_moments[received]||merror)$fatal(1,"moments mismatch %0d",received);
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
 $readmemh("input.hex",input_bits);$readmemh("pixels.hex",expected_pixels);
 $readmemh("tokens.hex",expected_tokens);$readmemh("moments.hex",expected_moments);
 repeat(3)@(negedge clk);#1;rst_n=1;
 for(f=0;f<F;f=f+1)begin
  i=0;hseen=0;
  while(i<N)begin
   pixel=input_bits[f*N+i];sof=i==0;eol=i%W==W-1;sv=1;
   @(posedge clk);take=ce&&sv&&sr;if(take)i=i+1;tick;
  end
  sv=0;
  while(!hseen||received!=f+1||ep!=f+1||dp!=f+1)tick;
  if(transferred!=(f+1)*N||decoded!=(f+1)*N)$fatal(1,"pixel counts");
  repeat(3)tick;
 end
 if(tokens!=T)$fatal(1,"token count");
 $display("FILL_RLE_MOMENTS PASS frames=%0d pixels=%0d tokens=%0d",F,decoded,tokens);$finish;
end
endmodule
'''


if __name__ == '__main__':
    folder = evidence_dir('fill_rle_moments')
    results = [profile(w,h,eight,folder) for w,h in ((11,9),(1,7),(7,1),(1,1)) for eight in (0,1)]
    write_json(folder/'results.json',dict(status='PASS',results=results,board_tested=False,
        oracle_source_sha256={name:hashlib.sha256(Path(__file__).with_name(name).read_bytes()).hexdigest()
                              for name in ('test_fill_components.py','test_fill_moments.py')},
        rtl_sha256={str(path.relative_to(ROOT)):hashlib.sha256(path.read_bytes()).hexdigest()
                    for path in SOURCES}))
    print(folder,flush=True)
