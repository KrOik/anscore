"""Canonical-code bit-list oracle for multiblock restart scan control."""
from pathlib import Path
import os,tempfile,subprocess,random,json
ROOT=Path(__file__).resolve().parent
OSS=ROOT.parents[3]/'tools/oss-cad-suite/oss-cad-suite'
os.environ['PATH']=os.pathsep.join([str(OSS/'bin'),str(OSS/'lib'),os.environ.get('PATH','')])
PACKER=ROOT.parents[0]/'jpeg_bitstream/jpeg_entropy_bitpacker.sv'
def codes():
    # One canonical symbol of each length 1..16, leaves all-ones unused.
    table=[];code=0;previous=0
    for length in range(1,17):
        code <<= length-previous;table.append((code,length));code+=1;previous=length
    return table

def oracle(blocks,interval):
    out=[];bits=[];rst=0
    for i,tokens in enumerate(blocks):
        for code,cb,amp,ab in tokens:
            bits.extend((code>>k)&1 for k in range(cb-1,-1,-1))
            bits.extend((amp>>k)&1 for k in range(ab-1,-1,-1))
        final=i==len(blocks)-1
        if final or (interval and (i+1)%interval==0):
            bits += [1]*((-len(bits))%8)
            segment=[]
            for offset in range(0,len(bits),8):
                value=sum(bit<<(7-j) for j,bit in enumerate(bits[offset:offset+8]));segment.append((value,0,0))
                if value==255:segment.append((0,0,0))
            if final and segment:segment[-1]=(segment[-1][0],0,1)
            out+=segment;bits=[]
            if not final:out.extend(((255,1,0),(0xd0+rst%8,1,0)));rst+=1
    return out,rst

def run():
    rng=random.Random(2026444);table=codes();cases=[]
    with tempfile.TemporaryDirectory(prefix='jpeg_scan_') as temp:
        td=Path(temp)
        for count,interval in ((1,0),(3,0),(5,1),(7,2),(8,3),(19,1),(4,100)):
            blocks=[]
            for i in range(count):
                tokens=[]
                for j in range(1+i%4):
                    c,cb=table[(i+j*3)%16];ab=(i+j)%12;amp=(1<<ab)-1 if j%2==0 else rng.randrange(1<<ab)
                    tokens.append((c,cb,amp,ab))
                if i==0:tokens.append((254,8,2047,11)) # explicit FF stuffing across amplitude+pad
                blocks.append(tokens)
            expected,restarts=oracle(blocks,interval)
            (td/'expected.hex').write_text('\n'.join(f'{v|(m<<8)|(last<<9):x}' for v,m,last in expected))
            seq=[]
            for i,tokens in enumerate(blocks):
                for j,(c,cb,a,ab) in enumerate(tokens):seq.append(f'send_token({c},{cb},{a},{ab},{int(j==len(tokens)-1)},{int(i==count-1 and j==len(tokens)-1)});')
            tb=TB.replace('@N@',str(len(expected))).replace('@COUNT@',str(count)).replace('@INTERVAL@',str(interval)).replace('@RST@',str(restarts)).replace('@SEQ@','\n'.join(seq))
            (td/'tb.sv').write_text(tb)
            subprocess.run(['iverilog','-g2012','-s','tb','-o',str(td/'sim'),str(PACKER),str(ROOT/'jpeg_entropy_scan_controller.v'),str(td/'tb.sv')],check=True,capture_output=True)
            p=subprocess.run(['vvp',str(td/'sim')],cwd=td,text=True,capture_output=True)
            if p.returncode or 'PASS' not in p.stdout:raise RuntimeError(f'{count}/{interval}\n'+p.stdout+p.stderr)
            print(count,interval,p.stdout.splitlines()[0]);cases.append({'blocks':count,'interval':interval,'bytes':len(expected),'restarts':restarts})
    (ROOT/'test_result.json').write_text(json.dumps({'status':'PASS','cases':cases,'seed':2026444,'negative_tests':['zero blocks','bad last metadata','zero code length','oversized code','code high bits','oversized amplitude','amplitude high bits','packer fault injection','abort','held abort through done','CE-low abort preserves stalled byte','reset']},indent=2)+'\n')
