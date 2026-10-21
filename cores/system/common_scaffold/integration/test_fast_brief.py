"""Real FAST9 -> corner NMS -> runtime BRIEF RTL, with a pixel-level oracle."""
import hashlib
import random
import tempfile
from pathlib import Path

from tooling import PACKAGE, ROOT, evidence_dir, execute, write_json

SOURCES = [PACKAGE / name for name in (
    'image/fast9/img_fast9_frame.sv',
    'image/corner_nms/img_corner_nms.v',
    'image/brief/brief_descriptor.sv',
)]
CIRCLE = ((0,-3),(1,-3),(2,-2),(3,-1),(3,0),(3,1),(2,2),(1,3),
          (0,3),(-1,3),(-2,2),(-3,1),(-3,0),(-3,-1),(-2,-2),(-1,-3))


def oracle(image, width, height, pattern, threshold):
    scores = [0] * len(image)
    for y in range(3, height-3):
        for x in range(3, width-3):
            center = image[y*width+x]
            ring = [image[(y+dy)*width+x+dx]-center for dx,dy in CIRCLE]
            strength = max([0] + [max(min(ring[(start+k)%16] for k in range(9)),
                                      -max(ring[(start+k)%16] for k in range(9)))
                                  for start in range(16)])
            scores[y*width+x] = max(0, strength-1)
    result = []
    for y in range(1, height-1):
        for x in range(1, width-1):
            index = y*width+x
            if scores[index] <= threshold:
                continue
            neighbors = [(y+dy)*width+x+dx for dy in (-1,0,1) for dx in (-1,0,1)
                         if dx or dy]
            if any(scores[n] > scores[index] or (scores[n] == scores[index] and n < index)
                   for n in neighbors):
                continue
            descriptor = sum(int(image[(y+ay)*width+x+ax] < image[(y+by)*width+x+bx]) << bit
                             for bit,(ax,ay,bx,by) in enumerate(pattern))
            result.append((index,x,y,descriptor))
    return result


