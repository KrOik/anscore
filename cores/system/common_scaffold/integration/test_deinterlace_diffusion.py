"""Real fields -> progressive -> error diffusion -> RLE -> moments RTL."""
import hashlib
from pathlib import Path
import random
import tempfile

from test_fill_moments import expected_moments
from tooling import PACKAGE, ROOT, evidence_dir, execute, write_json

SOURCES = [PACKAGE/'image/deinterlace/deinterlace_fields.sv',
           PACKAGE/'image/error_diffusion/floyd_steinberg.sv',
           PACKAGE/'image/binary_rle/binary_rle_encoder.v',
           PACKAGE/'image/binary_rle/binary_rle_decoder.v',
           PACKAGE/'image/moments/image_spatial_moments.sv']


def progressive(image,w,h,first,mode,threshold):
    """The paired fields' spatial samples form image; retain the newer field."""
    newest = 1-first if h>1 else 0
    out = []
    for y in range(h):
        for x in range(w):
            older = image[y*w+x]
            if y%2==newest or mode==0:
                out.append(older)
                continue
            candidates = [r for r in (y-1,y+1) if 0<=r<h and r%2==newest]
            assert candidates
            bob = (sum(image[r*w+x] for r in candidates)+len(candidates)//2)//len(candidates)
            out.append(bob if mode==1 or abs(older-bob)>threshold else older)
    return out


def diffusion(image,w,h,serpentine):
    errors = [0]*(w*h)
    codes = [0]*(w*h)
    def round_signed(v):
        return (1 if v>=0 else -1)*((abs(v)+8)//16)
    for y in range(h):
        direction = -1 if serpentine and y%2 else 1
        order = range(w-1,-1,-1) if direction<0 else range(w)
        for x in order:
            i = y*w+x
            corrected = min(255*16,max(0,image[i]*16+errors[i]))
            code = (corrected+2040)//4080
            codes[i] = code
            residual = corrected-code*255*16
            for dx,dy,weight in ((direction,0,7),(-direction,1,3),(0,1,5),(direction,1,1)):
                xx,yy=x+dx,y+dy
                if 0<=xx<w and yy<h:
                    errors[yy*w+xx] += round_signed(residual*weight)
    return codes


def profile(w,h,folder):
    n=w*h
    rng=random.Random(65981+w*h)
    fixtures=[[0]*n,[255]*n,[128]*n,
              [x*255//max(1,w-1) for y in range(h) for x in range(w)],
              [((y%2)*180+30+x*3)%256 for y in range(h) for x in range(w)],
              [255*((x+y)%2) for y in range(h) for x in range(w)]]
    fixtures += [[rng.randrange(256) for _ in range(n)] for _ in range(6)]
    stimulus=[];deinterlaced=[];dithered=[];moments=[];brightness_errors=[]
    for f,image in enumerate(fixtures):
        first=f%2 if h>1 else 0
        mode=f%3;threshold=(f*19)%128
        if h==1:
            coordinates=[(x,0,1 if x==0 else 0,0) for x in range(w)]
        else:
            coordinates=[(x,y,int(j==0 and x==0),parity)
                         for parity in (first,1-first)
                         for j,y in enumerate(range(parity,h,2)) for x in range(w)]
        stimulus.extend((parity<<10)|(fs<<9)|(int(x==w-1)<<8)|image[y*w+x]
                        for x,y,fs,parity in coordinates)
        frame=progressive(image,w,h,first,mode,threshold)
        codes=diffusion(frame,w,h,f%2)
        brightness_errors.append(abs(sum(frame)-255*sum(codes))/(n*255))
        deinterlaced.extend(frame);dithered.extend(codes)
        moments.append(expected_moments(codes,w))
    label=f'{w}x{h}'
    with tempfile.TemporaryDirectory(prefix='deinterlace_diffusion_') as temporary:
        td=Path(temporary)
        for name,values in (('input',stimulus),('progressive',deinterlaced),('codes',dithered),('moments',moments)):
            (td/(name+'.hex')).write_text(''.join(f'{v:x}\n' for v in values),encoding='utf-8')
        tb=TB
        for key,value in dict(W=w,H=h,F=len(fixtures)).items():
            tb=tb.replace('@'+key+'@',str(value))
        (td/'tb.sv').write_text(tb,encoding='utf-8')
        execute(['iverilog','-g2012','-s','tb','-o',td/'sim',*SOURCES,td/'tb.sv'],
                td,folder/f'{label}_compile.log')
        result=execute(['vvp',td/'sim'],td,folder/f'{label}_simulation.log',timeout=180)
        assert 'DEINTERLACE_DIFFUSION PASS' in result,result
    print(label,len(fixtures),'frames',n*len(fixtures),'pixels PASS',flush=True)
    return dict(width=w,height=h,frames=len(fixtures),pixels=n*len(fixtures),status='PASS',
                maximum_normalized_frame_mean_error=max(brightness_errors),
                mean_normalized_frame_mean_error=sum(brightness_errors)/len(brightness_errors))


TB=r'''
module tb;
localparam W=@W@,H=@H@,F=@F@,N=W*H;
localparam XW=W<2?1:$clog2(W),YW=H<2?1:$clog2(H),LW=$clog2(W+1);
reg clk=0;always #5 clk=~clk;
reg rst_n=0,ce=1,sv=0,fs=0,le=0,parity=0,mr=0;
reg[7:0] pixel=0,threshold=0;reg[1:0] mode=0;reg first=0,serp=0;
wire sr,pv,pr,ps,pe,pbob,pbusy,pdone;wire[7:0] pp;wire[3:0] perror;
wire qv,qr,qs,qe,ql,qdone,qerror;wire[7:0] qp;wire[0:0] code;wire[15:0] qx,qy;
wire tv,tr,tvalue,ts,te,tl,edone,eerror;wire[XW-1:0] tx;wire[YW-1:0] ty;wire[LW-1:0] length;
wire dv,dr,dvalue,ds,de,dl,ddone;wire[XW-1:0] dx;wire[YW-1:0] dy;wire[5:0] derror;
wire mv,md,mbusy,centroid_valid;wire[3:0] merror;wire[31:0] cx,cy;
wire[63:0] m00,m10,m01,m20,m11,m02;
wire[448:0] payload={m00,m10,m01,m20,m11,m02,cx,cy,centroid_valid};
deinterlace_fields #(.WIDTH(W),.HEIGHT(H),.BITS(8)) fields(
 .clk(clk),.rst_n(rst_n),.ce(ce),.s_pixel(pixel),.s_parity(parity),.s_field_sof(fs),.s_eol(le),.s_valid(sv),.s_ready(sr),
 .cfg_mode(mode),.cfg_first_parity(first),.cfg_threshold(threshold),
 .m_pixel(pp),.m_bob_used(pbob),.m_valid(pv),.m_ready(pr),.m_sof(ps),.m_eol(pe),.busy(pbusy),.done(pdone),.error_code(perror));
floyd_steinberg #(.WIDTH(W),.HEIGHT(H),.BITS(8),.OUTPUT_BITS(1)) diffusion_core(
 .clk(clk),.rst_n(rst_n),.ce(ce),.cfg_serpentine(serp),
 .s_pixel(pp),.s_valid(pv),.s_ready(pr),.s_sof(ps),.s_eol(pe),
 .m_pixel(qp),.m_code(code),.m_x(qx),.m_y(qy),.m_valid(qv),.m_ready(qr),.m_sof(qs),.m_eol(qe),.m_last(ql),
 .done_valid(qdone),.done_ready(1'b1),.done_error(qerror));
binary_rle_encoder #(.WIDTH(W),.HEIGHT(H)) encoder(
 .clk(clk),.rst(!rst_n),.ce(ce),.s_value(code[0]),.s_valid(qv),.s_sof(qs),.s_eol(qe),.s_ready(qr),
 .m_value(tvalue),.m_start_x(tx),.m_y(ty),.m_length(length),.m_sof(ts),.m_eol(te),.m_last(tl),
 .m_valid(tv),.m_ready(tr),.done_valid(edone),.done_ready(1'b1),.frame_error(eerror));
binary_rle_decoder #(.WIDTH(W),.HEIGHT(H)) decoder(
 .clk(clk),.rst(!rst_n),.ce(ce),.s_value(tvalue),.s_start_x(tx),.s_y(ty),.s_length(length),
 .s_sof(ts),.s_eol(te),.s_last(tl),.s_valid(tv),.s_ready(tr),
 .m_value(dvalue),.m_x(dx),.m_y(dy),.m_sof(ds),.m_eol(de),.m_last(dl),
 .m_valid(dv),.m_ready(dr),.done_valid(ddone),.done_ready(1'b1),.error(derror));
image_spatial_moments #(.WIDTH(W),.HEIGHT(H),.BITS(8),.MASK_ENABLE(1)) moments(
 .clk(clk),.rst_n(rst_n),.ce(ce),.binary_mode(1'b1),
 .s_pixel({7'b0,dvalue}),.s_mask(1'b1),.s_valid(dv),.s_sof(ds),.s_eol(de),.s_ready(dr),
 .m00(m00),.m10(m10),.m01(m01),.m20(m20),.m11(m11),.m02(m02),
 .centroid_x_q16(cx),.centroid_y_q16(cy),.centroid_valid(centroid_valid),
 .m_valid(mv),.m_ready(mr),.busy(mbusy),.done(md),.error_code(merror));
reg[10:0] inputs[0:F*N-1];reg[7:0] expected_progressive[0:F*N-1];reg expected_codes[0:F*N-1];
reg[448:0] expected_moments[0:F-1];
integer f=0,i,pc=0,qc=0,dc=0,mc=0,pd=0,qd=0,ed=0,dd=0,cycles=0;
reg take,held=0;reg[448:0] held_payload;reg[31:0] random_state=32'h317b9285;
always @(posedge clk)begin
 cycles=cycles+1;if(cycles>3000000)$fatal(1,"watchdog");
 if(rst_n)begin
  if(held&&(!mv||payload!==held_payload))$fatal(1,"moments unstable");
  held=mv&&(!ce||!mr);held_payload=payload;
  if(ce&&pv&&pr)begin
   if(pc>=F*N||pp!==expected_progressive[pc]||ps!==(pc%N==0)||pe!==(pc%W==W-1))$fatal(1,"progressive mismatch %0d",pc);
   pc=pc+1;
  end
  if(ce&&qv&&qr)begin
   if(qc>=F*N||code[0]!==expected_codes[qc]||qp!==(expected_codes[qc]?8'd255:8'd0)||
      qx!==qc%W||qy!==((qc%N)/W)||qs!==(qc%N==0)||qe!==(qc%W==W-1)||ql!==(qc%N==N-1))$fatal(1,"diffusion mismatch %0d",qc);
   qc=qc+1;
  end
  if(ce&&dv&&dr)begin
   if(dc>=F*N||dvalue!==expected_codes[dc]||dx!==dc%W||dy!==((dc%N)/W)||
      ds!==(dc%N==0)||de!==(dc%W==W-1)||dl!==(dc%N==N-1))$fatal(1,"RLE mismatch %0d",dc);
   dc=dc+1;
  end
  if(ce&&mv&&mr)begin
   if(mc>=F||payload!==expected_moments[mc]||merror)$fatal(1,"moments mismatch %0d",mc);
   mc=mc+1;
  end
  if(ce&&pdone)begin if(perror)$fatal(1,"deinterlace error");pd=pd+1;end
  if(ce&&qdone)begin if(qerror)$fatal(1,"diffusion error");qd=qd+1;end
  if(ce&&edone)begin if(eerror)$fatal(1,"encoder error");ed=ed+1;end
  if(ce&&ddone)begin if(derror)$fatal(1,"decoder error");dd=dd+1;end
 end
end
task tick;begin
 @(negedge clk);#1;
 random_state=random_state^(random_state<<13);random_state=random_state^(random_state>>17);random_state=random_state^(random_state<<5);
 ce=random_state[0]|random_state[1];mr=random_state[2]|random_state[4];
end endtask
initial begin
 $readmemh("input.hex",inputs);$readmemh("progressive.hex",expected_progressive);
 $readmemh("codes.hex",expected_codes);$readmemh("moments.hex",expected_moments);
 repeat(3)@(negedge clk);#1;rst_n=1;
 for(f=0;f<F;f=f+1)begin
  mode=f%3;threshold=(f*19)%128;first=H>1?f%2:0;serp=f%2;i=0;
  while(i<N)begin
   {parity,fs,le,pixel}=inputs[f*N+i];sv=1;
   @(posedge clk);take=ce&&sv&&sr;if(take)i=i+1;tick;
  end
  sv=0;
  while(mc!=f+1||pd!=f+1||qd!=f+1||ed!=f+1||dd!=f+1)tick;
  if(pc!=(f+1)*N||qc!=(f+1)*N||dc!=(f+1)*N)$fatal(1,"pixel counts");
  repeat(3)tick;
 end
 $display("DEINTERLACE_DIFFUSION PASS frames=%0d pixels=%0d",F,dc);$finish;
end
endmodule
'''


if __name__=='__main__':
    folder=evidence_dir('deinterlace_diffusion')
    results=[profile(w,h,folder) for w,h in ((9,7),(8,6),(1,7),(7,1),(1,1))]
    write_json(folder/'results.json',dict(status='PASS',results=results,board_tested=False,
        rtl_sha256={str(path.relative_to(ROOT)):hashlib.sha256(path.read_bytes()).hexdigest() for path in SOURCES},
        moment_oracle_sha256=hashlib.sha256(Path(__file__).with_name('test_fill_moments.py').read_bytes()).hexdigest()))
    print(folder,flush=True)
