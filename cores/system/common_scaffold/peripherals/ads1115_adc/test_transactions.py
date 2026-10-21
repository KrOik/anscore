from pathlib import Path
import hashlib,json,tempfile,sys
HERE=Path(__file__).resolve().parent;PACKAGE=HERE.parents[1]
PHY=PACKAGE/'peripherals/i2c_eeprom/i2c_eeprom_phy.sv';SOURCE=HERE/'ads1115_adc.sv'
sys.path.insert(0,str(PACKAGE/'integration'))
from tooling import execute
def hashes():return {p.name:hashlib.sha256(p.read_bytes()).hexdigest() for p in sorted(HERE.iterdir()) if p.suffix in ('.sv','.py','.md','.f') or p.name in ('manifest.json','references.json','dependency_sha256.json')}
def dependency():return {PHY.relative_to(PACKAGE).as_posix():hashlib.sha256(PHY.read_bytes()).hexdigest()}
TB=r'''
`timescale 1ns/1ps
module tb;
reg clk=0;always #5 clk=~clk;
reg rst_n=0,ce=1,start_valid=0,result_ready=0,done_ready=0;
reg[6:0]device_address=@ADDR@;reg[2:0]mux=@MUX@,pga=@PGA@,data_rate=@RATE@;
wire start_ready,result_valid,busy,done_valid;wire signed[15:0]sample;wire[15:0]config_readback;wire[31:0]polls;wire[3:0]error_code;
wire scl_drive_low,sda_drive_low;reg dev_sda=0,dev_scl=0,fault_sda=0,fault_scl=0;
wire scl_in=!(scl_drive_low||dev_scl||fault_scl),sda_in=!(sda_drive_low||dev_sda||fault_sda);
ads1115_adc #(.HALF_PERIOD_CYCLES(@HALF@),.STRETCH_TIMEOUT_CYCLES(@STRETCH@),.MAX_POLLS(@LIMIT@))dut(.*);
integer cycle=0,phase=4,bits=0,value=0,pointer=0,read_bit=0,byte_index=0;
integer starts=0,stops=0,read_bytes=0,write_bytes=0,poll_transactions=0,config_writes=0;
reg reading=0,ack=0,master_nack=0,force_off=0;reg[15:0]written=0,live_config=0,shadow_config=0,live_sample=16'h7777,shadow_sample=0;reg[7:0]out_byte;
always @(negedge clk)begin cycle=cycle+1;ce=force_off?0:cycle%11>2;end
// Device conversion is triggered only by a complete configuration write.
// Host cannot observe new conversion data before readiness; pointer read snapshots it.
always @(negedge sda_in)if(rst_n&&scl_in)begin
 starts=starts+1;phase=0;bits=0;value=0;reading=0;dev_sda=0;byte_index=0;
 shadow_config=live_config;shadow_sample=live_sample;
end
always @(posedge sda_in)if(rst_n&&scl_in)begin stops=stops+1;phase=4;reading=0;dev_sda=0;end
function[7:0]device_byte;input integer a;begin
 if(pointer==1)device_byte=a==0?shadow_config[15:8]:shadow_config[7:0];else device_byte=a==0?shadow_sample[15:8]:shadow_sample[7:0];
end endfunction
always @(posedge scl_in)if(rst_n)begin
 if(reading)begin
 if(read_bit<8)read_bit=read_bit+1;
 else if(read_bit==8)begin master_nack=sda_in;if(master_nack!=(byte_index==1))$fatal(1,"master ACK order");read_bit=9;read_bytes=read_bytes+1;end
 end else if(phase!=4)begin if(bits<8)begin value=(value<<1)|sda_in;bits=bits+1;end else if(bits==8)bits=9;end
end
always @(negedge scl_in)if(rst_n)begin
 if(reading)begin
 if(read_bit<8)begin out_byte=device_byte(byte_index);dev_sda=~out_byte[7-read_bit];end
 else if(read_bit==8)dev_sda=0;
 else begin byte_index=byte_index+1;if(master_nack)begin reading=0;phase=4;dev_sda=0;end
 else begin read_bit=0;out_byte=device_byte(byte_index);dev_sda=~out_byte[7];end end
 end else if(phase!=4)begin
 if(bits==8)begin ack=1;if(phase==0)ack=(value>>1)==@ADDR@&&!@NACK@;if(phase==2&&@DATA_NACK@)ack=0;dev_sda=ack;end
 else if(bits==9)begin
 dev_sda=0;
 if(!ack)phase=4;
 else if(phase==0)begin
 if(value&1)begin
 if(pointer==1)begin poll_transactions=poll_transactions+1;if(poll_transactions>@BUSY_POLLS@)begin live_config[15]=1;live_sample=@SAMPLE@;end end
 shadow_config=live_config;shadow_sample=live_sample;reading=1;read_bit=0;byte_index=0;out_byte=device_byte(0);dev_sda=~out_byte[7];
 end else phase=1;
 end else if(phase==1)begin pointer=value;phase=2;byte_index=0;end
 else begin
 if(pointer!=1)$fatal(1,"unexpected write pointer");
 if(byte_index==0)written[15:8]=value;else begin written[7:0]=value;live_config=written&16'h7fff;config_writes=config_writes+1;end
 byte_index=byte_index+1;write_bytes=write_bytes+1;
 end
 bits=0;value=0;
 end
 end
end
initial begin #5000000;$fatal(1,"watchdog");end
initial begin
 @INIT@
 repeat(5)@(negedge clk);rst_n=1;force_off=1;start_valid=1;
 repeat(4)@(negedge clk);if(!start_ready||busy||starts)$fatal(1,"CE0 accepted command");force_off=0;
 do @(posedge clk);while(!(ce&&start_ready));@(negedge clk);start_valid=0;
 // Inputs no longer belong to the transaction after its accepted edge.
 device_address=0;mux=0;pga=0;data_rate=0;
 @FAULT@
 wait(result_valid||done_valid);
 if(@ERROR@==0)begin
 if(!result_valid||sample!==16'(@SAMPLE@)||config_readback!==(@CONFIG@)||polls!=@EXPECTED_POLLS@)$fatal(1,"result sample/config/polls got %h %h %d",sample,config_readback,polls);
 if(written!==@WRITTEN@||config_writes!=1||write_bytes!=2||starts!=1+2*(@EXPECTED_POLLS@+1)||stops!=@EXPECTED_POLLS@+2||read_bytes!=2*(@EXPECTED_POLLS@+1))$fatal(1,"wire transaction mismatch");
 force_off=1;result_ready=1;repeat(8)begin @(posedge clk);#1;if(!result_valid||sample!==16'(@SAMPLE@)||config_readback!==@CONFIG@)$fatal(1,"held result");end
 @RESET_RESULT@
 force_off=0;wait(done_valid);
 end
 if(!done_valid||error_code!=@ERROR@)$fatal(1,"wrong terminal %d",error_code);
 if(@ERROR@==6&&(polls!=@LIMIT@||poll_transactions!=@LIMIT@||config_writes!=1))$fatal(1,"timeout count");
 if(@ERROR@==8&&starts!=0)$fatal(1,"invalid config used bus");
 force_off=1;done_ready=1;repeat(8)begin @(posedge clk);#1;if(!done_valid||error_code!=@ERROR@)$fatal(1,"held done");end
 force_off=0;wait(start_ready);
 $display("PASS ADS1115 @NAME@ starts=%0d stops=%0d rb=%0d wb=%0d polls=%0d",starts,stops,read_bytes,write_bytes,polls);$finish;
end
endmodule
'''
def run(name,**kw):
 d=dict(NAME=name,ADDR="7'h48",MUX=4,PGA=2,RATE=4,HALF=7,STRETCH=150,LIMIT=4,NACK=0,DATA_NACK=0,BUSY_POLLS=1,SAMPLE="16'h8000",ERROR=0,EXPECTED_POLLS=2,FAULT='',RESET_RESULT='',INIT='')
 d.update(kw);cfg=0x8103|(int(d['MUX'])<<12)|(int(d['PGA'])<<9)|(int(d['RATE'])<<5)
 d['WRITTEN']=f"16'h{cfg:04x}";d['CONFIG']=f"16'h{cfg:04x}"
 tb=TB
 for k,v in d.items():tb=tb.replace('@'+k+'@',str(v))
 with tempfile.TemporaryDirectory(prefix='ads1115_') as tmp:
  p=Path(tmp);(p/'tb.sv').write_text(tb,encoding='utf-8');execute(['iverilog','-g2012','-s','tb','-o',p/'sim',PHY,SOURCE,p/'tb.sv'],p,p/'compile.log')
  out=execute(['vvp',p/'sim'],p,p/'run.log',timeout=40)
  assert 'PASS ADS1115 '+name in out
 (HERE/('simulation_'+name+'.log')).write_text(out,encoding='utf-8');print(out.strip(),flush=True)
 return dict(name=name,parameters=d,log_filename='simulation_'+name+'.log',report_sha256=hashlib.sha256((HERE/('simulation_'+name+'.log')).read_bytes()).hexdigest())