def profile(bits, length, folder):
    width,height,radius = 13,11,2
    rng = random.Random(14701+bits+length)
    maximum = (1 << bits)-1
    pattern = [(0,0,0,0)] + [tuple(rng.randint(-radius,radius) for _ in range(4))
                             for _ in range(length-1)]
    images = [[0]*(width*height), [maximum]*(width*height)]
    images += [[rng.randrange(maximum+1) for _ in range(width*height)] for _ in range(4)]
    image = [0]*(width*height)
    for dx,dy in CIRCLE:
        image[(height//2+dy)*width+width//2+dx] = maximum
    images.append(image)
    threshold = maximum//16
    expected = [oracle(image,width,height,pattern,threshold) for image in images]
    assert not expected[0] and not expected[1] and expected[-1]
    flattened = [item for frame in expected for item in frame]
    assert flattened
    label = f'b{bits}_d{length}'
    with tempfile.TemporaryDirectory(prefix='fast_nms_brief_') as temporary:
        td = Path(temporary)
        def mem(name, values):
            (td/name).write_text(''.join(f'{value:x}\n' for value in values), encoding='utf-8')
        mem('pixels.hex', [pixel for image in images for pixel in image])
        mem('pattern.hex', [sum((value & 255) << (24-8*i) for i,value in enumerate(pair))
                            for pair in pattern])
        mem('descriptors.hex', [item[3] for item in flattened])
        mem('metadata.hex', [(item[0] << 32) | (item[1] << 16) | item[2] for item in flattened])
        mem('counts.hex', [len(frame) for frame in expected])
        text = TB
        for token,value in {'BITS':bits,'DESC':length,'WIDTH':width,'HEIGHT':height,
                            'RADIUS':radius,'FRAMES':len(images),'OUTPUTS':len(flattened),
                            'THRESHOLD':threshold}.items():
            text = text.replace('@'+token+'@',str(value))
        (td/'tb.sv').write_text(text,encoding='utf-8')
        execute(['iverilog','-g2012','-s','tb','-o',td/'sim',*SOURCES,td/'tb.sv'],
                td,folder/f'{label}_compile.log')
        output = execute(['vvp',td/'sim'],td,folder/f'{label}_simulation.log',timeout=120)
        assert 'FAST_NMS_BRIEF PASS' in output,output
    print(label,len(images),'frames',len(flattened),'descriptors PASS',flush=True)
    return dict(bits=bits,descriptor_bits=length,frames=len(images),
                descriptors=len(flattened),status='PASS')


TB = r'''
module tb;
localparam B=@BITS@,D=@DESC@,W=@WIDTH@,H=@HEIGHT@,R=@RADIUS@,F=@FRAMES@,O=@OUTPUTS@;
reg clk=0;always #5 clk=~clk;
reg rst_n=0,ce=1,sv=0,sof=0,eol=0,pv=0,cv=0,ncfg=0,mr=0,ack=0;
reg [B-1:0] pixel;
reg [7:0] pi;reg [31:0] pd;
wire fr,br,pr,cr,cd,cerr,fv,fc,fs,fe,fd,ferr,nv,nc,ns,ne,nd,nerr,nready,kr,rr,loaded,mv,invalid,nsr,ncr;
wire [B-1:0] score,nscore;wire[1:0] reason,nerror;wire[3:0] berror;
wire [D-1:0] descriptor;wire[15:0] mx,my,mid;
integer xpos=0,ypos=0;
wire[15:0] kx=xpos,ky=ypos,kid=ypos*W+xpos;
assign nready=!nc||kr;
img_fast9_frame #(.BITS(B),.WIDTH(W),.HEIGHT(H)) fast(
 .clk(clk),.rst_n(rst_n),.ce(ce),.cfg_valid(1'b0),.cfg_ready(),.cfg_threshold({B{1'b0}}),
 .s_data(pixel),.s_valid(sv&&br),.s_ready(fr),.s_sof(sof),.s_eol(eol),
 .m_score(score),.m_corner(fc),.m_valid(fv),.m_ready(nsr),.m_sof(fs),.m_eol(fe),
 .done_valid(fd),.done_ready(ack),.frame_error(ferr));
img_corner_nms #(.BITS(B),.WIDTH(W),.HEIGHT(H),.KEEP_BORDER(0)) nms(
 .clk(clk),.rst_n(rst_n),.clk_en(ce),.cfg_valid(ncfg),.cfg_ready(ncr),.cfg_threshold(B'(@THRESHOLD@)),.cfg_done(),
 .s_score(score),.s_valid(fv),.s_ready(nsr),.s_sof(fs),.s_eol(fe),
 .m_score(nscore),.m_corner(nc),.m_reason(reason),.m_valid(nv),.m_ready(nready),.m_sof(ns),.m_eol(ne),
 .done_valid(nd),.done_ready(ack),.done_error(nerr),.error_code(nerror));
brief_descriptor #(.BITS(B),.WIDTH(W),.HEIGHT(H),.DESC_BITS(D),.RADIUS(R)) brief(
 .clk(clk),.rst_n(rst_n),.ce(ce),.pattern_valid(pv),.pattern_ready(pr),.pattern_index(pi),
 .pattern_ax(pd[31:24]),.pattern_ay(pd[23:16]),.pattern_bx(pd[15:8]),.pattern_by(pd[7:0]),
 .cfg_valid(cv),.cfg_ready(cr),.cfg_done(cd),.cfg_error(cerr),
 .s_pixel(pixel),.s_valid(sv&&fr),.s_sof(sof),.s_eol(eol),.s_ready(br),
 .kp_valid(nv&&nc),.kp_ready(kr),.kp_x(kx),.kp_y(ky),.kp_id(kid),
 .release_valid(ack),.release_ready(rr),.frame_available(loaded),
 .m_descriptor(descriptor),.m_invalid(invalid),.m_valid(mv),.m_x(mx),.m_y(my),.m_id(mid),.m_ready(mr),.error_code(berror));
reg[B-1:0] pixels[0:F*W*H-1];reg[31:0] patterns[0:D-1];
reg[D-1:0] expected[0:O-1];reg[47:0] metadata[0:O-1];integer counts[0:F-1];
integer received=0,cycles=0,f,i,target=0;
reg[31:0] random_state=32'h46ac7139;reg held=0;reg[D+48:0] hold_payload;reg take;
always @(posedge clk) begin
 cycles=cycles+1;if(cycles>1000000)$fatal(1,"timeout");
 if(rst_n)begin
  if(held&&(!mv||{descriptor,invalid,mid,mx,my}!==hold_payload))$fatal(1,"stalled descriptor changed");
  held=mv&&(!ce||!mr);hold_payload={descriptor,invalid,mid,mx,my};
  if(ce&&nv&&nready)begin
   if(ns!==(xpos==0&&ypos==0)||ne!==(xpos==W-1))$fatal(1,"NMS raster markers");
   if(xpos==W-1)begin xpos<=0;ypos<=ypos+1;end else xpos<=xpos+1;
  end
  if(ce&&mv&&mr)begin
   if(received>=O)$fatal(1,"unexpected descriptor");
   if(invalid||descriptor!==expected[received]||{mid,mx,my}!==metadata[received])
    $fatal(1,"descriptor or metadata mismatch index=%0d",received);
   received=received+1;
  end
 end
end
task tick;begin
 @(negedge clk);#1;
 random_state=random_state^(random_state<<13);random_state=random_state^(random_state>>17);random_state=random_state^(random_state<<5);
 ce=random_state[0]|random_state[1];mr=random_state[2]|random_state[4];
end endtask
initial begin
 $readmemh("pixels.hex",pixels);$readmemh("pattern.hex",patterns);$readmemh("descriptors.hex",expected);
 $readmemh("metadata.hex",metadata);$readmemh("counts.hex",counts);
 repeat(3)@(negedge clk);#1;rst_n=1;
 for(i=0;i<D;i=i+1)begin pv=1;pi=i;pd=patterns[i];@(negedge clk);#1;if(!pr)$fatal(1,"pattern ready");end
 pv=0;cv=1;@(negedge clk);#1;cv=0;while(!cd)@(negedge clk);#1;
 if(cerr)$fatal(1,"config rejected");
 ncfg=1;@(negedge clk);#1;ncfg=0;
 for(f=0;f<F;f=f+1)begin
  i=0;
  while(i<W*H)begin
   pixel=pixels[f*W*H+i];sof=i==0;eol=i%W==W-1;sv=1;
   @(posedge clk);take=ce&&sv&&fr&&br;if(take)i=i+1;tick;
  end
  sv=0;target=target+counts[f];
  while(!fd||!nd||!rr)tick;
  if(received!=target||ferr||nerr||berror||xpos!=0||ypos!=H)$fatal(1,"frame completion");
  ce=1;ack=1;@(negedge clk);#1;ack=0;xpos=0;ypos=0;
 end
 if(received!=O)$fatal(1,"final count");
 $display("FAST_NMS_BRIEF PASS frames=%0d descriptors=%0d",F,received);$finish;
end
endmodule
'''


if __name__ == '__main__':
    folder = evidence_dir('fast_nms_brief')
    results = [profile(bits,length,folder) for bits,length in ((8,128),(12,256))]
    write_json(folder/'results.json',dict(status='PASS',results=results,board_tested=False,
        rtl_sha256={str(path.relative_to(ROOT)):hashlib.sha256(path.read_bytes()).hexdigest()
                    for path in SOURCES}))
    print(folder,flush=True)
