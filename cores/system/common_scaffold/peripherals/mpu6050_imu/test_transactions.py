from pathlib import Path
import hashlib,json,tempfile,sys
HERE=Path(__file__).resolve().parent;PACKAGE=HERE.parents[1]
PHY=PACKAGE/'peripherals/i2c_eeprom/i2c_eeprom_phy.sv';SOURCE=HERE/'mpu6050_imu.sv'
sys.path.insert(0,str(PACKAGE/'integration'))
from tooling import execute
def hashes():return {p.name:hashlib.sha256(p.read_bytes()).hexdigest() for p in sorted(HERE.iterdir()) if p.suffix in ('.sv','.py','.md','.f') or p.name in ('manifest.json','references.json','dependency_sha256.json')}
def dependency():return {PHY.relative_to(PACKAGE).as_posix():hashlib.sha256(PHY.read_bytes()).hexdigest()}
TB=r'''
`timescale 1ns/1ps
module tb;
reg clk=0;always #5 clk=~clk;
reg rst_n=0,ce=1,start_valid=0,result_ready=0,done_ready=0;
reg address_ad0=@AD0@,configure=@CONFIGURE@;reg[7:0]sample_rate_divider=@DIVIDER@;reg[2:0]dlpf=@DLPF@;reg[1:0]gyro_range=@GYRO@,accel_range=@ACCEL@;
wire start_ready,result_valid,busy,done_valid;wire signed[15:0]accel_x,accel_y,accel_z,temperature,gyro_x,gyro_y,gyro_z;wire[7:0]who_am_i,interrupt_status;wire[31:0]polls;wire[3:0]error_code;
wire scl_drive_low,sda_drive_low;reg dev_sda=0,dev_scl=0,fault_sda=0,fault_scl=0;
wire scl_in=!(scl_drive_low||dev_scl||fault_scl),sda_in=!(sda_drive_low||dev_sda||fault_sda);
mpu6050_imu #(.HALF_PERIOD_CYCLES(@HALF@),.STRETCH_TIMEOUT_CYCLES(@STRETCH@),.MAX_READY_POLLS(@LIMIT@),.STARTUP_DELAY_CYCLES(@STARTUP@))dut(.*);
integer cycle=0,phase=4,bits=0,value=0,pointer=0,read_bit=0,burst_bytes=0;
integer starts=0,stops=0,read_bytes=0,write_bytes=0,status_reads=0,sensor_bursts=0,config_writes=0,last_status_stop=0,config_stop=0,first_clear_start=0;
reg reading=0,ack=0,master_nack=0,force_off=0,bus_active=0;reg[7:0]mem[0:127],shadow[0:13],out_byte,status_snapshot;
always @(negedge clk)begin cycle=cycle+1;ce=force_off?0:cycle%11>2;end
function[7:0]device_byte;input integer a;begin device_byte=a==58 ? status_snapshot : (a>=8'h3b&&a<=8'h48 ? shadow[a-8'h3b]:mem[a]);end endfunction
function[7:0]expected_register;input integer i;begin case(i)0:expected_register=8'h6b;1:expected_register=8'h6c;2:expected_register=8'h19;3:expected_register=8'h1a;4:expected_register=8'h1b;5:expected_register=8'h1c;6:expected_register=8'h37;default:expected_register=8'h38;endcase end endfunction
function[7:0]expected_value;input integer i;begin case(i)0:expected_value=1;1:expected_value=0;2:expected_value=@DIVIDER@;3:expected_value=@DLPF@;4:expected_value=@GYRO@<<3;5:expected_value=@ACCEL@<<3;6:expected_value=0;default:expected_value=1;endcase end endfunction
// A sampling event writes only the internal register set, not the active read shadow.
task sample_a;begin
 mem[59]=8'h80;mem[60]=8'h00;mem[61]=8'h7f;mem[62]=8'hff;mem[63]=8'hff;mem[64]=8'hff;mem[65]=8'h01;mem[66]=8'h54;mem[67]=0;mem[68]=0;mem[69]=8'h12;mem[70]=8'h34;mem[71]=8'hfe;mem[72]=8'hdc;
end endtask
always @(negedge sda_in)if(rst_n&&scl_in)begin
 if(!bus_active)for(integer x=0;x<14;x=x+1)shadow[x]=mem[59+x];
 bus_active=1;starts=starts+1;phase=0;bits=0;value=0;reading=0;dev_sda=0;
end
always @(posedge sda_in)if(rst_n&&scl_in)begin
 stops=stops+1;phase=4;reading=0;dev_sda=0;bus_active=0;
 if(config_writes==8&&config_stop==0)config_stop=cycle;
 if(status_reads>last_status_stop)begin
 last_status_stop=status_reads;
 // First status read clears an intentionally stale event. New data arrives later.
 if(status_reads>=@READY_AFTER@+1&&@READY_AFTER@>=0)begin mem[58]=1;sample_a;end
 end
 for(integer x=0;x<14;x=x+1)shadow[x]=mem[59+x];
end
always @(posedge scl_in)if(rst_n)begin
 if(reading)begin
 if(read_bit<8)read_bit=read_bit+1;
 else if(read_bit==8)begin
 master_nack=sda_in;if(master_nack!=(pointer<59||pointer>=72))$fatal(1,"ACK/NACK position pointer%h",pointer);
 read_bit=9;read_bytes=read_bytes+1;burst_bytes=burst_bytes+1;
 // A whole new internal frame during the burst must not mix the output sample.
 if(pointer==62)for(integer x=59;x<=72;x=x+1)mem[x]=8'hee;
 end
 end else if(phase!=4)begin if(bits<8)begin value=(value<<1)|sda_in;bits=bits+1;end else if(bits==8)bits=9;end
end
always @(negedge scl_in)if(rst_n)begin
 if(reading)begin
 if(read_bit<8)begin out_byte=device_byte(pointer);dev_sda=~out_byte[7-read_bit];end
 else if(read_bit==8)dev_sda=0;
 else begin pointer=(pointer+1)%128;if(master_nack)begin reading=0;phase=4;dev_sda=0;end else begin read_bit=0;out_byte=device_byte(pointer);dev_sda=~out_byte[7];end end
 end else if(phase!=4)begin
 if(bits==8)begin ack=1;if(phase==0)ack=(value>>1)==(7'h68+@AD0@)&&!@NACK@;if(phase==2&&@DATA_NACK@)ack=0;dev_sda=ack;end
 else if(bits==9)begin
 dev_sda=0;if(!ack)phase=4;
 else if(phase==0)begin
 if(value&1)begin
 if(pointer==58)begin
 status_snapshot=mem[58];status_reads=status_reads+1;
 if(status_reads==1)begin first_clear_start=cycle;if(@CONFIGURE@&&cycle-config_stop<@STARTUP@+1)$fatal(1,"startup short");end
 end
 if(pointer==59)begin if(status_reads<2||!interrupt_status[0])$fatal(1,"burst before new readiness");sensor_bursts=sensor_bursts+1;end
 reading=1;read_bit=0;burst_bytes=0;out_byte=device_byte(pointer);dev_sda=~out_byte[7];if(pointer==58)mem[58]=0;
 end else phase=1;
 end else if(phase==1)begin pointer=value%128;phase=2;end
 else begin
 if(pointer!=expected_register(config_writes)||value!=expected_value(config_writes))$fatal(1,"configuration snapshot/order reg%h value%h index%d",pointer,value,config_writes);
 mem[pointer]=value;pointer=(pointer+1)%128;write_bytes=write_bytes+1;config_writes=config_writes+1;
 end
 bits=0;value=0;
 end
 end
end
initial begin #5000000;$fatal(1,"watchdog");end
initial begin
 for(integer i=0;i<128;i=i+1)mem[i]=0;
 mem[117]=@WHO@;mem[58]=1;for(integer i=59;i<=72;i=i+1)mem[i]=8'h77;
 @INIT@
 repeat(5)@(negedge clk);rst_n=1;force_off=1;start_valid=1;
 repeat(5)@(negedge clk);if(!start_ready||busy||starts)$fatal(1,"CE0 start");force_off=0;
 do @(posedge clk);while(!(ce&&start_ready));@(negedge clk);start_valid=0;
 address_ad0=!@AD0@;configure=!@CONFIGURE@;sample_rate_divider=0;dlpf=7;gyro_range=0;accel_range=0;
 @FAULT@
 wait(result_valid||done_valid);
 if(@ERROR@==0)begin
 if(!result_valid||{accel_x,accel_y,accel_z,temperature,gyro_x,gyro_y,gyro_z}!==112'h80007fffffff015400001234fedc||polls!=@POLLS@||who_am_i!=8'h68||!interrupt_status[0])$fatal(1,"sample coherency/result polls%d",polls);
 if(config_writes!=8*@CONFIGURE@||sensor_bursts!=1||status_reads!=@POLLS@+1||read_bytes!=16+@POLLS@||starts!=6+2*@POLLS@+8*@CONFIGURE@||stops!=3+@POLLS@+8*@CONFIGURE@)$fatal(1,"bus counts s%d st%d rb%d status%d",starts,stops,read_bytes,status_reads);
 force_off=1;result_ready=1;repeat(8)begin @(posedge clk);#1;if(!result_valid||{accel_x,accel_y,accel_z,temperature,gyro_x,gyro_y,gyro_z}!==112'h80007fffffff015400001234fedc)$fatal(1,"held result");end
 @RESET_RESULT@
 force_off=0;wait(done_valid);
 end
 if(!done_valid||error_code!=@ERROR@)$fatal(1,"terminal error%d",error_code);
 if(@ERROR@==6&&(polls!=@LIMIT@||sensor_bursts!=0||status_reads!=@LIMIT@+1))$fatal(1,"poll budget");
 if(@ERROR@==8&&starts)$fatal(1,"invalid params used bus");
 @CHECK@
 force_off=1;done_ready=1;repeat(8)begin @(posedge clk);#1;if(!done_valid||error_code!=@ERROR@)$fatal(1,"held done");end
 force_off=0;wait(start_ready);
 $display("PASS MPU6050 @NAME@ starts=%0d stops=%0d rb=%0d wb=%0d polls=%0d",starts,stops,read_bytes,write_bytes,polls);$finish;
end
endmodule
'''
def run(name,**kw):
 d=dict(NAME=name,AD0=0,CONFIGURE=1,DIVIDER=7,DLPF=3,GYRO=2,ACCEL=1,HALF=7,STRETCH=150,LIMIT=4,STARTUP=10,NACK=0,DATA_NACK=0,READY_AFTER=1,WHO="8'h68",ERROR=0,POLLS=2,INIT='',FAULT='',RESET_RESULT='',CHECK='')
 d.update(kw);tb=TB
 for k,v in d.items():tb=tb.replace('@'+k+'@',str(v))
 with tempfile.TemporaryDirectory(prefix='mpu6050_') as tmp:
  p=Path(tmp);(p/'tb.sv').write_text(tb,encoding='utf-8');execute(['iverilog','-g2012','-s','tb','-o',p/'sim',PHY,SOURCE,p/'tb.sv'],p,p/'compile.log');out=execute(['vvp',p/'sim'],p,p/'run.log',timeout=40);assert 'PASS MPU6050 '+name in out
 log=HERE/('simulation_'+name+'.log');log.write_text(out,encoding='utf-8');print(out.strip(),flush=True)
 return dict(name=name,parameters=d,log_filename=log.name,report_sha256=hashlib.sha256(log.read_bytes()).hexdigest())
