"""Sub-clock asynchronous input phases and independent sample-grid oracle."""
from test_measurement import *
import math
def main():
 frozen=hashes();rows=[]
 for offset in [0.10,2.40,4.99,5.01,7.50,9.90]:
  edges=[100+offset,183.2+offset,300.9+offset,392.3+offset,505.8+offset]
  # Clock sample grid is t=5+10*k ns. The 2FF latency and symmetric filter
  # shift every accepted edge equally, so they cancel in width differences.
  grid=[math.ceil((t-5)/10) for t in edges]
  expected=[(1,0,grid[1]-grid[0],grid[2]-grid[1],grid[2]-grid[0]),(1,0,grid[3]-grid[2],grid[4]-grid[3],grid[4]-grid[2])]
  for n,(a,b,c) in enumerate([(0,1,2),(2,3,4)]):
   for ticks,physical in zip(expected[n][2:],[edges[b]-edges[a],edges[c]-edges[b],edges[c]-edges[a]]):assert abs(ticks*10-physical)<10
  body=f'''
initial begin
 #30;rst_n=1;#10;start_valid=1;#10;start_valid=0;
 #{edges[0]-50:.3f};input_pin=1;
 #83.200;input_pin=0;#117.700;input_pin=1;#91.400;input_pin=0;#113.500;input_pin=1;
 #100;abort=1;@(posedge clk);#1;@(negedge clk);#1;abort=0;ce=1;m_ready=1;
 wait(done_valid);@(negedge clk);#1;if(events!=2||drop_count||error_code!=3)$fatal(1,"quantization completion");
 $display("PASS PULSE quantized sub-clock phase {offset}");$finish;
end
initial begin #10000;$fatal(1,"watchdog");end
endmodule
'''
  # Prefix declaration keeps CE=1 and output backpressured until the final drain.
  original=TB.split('initial begin\n $readmemh')[0]
  tb='`timescale 1ns/1ps\n'+original+body
  for k,v in dict(W=32,N=1,POL=1,FILTER=3,TIMEOUT=0,MINH=1,MAXH=4294967295,MINL=1,MAXL=4294967295).items():tb=tb.replace('@'+k+'@',str(v))
  with tempfile.TemporaryDirectory(prefix='pulse_phase_') as tmp:
   p=Path(tmp);(p/'tb.sv').write_text(tb)
   execute(['iverilog','-g2012','-s','tb','-o',p/'sim',SOURCE,p/'tb.sv'],p,p/'compile.log');out=execute(['vvp',p/'sim'],p,p/'run.log')
   (HERE/f'simulation_phase{offset}.log').write_text(out)
  actual=[tuple(map(int,s.split()[2:])) for s in out.splitlines() if s.startswith('EVENT ')]
  assert actual==expected,(offset,actual,expected)
  rows.append(dict(phase_ns=offset,raw_edge_ns=edges,quantized_intervals=expected,output=out))
 assert hashes()==frozen
 (HERE/'quantization_evidence.json').write_text(json.dumps(dict(status='PASS',sources=frozen,profiles=rows,scope='Deterministic sampling quantization only, less than one clock interval error for ideal digital edges; analog metastability MTBF is not simulated or claimed.'),indent=2)+'\n')
 print('PASS PULSE quantization six asynchronous phases and sample-boundary sides')
if __name__=='__main__':main()
