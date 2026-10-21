"""Independent row-major Census oracle, one-hot bit ordering, and randomized transport."""
from pathlib import Path
import hashlib,random,sys,tempfile
sys.path.insert(0,str(Path(__file__).resolve().parents[2]/'integration'))
from tooling import ROOT,execute,evidence_dir,write_json
HERE=Path(__file__).resolve().parent
def oracle(pixels,width,height,threshold,radius):
    output=[]
    for y in range(height):
        for x in range(width):
            border=not(radius<=x<width-radius and radius<=y<height-radius)
            descriptor=0
            if not border:
                neighbors=[pixels[(y+dy)*width+x+dx] for dy in range(-radius,radius+1) for dx in range(-radius,radius+1) if dx or dy]
                center=pixels[y*width+x]
                descriptor=sum((int(center-value>threshold)<<i) for i,value in enumerate(neighbors))
            output.append((descriptor,int(border)))
    return output

def run(bits,width,height,radius,folder):
    count=(2*radius+1)**2-1
    rng=random.Random(bits*width+height);limit=(1<<bits)-1
    frames=[([rng.randrange(limit+1) for _ in range(width*height)],20),([100]*(width*height),0)]
    frames.extend([([i%256 for i in range(width*height)],0),([rng.randrange(limit+1) for _ in range(width*height)],limit)])
    if width>=2*radius+1 and height>=2*radius+1:
        offsets=[(dx,dy) for dy in range(-radius,radius+1) for dx in range(-radius,radius+1) if dx or dy]
        # One bit at a time checks ordering and center omission, including the final bit.
        for selected,(dx,dy) in enumerate(offsets):
            pixels=[100]*(width*height);cx=width//2;cy=height//2
            pixels[(cy+dy)*width+cx+dx]=0
            frames.append((pixels,99))
        pixels=[100]*(width*height);pixels[(height//2)*width+width//2]=200
        frames.append((pixels,100))
    expected=[];samples=[];configs=[]
    for pixels,threshold in frames:
        samples.extend(pixels);expected.extend(s|(c<<count) for s,c in oracle(pixels,width,height,threshold,radius));configs.append(threshold)
    label=f'b{bits}_{width}x{height}_r{radius}'
    with tempfile.TemporaryDirectory(prefix='census_') as temp:
        p=Path(temp)
        for name,data in (('pixels',samples),('expected',expected),('config',configs)):
            (p/f'{name}.hex').write_text(''.join(f'{v:x}\n' for v in data),encoding='utf-8')
        tb='''`timescale 1ns/1ps
module tb;
localparam B=BB,W=WW,H=HH,N=W*H,F=FF,R=RR,C=(2*R+1)*(2*R+1)-1;
reg clk=0;always #5 clk=~clk;
reg rst=0,ce=1,cv=0,sv=0,sf=0,se=0,mr=0,dr=0;
reg[B-1:0]sd,threshold;wire cr,sr,mv,corner,ms,ml,dv,error;wire[C-1:0]score;
reg[B-1:0]pixels[0:N*F-1],configurations[0:F-1];reg[C:0]expected[0:N*F-1];
integer sent=0,received=0,frame=0,cycles=0;reg accepted=0,held=0;reg[C+2:0]previous;
reg[31:0]rnd=32'h121baba;
img_census_frame #(.BITS(B),.WIDTH(W),.HEIGHT(H),.RADIUS(R)) d(clk,rst,ce,cv,cr,threshold,sd,sv,sr,sf,se,
score,corner,mv,mr,ms,ml,dv,dr,error);
always @(posedge clk)if(rst)begin
accepted=ce&&sv&&sr;if(accepted)sent=sent+1;
if(ce&&mv&&mr)begin
if({corner,score}!==expected[frame*N+received]||ms!==(received==0)||ml!==(received%W==W-1))
$fatal(1,"CENSUS frame %d pixel %d got %d %d expected %h",frame,received,corner,score,expected[frame*N+received]);
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
if(frame==1)begin
@(negedge clk);#1;sv=1;sf=0;se=(W==1);sd=0;
@(posedge clk);while(!(ce&&sr))@(posedge clk);
@(negedge clk);#1;sv=0;wait(dv);if(!error||mv)$fatal(1,"bad frame before recovery");
@(negedge clk);#1;dr=1;
@(posedge clk);while(!ce)@(posedge clk);
@(negedge clk);#1;dr=0;sent=0;received=0;accepted=0;
end
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
$display("CENSUS PASS frames=%0d pixels=%0d",F,N*F);$finish;
end endmodule
'''
        for name,value in (('BB',bits),('WW',width),('HH',height),('FF',len(frames)),('RR',radius)):tb=tb.replace(name,str(value))
        (p/'tb.sv').write_text(tb,encoding='utf-8')
        execute(['iverilog','-g2012','-s','tb','-o',p/'sim',HERE/'img_census_frame.sv',p/'tb.sv'],p,folder/f'{label}_compile.log')
        text=execute(['vvp',p/'sim'],p,folder/f'{label}_simulation.log')
        assert 'CENSUS PASS' in text
    return {'bits':bits,'width':width,'height':height,'radius':radius,'frames':len(frames),'pixels':len(expected),'status':'PASS'}

def main():
    folder=evidence_dir('census')
    cases=[run(b,w,h,r,folder) for b,w,h,r in ((8,5,5,1),(8,9,7,2),(10,8,8,1),(12,1,1,2),(16,7,9,2),(12,1,7,1),(8,7,1,2))]
    write_json(folder/'result.json',{'status':'PASS','cases':cases,'board_tested':False,'rtl_sha256':hashlib.sha256((HERE/'img_census_frame.sv').read_bytes()).hexdigest()})
    print(cases);print(folder)
if __name__=='__main__':main()