def main():
 frozen=hashes();dep=dependency();rows=[]
 profiles=[('configure_coherent',{}),('read_only',dict(CONFIGURE=0)),('read_only_ignored_config',dict(CONFIGURE=0,DLPF=7)),('address_ad0',dict(AD0=1)),('fresh_first_poll',dict(READY_AFTER=0,POLLS=1)),('last_poll_ready',dict(READY_AFTER=3,POLLS=4)),('timeout',dict(READY_AFTER=-1,ERROR=6)),('timeout_one',dict(READY_AFTER=-1,LIMIT=1,ERROR=6)),('bad_identity',dict(WHO="8'h69",ERROR=2,CHECK='if(config_writes||status_reads||sensor_bursts)$fatal(1,"wrong device side effects");')),('nack_address',dict(NACK=1,ERROR=1)),('nack_config',dict(DATA_NACK=1,ERROR=1)),('minimum_timing',dict(HALF=4,STRETCH=4,STARTUP=0)),('startup_one',dict(STARTUP=1)),('bad_half',dict(HALF=3,ERROR=8)),('bad_stretch',dict(STRETCH=3,ERROR=8)),('bad_limit',dict(LIMIT=0,ERROR=8)),('bad_startup',dict(STARTUP=-1,ERROR=8)),('reserved_dlpf',dict(DLPF=7,ERROR=8)),('legal_stretch',dict(FAULT='wait(scl_drive_low);dev_scl=1;wait(!scl_drive_low);#90;dev_scl=0;')),('stretch_timeout',dict(FAULT='wait(scl_drive_low);fault_scl=1;',ERROR=3)),('arbitration',dict(FAULT='wait(starts==1);@(negedge scl_in);#20;fault_sda=1;',ERROR=4)),('busy_bus',dict(INIT='fault_sda=1;',ERROR=5)),('ce0_progress',dict(FAULT='wait(starts==1);force_off=1;wait(result_valid);force_off=0;')),('reset_active',dict(FAULT='wait(scl_drive_low);force_off=1;@(negedge clk);rst_n=0;repeat(5)@(negedge clk);if(!start_ready||busy||done_valid||result_valid||scl_drive_low||sda_drive_low)$fatal(1,"reset");$display("PASS MPU6050 reset_active");$finish;')),('reset_result',dict(RESET_RESULT='@(negedge clk);rst_n=0;repeat(5)@(negedge clk);if(!start_ready||result_valid||done_valid||scl_drive_low||sda_drive_low)$fatal(1,"reset held");$display("PASS MPU6050 reset_result");$finish;'))]
 for name,kw in profiles:rows.append(run(name,**kw))
 for n in range(4):rows.append(run('range_'+str(n),GYRO=n,ACCEL=n))
 for n in range(7):rows.append(run('dlpf_'+str(n),DLPF=n))
 for n in [0,255]:rows.append(run('divider_'+str(n),DIVIDER=n))
 assert frozen==hashes() and dep==dependency()
 (HERE/'simulation.json').write_text(json.dumps(dict(status='PASS',sources=frozen,dependency_sha256=dep,profiles=rows),indent=2)+'\n',encoding='utf-8')
if __name__=='__main__':main()
