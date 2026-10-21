from pathlib import Path
import hashlib,json,tempfile,sys
HERE=Path(__file__).resolve().parent;PACKAGE=HERE.parents[1]
PHY=PACKAGE/'peripherals/i2c_eeprom/i2c_eeprom_phy.sv';SOURCE=HERE/'camera_register_sequencer.sv'
sys.path.insert(0,str(PACKAGE/'integration'))
from tooling import execute
def hashes():return {p.name:hashlib.sha256(p.read_bytes()).hexdigest() for p in sorted(HERE.iterdir()) if p.suffix in ('.sv','.py','.md','.f') or p.name in ('manifest.json','references.json','dependency_sha256.json')}
def dependency():return {PHY.relative_to(PACKAGE).as_posix():hashlib.sha256(PHY.read_bytes()).hexdigest()}
TB=r'''
`timescale 1ns/1ps
module tb;
reg clk=0;always #5 clk=~clk;
reg rst_n=0,ce=1,start_valid=0,done_ready=0,descriptor_valid=1;
reg[6:0]device_address=7'h21;reg sccb_mode=@SCCB@,register_address_16=@WIDE@;
wire start_ready,descriptor_ready,busy,done_valid;wire[31:0]descriptor_index,completed;wire[7:0]last_read,retries;wire[3:0]error_code;
reg[1:0]descriptor_op;reg[15:0]descriptor_register;reg[7:0]descriptor_data,descriptor_mask;reg[31:0]descriptor_delay;
wire scl_drive_low,sda_drive_low;reg dev_sda=0,dev_scl=0,fault_sda=0,fault_scl=0;
wire scl_in=!(scl_drive_low||dev_scl||fault_scl),sda_in=!(sda_drive_low||dev_sda||fault_sda);
camera_register_sequencer #(.HALF_PERIOD_CYCLES(@HALF@),.STRETCH_TIMEOUT_CYCLES(@STRETCH@),.MAX_DESCRIPTORS(@LIMIT@),.MAX_RETRIES(@RETRIES@))dut(.*);
always @*begin
 descriptor_register=0;descriptor_data=0;descriptor_mask=8'hff;descriptor_delay=0;descriptor_op=3;
 case(descriptor_index)
 0:begin descriptor_op=0;descriptor_register=@REG0@;descriptor_data=8'ha5;end
 1:begin descriptor_op=2;descriptor_delay=@DELAY@;end
 2:begin descriptor_op=1;descriptor_register=@REG0@;descriptor_data=8'ha5;end
 3:begin descriptor_op=0;descriptor_register=@REG1@;descriptor_data=8'h5a;end
 4:begin descriptor_op=1;descriptor_register=@REG1@;descriptor_data=8'h50;descriptor_mask=8'hf0;end
 endcase
 if(!descriptor_ready)begin descriptor_op=3;descriptor_register=16'hffff;descriptor_data=0;descriptor_mask=0;descriptor_delay=0;end
 @DESC_OVERRIDE@
end
integer cycle=0,phase=4,bits=0,value=0,pointer=0,regbytes=0,read_bit=0;
integer starts=0,stops=0,read_bytes=0,write_bytes=0,read_attempts=0,nack_attempts=0,accepted=0,delay_start=0;
reg reading=0,ack=0,force_off=0;reg[7:0]mem[0:65535],out_byte;
always @(negedge clk)begin cycle=cycle+1;ce=force_off?0:cycle%11>2;descriptor_valid=cycle%13>2;end
always @(posedge clk)if(rst_n&&ce&&descriptor_valid&&descriptor_ready)begin
 accepted=accepted+1;if(descriptor_index==1)delay_start=cycle;
 if(descriptor_index==2&&cycle-delay_start<@DELAY@+1)$fatal(1,"short delay");
end
always @(posedge descriptor_ready)if(rst_n&&descriptor_index==2&&cycle-delay_start!=@DELAY@+1)$fatal(1,"exact delay residency");
always @(negedge sda_in)if(rst_n&&scl_in)begin
 starts=starts+1;phase=0;bits=0;value=0;reading=0;dev_sda=0;regbytes=0;
end
always @(posedge sda_in)if(rst_n&&scl_in)begin stops=stops+1;phase=4;reading=0;dev_sda=0;end
always @(posedge scl_in)if(rst_n)begin
 if(reading)begin
 if(read_bit<8)read_bit=read_bit+1;
 else if(read_bit==8)begin if(!sda_in)$fatal(1,"read missing final NA/NACK");read_bit=9;read_bytes=read_bytes+1;end
 end else if(phase!=4)begin if(bits<8)begin value=(value<<1)|sda_in;bits=bits+1;end else if(bits==8)bits=9;end
end
always @(negedge scl_in)if(rst_n)begin
 if(reading)begin
 if(read_bit<8)dev_sda=~out_byte[7-read_bit];else if(read_bit==8)dev_sda=0;else begin reading=0;phase=4;dev_sda=0;end
 end else if(phase!=4)begin
 if(bits==8)begin
 ack=1;
 if(phase==0)begin
 if((value>>1)!=7'h21)$fatal(1,"address snapshot lost");
 if(nack_attempts<@NACK_COUNT@)begin ack=0;nack_attempts=nack_attempts+1;end
 end
 // SCCB DC ninth bit may be high; target still receives the byte.
 dev_sda=@DC_HIGH@?0:ack;
 end else if(bits==9)begin
 dev_sda=0;
 if(!ack)phase=4;
 else if(phase==0)begin
 if(value&1)begin
 read_attempts=read_attempts+1;out_byte=read_attempts<=@MISMATCH@?8'h00:mem[pointer];reading=1;read_bit=0;dev_sda=~out_byte[7];
 end else phase=1;
 end else if(phase==1)begin
 if(@WIDE@&&regbytes==0)begin pointer=value<<8;regbytes=1;end
 else begin pointer=@WIDE@?(pointer|value):value;phase=2;end
 end else begin mem[pointer]=value;write_bytes=write_bytes+1;pointer=pointer+1;end
 bits=0;value=0;
 end
 end
end
initial begin #5000000;$fatal(1,"watchdog");end
initial begin
 for(integer i=0;i<65536;i=i+1)mem[i]=0;
 @INIT@
 repeat(5)@(negedge clk);rst_n=1;force_off=1;start_valid=1;
 repeat(5)@(negedge clk);if(!start_ready||starts||busy)$fatal(1,"CE0 accepted start");force_off=0;
 do @(posedge clk);while(!(ce&&start_ready));@(negedge clk);start_valid=0;
 device_address=0;sccb_mode=0;register_address_16=0;
 @FAULT@
 wait(done_valid);
 if(error_code!=@ERROR@)$fatal(1,"wrong error got %d",error_code);
 if(@ERROR@==0)begin
 if(completed!=5||descriptor_index!=5||accepted!=6||mem[@REG0@]!=8'ha5||mem[@REG1@]!=8'h5a||last_read!=8'h5a)$fatal(1,"sequence result");
 if(write_bytes!=2||read_bytes!=@READ_BYTES@||starts!=@STARTS@||stops!=@STOPS@)$fatal(1,"bus counts %d %d %d %d",write_bytes,read_bytes,starts,stops);
 end
 @CHECK@
 force_off=1;done_ready=1;repeat(8)begin @(posedge clk);#1;if(!done_valid||error_code!=@ERROR@)$fatal(1,"unstable done");end
 force_off=0;wait(start_ready);
 $display("PASS CAMERA @NAME@ starts=%0d stops=%0d reads=%0d writes=%0d",starts,stops,read_bytes,write_bytes);$finish;
end
endmodule
'''
def run(name,**kw):
 d=dict(NAME=name,SCCB=0,WIDE=0,HALF=7,STRETCH=150,LIMIT=16,RETRIES=2,REG0="16'h0012",REG1="16'h0034",DELAY=9,NACK_COUNT=0,MISMATCH=0,DC_HIGH=0,ERROR=0,FAULT='',INIT='',CHECK='',DESC_OVERRIDE='')
 d.update(kw);extra=int(d['MISMATCH']);nack=int(d['NACK_COUNT']);d.update(READ_BYTES=2+extra,STARTS=6+2*extra+nack,STOPS=(4+extra+nack if not d['SCCB'] else 6+2*extra+nack))
 tb=TB
 for k,v in d.items():tb=tb.replace('@'+k+'@',str(v))
 with tempfile.TemporaryDirectory(prefix='camera_seq_') as tmp:
  p=Path(tmp);(p/'tb.sv').write_text(tb,encoding='utf-8');execute(['iverilog','-g2012','-s','tb','-o',p/'sim',PHY,SOURCE,p/'tb.sv'],p,p/'compile.log');out=execute(['vvp',p/'sim'],p,p/'run.log',timeout=40)
  assert 'PASS CAMERA '+name in out
 log=HERE/('simulation_'+name+'.log');log.write_text(out,encoding='utf-8');print(out.strip(),flush=True)
 return dict(name=name,parameters=d,log_filename=log.name,report_sha256=hashlib.sha256(log.read_bytes()).hexdigest())
