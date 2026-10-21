"""Independent image/geometry HOG reference and real RTL numerical regression."""
from pathlib import Path
import os,tempfile,subprocess,json,random,math
ROOT=Path(__file__).resolve().parent
OSS=ROOT.parents[3]/'tools/oss-cad-suite/oss-cad-suite'
os.environ['PATH']=os.pathsep.join([str(OSS/'bin'),str(OSS/'lib'),os.environ.get('PATH','')])
def approximate_coordinate(dx,dy):
    if not(dx or dy):return 0
    angle=math.degrees(math.atan2(dy,dx))%180
    x,y=abs(dx),abs(dy)
    # Four monotone polar octants, evaluated from the geometric direction.
    if angle<=45:coordinate=(576*y)//x if x else 0
    elif angle<=90:coordinate=1152-(576*x)//y
    elif angle<=135:coordinate=1152+(576*x)//y
    else:coordinate=2304-(576*y)//x
    return coordinate%2304

def orientation_audit():
    worst=(0,None)
    for dx in range(-255,256):
        for dy in range(-255,256):
            if not(dx or dy):continue
            approx=approximate_coordinate(dx,dy)*180/2304
            exact=math.degrees(math.atan2(dy,dx))%180
            error=abs(approx-exact);error=min(error,180-error)
            if error>worst[0]:worst=(error,(dx,dy))
    assert worst[0]<4.16,worst
    return {'exhaustive_gradient_pairs':511*511-1,'maximum_degrees':worst[0],'worst_gradient':worst[1],'bound_degrees':4.16}

