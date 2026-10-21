"""Independent TMDS oracle with reachable disparity and whole-symbol validation."""
from pathlib import Path
import hashlib,json,random,sys,tempfile
HERE=Path(__file__).resolve().parent
sys.path.insert(0,str(HERE.parents[1]/'integration'))
from tooling import execute
SOURCES=[HERE/'tmds_encoder.sv',HERE/'tmds_decoder.sv']
CONTROLS=[0b1101010100,0b0010101011,0b0101010100,0b1010101011]
def encode(data,rd):
 # Stage1 chooses XOR or XNOR to minimize transitions. Build using integer bits,
 # then update disparity by counting the ACTUAL ten emitted bits, not RTL algebra.
 use_xor=data.bit_count()<4 or (data.bit_count()==4 and data&1)
 q=data&1;previous=q
 for i in range(1,8):
  previous=previous^((data>>i)&1)^(not use_xor)
  q|=previous<<i
 balance=q.bit_count()*2-8
 if rd==0 or balance==0:invert=not use_xor
 else:invert=(rd>0)==(balance>0)
 symbol=(int(invert)<<9)|(int(use_xor)<<8)|(q^(255 if invert else 0))
 new_rd=rd+symbol.bit_count()*2-10
 return symbol,new_rd
def witnesses():
 paths={0:[]};todo=[0]
 for rd in todo:
  for byte in range(256):
   _,n=encode(byte,rd)
   if n not in paths:
    assert abs(n)<=16
    paths[n]=paths[rd]+[byte];todo.append(n)
 return paths
PATHS=witnesses()
assert sorted(PATHS)==list(range(-8,9,2))
TB=r"""module tb;
localparam DIR=@DIR@,N=@N@;
reg clk=0;always #5 clk=~clk;reg rst_n=0,ce=1,s_valid=0,m_ready=0;
reg[10:0]input_token=0;wire s_ready,m_valid;wire signed[5:0]running_disparity;
wire[11:0]out_token;wire sync_;
generate if(DIR==0)begin
wire[9:0]symbol;
tmds_encoder dut(.clk(clk),.rst_n(rst_n),.ce(ce),.s_data(input_token[7:0]),.s_de(input_token[10]),.s_control(input_token[9:8]),.s_valid(s_valid),.s_ready(s_ready),.m_symbol(symbol),.m_valid(m_valid),.m_ready(m_ready),.running_disparity(running_disparity));assign out_token={2'b0,symbol};assign sync_=1;
end else begin
tmds_decoder dut(.clk(clk),.rst_n(rst_n),.ce(ce),.s_symbol(input_token[9:0]),.s_valid(s_valid),.s_ready(s_ready),.m_data(out_token[7:0]),.m_de(out_token[10]),.m_control(out_token[9:8]),.m_error(out_token[11]),.m_valid(m_valid),.m_ready(m_ready),.synchronized(sync_),.running_disparity(running_disparity));
end endgenerate
reg[10:0]inputs[0:N-1];reg[18:0]expected[0:N-1];integer sent=0,got=0,cyc=0;reg held=0;reg[11:0]oldtoken;reg[18:0]accepted_expected;reg[31:0]rng=32'h9735a129;
always @(negedge clk)if(rst_n)begin
rng=rng^(rng<<13);rng=rng^(rng>>17);rng=rng^(rng<<5);ce=cyc%19>3;m_ready=rng[3];
input_token=sent<N?inputs[sent]:0;s_valid=sent<N;
end
always @(posedge clk)if(rst_n)begin
cyc=cyc+1;if(cyc>2000000)$fatal(1,"timeout");
if(held&&(!m_valid||out_token!==oldtoken))$fatal(1,"held token changed");held=m_valid&&!(ce&&m_ready);oldtoken=out_token;
if(ce&&m_valid&&m_ready)begin
if(got>=N||out_token!==expected[got][11:0])$fatal(1,"oracle DIR %d index %d got %h expected %h",DIR,got,out_token,expected[got][11:0]);got=got+1;
end
if(ce&&s_valid&&s_ready)begin
accepted_expected=expected[sent];sent=sent+1;
#1;if(running_disparity!==accepted_expected[17:12]||sync_!==accepted_expected[18])$fatal(1,"state mismatch DIR %d input %d rd %d expected %d",DIR,sent,running_disparity,$signed(accepted_expected[17:12]));
end
if(got==N)begin $display("PASS TMDS direction=%0d tokens=%0d",DIR,N);$finish;end
end
initial begin $readmemh("inputs.hex",inputs);$readmemh("expected.hex",expected);repeat(3)@(negedge clk);rst_n=1;end
endmodule"""
def simulate(name,direction,inputs,expected):
 assert len(inputs)==len(expected)
 with tempfile.TemporaryDirectory(prefix='tmds_codec_test_',dir=None) as tmp:
  d=Path(tmp);(d/'inputs.hex').write_text(''.join(f'{v:03x}\n' for v in inputs));(d/'expected.hex').write_text(''.join(f'{v:05x}\n' for v in expected));(d/'tb.sv').write_text(TB.replace('@DIR@',str(direction)).replace('@N@',str(len(inputs))))
  execute(['iverilog','-g2012','-s','tb','-o',d/'sim',*SOURCES,d/'tb.sv'],d,HERE/(name+'_compile.log'))
  out=execute(['vvp',d/'sim'],d,HERE/(name+'_simulation.log'),timeout=180);assert 'PASS TMDS' in out;print(out,flush=True)
