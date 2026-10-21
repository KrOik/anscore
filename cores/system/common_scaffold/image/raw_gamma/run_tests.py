from pathlib import Path
import sys,tempfile,random,json,hashlib,math
from fractions import Fraction
H=Path(__file__).resolve().parent
sys.path.insert(0,str(H.parents[1]))
from integration.tooling import ROOT,execute

def oracle(pixel,table,bits,index):
 maximum=(1<<bits)-1;segments=1<<index
 coordinate=Fraction(pixel*segments,maximum)
 if pixel==maximum:return table[-1]
 left=coordinate.numerator//coordinate.denominator
 value=table[left]+(table[left+1]-table[left])*(coordinate-left)
 rounded=value+Fraction(1,2)
 return rounded.numerator//rounded.denominator

def run(bits,outbits,index):
 n=1<<bits;k=1<<index;maximum=(1<<outbits)-1;rng=random.Random(bits*11+outbits+index)
 tables=[[round((j/k)**(1/2.2)*maximum) for j in range(k+1)],
         [round((j/k)**2.2*maximum) for j in range(k+1)],
         [maximum if j%2 else 0 for j in range(k+1)],
         [rng.randrange(maximum+1) for j in range(k+1)]]
 expected=[oracle(p,table,bits,index) for table in tables for p in range(n)]
 with tempfile.TemporaryDirectory(prefix='raw_gamma_') as td:
  p=Path(td);(p/'tables.mem').write_text('\n'.join(f'{v:x}' for table in tables for v in table));(p/'expected.mem').write_text('\n'.join(f'{v:x}' for v in expected))
  tb=f'''module tb;
 reg clk=0;always #5 clk=~clk;reg rst_n=0,ce=1,cfg_begin_valid=0,cfg_valid=0,cfg_commit_valid=0,cfg_abort=0,cfg_done_ready=0,start_valid=0,abort=0,s_valid=0,s_sof=0,s_eol=0,s_last=0,m_ready=0,done_ready=0;
 reg[{index}:0]cfg_index;reg[{outbits-1}:0]cfg_value;reg[{bits-1}:0]s_pixel;
 wire cfg_begin_ready,cfg_ready,cfg_commit_ready,cfg_done_valid,cfg_error,table_active_valid,start_ready,s_ready,m_valid,m_sof,m_eol,m_last,done_valid,frame_error;wire[3:0]cfg_error_code,error_code;wire[{outbits-1}:0]m_pixel;
 raw_gamma #(.WIDTH({n}),.HEIGHT(1),.BITS({bits}),.OUT_BITS({outbits}),.INDEX_BITS({index}))dut(.*);
 reg[{outbits-1}:0]tables[0:{len(tables)*(k+1)-1}],expected[0:{len(expected)-1}];integer f,i,j,got=0,cycles=0,accepted=0,last_accept_cycle=0;reg[31:0]rng=77;reg take,held_valid=0;reg[{outbits+2}:0]held;
 wire[{outbits+2}:0]token={{m_pixel,m_sof,m_eol,m_last}};
 always @(posedge clk)begin cycles=cycles+1;if(cycles>500000)$fatal(1,"timeout state=%d",dut.state);
 if(rst_n)begin
 if(held_valid&&(!m_valid||token!==held))$fatal(1,"hold");held_valid=m_valid&&(!ce||!m_ready);held=token;
 if(ce&&m_valid&&m_ready)begin if(got>={len(expected)}||m_pixel!==expected[got]||m_sof!=(got%{n}==0)||m_eol!=(got%{n}=={n-1})||m_last!=(got%{n}=={n-1}))$fatal(1,"pixel %d got %d expected %d",got,m_pixel,expected[got]);got=got+1;end
 if(f==0&&ce&&s_valid&&s_ready)begin if(accepted>0&&cycles!=last_accept_cycle+1)$fatal(1,"II1");last_accept_cycle=cycles;accepted=accepted+1;end
 end else held_valid=0;end
 task tick;begin @(negedge clk);#1;if(f==0)begin ce=1;m_ready=1;end else begin rng=rng^(rng<<13);rng=rng^(rng>>17);rng=rng^(rng<<5);ce=rng[0]|rng[1];m_ready=rng[2]|rng[3];end end endtask
 initial begin $readmemh("tables.mem",tables);$readmemh("expected.mem",expected);f=0;repeat(3)@(negedge clk);rst_n=1;
 for(f=0;f<{len(tables)};f=f+1)begin ce=1;cfg_begin_valid=1;@(negedge clk);cfg_begin_valid=0;
 // Reverse-order node loads validate bitmap completeness independently of ordering.
 for(j={k};j>=0;j=j-1)begin cfg_index=j;cfg_value=tables[f*{k+1}+j];cfg_valid=1;@(negedge clk);end cfg_valid=0;
 cfg_commit_valid=1;@(negedge clk);cfg_commit_valid=0;if(!cfg_done_valid||cfg_error||!table_active_valid)$fatal(1,"commit");cfg_done_ready=1;@(negedge clk);cfg_done_ready=0;
 start_valid=1;@(negedge clk);start_valid=0;m_ready=1;
 i=0;while(i<{n})begin s_valid=1;s_pixel=i;s_sof=i==0;s_eol=i=={n-1};s_last=i=={n-1};@(posedge clk);take=ce&&s_ready;if(take)i=i+1;tick;end s_valid=0;
 while(!done_valid)tick;if(frame_error||error_code||got!=(f+1)*{n})$fatal(1,"completion");ce=0;done_ready=1;repeat(3)@(negedge clk);if(!done_valid)$fatal(1,"CE done");ce=1;@(negedge clk);done_ready=0;
 end
 if(accepted!={n})$fatal(1,"II1 count");$display("PASS raw_gamma B{bits}->B{outbits} nodes{k+1}: {len(expected)} pixels,full-code gamma/inverse/nonmonotonic/random,II1/CE/hold/endpoints");$finish;end endmodule'''
  (p/'tb.sv').write_text(tb);tag=f'b{bits}_o{outbits}_i{index}'
  execute(['iverilog','-g2012','-s','tb','-o',p/'sim',H/'raw_gamma.sv',p/'tb.sv'],ROOT,H/f'{tag}_compile.log')
  print(execute(['vvp',p/'sim'],p,H/f'{tag}_simulation.log').strip(),flush=True)
 return {'result':'PASS','input_bits':bits,'output_bits':outbits,'index_bits':index,'nodes':k+1,'frames':len(tables),'pixels':len(expected),'all_input_codes':True,'unstalled_ii':1}
if __name__=='__main__':
 rows=[run(8,12,4),run(10,8,6),run(12,12,4),run(12,10,6),run(8,8,8)]
 (H/'test_evidence.json').write_text(json.dumps({'result':'PASS','oracle':'independent exact Fraction segment coordinates and rational blend','cases':rows,'rtl_sha256':hashlib.sha256((H/'raw_gamma.sv').read_bytes()).hexdigest(),'board':False},indent=2)+'\n')
