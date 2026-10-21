"""Exact rational cube interpolation reference and real-RTL streaming tests."""
from pathlib import Path
from fractions import Fraction
import os,tempfile,subprocess,random,json,itertools,importlib.util
ROOT=Path(__file__).resolve().parent
OSS=ROOT.parents[3]/'tools/oss-cad-suite/oss-cad-suite'
os.environ['PATH']=os.pathsep.join([str(OSS/'bin'),str(OSS/'lib'),os.environ.get('PATH','')])
def oracle(table,pixel,bits,grid_log2):
    d=(1<<bits)-1;k=1<<grid_log2;n=k+1
    cells=[]
    for value in pixel:
        location=Fraction(value*k,d);low=min(location.numerator//location.denominator,k-1)
        cells.append((low,location-low))
    result=[]
    for color in range(3):
        value=Fraction(0)
        for upper in itertools.product((0,1),repeat=3):
            coords=[cells[a][0]+upper[a] for a in range(3)]
            weight=Fraction(1)
            for a in range(3):weight*=cells[a][1] if upper[a] else 1-cells[a][1]
            value+=table[(coords[2]*n+coords[1])*n+coords[0]][color]*weight
        result.append(min(d,(2*value.numerator+value.denominator)//(2*value.denominator)))
    return tuple(result)
def pack(rgb,bits):return (rgb[0]<<(2*bits))|(rgb[1]<<bits)|rgb[2]
def run():
    rng=random.Random(2026460);results=[]
    with tempfile.TemporaryDirectory(prefix='color_lut3d_') as temp:
        td=Path(temp)
        for bits,gl in ((8,1),(10,2),(12,1),(8,3),(12,4)):
            d=(1<<bits)-1;k=1<<gl;n=k+1
            a=[];b=[];c=[]
            for blue in range(n):
                for green in range(n):
                    for red in range(n):
                        a.append(tuple((v*d+k//2)//k for v in (red,green,blue)))
                        b.append(((red*red*d+k*k//2)//(k*k),(green*blue*d+k*k//2)//(k*k),d-(blue*d+k//2)//k))
                        c.append(tuple(rng.randrange(d+1) for _ in range(3)))
            permutation=[(v[1],v[2],v[0]) for v in a]
            cube='LUT_3D_SIZE '+str(n)+'\n'+'\n'.join(f'{green/k:.16f} {blue/k:.16f} {red/k:.16f}' for blue in range(n) for green in range(n) for red in range(n))+'\n'
            spec=importlib.util.spec_from_file_location('cube_export',ROOT.parents[3]/'host/color_lut3d/export_cube.py')
            exporter=importlib.util.module_from_spec(spec);spec.loader.exec_module(exporter)
            payload,metadata=exporter.convert(cube,bits)
            assert [int(line,16) for line in payload.splitlines()]==[pack(v,bits) for v in permutation]
            (td/'table3.hex').write_text(payload)
            pixels=list(itertools.product((0,d),repeat=3))+[(v,v,v) for v in (1,d//2,d//2+1,d-1)]+[tuple(rng.randrange(d+1) for _ in range(3)) for _ in range(8)]
            for table_index,table in enumerate((a,b,c)):
                (td/f'table{table_index}.hex').write_text('\n'.join(f'{pack(rgb,bits):x}' for rgb in table))
            expected=[]
            for table in (a,b,c,permutation):expected += [pack(oracle(table,p,bits,gl),bits) for p in pixels]
            assert all(oracle(a,p,bits,gl)==p for p in pixels),'identity not exact'
            (td/'expected.hex').write_text('\n'.join(f'{v:x}' for v in expected))
            (td/'pixels.hex').write_text('\n'.join(f'{pack(p,bits):x}' for p in pixels))
            tb=TB.replace('@BITS@',str(bits)).replace('@GL@',str(gl)).replace('@P@',str(len(pixels)))
            (td/'tb.sv').write_text(tb)
            subprocess.run(['iverilog','-g2012','-s','tb','-o',str(td/'sim'),str(ROOT/'color_lut3d.v'),str(td/'tb.sv')],check=True,capture_output=True)
            p=subprocess.run(['vvp',str(td/'sim')],cwd=td,text=True,capture_output=True)
            if p.returncode or 'PASS' not in p.stdout:raise RuntimeError(f'BITS{bits} GL{gl}\n'+p.stdout+p.stderr)
            print(bits,gl,p.stdout.splitlines()[0]);results.append({'bits':bits,'grid_log2':gl,'vertices':n**3,'pixels':len(expected)})
        for name,value in (('BITS',7),('BITS',13),('GRID_LOG2',0),('GRID_LOG2',5)):
            (td/'bad.sv').write_text(f'module tb;color_lut3d #(.{name}({value})) d();endmodule')
            p=subprocess.run(['iverilog','-g2012','-s','tb','-o',str(td/'bad'),str(ROOT/'color_lut3d.v'),str(td/'bad.sv')],capture_output=True)
            if p.returncode==0:assert subprocess.run(['vvp',str(td/'bad')],capture_output=True).returncode
    (ROOT/'test_result.json').write_text(json.dumps({'status':'PASS','cases':results,'invalid_parameters':4,'cube_exporter_integration':True,'seed':2026460},indent=2)+'\n')
TB=r'''
module tb;
localparam B=@BITS@,GL=@GL@,N=(1<<GL)+1,DEPTH=N*N*N,P=@P@;
reg clk=0;always #5 clk=~clk;
reg rst=1,ce=1,lb=0,lv=0,ll=0,cv=0,sv=0,sof=0,eol=0,eof=0,mr=0,force_stall=0;
reg[3*B-1:0] ld=0,sd=0;wire lbr,lr,cr,cd,configured,sr,mv,ms,ml,me,busy,marker;wire[3:0] error;wire[3*B-1:0] md;
color_lut3d #(.BITS(B),.GRID_LOG2(GL)) dut(clk,rst,ce,lb,lbr,ld,lv,ll,lr,cv,cr,cd,configured,error,marker,sd,sv,sof,eol,eof,sr,md,mv,ms,ml,me,mr,busy);
reg[3*B-1:0] table0[0:DEPTH-1],table1[0:DEPTH-1],table2[0:DEPTH-1],table3[0:DEPTH-1],expected[0:4*P-1],pixels[0:P-1];
reg[31:0] random_state=32'h72649;integer received=0,cycles=0,i;reg checking=1,held=0;reg[3*B+2:0] held_payload;
always @(negedge clk)begin
 random_state={random_state[30:0],random_state[31]^random_state[21]^random_state[1]^random_state[0]};
 ce=random_state[0]|random_state[2];mr=force_stall?0:(random_state[3]|random_state[5]);
end
always @(posedge clk)if(!rst)begin
 cycles=cycles+1;if(cycles>2000000)$fatal(1,"timeout");
 if(held&&(!mv||{md,ms,ml,me}!==held_payload))$fatal(1,"output stall");
 held=mv&&!(ce&&mr);held_payload={md,ms,ml,me};
 if(ce&&mv&&mr&&checking)begin
 if(received>=4*P||md!==expected[received])$fatal(1,"numeric pixel%0d got%h expected%h",received,md,expected[received]);
 if(ms!==(received%P==0)||ml!==((received%P)%5==4||received%P==P-1)||me!==(received%P==P-1))$fatal(1,"markers");
 received=received+1;
 end
end
 task begin_load;begin
 @(negedge clk);#1;lb=1;@(posedge clk);while(!lbr)@(posedge clk);
 @(negedge clk);#1;lb=0;
 if(configured)$fatal(1,"load must invalidate");
 end endtask
 task load_vertex(input[3*B-1:0] value,input finalword);begin
 @(negedge clk);#1;ld=value;ll=finalword;lv=1;
 @(posedge clk);while(!lr)@(posedge clk);
 @(negedge clk);#1;lv=0;
 end endtask
 task write_table(input integer which,input start_index);integer j;reg[3*B-1:0] value;begin
 for(j=start_index;j<DEPTH;j=j+1)begin
 case(which)0:value=table0[j];1:value=table1[j];2:value=table2[j];default:value=table3[j];endcase
 load_vertex(value,j==DEPTH-1);
 end
 end endtask
 task commit_table(input expect_success);begin
 @(negedge clk);#1;cv=1;@(posedge clk);while(!cr)@(posedge clk);
 @(negedge clk);#1;cv=0;
 if(expect_success&&(!configured||!cd))$fatal(1,"commit not successful");
 if(!expect_success&&(configured||error!=1))$fatal(1,"partial commit not rejected");
 end endtask
 task send_pixel(input integer index);begin
 @(negedge clk);#1;sd=pixels[index];sof=index==0;eof=index==P-1;eol=index%5==4||eof;sv=1;
 @(posedge clk);while(!sr)@(posedge clk);
 @(negedge clk);#1;sv=0;
 end endtask
 task reset_dut;begin
 @(negedge clk);#1;rst=1;sv=0;lb=0;lv=0;cv=0;@(negedge clk);#1;rst=0;held=0;
 if(configured||mv||marker||error)$fatal(1,"reset");
 end endtask
 initial begin
 $readmemh("table0.hex",table0);$readmemh("table1.hex",table1);$readmemh("table2.hex",table2);$readmemh("table3.hex",table3);$readmemh("expected.hex",expected);$readmemh("pixels.hex",pixels);
 repeat(3)@(negedge clk);#1;rst=0;
 commit_table(0);if(sr)$fatal(1,"uninitialized table accepted pixel");
 begin_load;write_table(0,0);commit_table(1);
 send_pixel(0);while(received<1)@(negedge clk);
 // Pending load cannot change or block the remaining active frame.
 #1;cv=1;repeat(3)begin @(negedge clk);#1;if(cr)$fatal(1,"midframe commit");end
 cv=0;lb=1;repeat(3)begin @(negedge clk);#1;if(lbr||!configured)$fatal(1,"midframe load accepted");end
 for(i=1;i<P;i=i+1)send_pixel(i);
 while(received<P)@(negedge clk);
 @(posedge clk);while(!lbr)@(posedge clk);
 @(negedge clk);#1;lb=0;if(configured)$fatal(1,"deferred load not atomic");
 write_table(1,0);commit_table(1);
 for(i=0;i<P;i=i+1)send_pixel(i);
 while(received<2*P)@(negedge clk);
 begin_load;load_vertex(table2[0],0);commit_table(0);
 if(sr)$fatal(1,"partial table used");
 write_table(2,1);commit_table(1);
 for(i=0;i<P;i=i+1)send_pixel(i);
 while(received<3*P)@(negedge clk);
 begin_load;write_table(3,0);commit_table(1);
 for(i=0;i<P;i=i+1)send_pixel(i);
 while(received<4*P)@(negedge clk);
 if(marker)$fatal(1,"unexpected marker error");checking=0;
 // Reset while arithmetic is active must invalidate the table.
 send_pixel(0);repeat(10)@(negedge clk);reset_dut;commit_table(0);
 begin_load;write_table(3,0);commit_table(1);force_stall=1;
 @(negedge clk);#1;sd=0;sof=0;eol=0;eof=1;sv=1;
 @(posedge clk);while(!sr)@(posedge clk);
 @(negedge clk);#1;sv=0;
 while(!mv)@(negedge clk);#1;
 if(!marker||ms||ml||!me)$fatal(1,"invalid frame markers not diagnosed/preserved");
 repeat(5)@(negedge clk);reset_dut;force_stall=0;
 begin_load;load_vertex(0,1);if(error!=2||configured)$fatal(1,"early last");
 begin_load;for(i=0;i<DEPTH;i=i+1)load_vertex(0,0);
 if(error!=2||configured)$fatal(1,"missing last");
 reset_dut;begin_load;load_vertex(0,0);reset_dut;commit_table(0);
 // Simultaneous config requests have load-begin priority, never deadlock.
 @(negedge clk);#1;lb=1;cv=1;
 @(posedge clk);while(!lbr)@(posedge clk);
 if(cr)$fatal(1,"configuration double accept");
 @(negedge clk);#1;lb=0;
 @(posedge clk);while(!cr)@(posedge clk);
 @(negedge clk);#1;cv=0;
 if(configured||error!=1)$fatal(1,"simultaneous config incomplete commit");
 $display("PASS exact rational trilinear pixels, endpoints, atomic load, partial table, stalls/reset");$finish;
 end
endmodule
'''
if __name__=='__main__':run()
