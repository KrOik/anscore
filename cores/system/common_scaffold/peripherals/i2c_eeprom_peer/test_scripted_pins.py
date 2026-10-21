"""Independent, scripted physical-wire transcript checker; imports no owner model."""
from pathlib import Path
import hashlib,json,tempfile,sys,re
H=Path(__file__).resolve().parent;O=H.parent/'i2c_eeprom';sys.path.insert(0,str(H.parents[1]/'integration'))
from tooling import execute
sha=lambda p:hashlib.sha256(p.read_bytes()).hexdigest()
TB=r"""`timescale 1ns/1ps
module tb;
reg clk=0;always #5 clk=~clk;
reg rst_n=0,ce=0,start_valid=0,write=0,tx_valid=0,rx_ready=0,done_ready=0;
reg[6:0]device_address=7'h50;reg[15:0]word_address=0,length=0;reg[7:0]tx_data=0;
wire start_ready,tx_ready,rx_valid,rx_last,busy,done_valid;wire[7:0]rx_data;wire[3:0]error_code;wire[15:0]bytes_completed;
wire scl_drive_low,sda_drive_low;reg slave_low=0;wire scl_in=!scl_drive_low;wire sda_in=!(sda_drive_low||slave_low);
i2c_eeprom #(.ADDR_BYTES(@AB@),.CAPACITY_BYTES(@CAP@),.PAGE_BYTES(8),.HALF_PERIOD_CYCLES(@HALF@),.STRETCH_TIMEOUT_CYCLES(100),.POLL_LIMIT(4),.POLL_GAP_CYCLES(7),.HOST_TIMEOUT_CYCLES(600))dut(.*);
integer bytes_seen=0,starts=0,stops=0,poll_nacks=0,acks=0;reg slave_done=0;
task tick;begin @(negedge clk);#1;end endtask
task await_start;begin : search forever begin @(negedge sda_in);if(scl_in)begin starts=starts+1;disable search;end end end endtask
task await_stop;begin : search forever begin @(posedge sda_in);if(scl_in)begin stops=stops+1;disable search;end end end endtask
task receive;input[7:0]expected;input ack;reg[7:0]v;integer j;begin
 v=0;for(j=0;j<8;j=j+1)begin @(posedge scl_in);v={v[6:0],sda_in};@(negedge scl_in);end
 if(v!==expected)$fatal(1,"physical byte%0d got%h expected%h",bytes_seen,v,expected);bytes_seen=bytes_seen+1;
 slave_low=ack;@(posedge scl_in);if(sda_in!==!ack)$fatal(1,"slave ACK");@(negedge scl_in);slave_low=0;
end endtask
task transmit;input[7:0]v;input last;integer j;begin
 for(j=7;j>=0;j=j-1)begin slave_low=!v[j];@(posedge scl_in);@(negedge scl_in);end
 slave_low=0;@(posedge scl_in);if(sda_in!==last)$fatal(1,"master ACK/NACK final=%0d got=%b",last,sda_in);acks=acks+1;@(negedge scl_in);
end endtask
task address_bytes;input integer a;begin if(@AB@==2)receive((a>>8)&255,1);receive(a&255,1);end endtask
integer addr,remain,chunk,k,q,offset;
initial begin
 wait(rst_n);
 // Three independently specified page transactions: 2,8,3 bytes. Every page has two busy NACKs then readiness ACK.
 addr=@ADDR@;remain=13;offset=0;
 while(remain>0)begin
  chunk=8-(addr%8);if(chunk>remain)chunk=remain;
  await_start;receive(8'ha0,1);address_bytes(addr);
  for(k=0;k<chunk;k=k+1)receive((offset+k)*17+3,1);
  await_stop;
  for(q=0;q<3;q=q+1)begin await_start;receive(8'ha0,q==2);if(q!=2)poll_nacks=poll_nacks+1;await_stop;end
  addr=addr+chunk;remain=remain-chunk;offset=offset+chunk;
 end
 // Random read: pointer load then repeated START, with no intervening STOP.
 await_start;receive(8'ha0,1);address_bytes(@ADDR@);
 await_start;receive(8'ha1,1);
 for(k=0;k<13;k=k+1)transmit(k*17+3,k==12);
 await_stop;slave_done=1;
end
integer i;reg[7:0]held;integer oldstarts,oldstops;
task command;input wr;begin
 while(!start_ready)tick;write=wr;word_address=@ADDR@;length=13;start_valid=1;tick;start_valid=0;
 // The accepted descriptor is a snapshot, not a live host bus.
 word_address=0;length=1;device_address=7'h22;write=!wr;
end endtask
initial begin
 repeat(4)tick;rst_n=1;start_valid=1;repeat(12)tick;
 if(!start_ready||busy||scl_drive_low||sda_drive_low||starts)$fatal(1,"CE0 start accepted");start_valid=0;ce=1;device_address=7'h50;command(1);
 for(i=0;i<13;i=i+1)begin tx_data=i*17+3;tx_valid=1;while(!tx_ready)tick;tick;tx_valid=0;end
 while(!done_valid)tick;if(error_code||bytes_completed!=13)$fatal(1,"write result %d %d",error_code,bytes_completed);
 ce=0;done_ready=1;repeat(25)tick;if(!done_valid||error_code||bytes_completed!=13)$fatal(1,"CE0 done hold");ce=1;tick;done_ready=0;
 device_address=7'h50;command(0);
 for(i=0;i<13;i=i+1)begin
  while(!rx_valid)tick;
  if(rx_data!==((i*17+3)&255)||rx_last!==(i==12))$fatal(1,"read host byte%0d",i);
  if(i==0)begin
   held=rx_data;ce=0;rx_ready=1;oldstarts=starts;oldstops=stops;repeat(750)tick;
   if(!rx_valid||rx_data!==held||rx_last||bytes_completed||!scl_drive_low||starts!=oldstarts||stops!=oldstops)$fatal(1,"CE0 RX hold");ce=1;
  end
  rx_ready=1;tick;rx_ready=0;
 end
 while(!done_valid)tick;
 if(error_code||bytes_completed!=13)$fatal(1,"read done");while(!slave_done)tick;
 if(starts!=14||stops!=13||poll_nacks!=6||acks!=13)$fatal(1,"wire transcript start%0d stop%0d nacks%0d read%0d",starts,stops,poll_nacks,acks);
 ce=0;rst_n=0;tick;if(!start_ready||done_valid||scl_drive_low||sda_drive_low)$fatal(1,"CE0 reset");
 $display("PASS EEPROM_PEER AB=@AB@ HALF=@HALF@ starts=%0d stops=%0d busyNACK=%0d readACKs=%0d",starts,stops,poll_nacks,acks);$finish;
end
initial begin #3000000;$fatal(1,"watchdog");end
endmodule"""
def main():
 frozen=json.loads((O/'source_freeze.json').read_text(encoding='utf-8'));freeze=sha(O/'source_freeze.json')
 assert all(sha(O/n)==v for n,v in frozen.items())
 rows=[]
 for ab,cap,addr,half in [(1,256,0x76,4),(1,256,0x76,9),(2,32768,0x1fe,4),(2,65536,0x7ffe,9)]:
  label=f'a{ab}_c{cap}_h{half}';tb=TB
  for k,v in dict(AB=ab,CAP=cap,ADDR=addr,HALF=half).items():tb=tb.replace('@'+k+'@',str(v))
  with tempfile.TemporaryDirectory(prefix='eeprom_peer_') as td:
   p=Path(td);(p/'tb.sv').write_text(tb,encoding='utf-8')
   execute(['iverilog','-g2012','-s','tb','-o',p/'sim',O/'i2c_eeprom.sv',O/'i2c_eeprom_phy.sv',p/'tb.sv'],p,H/f'compile_{label}.log')
   out=execute(['vvp',p/'sim'],p,H/f'simulation_{label}.log');assert 'PASS EEPROM_PEER' in out
   rows.append(dict(label=label,address_bytes=ab,capacity=cap,address=addr,half_period=half,status='PASS',stdout=out,simulation_sha256=sha(H/f'simulation_{label}.log')));print(out,flush=True)
 assert freeze==sha(O/'source_freeze.json') and all(sha(O/n)==v for n,v in frozen.items())
 (H/'pin_evidence.json').write_text(json.dumps(dict(status='PASS',owner_source_freeze_sha256=freeze,inputs=frozen,script_sha256=sha(Path(__file__)),profiles=rows),indent=2)+'\n',encoding='utf-8')
 resources=[];syn=json.loads((O/'synthesis.json').read_text(encoding='utf-8'))
 for row in syn['profiles']:
  log=O/row['log_filename'];assert sha(log)==row['report_sha256'];out=log.read_text(encoding='utf-8');stats=out[out.rfind('=== i2c_eeprom ==='):]
  cells={k:int(v) for v,k in re.findall(r'^\s*(\d+)\s+([A-Za-z0-9_]+)\s*$',stats,re.M)}
  lut=sum(v for k,v in cells.items() if k.startswith(('LUT','ALU','MUX')) and k!='ALU54D')+4*cells.get('RAM16SDP4',0)
  dsp=sum(v for k,v in cells.items() if 'DSP' in k or 'MULT' in k or k in ('ALU54D','PADD9','PADD18'))
  bram=2*sum(v for k,v in cells.items() if k in ('SP','SPX9','DPB','DPX9B','SDPB','SDPX9B','ROM','ROMX9'))
  assert (lut,dsp,bram)==(row['lut_class'],row['dsp'],row['bram9']) and lut<=15000 and dsp<=4 and bram<=46
  resources.append(dict(log=row['log_filename'],log_sha256=sha(log),lut_class=lut,dsp=dsp,bram9=bram))
 report=dict(status='PASS',owner_source_freeze_sha256=freeze,inputs=frozen,peer_script_sha256=sha(Path(__file__)),pin_evidence_sha256=sha(H/'pin_evidence.json'),profiles=rows,resources=resources,review=dict(rtl='Reviewed scheduler/PHY: page boundary uses incremented word address; ACK polling only post STOP; random-read repeated START; final read NACK; descriptor snapshot and host CE match docs.',model='Reviewed owner model: actual page-local pointer wrap and busy-NACK are physical wire driven. Peer does not import it: scripted exact address/data/page/poll transcript and device-driven read bytes.',documentation='Geometry and CE三方qualifier limits accurately documented; no claim of complete multi-master, bus recovery, write protection detection or electrical signoff.'),scope='Read-only peer review and isolated physical digital pin simulation, no owner edits/JTAG/UART/board access')
 (H/'peer_review_eeprom.json').write_text(json.dumps(report,indent=2)+'\n',encoding='utf-8');print('PASS EEPROM_PEER_RESOURCE',resources)

if __name__=='__main__':main()
