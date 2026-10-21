"""Independent pin-only 24xx device model with physical page wrap and busy NACK."""
from pathlib import Path
import sys,tempfile,json,hashlib
HERE=Path(__file__).resolve().parent
sys.path.insert(0,str(HERE.parents[1]/'integration'))
from tooling import execute
SOURCES=[HERE/'i2c_eeprom.sv',HERE/'i2c_eeprom_phy.sv']
def hashes():
 return {p.name:hashlib.sha256(p.read_bytes()).hexdigest() for p in sorted(HERE.iterdir()) if p.suffix in ('.sv','.py','.md','.f','.vh') or p.name in ('manifest.json','references.json')}
TB=r'''
`timescale 1ns/1ps
module tb;
reg clk=0;always #5 clk=~clk;
reg rst_n=0,ce=1,start_valid=0,write=0,tx_valid=0,rx_ready=0,done_ready=0;
reg[6:0]device_address=7'h50;reg[15:0]word_address=0,length=0;
reg[7:0]tx_data=0;wire start_ready,tx_ready,rx_valid,rx_last,busy,done_valid;
wire[7:0]rx_data;wire[3:0]error_code;wire[15:0]bytes_completed;
wire scl_drive_low,sda_drive_low;reg dev_sda=0,dev_scl=0,fault_sda=0,fault_scl=0;
wire scl_in=!(scl_drive_low||dev_scl||fault_scl),sda_in=!(sda_drive_low||dev_sda||fault_sda);
i2c_eeprom #(.ADDR_BYTES(@ADDR_BYTES@),.CAPACITY_BYTES(@CAPACITY@),.PAGE_BYTES(@PAGE@),.HALF_PERIOD_CYCLES(@HALF@),.STRETCH_TIMEOUT_CYCLES(80),.POLL_LIMIT(5),.POLL_GAP_CYCLES(8),.HOST_TIMEOUT_CYCLES(600))dut(.*);
reg[7:0]mem[0:65535];integer cycle=0,j;
// The device model sees only physical wires, never DUT state/counters.
integer phase=0,bits=0,value=0,pointer=0,addr_acc=0,addr_count=0,read_bit=0;
integer starts=0,stops=0,page_writes=0,write_bytes=0,read_bytes=0,poll_nacks=0,busy_left=0,pagebase=0;
reg selected=0,reading=0,ack=0,write_dirty=0,master_nack=0,force_off=0;
always @(negedge clk)begin cycle=cycle+1;ce=force_off?0:(cycle%11>2);end
always @(negedge sda_in)if(scl_in&&rst_n)begin
 starts=starts+1;phase=0;bits=0;value=0;reading=0;selected=0;dev_sda=0;
end
always @(posedge sda_in)if(scl_in&&rst_n)begin
 stops=stops+1;phase=4;reading=0;dev_sda=0;
 if(write_dirty)begin page_writes=page_writes+1;busy_left=@BUSY_POLLS@;write_dirty=0;end
end
always @(posedge scl_in)if(rst_n)begin
 if(reading)begin
  if(read_bit<8)read_bit=read_bit+1;
  else if(read_bit==8)begin master_nack=sda_in;read_bit=9;read_bytes=read_bytes+1;end
 end else if(phase!=4)begin
  if(bits<8)begin value=(value<<1)|sda_in;bits=bits+1;end
  else if(bits==8)bits=9;
 end
end
always @(negedge scl_in)if(rst_n)begin
 if(reading)begin
  if(read_bit<8)dev_sda=~mem[pointer][7-read_bit];
  else if(read_bit==8)dev_sda=0;
  else begin
   pointer=(pointer+1)%@CAPACITY@;
   if(master_nack)begin reading=0;phase=4;dev_sda=0;end
   else begin read_bit=0;dev_sda=~mem[pointer][7];end
  end
 end else if(phase!=4)begin
  if(bits==8)begin
   ack=1;
   if(phase==0)begin
    ack=(value>>1)==7'h50&&!@NACK_DEV@;
    if(@NACK_READ@&&(value&1))ack=0;
    if(busy_left>0)begin ack=0;busy_left=busy_left-1;poll_nacks=poll_nacks+1;end
   end else if(phase==2&&@NACK_DATA@)ack=0;
   else if(phase==1&&@NACK_ADDR@)ack=0;
   dev_sda=ack;
  end else if(bits==9)begin
   dev_sda=0;
   if(!ack)phase=4;
   else if(phase==0)begin
    selected=1;
    if(value&1)begin reading=1;read_bit=0;dev_sda=~mem[pointer][7];end
    else begin phase=1;addr_acc=0;addr_count=0;end
   end else if(phase==1)begin
    addr_acc=(addr_acc<<8)|value;addr_count=addr_count+1;
    if(addr_count==@ADDR_BYTES@)begin pointer=addr_acc%@CAPACITY@;pagebase=pointer&~(@PAGE@-1);phase=2;end
   end else if(phase==2)begin
    mem[pointer]=value;pointer=pagebase|((pointer+1)&(@PAGE@-1));write_bytes=write_bytes+1;write_dirty=1;
   end
   bits=0;value=0;
  end
 end
end
// Controlled legal clock stretching on every master low-to-high transition.
always @(posedge scl_drive_low)if(rst_n&&@STRETCH@)begin dev_scl=1;fork begin @(negedge scl_drive_low);#90;dev_scl=0;end join_none end
reg held=0;reg[8:0]held_payload;
always @(posedge clk)if(rst_n)begin
 if(held&&(!rx_valid||{rx_last,rx_data}!==held_payload))$fatal(1,"read payload changed while stalled");
 held=rx_valid&&!(ce&&rx_ready);held_payload={rx_last,rx_data};
end else held=0;
task automatic request;input wr;input integer a,n;begin
 @(negedge clk);#1;write=wr;word_address=a;length=n;start_valid=1;
 @(posedge clk);while(!(ce&&start_ready))@(posedge clk);
 @(negedge clk);#1;start_valid=0;device_address=0;word_address=65535;length=0;write=~wr;
end endtask
task automatic completion;input integer expected,count;begin
 wait(done_valid);@(negedge clk);#1;
 if(error_code!=expected||bytes_completed!=count||busy||scl_drive_low||sda_drive_low)$fatal(1,"done error%0d expected%0d count%0d exp%0d",error_code,expected,bytes_completed,count);
 force_off=1;ce=0;done_ready=1;repeat(5)@(negedge clk);#1;if(!done_valid)$fatal(1,"CE0 consumed DONE");
 force_off=0;
 @(posedge clk);while(!ce)@(posedge clk);
 @(negedge clk);#1;done_ready=0;device_address=7'h50;
 if(!start_ready)$fatal(1,"not idle after DONE");
end endtask
initial begin
 for(j=0;j<65536;j=j+1)mem[j]=(j*13+7)&255;
 repeat(5)@(negedge clk);#1;rst_n=1;repeat(5)@(negedge clk);
 @HOST@
 $display("PASS EEPROM @LABEL@ starts=%0d stops=%0d pages=%0d wb=%0d rb=%0d pollnack=%0d",starts,stops,page_writes,write_bytes,read_bytes,poll_nacks);$finish;
end
initial begin #10000000;$fatal(1,"watchdog");end
endmodule
'''
WRITE_READ=r'''
 request(1,@ADDRESS@,@LENGTH@);
 for(integer x=0;x<@LENGTH@;x=x+1)begin
  repeat(x%3)@(negedge clk);#1;tx_valid=1;tx_data=(x*17+91)&255;
  @(posedge clk);while(!(ce&&tx_ready))@(posedge clk);
  @(negedge clk);#1;tx_valid=0;
 end
 completion(0,@LENGTH@);
 if(page_writes!=@PAGES@||write_bytes!=@LENGTH@||poll_nacks!=@PAGES@*@BUSY_POLLS@)$fatal(1,"page splitting/ACK polling count pages%0d",page_writes);
 for(integer x=0;x<@LENGTH@;x=x+1)if(mem[@ADDRESS@+x]!==((x*17+91)&255))$fatal(1,"page wrapping corrupted memory x%0d",x);
 request(0,@ADDRESS@,@LENGTH@);
 for(integer x=0;x<@LENGTH@;x=x+1)begin
  wait(rx_valid);@(negedge clk);#1;
  if(rx_data!==((x*17+91)&255)||rx_last!=(x==@LENGTH@-1))$fatal(1,"sequential read byte%0d data%h",x,rx_data);
  force_off=1;ce=0;rx_ready=1;repeat(5)@(negedge clk);#1;if(!rx_valid)$fatal(1,"CE0 consumed RX");
  force_off=0;
  @(posedge clk);while(!ce)@(posedge clk);
  @(negedge clk);#1;rx_ready=0;
 end
 completion(0,@LENGTH@);
 if(read_bytes!=@LENGTH@)$fatal(1,"read beat count");
'''