def main():
 frozen=hashes();dep=dependency();rows=[]
 for name,kw in [('negative_min',{}),('zero',dict(SAMPLE="16'h0000",BUSY_POLLS=0,EXPECTED_POLLS=1)),('positive_max',dict(SAMPLE="16'h7fff",BUSY_POLLS=3,EXPECTED_POLLS=4)),('negative_one',dict(SAMPLE="16'hffff")),('addr4b',dict(ADDR="7'h4b")),('timeout',dict(BUSY_POLLS=100,ERROR=6)),('timeout_one',dict(LIMIT=1,BUSY_POLLS=100,ERROR=6)),('nack_address',dict(NACK=1,ERROR=1)),('nack_config',dict(DATA_NACK=1,ERROR=1)),('minimum_timing',dict(HALF=4,STRETCH=4)),('bad_address',dict(ADDR="7'h47",ERROR=8)),('bad_half',dict(HALF=3,ERROR=8)),('bad_stretch',dict(STRETCH=3,ERROR=8)),('bad_limit0',dict(LIMIT=0,ERROR=8)),('bad_limit_negative',dict(LIMIT=-1,ERROR=8)),('legal_stretch',dict(FAULT='wait(scl_drive_low);dev_scl=1;wait(!scl_drive_low);#90;dev_scl=0;')),('arbitration',dict(FAULT='wait(starts==1);@(negedge scl_in);#20;fault_sda=1;',ERROR=4)),('ce0_progress',dict(FAULT='force_off=1;wait(poll_transactions==2);force_off=0;')),('bus_busy',dict(INIT='fault_sda=1;',ERROR=5)),('stretch_timeout',dict(FAULT='wait(scl_drive_low);fault_scl=1;',ERROR=3)),('reset_active',dict(FAULT='wait(scl_drive_low);force_off=1;@(negedge clk);rst_n=0;repeat(4)@(negedge clk);if(!start_ready||busy||scl_drive_low||sda_drive_low||result_valid||done_valid)$fatal(1,"reset");$display("PASS ADS1115 reset_active");$finish;')),('reset_result',dict(RESET_RESULT='@(negedge clk);rst_n=0;repeat(4)@(negedge clk);if(!start_ready||result_valid||done_valid||scl_drive_low||sda_drive_low)$fatal(1,"reset held");$display("PASS ADS1115 reset_result");$finish;'))]:rows.append(run(name,**kw))
 for mux in range(8):rows.append(run('mux_'+str(mux),MUX=mux))
 for pga in range(8):rows.append(run('pga_'+str(pga),PGA=pga))
 for rate in range(8):rows.append(run('rate_'+str(rate),RATE=rate))
 assert frozen==hashes() and dep==dependency()
 (HERE/'simulation.json').write_text(json.dumps(dict(status='PASS',sources=frozen,dependency_sha256=dep,profiles=rows),indent=2)+'\n',encoding='utf-8')
if __name__=='__main__':main()
