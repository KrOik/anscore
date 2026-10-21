"""Exhaustive 565 expansion and independent RGB quantization vectors."""
import hashlib,json,random,sys,tempfile
from pathlib import Path
sys.path.insert(0,str(Path(__file__).resolve().parents[2]/'integration'))
from tooling import ROOT,execute,evidence_dir,write_json
HERE=Path(__file__).resolve().parent

def run(pack,swap,rounding,folder):
    rng=random.Random(0x565+rounding)
    if pack:
        samples=[(v<<16)|(w<<8)|u for v in range(256) for w,u in
                 ((v,v),(0,255),(255,0),(v,255-v))]
        samples += [rng.randrange(1<<24) for _ in range(4096)]
    else: samples=list(range(65536))
    expected=[]
    for value in samples:
        if pack:
            r,g,b=value//65536,(value//256)%256,value%256
            q=lambda x,step: min(255//step,(x+(step//2 if rounding else 0))//step)
            out=q(r,8)*2048+q(g,4)*32+q(b,8)
            if swap: out=(out%256)*256+out//256
        else:
            pixel=(value%256)*256+value//256 if swap else value
            r,g,b=pixel//2048,(pixel//32)%64,pixel%32
            rr,gg,bb=r*8+r//4,g*4+g//16,b*8+b//4
            out=rr*65536+gg*256+bb
            assert (rr//8)*2048+(gg//4)*32+bb//8==pixel
        expected.append(out)
    label=f'p{pack}_s{swap}_r{rounding}'
    with tempfile.TemporaryDirectory(prefix='rgb565_') as temp:
        p=Path(temp)
        (p/'in.hex').write_text(''.join(f'{v:x}\n' for v in samples),encoding='utf-8')
        (p/'out.hex').write_text(''.join(f'{v:x}\n' for v in expected),encoding='utf-8')
        tb='''`timescale 1ns/1ps
module tb;
reg clk=0;always #5 clk=~clk;
reg rst=0,ce=1,sv=0,sf=0,se=0,mr=0;
reg[IW-1:0]sd;wire sr,mv,mf,me;wire[OW-1:0]md;
reg[IW-1:0]inputs[0:N-1];reg[OW-1:0]outputs[0:N-1];
integer sent=0,received=0,cycles=0;reg accepted=0;reg[31:0]lfsr=32'h2fa565;
rgb565_stream #(.PACK(P),.SWAP_BYTES(S),.ROUND_NEAREST(R)) d(clk,rst,ce,sd,sv,sf,se,sr,md,mv,mf,me,mr);
always @(posedge clk) if(rst) begin
 accepted=ce&&sv&&sr;
 if(accepted)sent=sent+1;
 if(ce&&mv&&mr)begin
 if(received>=N || md!==outputs[received]||mf!==(received%97==0)||me!==(received%97==96))
 $fatal(1,"numeric/markers index %d data %h",received,md);
 received=received+1;
 end
end
reg held=0;reg[OW+1:0]previous;
always @(negedge clk) if(rst) begin
 if(held && {md,mf,me}!==previous) $fatal(1,"stall stability");
 lfsr={lfsr[30:0],lfsr[31]^lfsr[21]^lfsr[1]^lfsr[0]};
 ce=lfsr[2]||lfsr[5];mr=lfsr[7];
 if(!sv||accepted)begin
 sv=sent<N&&(lfsr[3]||lfsr[6]);
 if(sent<N)begin sd=inputs[sent];sf=sent%97==0;se=sent%97==96;end
 end
 held=mv&&(!ce||!mr);previous={md,mf,me};
 cycles=cycles+1;if(cycles>20*N+100)$fatal(1,"timeout");
 if(received==N)begin
 rst=0;#1;if(mv||sr)$fatal(1,"reset");
 $display("RGB565 PASS vectors=%0d",N);$finish;
 end
end
initial begin $readmemh("in.hex",inputs);$readmemh("out.hex",outputs);
repeat(3)@(negedge clk);#1;rst=1;end
endmodule
'''
        # Token replacement only applies to whole identifier tokens.
        import re
        values={'IW':24 if pack else 16,'OW':16 if pack else 24,'N':len(samples),'P':pack,'S':swap,'R':rounding}
        tb=re.sub(r'\b(IW|OW|N|P|S|R)\b',lambda m:str(values[m[0]]),tb)
        (p/'tb.sv').write_text(tb,encoding='utf-8')
        execute(['iverilog','-g2012','-s','tb','-o',p/'sim',HERE/'rgb565_stream.sv',p/'tb.sv'],p,folder/f'{label}_compile.log')
        output=execute(['vvp',p/'sim'],p,folder/f'{label}_sim.log')
        assert 'RGB565 PASS' in output
    return {'pack':pack,'swap_bytes':swap,'round_nearest':rounding,'vectors':len(samples),'status':'PASS'}

def main():
    folder=evidence_dir('rgb565')
    cases=[run(p,s,r,folder) for p in (0,1) for s in (0,1) for r in ((0,1) if p else (0,))]
    write_json(folder/'results.json',{'cases':cases,'rtl_sha256':hashlib.sha256((HERE/'rgb565_stream.sv').read_bytes()).hexdigest(),'board_tested':False})
    print('RGB565 PASS',sum(c['vectors'] for c in cases),'vectors');print(folder)
if __name__=='__main__':main()
