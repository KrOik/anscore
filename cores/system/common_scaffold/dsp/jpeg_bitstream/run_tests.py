"""Independent string-bitstream oracle, stuffing and drain/stall regression."""
from pathlib import Path
import hashlib,random,sys,tempfile
sys.path.insert(0,str(Path(__file__).resolve().parents[2]/'integration'))
from tooling import ROOT,execute,evidence_dir,write_json
HERE=Path(__file__).resolve().parent

def main():
    rng=random.Random(0xff00)
    tokens=[];expected=[];bits='';flushes=0;errors=0
    def append(code,cl,amp,al,flush,bad=False):
        nonlocal bits,flushes,errors
        tokens.append((code,cl,amp,al,int(flush),int(bad)))
        if bad: errors+=1;return
        bits+=(format(code,f'0{cl}b') if cl else '')+(format(amp,f'0{al}b') if al else '')
        if flush:
            bits+='1'*((-len(bits))%8);flushes+=1
        emitted=[]
        while len(bits)>=8:
            byte=int(bits[:8],2);bits=bits[8:];emitted.append([byte,0])
            if byte==255: emitted.append([0,0])
        if flush and emitted: emitted[-1][1]=1
        expected.extend(emitted)
    append(0,0,0,0,True)
    append(65535,16,65535,16,True)
    append(1,1,0,0,False)
    append(0,17,0,0,False,True)
    append(8,3,0,0,False,True)
    append(0,0,0,0,False,True)
    append(1,1,1,0,False,True)
    append(0,1,0,17,False,True)
    append(0,0,1,1,True,True)
    append(0,0,0,0,True)
    for n in (1,2,7,15,100,200):
        for i in range(n):
            cl=rng.randint(1,16);al=rng.randint(0,16)
            append(rng.randrange(1<<cl),cl,rng.randrange(1<<al),al,i==n-1)
    with tempfile.TemporaryDirectory(prefix='jpeg_bits_') as temp:
        p=Path(temp)
        # 44 bits: bad/flush, amplitude length, code length, amplitude, code.
        packed=[c|(a<<16)|(cl<<32)|(al<<37)|(f<<42)|(bad<<43) for c,cl,a,al,f,bad in tokens]
        (p/'tokens.hex').write_text(''.join(f'{v:x}\n' for v in packed),encoding='utf-8')
        (p/'bytes.hex').write_text(''.join(f'{b|(last<<8):x}\n' for b,last in expected),encoding='utf-8')
        tb='''`timescale 1ns/1ps
module tb;
reg clk=0;always #5 clk=~clk;
reg rst=0,ce=1,sv=0,mr=0;reg[43:0]token;
wire sr,mv,ml,err,done;wire[7:0]md;wire[6:0]pending;
reg[43:0]tokens[0:NT-1];reg[8:0]bytes[0:NB-1];
integer sent=0,received=0,errors=0,flushes=0,cycles=0,reset_stage=0;
reg accepted=0,held=0;reg[8:0]previous;reg[31:0]rnd=32'hffab123;
jpeg_entropy_bitpacker d(clk,rst,ce,token[15:0],token[31:16],token[36:32],token[41:37],token[42],sv,sr,md,mv,ml,mr,err,done,pending);
always @(posedge clk)if(rst)begin
accepted=ce&&sv&&sr;if(accepted)sent=sent+1;
if(ce&&mv&&mr)begin
if(received>=NB||{ml,md}!==bytes[received])$fatal(1,"byte %d got %h last %b",received,md,ml);
received=received+1;
end
end
always @(negedge clk)if(rst)begin
if(reset_stage==1)begin sv=0;reset_stage=2;end
else if(reset_stage==2)begin
if(pending!=1)$fatal(1,"partial reset setup");
rst=0;#1;if(mv||sr||pending)$fatal(1,"reset abort");
$display("JPEG_BITS PASS tokens=%0d bytes=%0d",NT,NB);$finish;
end else begin
if(held&&{ml,md}!==previous)$fatal(1,"stall");
if(ce&&err)errors=errors+1;if(ce&&done)flushes=flushes+1;
rnd={rnd[30:0],rnd[31]^rnd[21]^rnd[1]^rnd[0]};ce=rnd[0]||rnd[3];mr=rnd[7];
if(!sv||accepted)begin sv=sent<NT&&(rnd[1]||rnd[5]);if(sent<NT)token=tokens[sent];end
held=mv&&(!ce||!mr);previous={ml,md};cycles=cycles+1;
if(cycles>50000)$fatal(1,"timeout");
if(sent==NT&&sr&&!sv)begin
if(received!=NB||errors!=NE||flushes!=NF||pending!=0)$fatal(1,"counts bytes %d errors %d flush %d",received,errors,flushes);
// Accept one unflushed bit, then reset must cancel the partial segment.
ce=1;mr=0;sv=1;token=44'h100000001;reset_stage=1;
end
end
end
initial begin $readmemh("tokens.hex",tokens);$readmemh("bytes.hex",bytes);
repeat(3)@(negedge clk);#1;rst=1;end
endmodule
'''
        import re
        values={'NT':len(tokens),'NB':len(expected),'NE':errors,'NF':flushes}
        tb=re.sub(r'\b(NT|NB|NE|NF)\b',lambda m:str(values[m[0]]),tb)
        (p/'tb.sv').write_text(tb,encoding='utf-8')
        folder=evidence_dir('jpeg_bitstream')
        execute(['iverilog','-g2012','-s','tb','-o',p/'sim',HERE/'jpeg_entropy_bitpacker.sv',p/'tb.sv'],p,folder/'compile.log')
        output=execute(['vvp',p/'sim'],p,folder/'simulation.log')
        assert 'JPEG_BITS PASS' in output
    write_json(folder/'result.json',{'status':'PASS','tokens':len(tokens),'bytes':len(expected),'flushes':flushes,'rejected_tokens':errors,'board_tested':False,'rtl_sha256':hashlib.sha256((HERE/'jpeg_entropy_bitpacker.sv').read_bytes()).hexdigest()})
    print(output.strip());print(folder)
if __name__=='__main__':main()