def run(label,addr_bytes=2,capacity=32768,page=64,address=62,length=133,host=None,nack_dev=False,nack_data=False,busy_polls=2,stretch=False,half=6,nack_addr=False,nack_read=False):
 pages=(address%page+length+page-1)//page
 args=dict(NACK_ADDR=int(nack_addr),NACK_READ=int(nack_read),HALF=half,LABEL=label,ADDR_BYTES=addr_bytes,CAPACITY=capacity,PAGE=page,ADDRESS=address,LENGTH=length,PAGES=pages,NACK_DEV=int(nack_dev),NACK_DATA=int(nack_data),BUSY_POLLS=busy_polls,STRETCH=int(stretch),HOST=WRITE_READ if host is None else host)
 text=TB
 for _ in range(2):
  for k,v in args.items():text=text.replace('@'+k+'@',str(v))
 with tempfile.TemporaryDirectory(prefix='i2c_eeprom_') as tmp:
  p=Path(tmp);(p/'tb.sv').write_text(text,encoding='utf-8')
  execute(['iverilog','-g2012','-s','tb','-o',p/'sim',*SOURCES,p/'tb.sv'],p,p/'compile.log')
  out=execute(['vvp',p/'sim'],p,p/'run.log');assert 'PASS EEPROM' in out
  (HERE/('simulation_'+label+'.log')).write_text(out,encoding='utf-8');print(out.strip(),flush=True)
 return dict(label=label,addr_bytes=addr_bytes,capacity=capacity,page=page,address=address,length=length,output=out)

def main():
 frozen=hashes();rows=[]
 rows.append(run('cross_page_16bit'))
 rows.append(run('cross_page_8bit',addr_bytes=1,capacity=256,page=8,address=7,length=27))
 rows.append(run('single_last_byte',addr_bytes=2,capacity=65536,page=128,address=65535,length=1))
 rows.append(run('clock_stretch',address=63,length=3,stretch=True))
 assert hashes()==frozen
 (HERE/'transaction_evidence.json').write_text(json.dumps(dict(status='PASS',sources=frozen,profiles=rows),indent=2)+'\n',encoding='utf-8')
if __name__=='__main__':main()
