"""Independent integer convolution oracle, OpenCV cross-check and multi-level transport."""
from pathlib import Path
import hashlib,random,sys,tempfile
sys.path.insert(0,str(Path(__file__).resolve().parents[2]/'integration'))
from tooling import ROOT,execute,evidence_dir,write_json
HERE=Path(__file__).resolve().parent

def reflect(value,size):
    if size==1:return 0
    while value<0 or value>=size:
        value=-value if value<0 else 2*size-2-value
    return value

def oracle(pixels,width,height,levels):
    result=[];weights=(1,4,6,4,1)
    for level in range(levels):
        ow=(width+1)//2;oh=(height+1)//2;next_pixels=[]
        for y in range(oh):
            for x in range(ow):
                total=sum(weights[dy+2]*weights[dx+2]*pixels[reflect(2*y+dy,height)*width+reflect(2*x+dx,width)] for dy in range(-2,3) for dx in range(-2,3))
                value=(total+128)//256;next_pixels.append(value)
                result.append((value,level,int(x==0 and y==0),int(x==ow-1)))
        pixels=next_pixels;width=ow;height=oh
    return result

def run(bits,width,height,levels,folder):
    rng=random.Random(bits*width+height);limit=(1<<bits)-1;n=width*height;l=max(1,(levels-1).bit_length())
    frames=[[rng.randrange(limit+1) for _ in range(n)],[0]*n,[limit]*n,[limit if i==n//2 else 0 for i in range(n)],[(i*23)% (limit+1) for i in range(n)],[limit if (i%width==0 or i//width==0) else 0 for i in range(n)]]
    expected=[];samples=[];external=0
    try:
        import cv2
        import numpy as np
    except ImportError:
        cv2=None
    for pixels in frames:
        values=oracle(pixels,width,height,levels)
        samples.extend(pixels);expected.extend(v|(lev<<bits)|(eol<<(bits+l))|(sof<<(bits+l+1)) for v,lev,sof,eol in values)
        if cv2 is not None:
            image=np.array(pixels,dtype=np.uint8 if bits==8 else np.uint16).reshape(height,width)
            for level in range(levels):
                image=cv2.pyrDown(image,borderType=cv2.BORDER_REFLECT_101)
                actual=image.reshape(-1).tolist();reference=[v for v,lev,_,_ in values if lev==level]
                assert actual==reference,('OpenCV',width,height,level)
                external+=1
    total=len(expected)//len(frames)
    label=f'b{bits}_{width}x{height}_l{levels}'
    with tempfile.TemporaryDirectory(prefix='pyramid_') as temp:
        p=Path(temp)
        for name,data in (('pixels',samples),('expected',expected)):
            (p/f'{name}.hex').write_text(''.join(f'{v:x}\n' for v in data),encoding='utf-8')
        tb='''`timescale 1ns/1ps
module tb;
localparam B=BB,W=WW,H=HH,N=W*H,F=FF,LV=LL,L=LV<=1?1:$clog2(LV),T=TT;
reg clk=0;always #5 clk=~clk;
reg rst=0,ce=1,cv=0,sv=0,sf=0,se=0,mr=0,dr=0;
reg[B-1:0]sd,threshold;wire cr,sr,mv,ms,ml,dv,error;wire[L-1:0]corner;wire[B-1:0]score;
reg[B-1:0]pixels[0:N*F-1],configurations[0:F-1];reg[B+L+1:0]expected[0:T*F-1];
integer sent=0,received=0,frame=0,cycles=0;reg accepted=0,held=0;reg[B+L+1:0]previous;
reg[31:0]rnd=32'h121baba;
img_gaussian_pyramid_frame #(.BITS(B),.WIDTH(W),.HEIGHT(H),.LEVELS(LV)) d(clk,rst,ce,sd,sv,sr,sf,se,
score,corner,mv,mr,ms,ml,dv,dr,error);
always @(posedge clk)if(rst)begin
accepted=ce&&sv&&sr;if(accepted)sent=sent+1;
if(ce&&mv&&mr)begin
if({ms,ml,corner,score}!==expected[frame*T+received])
$fatal(1,"PYRAMID frame %d pixel %d got %d %d expected %h",frame,received,corner,score,expected[frame*T+received]);
received=received+1;
end
end
always @(negedge clk)if(rst)begin
if(held&&{corner,score,ms,ml}!==previous)$fatal(1,"stall stability");
rnd={rnd[30:0],rnd[31]^rnd[21]^rnd[1]^rnd[0]};ce=rnd[1]||rnd[4];mr=rnd[7];
held=mv&&(!ce||!mr);previous={corner,score,ms,ml};cycles=cycles+1;
if(cycles>1000000)$fatal(1,"timeout");
end
initial begin
$readmemh("pixels.hex",pixels);$readmemh("expected.hex",expected);
repeat(3)@(negedge clk);#1;rst=1;
for(frame=0;frame<F;frame=frame+1)begin
sent=0;received=0;
if(frame==1)begin
@(negedge clk);#1;sv=1;sf=0;se=(W==1);sd=0;
@(posedge clk);while(!(ce&&sr))@(posedge clk);
@(negedge clk);#1;sv=0;wait(dv);if(!error||mv)$fatal(1,"bad frame before recovery");
@(negedge clk);#1;dr=1;
@(posedge clk);while(!ce)@(posedge clk);
@(negedge clk);#1;dr=0;sent=0;received=0;accepted=0;
end
while(sent<N)begin
@(negedge clk);#1;
if(!sv||accepted)begin sv=sent<N&&(rnd[3]||rnd[8]);if(sent<N)begin sd=pixels[frame*N+sent];sf=sent==0;se=sent%W==W-1;end end
end
@(negedge clk);#1;sv=0;
wait(dv);if(received!=T||error)$fatal(1,"frame result");
repeat(3)@(negedge clk);#1;dr=1;
@(posedge clk);while(!ce)@(posedge clk);
@(negedge clk);#1;dr=0;
end
// A malformed first marker produces an error result and no score stream.
@(negedge clk);#1;sv=1;sf=0;se=(W==1);sd=0;
@(posedge clk);while(!(ce&&sr))@(posedge clk);
@(negedge clk);#1;sv=0;wait(dv);if(!error||mv)$fatal(1,"marker rejection");
// Reset also aborts a stalled result and clears diagnostics.
rst=0;@(posedge clk);@(negedge clk);#1;if(dv||mv||error)$fatal(1,"reset");
$display("PYRAMID PASS frames=%0d pixels=%0d",F,T*F);$finish;
end endmodule
'''
        for name,value in (('BB',bits),('WW',width),('HH',height),('FF',len(frames)),('LL',levels),('TT',total)):tb=tb.replace(name,str(value))
        (p/'tb.sv').write_text(tb,encoding='utf-8')
        execute(['iverilog','-g2012','-s','tb','-o',p/'sim',HERE/'img_gaussian_pyramid_frame.sv',p/'tb.sv'],p,folder/f'{label}_compile.log')
        output=execute(['vvp',p/'sim'],p,folder/f'{label}_simulation.log');assert 'PYRAMID PASS' in output
    return dict(bits=bits,width=width,height=height,levels=levels,frames=len(frames),outputs=len(expected),opencv_levels_checked=external,status='PASS')

def main():
    folder=evidence_dir('gaussian_pyramid')
    cases=[run(b,w,h,l,folder) for b,w,h,l in ((8,9,7,3),(8,2,2,4),(8,1,5,3),(8,5,1,4),(8,1,1,4),(16,7,5,2),(10,8,8,1),(8,17,13,4))]
    write_json(folder/'result.json',dict(status='PASS',cases=cases,board_tested=False,rtl_sha256=hashlib.sha256((HERE/'img_gaussian_pyramid_frame.sv').read_bytes()).hexdigest()))
    print(cases);print(folder)
if __name__=='__main__':main()
