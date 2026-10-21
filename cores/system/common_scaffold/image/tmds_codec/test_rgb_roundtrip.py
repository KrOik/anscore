from run_tests import HERE,SOURCES,CONTROLS,encode,execute
from pathlib import Path
import tempfile,json,hashlib,random
TB=r"""module tb;
localparam N=@N@;
reg clk=0;always #5 clk=~clk;reg rst_n=0,ce=1,s_valid=0;reg[26:0]source=0;
wire[2:0]er,ev,dr,dv;wire[29:0]symbols;wire[23:0]pixels;wire[2:0]des,errors,locks;wire[5:0]controls;reg[2:0]ready=0;
wire allready=&er;
genvar g;generate for(g=0;g<3;g=g+1)begin:lane
wire signed[5:0]erd,drd;
tmds_encoder enc(.clk(clk),.rst_n(rst_n),.ce(ce),.s_data(source[g*8+:8]),.s_de(source[26]),.s_control(g==0?source[25:24]:2'b00),.s_valid(s_valid&&allready),.s_ready(er[g]),.m_symbol(symbols[g*10+:10]),.m_valid(ev[g]),.m_ready(dr[g]),.running_disparity(erd));
tmds_decoder dec(.clk(clk),.rst_n(rst_n),.ce(ce),.s_symbol(symbols[g*10+:10]),.s_valid(ev[g]),.s_ready(dr[g]),.m_data(pixels[g*8+:8]),.m_de(des[g]),.m_control(controls[g*2+:2]),.m_error(errors[g]),.m_valid(dv[g]),.m_ready(ready[g]),.synchronized(locks[g]),.running_disparity(drd));
end endgenerate
reg[26:0]inputs[0:N-1];reg[29:0]codes[0:N-1];integer sent=0,eg[0:2],dg[0:2],k,cyc=0;reg[31:0]rng=32'h56473891;reg[26:0]golden;
always @(negedge clk)if(rst_n)begin
rng=rng^(rng<<13);rng=rng^(rng>>17);rng=rng^(rng<<5);ce=cyc%17>2;ready=rng[2:0];s_valid=sent<N;source=sent<N?inputs[sent]:0;
end
always @(posedge clk)if(rst_n)begin
cyc=cyc+1;if(cyc>1000000)$fatal(1,"timeout");
if(ce)begin
if(s_valid&&allready)sent=sent+1;
for(k=0;k<3;k=k+1)begin
if(ev[k]&&dr[k])begin if(eg[k]>=N||symbols[k*10+:10]!==codes[eg[k]][k*10+:10])$fatal(1,"TMDS lane oracle %d %d",k,eg[k]);eg[k]=eg[k]+1;end
if(dv[k]&&ready[k])begin
golden=inputs[dg[k]];
if(dg[k]>=N||errors[k]||des[k]!==golden[26]||pixels[k*8+:8]!==(golden[26]?golden[k*8+:8]:8'b0)||controls[k*2+:2]!==(golden[26]||k!=0?2'b0:golden[25:24]))$fatal(1,"RGB roundtrip %d %d",k,dg[k]);dg[k]=dg[k]+1;
end
end
end
if(dg[0]==N&&dg[1]==N&&dg[2]==N)begin $display("PASS TMDS RGB3 lanes tokens=%0d symbols=%0d",N,N*3);$finish;end
end
initial begin for(k=0;k<3;k=k+1)begin eg[k]=0;dg[k]=0;end $readmemh("inputs.hex",inputs);$readmemh("codes.hex",codes);repeat(3)@(negedge clk);rst_n=1;end
endmodule"""
def main():
 hashes={p.name:hashlib.sha256(p.read_bytes()).hexdigest() for p in SOURCES};rng=random.Random(7892);inputs=[0];codes=[];rd=[0,0,0]
 for line in range(80):
  for i in range(320):inputs.append((1<<26)|rng.getrandbits(24))
  for i in range(20):inputs.append(((line+i)%4)<<24)
 for token in inputs:
  codeword=0
  for lane in range(3):
   if token>>26:code,rd[lane]=encode((token>>(lane*8))&255,rd[lane])
   else:code=CONTROLS[((token>>24)&3) if lane==0 else 0];rd[lane]=0
   codeword|=code<<(lane*10)
  codes.append(codeword)
 with tempfile.TemporaryDirectory(prefix='tmds_rgb_') as tmp:
  d=Path(tmp)
  for name,values in [('inputs',inputs),('codes',codes)]: (d/(name+'.hex')).write_text(''.join(f'{v:x}\n' for v in values))
  (d/'tb.sv').write_text(TB.replace('@N@',str(len(inputs))));execute(['iverilog','-g2012','-s','tb','-o',d/'sim',*SOURCES,d/'tb.sv'],d,HERE/'rgb_compile.log');out=execute(['vvp',d/'sim'],d,HERE/'rgb_simulation.log',timeout=180);assert 'PASS TMDS' in out;print(out)
 assert hashes=={p.name:hashlib.sha256(p.read_bytes()).hexdigest() for p in SOURCES}
 (HERE/'rgb_evidence.json').write_text(json.dumps(dict(status='PASS',sources=hashes,lanes=3,rgb_pixels=25600,tokens_per_lane=len(inputs),wire_symbols=len(inputs)*3,scope='Actual three encoder->decoder RTL lanes, independent emitted-symbol and RGB/control oracle, separate output backpressure and global CE gaps. No physical serialization.'),indent=2)+'\n')
if __name__=='__main__':main()