def encoder_vectors():
 ins=[];expected=[];rd=0
 def control(c):
  nonlocal rd
  rd=0;ins.append(c<<8);expected.append((1<<18)|CONTROLS[c])
 def data(v):
  nonlocal rd
  code,rd=encode(v,rd);ins.append(1024|v);expected.append((1<<18)|((rd&63)<<12)|code)
 for state,path in sorted(PATHS.items()):
  for byte in range(256):
   control(byte%4)
   for b in path:data(b)
   assert rd==state;data(byte)
 rng=random.Random(892)
 for i in range(24000):
  if i%683==0:control((i//683)%4)
  else:data(rng.randrange(256))
 return ins,expected

def decoder_vectors():
 ins=[];expected=[];rd=0;locked=False
 def symbol(code):
  nonlocal rd,locked
  ins.append(code)
  if code in CONTROLS:
   rd=0;locked=True;token=CONTROLS.index(code)<<8
  else:
   table={encode(b,rd)[0]:b for b in range(256)} if locked else {}
   if code in table:
    value=table[code];_,rd=encode(value,rd);token=1024|value
   else:rd=0;locked=False;token=2048
  expected.append((int(locked)<<18)|((rd&63)<<12)|token)
 # Reset leaves unsynchronized; even a valid video symbol must error until control.
 symbol(encode(0,0)[0])
 invalid=0;valid=0
 for state,path in sorted(PATHS.items()):
  valid_codes={encode(b,state)[0] for b in range(256)}
  assert len(valid_codes)==256 and not(valid_codes&set(CONTROLS))
  for code in range(1024):
   symbol(CONTROLS[code%4])
   for b in path:symbol(encode(b,rd)[0])
   assert rd==state
   symbol(code)
   if code not in valid_codes and code not in CONTROLS:
    invalid+=1;symbol(encode(0,0)[0]) # unsynchronized video stays invalid
   else:valid+=1
   symbol(CONTROLS[(code+1)%4])
   symbol(encode(code&255,0)[0]) # every error/control reacquires and recovers
 return ins,expected,invalid,valid

def main():
 source_hashes={p.name:hashlib.sha256(p.read_bytes()).hexdigest() for p in SOURCES}
 ei,ee=encoder_vectors();simulate('encoder',0,ei,ee)
 di,de,invalid,valid=decoder_vectors();simulate('decoder',1,di,de)
 assert source_hashes=={p.name:hashlib.sha256(p.read_bytes()).hexdigest() for p in SOURCES}
 (HERE/'evidence.json').write_text(json.dumps(dict(status='PASS',sources=source_hashes,reachable_disparities=sorted(PATHS),encoder_tokens=len(ei),decoder_tokens=len(di),encoder_exhaustive_pairs=256*len(PATHS),decoder_exhaustive_pairs=1024*len(PATHS),invalid_symbol_contexts=invalid,valid_or_control_contexts=valid,scope='Independent integer oracle, all byte/disparity pairs, all 1024 symbols in every reachable disparity, controls, invalid-loss/reacquisition, long data, CE gaps, held tokens and exact internal RD state.'),indent=2)+'\n')
if __name__=='__main__':main()