TB=r'''
module tb;
localparam N=@N@;
reg clk=0;always #5 clk=~clk;
reg rst=1,ce=1,start=0,abort=0,sv=0,be=0,sl=0,mr=0,pr=0,done_ready=0;
reg force_pause=0,force_stall=0;reg[9:0] abort_snapshot;
reg[31:0] total=@COUNT@,interval=@INTERVAL@;
reg[15:0] code=0,amp=0;reg[4:0] cb=0,ab=0;
wire sr,start_ready,mv,marker,last,pv,done,busy;wire[7:0] data;wire[3:0] err;wire[31:0] completed,restarts;
jpeg_entropy_scan_controller d(clk,rst,ce,start,start_ready,total,interval,abort,code,amp,cb,ab,be,sl,sv,sr,data,mv,mr,marker,last,pv,pr,done,done_ready,err,busy,completed,restarts);
reg[9:0] expected[0:N-1],held_byte;reg held=0,checking=1,predheld=0;
integer received=0,resets=0,cycles=0;reg[31:0] random_state=32'h718242;
always @(negedge clk) begin
 random_state={random_state[30:0],random_state[31]^random_state[21]^random_state[1]^random_state[0]};
 ce=force_pause?0:(random_state[0]|random_state[2]);mr=force_stall?0:(random_state[3]|random_state[5]);pr=random_state[1]&random_state[4];
end
always @(posedge clk) if(!rst) begin
 cycles=cycles+1;if(cycles>200000)$fatal(1,"timeout");
 if(held&&(!mv||{last,marker,data}!==held_byte)&&!abort)$fatal(1,"byte stability");
 held=mv&&!(ce&&mr);held_byte={last,marker,data};
 if(predheld&&!pv&&!abort)$fatal(1,"predictor event lost");predheld=pv&&!(ce&&pr);
 if(ce&&pv&&pr)resets=resets+1;
 if(ce&&mv&&mr&&checking) begin
 if(received>=N||{last,marker,data}!==expected[received])$fatal(1,"byte %0d got%h expected%h",received,{last,marker,data},expected[received]);received=received+1;
 end
end
 task go;begin
 @(negedge clk);#1;start=1;@(posedge clk);while(!start_ready)@(posedge clk);
 @(negedge clk);#1;start=0;
 end endtask
 task send_token(input[15:0] c,input[4:0] clen,input[15:0] a,input[4:0] alen,input bend,send);begin
 repeat(c%3)@(negedge clk);#1;code=c;cb=clen;amp=a;ab=alen;be=bend;sl=send;sv=1;
 @(posedge clk);while(!sr)@(posedge clk);
 @(negedge clk);#1;sv=0;
 end endtask
 task consume_result(input[3:0] e);begin
 while(!done)@(negedge clk);#1;
 if(err!==e)$fatal(1,"error %0d expected %0d",err,e);
 repeat(5)@(negedge clk);#1;done_ready=1;
 @(posedge clk);while(!ce)@(posedge clk);
 @(negedge clk);#1;done_ready=0;held=0;predheld=0;
 end endtask
 task reset_dut;begin
 @(negedge clk);#1;rst=1;sv=0;@(negedge clk);#1;rst=0;held=0;predheld=0;
 if(mv||done||busy||err)$fatal(1,"reset");
 end endtask
 initial begin
 $readmemh("expected.hex",expected);repeat(3)@(negedge clk);#1;rst=0;
 go;total=999;interval=999; // prove active configuration is latched
 @SEQ@
 while(!done)@(negedge clk);#1;
 if(received!=N||completed!=@COUNT@||restarts!=@RST@||resets!=@RST@+1)$fatal(1,"terminal counters");
 consume_result(0);checking=0;
 total=0;go;consume_result(1);
 total=1;interval=0;go;send_token(0,1,0,0,1,0);consume_result(2);
 go;send_token(0,0,0,0,1,1);consume_result(2);
 go;send_token(0,17,0,0,1,1);consume_result(2);
 go;send_token(2,1,0,0,1,1);consume_result(2);
 go;send_token(0,1,0,12,1,1);consume_result(2);
 go;send_token(0,1,2,1,1,1);consume_result(2);
 go;@(negedge clk);#1;force d.p_error=1;
 @(posedge clk);while(!ce)@(posedge clk);
 @(negedge clk);#1;release d.p_error;held=0;predheld=0;consume_result(3);
 go;@(negedge clk);#1;abort=1;@(posedge clk);while(!ce)@(posedge clk);
 @(negedge clk);#1;abort=0;held=0;predheld=0;consume_result(4);
 // Hold abort through CLEAR and DONE; CE-low abort must not cancel a stalled byte.
 go;force_stall=1;send_token(254,8,2047,11,0,0);
 while(!mv)@(negedge clk);#1;abort_snapshot={last,marker,data};force_pause=1;
 @(negedge clk);#1;abort=1;
 repeat(4)begin @(negedge clk);#1;if(!mv||{last,marker,data}!==abort_snapshot)$fatal(1,"CE-low abort changed stalled byte");end
 force_pause=0;
 consume_result(4); // abort deliberately stays high until result accepted
 if(busy||start_ready)$fatal(1,"held abort completion/idle gate");
 abort=0;force_stall=0;
 go;send_token(0,1,0,0,0,0);reset_dut;
 $display("PASS scan bytes/restarts/predictor events and error/reset paths");$finish;
 end
endmodule
'''
if __name__=='__main__':run()
