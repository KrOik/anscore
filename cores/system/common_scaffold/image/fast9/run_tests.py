"""Independent FAST circle-arc oracle, marker and random transport checks."""
from pathlib import Path
import hashlib,random,sys,tempfile
sys.path.insert(0,str(Path(__file__).resolve().parents[2]/'integration'))
from tooling import ROOT,execute,evidence_dir,write_json
HERE=Path(__file__).resolve().parent
CIRCLE=((0,-3),(1,-3),(2,-2),(3,-1),(3,0),(3,1),(2,2),(1,3),
        (0,3),(-1,3),(-2,2),(-3,1),(-3,0),(-3,-1),(-2,-2),(-1,-3))

def oracle(pixels,width,height,threshold):
    values=[]
    for y in range(height):
        for x in range(width):
            strength=0
            if 3<=x<width-3 and 3<=y<height-3:
                center=pixels[y*width+x]
                ring=[pixels[(y+dy)*width+x+dx]-center for dx,dy in CIRCLE]
                for start in range(16):
                    arc=[ring[(start+k)%16] for k in range(9)]
                    if min(arc)>0:strength=max(strength,min(arc))
                    if max(arc)<0:strength=max(strength,-max(arc))
            values.append((max(0,strength-1),int(strength>threshold)))
    return values

def run(bits,width,height,folder):
    rng=random.Random(bits*width+height);limit=(1<<bits)-1
    frames=[([rng.randrange(limit+1) for _ in range(width*height)],20),([100]*(width*height),0)]
    if width>=7 and height>=7:
        for length,dark,threshold in ((9,False,99),(9,False,100),(9,True,40),(8,False,0)):
            center=200 if dark else 100;pixels=[center]*(width*height);cx=width//2;cy=height//2
            for k in range(length):
                dx,dy=CIRCLE[(13+k)%16];pixels[(cy+dy)*width+cx+dx]=100 if dark else 200
            frames.append((pixels,threshold))
    expected=[];samples=[];configs=[]
    for pixels,threshold in frames:
        samples.extend(pixels);expected.extend(s|(c<<bits) for s,c in oracle(pixels,width,height,threshold));configs.append(threshold)
    label=f'b{bits}_{width}x{height}'
    with tempfile.TemporaryDirectory(prefix='fast9_') as temp:
        p=Path(temp)
        for name,data in (('pixels',samples),('expected',expected),('config',configs)):
            (p/f'{name}.hex').write_text(''.join(f'{v:x}\n' for v in data),encoding='utf-8')
        tb='''`timescale 1ns/1ps
module tb;
localparam B=BB,W=WW,H=HH,N=W*H,F=FF;
reg clk=0;always #5 clk=~clk;
reg rst=0,ce=1,cv=0,sv=0,sf=0,se=0,mr=0,dr=0;
reg[B-1:0]sd,threshold;wire cr,sr,mv,corner,ms,ml,dv,error;wire[B-1:0]score;
reg[B-1:0]pixels[0:N*F-1],configurations[0:F-1];reg[B:0]expected[0:N*F-1];
integer sent=0,received=0,frame=0,cycles=0;reg accepted=0,held=0;reg[B+2:0]previous;
reg[31:0]rnd=32'h121baba;
img_fast9_frame #(.BITS(B),.WIDTH(W),.HEIGHT(H)) d(clk,rst,ce,cv,cr,threshold,sd,sv,sr,sf,se,
score,corner,mv,mr,ms,ml,dv,dr,error);
always @(posedge clk)if(rst)begin
accepted=ce&&sv&&sr;if(accepted)sent=sent+1;
if(ce&&mv&&mr)begin
if({corner,score}!==expected[frame*N+received]||ms!==(received==0)||ml!==(received%W==W-1))
$fatal(1,"FAST frame %d pixel %d got %d %d expected %h",frame,received,corner,score,expected[frame*N+received]);
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
$readmemh("pixels.hex",pixels);$readmemh("expected.hex",expected);$readmemh("config.hex",configurations);
repeat(3)@(negedge clk);#1;rst=1;
for(frame=0;frame<F;frame=frame+1)begin
sent=0;received=0;
@(negedge clk);#1;cv=1;threshold=configurations[frame];
@(posedge clk);while(!(ce&&cr))@(posedge clk);
@(negedge clk);#1;cv=0;
while(sent<N)begin
@(negedge clk);#1;
if(!sv||accepted)begin sv=sent<N&&(rnd[3]||rnd[8]);if(sent<N)begin sd=pixels[frame*N+sent];sf=sent==0;se=sent%W==W-1;end end
end
@(negedge clk);#1;sv=0;
wait(dv);if(received!=N||error)$fatal(1,"frame result");
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
$display("FAST9 PASS frames=%0d pixels=%0d",F,N*F);$finish;
end endmodule
'''
        for name,value in (('BB',bits),('WW',width),('HH',height),('FF',len(frames))):tb=tb.replace(name,str(value))
        (p/'tb.sv').write_text(tb,encoding='utf-8')
        execute(['iverilog','-g2012','-s','tb','-o',p/'sim',HERE/'img_fast9_frame.sv',p/'tb.sv'],p,folder/f'{label}_compile.log')
        text=execute(['vvp',p/'sim'],p,folder/f'{label}_simulation.log')
        assert 'FAST9 PASS' in text
    return {'bits':bits,'width':width,'height':height,'frames':len(frames),'pixels':len(expected),'status':'PASS'}

def main():
    folder=evidence_dir('fast9')
    cases=[run(b,w,h,folder) for b,w,h in ((8,7,7),(8,11,9),(10,8,8),(12,1,1),(12,9,7))]
    external={'status':'UNAVAILABLE','reason':'optional OpenCV dependency not installed'}
    try:
        import cv2
        import numpy as np
    except ImportError:
        pass
    else:
        rng=random.Random(91216)
        for threshold in (0,1,20,99,254,255):
            for width,height in ((7,7),(19,13),(32,24)):
                pixels=[rng.randrange(256) for _ in range(width*height)]
                detector=cv2.FastFeatureDetector_create(threshold=threshold,nonmaxSuppression=False,type=cv2.FAST_FEATURE_DETECTOR_TYPE_9_16)
                actual={(int(k.pt[0]),int(k.pt[1])) for k in detector.detect(np.array(pixels,dtype=np.uint8).reshape(height,width))}
                expected={(i%width,i//width) for i,(_,corner) in enumerate(oracle(pixels,width,height,threshold)) if corner}
                assert actual==expected, (threshold,width,height,actual^expected)
        external={'status':'PASS','version':cv2.__version__,'images':18,'scope':'8-bit corner coordinates, nonmax disabled'}
    write_json(folder/'result.json',{'status':'PASS','cases':cases,'opencv_crosscheck':external,'board_tested':False,'rtl_sha256':hashlib.sha256((HERE/'img_fast9_frame.sv').read_bytes()).hexdigest()})
    print(cases);print(folder)
if __name__=='__main__':main()
