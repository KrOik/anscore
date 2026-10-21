"""Reset priority under CE=0 at an active reset pulse and held result."""
from test_temperature import *

def main():
 frozen=hashes();rows=[]
 for held in [False,True]:
  # Reuse only independent physical device. Replace host sequence; reset can truncate a pulse.
  text=TB
  begin=text.index('initial begin\n repeat(5)')
  end=text.index('initial begin #2000000',begin)
  text=text[:begin]+r"""
initial begin
 repeat(5)@(negedge clk);rst_n=1;repeat(5)@(negedge clk);request;
 @WAIT@
 @(negedge clk);#0.01;force_off=1;ce=0;rst_n=0;
 repeat(4)@(negedge clk);#0.01;
 if(!start_ready||ow_drive_low||busy||result_valid||done_valid||error_code)$fatal(1,"CE0 reset did not clear");
 rst_n=1;start_valid=1;repeat(5)@(negedge clk);#0.01;
 if(!start_ready||ow_drive_low||busy)$fatal(1,"CE0 accepted start");
 $display("PASS reset CE0 protocol");$finish;
end
"""+text[end:]
  values=[0x91,1,0x4b,0x46,0x7f,0xff,0x0c,0x10];values.append(crc8(values))
  args=dict(HZ=1000000,MATCH=0,ROM=f'{ROM:016x}',SCRATCH=f'{sum(b<<(8*i) for i,b in enumerate(values)):018x}',TIMEOUT=1000,STUCK=0,BUSY=0,READY_AFTER=2,READY_US=-1,SECOND_STUCK=0,NOPRESENCE=0,PRESENCE_DELAY=30,PRESENCE_WIDTH=120,REPLY_START=2,REPLY_END=15,WAIT='wait(result_valid);' if held else 'wait(ow_drive_low);repeat(20)@(negedge clk);')
  # Pin timing monitor excludes the intentional reset cancellation edge.
  text=text.replace('if(rst_n)begin\n low_width=', 'if(rst_n)begin\n low_width=')
  for k,v in args.items():text=text.replace('@'+k+'@',str(v))
  with tempfile.TemporaryDirectory(prefix='ds18_protocol_') as tmp:
   p=Path(tmp);(p/'tb.sv').write_text(text)
   execute(['iverilog','-g2012','-s','tb','-o',p/'sim',SOURCE,p/'tb.sv'],p,p/'compile.log')
   out=execute(['vvp',p/'sim'],p,p/'run.log');assert 'PASS reset CE0' in out
   rows.append(dict(held_result=held,output=out))
 assert hashes()==frozen
 (HERE/'protocol_evidence.json').write_text(json.dumps(dict(status='PASS',sources=frozen,profiles=rows),indent=2)+'\n')
 print('PASS CE0 reset cases',len(rows))
if __name__=='__main__':main()
