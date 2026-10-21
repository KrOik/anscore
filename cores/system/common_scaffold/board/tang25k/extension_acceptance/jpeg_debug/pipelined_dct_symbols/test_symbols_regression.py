"""JPEG baseline symbol oracle and actual RTL protocol regression."""
from pathlib import Path
import os,tempfile,subprocess,json,random
ROOT=Path(__file__).resolve().parent
OSS=ROOT.parents[6]/'tools/oss-cad-suite/oss-cad-suite'
os.environ['PATH']=os.pathsep.join([str(OSS/'bin'),str(OSS/'lib'),os.environ.get('PATH','')])

def category_amplitude(value):
    size=abs(value).bit_length()
    return size,value if value>=0 else value+(1<<size)-1

def symbols(blocks):
    predictors=[0]*3;out=[]
    def token(dc,run,size,amplitude,end,restart,component):
        return amplitude|(size<<16)|(run<<20)|(dc<<24)|(end<<25)|(restart<<26)|(component<<27)
    for component,restart,coefficients in blocks:
        if restart:predictors=[0]*3
        diff=coefficients[0]-predictors[component];predictors[component]=coefficients[0]
        size,amplitude=category_amplitude(diff);assert size<=11
        out.append(token(1,0,size,amplitude,0,restart,component))
        run=0
        for index,value in enumerate(coefficients[1:],1):
            if value==0:
                run+=1
                if index==63:out.append(token(0,0,0,0,1,0,component))
            else:
                while run>=16:out.append(token(0,15,0,0,0,0,component));run-=16
                size,amplitude=category_amplitude(value);assert size<=10
                out.append(token(0,run,size,amplitude,index==63,0,component));run=0
    return out

def run():
    rng=random.Random(2026423);blocks=[]
    for component,dc,restart in ((0,100,0),(1,200,0),(0,50,1),(1,25,0),(2,1023,0),(2,-1024,0)):
        blocks.append((component,restart,[dc]+[0]*63))
    blocks.append((2,1,[2047]+[0]*63))
    blocks.append((2,0,[0]+[0]*63))
    amplitudes=[sign*((1<<size)-1) for size in range(1,11) for sign in (-1,1)]
    blocks.append((0,1,[0]+amplitudes+[0]*(63-len(amplitudes))))
    for index in (1,16,17,32,33,48,49,63):
        a=[0]*64;a[index]=-1023;blocks.append((0,0,a))
    # Every legal AC category, both signs, dense and sparse patterns.
    for n in range(30):
        a=[rng.randrange(-300,301)]+[0 if rng.randrange(3) else rng.choice((-1,1))*rng.randrange(1,1024) for _ in range(63)]
        blocks.append((n%3,int(n%11==0),a))
    expected=symbols(blocks)
    sequence=[]
    for component,restart,a in blocks:
        sequence += [f'send_coefficient({value},{int(i==0)},{int(i==63)},{component},{int(restart and i==0)});' for i,value in enumerate(a)]
    with tempfile.TemporaryDirectory(prefix='jpeg_symbols_') as temp:
        td=Path(temp);(td/'expected.hex').write_text('\n'.join(f'{v:x}' for v in expected))
        tb=TB.replace('@N@',str(len(expected))).replace('@SEQ@','\n'.join(sequence))
        (td/'tb.sv').write_text(tb)
        subprocess.run(['iverilog','-g2012','-s','tb','-o',str(td/'sim'),str(ROOT/'jpeg_baseline_symbols_fast.v'),str(td/'tb.sv')],check=True,capture_output=True)
        p=subprocess.run(['vvp',str(td/'sim')],cwd=td,text=True,capture_output=True)
        (ROOT/'symbols_simulation.log').write_text(p.stdout+p.stderr)
        if p.returncode or 'PASS' not in p.stdout:raise RuntimeError(p.stdout+p.stderr)
        print(p.stdout)
        for name,value in (('COEFF_W',1),('COEFF_W',17),('COMPONENTS',0),('COMPONENTS',5)):
            (td/'bad.sv').write_text(f'module tb;jpeg_baseline_symbols_fast #(.{name}({value})) d();endmodule')
            subprocess.run(['iverilog','-g2012','-s','tb','-o',str(td/'bad'),str(ROOT/'jpeg_baseline_symbols_fast.v'),str(td/'bad.sv')],check=True,capture_output=True)
            bad=subprocess.run(['vvp',str(td/'bad')],capture_output=True);(ROOT/f'invalid_{name}_{value}.log').write_bytes(bad.stdout+bad.stderr);assert bad.returncode
    (ROOT/'symbols_regression_result.json').write_text(json.dumps({'status':'PASS','blocks':len(blocks),'coefficients':64*len(blocks),'tokens':len(expected),'static_invalid_parameters':4,'terminal_errors':5,'seed':2026423},indent=2)+'\n')
