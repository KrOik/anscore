"""Independent CSI-2 TX byte oracle and randomized CE/backpressure regression."""
from pathlib import Path
import binascii, hashlib, json, random, sys, tempfile
HERE=Path(__file__).resolve().parent
sys.path.insert(0,str(HERE.parents[1]/'integration'))
from tooling import execute
RTL=HERE/'csi2_packet_tx.sv'
ROWS=((0,1,2,4,5,7,10,11,13,16,20,21,22,23),(0,1,3,4,6,8,10,12,14,17,20,21,22,23),(0,2,3,5,6,9,11,12,15,18,20,21,22),(1,2,3,7,8,9,13,14,15,19,20,21,23),(4,5,6,7,8,9,16,17,18,19,20,22,23),(10,11,12,13,14,15,16,17,18,19,21,22,23))
def rev(x,n):return int(f'{x:0{n}b}'[::-1],2)
def crc(data):return rev(binascii.crc_hqx(bytes(rev(x,8) for x in data),65535),16)
def packet(vc,dt,wc,data):
 h=bytes([(vc<<6)|dt,wc&255,wc>>8]);v=int.from_bytes(h,'little')
 e=sum((sum((v>>i)&1 for i in r)%2)<<j for j,r in enumerate(ROWS))
 return h+bytes([e])+(data+crc(data).to_bytes(2,'little') if dt>=16 else b'')
assert crc(b'123456789')==0x6f91
TB=r'''module tb;
reg clk=0;always #5 clk=~clk;
reg rst_n=0,ce=1,start_valid=0,abort=0;
reg[1:0]cfg_vc=0;reg[5:0]cfg_dt=0;reg[15:0]cfg_word_count=0;
reg[7:0]s_data=0;reg s_valid=0,s_last=0,m_ready=0,done_ready=0;
wire start_ready,s_ready,m_valid,m_sof,m_last,done_valid,done_error,busy;
wire[7:0]m_data,error_code;wire[31:0]output_bytes;
csi2_packet_tx dut(.*);
reg[7:0]ins[0:IN_N-1],outs[0:OUT_N-1];
reg[63:0]cmd[0:CASE_N-1];
integer c=0,i=0,o=0,ib=0,ob=0,n,w,vc,dt,err,cyc=0,got=0;
reg held=0;reg[9:0]prev;
wire[9:0]token={m_sof,m_last,m_data};
always @(negedge clk)begin
cyc=cyc+1;ce=cyc%17>2;m_ready=cyc%13<8;
if(cyc>5000000)$fatal(1,"timeout");
end
always @(posedge clk)if(rst_n)begin
 if(held&&(!m_valid||token!==prev))$fatal(1,"unstable output");
 held=m_valid&&!(ce&&m_ready);prev=token;
 if(ce&&m_valid&&m_ready)begin
 if(m_data!==outs[ob+got]||m_sof!==(got==0)||m_last!==(got==n-1))$fatal(1,"byte mismatch case %d byte %d",c,got);
 got=got+1;
 end
end
initial begin
$readmemh("input.hex",ins);$readmemh("output.hex",outs);$readmemh("commands.hex",cmd);
repeat(3)@(negedge clk);rst_n=1;
for(c=0;c<CASE_N;c=c+1)begin
 {err,vc,dt,w,n}=0;
 err=cmd[c][63:56];vc=cmd[c][49:48];dt=cmd[c][45:40];w=cmd[c][31:16];n=cmd[c][15:0];
 if(dt>=16&&w==65535)n=65541;
 got=0;i=0;
 @(negedge clk);cfg_vc=vc;cfg_dt=dt;cfg_word_count=w;start_valid=1;
 do @(posedge clk);while(!(ce&&start_ready));
 @(negedge clk);start_valid=0;cfg_dt=7;cfg_vc=3;cfg_word_count=0;
 while(!done_valid)begin
 s_valid=i<w&&dt>=16;s_data=ins[ib+i];s_last=i==w-1;
 @(posedge clk);if(ce&&s_ready&&s_valid)i=i+1;
 @(negedge clk);
 end
 s_valid=0;
 if(done_error!==(err!=0)||error_code!==err||got!=n||output_bytes!=n)$fatal(1,"report mismatch %d got %d n %d",c,got,n);
 repeat(5)begin @(posedge clk);if(!done_valid)$fatal(1,"DONE dropped");end
 @(negedge clk);done_ready=1;
 do @(posedge clk);while(!ce);
 @(negedge clk);done_ready=0;
 ib=ib+(dt>=16&&err==0?w:0);ob=ob+n;
end
$display("PASS CSI2 TX cases=%0d bytes=%0d",CASE_N,ob);$finish;
end
endmodule'''
def main():
 rng=random.Random(781);cases=[]
 for vc in range(4):
  for dt in range(64):
   wc=rng.randrange(65536) if dt<16 else (dt+vc)%23
   cases.append((vc,dt,wc,bytes(rng.randrange(256) for _ in range(wc)) if dt>=16 else b''))
 for wc in [0,1,4096,65535]:cases.append((2,0x2b,wc,bytes((i*37+11)&255 for i in range(wc))))
 inputs=b'';outputs=b'';commands=[]
 for vc,dt,wc,data in cases:
  bad=4<=dt<=7;wire=b'' if bad else packet(vc,dt,wc,data)
  inputs+=data;outputs+=wire
  commands.append((int(bad)<<56)|(vc<<48)|(dt<<40)|(wc<<16)|(len(wire)&65535))
 with tempfile.TemporaryDirectory(prefix='csi2_tx_test_') as t:
  d=Path(t)
  for name,seq,width in [('input',inputs,2),('output',outputs,2),('commands',commands,16)]:
   (d/(name+'.hex')).write_text(''.join(f'{x:0{width}x}\n' for x in seq))
  tb=TB.replace('IN_N',str(len(inputs))).replace('OUT_N',str(len(outputs))).replace('CASE_N',str(len(cases)))
  (d/'tb.sv').write_text(tb)
  execute(['iverilog','-g2012','-s','tb','-o',d/'sim',RTL,d/'tb.sv'],d,HERE/'main_compile.log')
  out=execute(['vvp',d/'sim'],d,HERE/'main_simulation.log',timeout=180)
  assert 'PASS' in out
 (HERE/'main_evidence.json').write_text(json.dumps(dict(status='PASS',source_sha256=hashlib.sha256(RTL.read_bytes()).hexdigest(),cases=len(cases),output_bytes=len(outputs),crc_kat='6f91',scope='All 64 DT x 4 VC, 65535 WC, byte oracle, CE, stall, cfg capture and DONE drain'),indent=2)+'\n')
 print(out)
if __name__=='__main__':main()