def main():
 frozen=hashes();dep=dependency();rows=[]
 profiles=[('i2c8',{}),('i2c16',dict(WIDE=1,REG0="16'h3012",REG1="16'h7f34")),('sccb8_dc_low',dict(SCCB=1)),('sccb8_dc_high',dict(SCCB=1,DC_HIGH=1)),('i2c_strict_dc_high',dict(DC_HIGH=1,ERROR=1)),('sccb_absent_readback',dict(SCCB=1,NACK_COUNT=99,ERROR=2)),('zero_retry_nack',dict(RETRIES=0,NACK_COUNT=1,ERROR=1)),('zero_retry_verify',dict(RETRIES=0,MISMATCH=1,ERROR=2)),('masked_verify',dict(MISMATCH=1)),('retry_verify_limit',dict(MISMATCH=2)),('verify_exhausted',dict(MISMATCH=99,ERROR=2,CHECK='if(retries!=2||read_bytes!=3||completed!=2)$fatal(1,"verify retry budget");')),('nack_retry',dict(NACK_COUNT=1)),('nack_exhausted',dict(NACK_COUNT=99,ERROR=1,CHECK='if(retries!=2||starts!=3||stops!=3)$fatal(1,"NACK retries");')),('max_descriptors_exact_end',dict(LIMIT=5)),('max_retries255',dict(RETRIES=255)),('delay_one',dict(DELAY=1)),('zero_delay',dict(DELAY=0)),('minimum_timing',dict(HALF=4,STRETCH=4)),('zero_retry',dict(RETRIES=0)),('zero_mask',dict(DESC_OVERRIDE='if(descriptor_index==2||descriptor_index==4)begin descriptor_mask=0;descriptor_data=0;end')),('bad_half',dict(HALF=3,ERROR=8)),('bad_stretch',dict(STRETCH=3,ERROR=8)),('bad_limit',dict(LIMIT=0,ERROR=8)),('bad_retries',dict(RETRIES=-1,ERROR=8)),('bad_retries256',dict(RETRIES=256,ERROR=8)),('bad_sccb16',dict(SCCB=1,WIDE=1,ERROR=8)),('bad_subaddress',dict(REG0="16'h0112",ERROR=8)),('descriptor_limit',dict(LIMIT=3,ERROR=8,CHECK='if(completed!=3||descriptor_index!=3)$fatal(1,"descriptor limit");')),('busy_bus',dict(INIT='fault_sda=1;',ERROR=5)),('stretch_timeout',dict(FAULT='wait(scl_drive_low);fault_scl=1;',ERROR=3)),('legal_stretch',dict(FAULT='wait(scl_drive_low);dev_scl=1;wait(!scl_drive_low);#90;dev_scl=0;')),('arbitration',dict(FAULT='wait(starts==1);@(negedge scl_in);#20;fault_sda=1;',ERROR=4)),('ce0_progress',dict(FAULT='wait(starts==1);force_off=1;wait(stops==1);force_off=0;')),('reset_active',dict(FAULT='wait(scl_drive_low);force_off=1;@(negedge clk);rst_n=0;repeat(5)@(negedge clk);if(!start_ready||busy||done_valid||scl_drive_low||sda_drive_low)$fatal(1,"reset");$display("PASS CAMERA reset_active");$finish;'))]
 for name,kw in profiles:rows.append(run(name,**kw))
 assert frozen==hashes() and dep==dependency()
 (HERE/'simulation.json').write_text(json.dumps(dict(status='PASS',sources=frozen,dependency_sha256=dep,profiles=rows),indent=2)+'\n',encoding='utf-8')
if __name__=='__main__':main()