TB=r'''
module tb;
localparam N=@N@;
reg clk=0;always #5 clk=~clk;
reg rst=1,ce=1,sv=0,first=0,last=0,restart=0,tr=0;reg signed[15:0] coefficient=0;reg[1:0] component=0;
wire sr,tv,dc,block_end,token_restart;wire[3:0] run,size,error_code;wire[15:0] amplitude;wire[1:0] token_component;
jpeg_baseline_symbols_fast d(clk,rst,ce,coefficient,sv,sr,first,last,component,restart,tv,tr,dc,run,size,amplitude,block_end,token_restart,token_component,error_code);
wire[28:0] packed_token={token_component,token_restart,block_end,dc,run,size,amplitude};
reg[28:0] expected[0:N-1],held_token;reg held=0,checking=1;integer count=0,cycles=0;reg[31:0] random_state=32'h5198414;
always @(negedge clk) begin
 random_state={random_state[30:0],random_state[31]^random_state[21]^random_state[1]^random_state[0]};
 ce=random_state[0]|random_state[2];tr=random_state[3]|random_state[5];
end
always @(posedge clk) if(!rst) begin
 cycles=cycles+1;if(cycles>200000)$fatal(1,"timeout");
 if(held&&(!tv||packed_token!==held_token))$fatal(1,"token stability");
 held=tv&&!(ce&&tr);held_token=packed_token;
 if(ce&&tv&&tr&&checking) begin
 if(count>=N||packed_token!==expected[count])$fatal(1,"token %0d got %h expected %h",count,packed_token,expected[count]);
 count=count+1;
 end
end
 task send_coefficient(input signed[15:0] v,input f,l,input[1:0] comp,input r);begin
 repeat((v&3))@(negedge clk);
 #1;coefficient=v;first=f;last=l;component=comp;restart=r;sv=1;
 @(posedge clk);while(!sr)@(posedge clk);
 @(negedge clk);#1;sv=0;
 end endtask
 task reset_dut;begin
 @(negedge clk);#1;rst=1;sv=0;@(negedge clk);#1;rst=0;held=0;
 if(error_code||tv)$fatal(1,"reset status");
 end endtask
 task expect_error(input[3:0] code);begin
 if(error_code!==code||sr||tv)$fatal(1,"error got%0d expected%0d",error_code,code);
 repeat(5)@(negedge clk);
 if(error_code!==code||sr||tv)$fatal(1,"terminal error not held");
 reset_dut;
 end endtask
 initial begin
 $readmemh("expected.hex",expected);
 repeat(3)@(negedge clk);#1;rst=0;
 @SEQ@
 while(count<N)@(negedge clk);
 if(error_code)$fatal(1,"unexpected error");checking=0;
 reset_dut;send_coefficient(0,0,0,0,0);expect_error(1);
 send_coefficient(0,1,0,3,0);expect_error(2);
 send_coefficient(0,1,0,0,0);send_coefficient(0,0,0,1,0);expect_error(2);
 send_coefficient(-32768,1,0,0,0);expect_error(3);
 send_coefficient(4095,1,0,0,0);expect_error(3);
 send_coefficient(0,1,0,0,0);send_coefficient(-32768,0,0,0,0);expect_error(4);
 send_coefficient(0,1,0,0,0);send_coefficient(2047,0,0,0,0);expect_error(4);
 send_coefficient(0,1,0,0,0);send_coefficient(0,0,0,0,1);expect_error(5);
 // Abort a partial block with reset, then legal initial predictor behavior.
 send_coefficient(100,1,0,0,0);reset_dut;
 send_coefficient(1,1,0,0,0);
 while(!tv)@(negedge clk);#1;
 if(!dc||size!=1||amplitude!=1)$fatal(1,"predictor reset");
 reset_dut;
 $display("PASS JPEG %0d exact tokens, stream stalls, restart, five terminal errors",N);$finish;
 end
endmodule
'''
if __name__=='__main__':run()