def oracle(image,cw,ch,epsilon=1,exact_angles=False):
    h,w=len(image),len(image[0]);nx,ny=w//cw,h//ch
    cells=[[[0.0 if exact_angles else 0 for _ in range(9)] for x in range(nx)] for y in range(ny)]
    for y in range(ny*ch):
        for x in range(nx*cw):
            dx=image[y][min(w-1,x+1)]-image[y][max(0,x-1)]
            dy=image[min(h-1,y+1)][x]-image[max(0,y-1)][x]
            magnitude=abs(dx)+abs(dy)
            if not magnitude:continue
            coordinate=(math.degrees(math.atan2(dy,dx))%180)*256/20 if exact_angles else approximate_coordinate(dx,dy)
            base=int(coordinate//256);fraction=coordinate-base*256
            cells[y//ch][x//cw][base]+=magnitude*(256-fraction)
            cells[y//ch][x//cw][(base+1)%9]+=magnitude*fraction
    descriptors=[]
    for by in range(ny-1):
        for bx in range(nx-1):
            values=[value for cy,cx in ((by,bx),(by,bx+1),(by+1,bx),(by+1,bx+1)) for value in cells[cy][cx]]
            den=sum(values)+epsilon
            descriptors.extend([v*65535/den for v in values] if exact_angles else [(v*65535+den//2)//den for v in values])
    return descriptors

def run():
    audit=orientation_audit();rng=random.Random(2026470);cases=[]
    with tempfile.TemporaryDirectory(prefix='hog_l1_') as temp:
        td=Path(temp)
        for bits,w,h,cw,ch in ((8,4,4,2,2),(8,7,5,3,2),(10,8,6,2,3),(12,5,7,2,2),(8,3,3,4,4),(8,4,4,4,2),(8,16,16,4,4)):
            d=(1<<bits)-1
            def ramp(ax,ay):
                lo=min(0,ax*(w-1))+min(0,ay*(h-1));hi=max(0,ax*(w-1))+max(0,ay*(h-1))
                return [[(ax*x+ay*y-lo)*d//max(1,hi-lo) for x in range(w)] for y in range(h)]
            images=[[[d//2]*w for _ in range(h)],ramp(1,0),ramp(0,1),ramp(1,1),ramp(-1,1),ramp(11,4),ramp(6,5),ramp(4,11),ramp(-11,4),[[rng.randrange(d+1) for x in range(w)] for y in range(h)],[[d if x==0 or y==0 or x==w-1 or y==h-1 else 0 for x in range(w)] for y in range(h)],[[0]*w for _ in range(h)]]
            expected=[];seq=[];max_exact_difference=0.0;counts=[]
            for fi,image in enumerate(images):
                approx=oracle(image,cw,ch);exact=oracle(image,cw,ch,exact_angles=True)
                if approx:max_exact_difference=max(max_exact_difference,max(abs(a-b) for a,b in zip(approx,exact)))
                expected+=approx;counts.append(len(approx))
                if fi==len(images)-1:seq.append('send_pixel(1,1,W==1); reset_dut;')
                for y,row in enumerate(image):
                    for x,value in enumerate(row):seq.append(f'send_pixel({value},{int(x==0 and y==0) if fi!=9 else 0},{int(x==w-1)});')
                seq.append(f'finish_frame({fi},{len(expected)},{int(fi==9)});')
            (td/'expected.hex').write_text('\n'.join(f'{v:x}' for v in expected) if expected else '0\n')
            tb=TB.replace('@BITS@',str(bits)).replace('@W@',str(w)).replace('@H@',str(h)).replace('@CW@',str(cw)).replace('@CH@',str(ch)).replace('@N@',str(max(1,len(expected)))).replace('@SEQ@','\n'.join(seq))
            (td/'tb.sv').write_text(tb)
            p=subprocess.run(['iverilog','-g2012','-s','tb','-o',str(td/'sim'),str(ROOT/'hog_l1_9.v'),str(td/'tb.sv')],capture_output=True,text=True)
            if p.returncode:raise RuntimeError(p.stderr)
            p=subprocess.run(['vvp',str(td/'sim')],cwd=td,capture_output=True,text=True)
            if p.returncode or 'PASS' not in p.stdout:raise RuntimeError(f'{bits}/{w}x{h}/{cw}x{ch}\n'+p.stdout+p.stderr)
            print(bits,w,h,cw,ch,p.stdout.splitlines()[0]);cases.append({'bits':bits,'width':w,'height':h,'cell':[cw,ch],'frames':len(images),'descriptor_values':len(expected),'max_difference_from_exact_angle_Q16':max_exact_difference})
        for name,value in (('BITS',7),('BITS',13),('WIDTH',0),('CELL_W',0),('CELL_H',33),('EPSILON',0)):
            (td/'bad.sv').write_text(f'module tb;hog_l1_9 #(.{name}({value})) d();endmodule')
            p=subprocess.run(['iverilog','-g2012','-s','tb','-o',str(td/'bad'),str(ROOT/'hog_l1_9.v'),str(td/'bad.sv')],capture_output=True)
            if p.returncode==0:assert subprocess.run(['vvp',str(td/'bad')],capture_output=True).returncode
    (ROOT/'test_result.json').write_text(json.dumps({'status':'PASS','orientation_audit':audit,'cases':cases,'invalid_parameters':6,'seed':2026470},indent=2)+'\n')
TB=r'''
module tb;
localparam B=@BITS@,W=@W@,H=@H@,CW=@CW@,CH=@CH@,NX=W/CW,NY=H/CH,BXW=NX<3?1:$clog2(NX-1),BYW=NY<3?1:$clog2(NY-1),DP=(NX>=2&&NY>=2)?(NX-1)*(NY-1)*36:0,SAFE_DP=DP>0?DP:1,SAFE_BX=NX>=2?NX-1:1,N=@N@;
reg clk=0;always #5 clk=~clk;
reg rst=1,ce=1,sv=0,sof=0,eol=0,mr=0,dr=0;reg[B-1:0] gray=0;
wire sr,mv,bl,last,done,marker,arithmetic,busy;wire[15:0] value;wire[BXW-1:0] bx;wire[BYW-1:0] by;wire[5:0] index;wire[1:0] cellid;wire[3:0] bin;
hog_l1_9 #(.BITS(B),.WIDTH(W),.HEIGHT(H),.CELL_W(CW),.CELL_H(CH)) dut(clk,rst,ce,gray,sv,sof,eol,sr,mv,mr,value,bx,by,index,cellid,bin,bl,last,done,dr,marker,arithmetic,busy);
reg[15:0] expected[0:N-1];integer received=0,cycles=0,local_index,block_index;reg[31:0] random_state=32'h172649;reg held=0;reg[15+BXW+BYW+6+2+4+2:0] payload;
always @(negedge clk)begin
 random_state={random_state[30:0],random_state[31]^random_state[21]^random_state[1]^random_state[0]};
 ce=random_state[0]|random_state[2];mr=random_state[3]|random_state[5];
end
always @(posedge clk)if(!rst)begin
 cycles=cycles+1;if(cycles>4000000)$fatal(1,"timeout");
 if(held&&(!mv||{value,bx,by,index,cellid,bin,bl,last}!==payload))$fatal(1,"stall payload");
 held=mv&&!(ce&&mr);payload={value,bx,by,index,cellid,bin,bl,last};
 if(ce&&mv&&mr)begin
 if(DP==0||received>=N||value!==expected[received])$fatal(1,"value %0d got%0d expected%0d",received,value,expected[received]);
 local_index=(received%SAFE_DP)%36;block_index=(received%SAFE_DP)/36;
 if(bx!==block_index%SAFE_BX||by!==block_index/SAFE_BX||index!==local_index||cellid!==local_index/9||bin!==local_index%9||bl!==(local_index==35)||last!==(received%SAFE_DP==DP-1))$fatal(1,"metadata");
 received=received+1;
 end
end
 task send_pixel(input[B-1:0] v,input first,lastpixel);begin
 repeat(v%2)@(negedge clk);#1;gray=v;sof=first;eol=lastpixel;sv=1;
 @(posedge clk);while(!sr)@(posedge clk);
 @(negedge clk);#1;sv=0;
 end endtask
 task finish_frame(input integer i,expected_count,expected_marker);begin
 while(!done)@(negedge clk);#1;
 if(received!=expected_count||marker!=expected_marker||arithmetic)$fatal(1,"terminal status frame%0d gotcount%0d expected%0d marker%0d arithmetic%0d",i,received,expected_count,marker,arithmetic);
 repeat(5)begin @(negedge clk);#1;if(!done||marker!=expected_marker||arithmetic)$fatal(1,"done stall");end
 dr=1;@(posedge clk);while(!ce)@(posedge clk);
 @(negedge clk);#1;dr=0;
 end endtask
 task reset_dut;begin
 @(negedge clk);#1;rst=1;sv=0;@(negedge clk);#1;rst=0;held=0;
 if(mv||done||marker||arithmetic)$fatal(1,"reset");
 end endtask
 initial begin
 $readmemh("expected.hex",expected);repeat(3)@(negedge clk);#1;rst=0;
 @SEQ@
 $display("PASS %0d exact HOG descriptor values and frame protocol",received);$finish;
 end
endmodule
'''
if __name__=='__main__':run()
