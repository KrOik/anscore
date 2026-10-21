"""Independent wire model: sensor live words advance during frozen burst reads."""
from pathlib import Path
import hashlib,json,sys,tempfile
H=Path(__file__).resolve().parent;P=H.parents[1];O=P/'peripherals/mpu6050_imu'
sys.path.insert(0,str(P/'integration'))
from tooling import execute
def sha(p):return hashlib.sha256(p.read_bytes()).hexdigest()
TB=r'''
`timescale 1ns/1ps
module tb;
reg clk=0;always #5 clk=~clk;
reg rst_n=0,ce=0,start_valid=0,result_ready=0,done_ready=0;
reg address_ad0=0,configure=0;reg[7:0]sample_rate_divider=0;reg[2:0]dlpf=0;reg[1:0]gyro_range=0,accel_range=0;
wire start_ready,result_valid,busy,done_valid,scl_drive_low,sda_drive_low;
wire signed[15:0]accel_x,accel_y,accel_z,temperature,gyro_x,gyro_y,gyro_z;
wire[7:0]who_am_i,interrupt_status;wire[31:0]polls;wire[3:0]error_code;
reg low=0;wire scl_in=!scl_drive_low,sda_in=!(sda_drive_low||low);
mpu6050_imu #(.HALF_PERIOD_CYCLES(@HALF@),.STRETCH_TIMEOUT_CYCLES(80),.MAX_READY_POLLS(3),.STARTUP_DELAY_CYCLES(37))dut(.*);
integer starts=0,stops=0,total_starts=0,total_stops=0,tx=0,rx=0,clock_count=0,results=0;
always @(posedge clk)clock_count=clock_count+1;
always @(negedge sda_in)if(rst_n&&scl_in)total_starts=total_starts+1;
always @(posedge sda_in)if(rst_n&&scl_in)total_stops=total_stops+1;
always @(posedge clk)if(rst_n&&ce&&result_valid&&result_ready)results=results+1;
task tick;begin @(negedge clk);#1;end endtask
task begin_bus;begin : seek forever begin @(negedge sda_in);if(scl_in)begin starts=starts+1;disable seek;end end end endtask
task end_bus;begin : seek forever begin @(posedge sda_in);if(scl_in)begin stops=stops+1;disable seek;end end end endtask
task get;input[7:0]expected;input ack;reg[7:0]v;integer b;begin
 v=0;for(b=0;b<8;b=b+1)begin @(posedge scl_in);v={v[6:0],sda_in};@(negedge scl_in);end
 if(v!==expected)$fatal(1,"byte %h expected %h",v,expected);tx=tx+1;low=ack;@(posedge scl_in);@(negedge scl_in);low=0;
end endtask
task put;input[7:0]v;input last;integer b;begin
 for(b=7;b>=0;b=b-1)begin low=!v[b];@(posedge scl_in);@(negedge scl_in);end
 low=0;@(posedge scl_in);if(sda_in!==last)$fatal(1,"ACK/NACK mismatch");@(negedge scl_in);rx=rx+1;
end endtask
task read_one;input[7:0]address,ptr,value;begin
 begin_bus;get(address,1);get(ptr,1);begin_bus;get(address|1,1);put(value,1);end_bus;
end endtask
reg[7:0]regs[0:7],vals[0:7];reg[15:0]live[0:6],shadow[0:6];
integer s,j,b,p,stamp;reg[7:0]addr;
initial begin
 regs[0]=8'h6b;regs[1]=8'h6c;regs[2]=8'h19;regs[3]=8'h1a;regs[4]=8'h1b;regs[5]=8'h1c;regs[6]=8'h37;regs[7]=8'h38;
 wait(rst_n);
 for(s=0;s<4;s=s+1)begin
  addr=(s%2)?8'hd2:8'hd0;read_one(addr,8'h75,8'h68);
  if(s<2)begin
   vals[0]=1;vals[1]=0;vals[2]=s?255:0;vals[3]=s?6:0;vals[4]=s?24:0;vals[5]=s?16:8;vals[6]=0;vals[7]=1;
   for(j=0;j<8;j=j+1)begin begin_bus;get(addr,1);get(regs[j],1);get(vals[j],1);end_bus;end
   stamp=clock_count;
  end
  // A stale DATA_RDY must be consumed unconditionally, then wait for new readiness.
  begin_bus;if(s<2&&clock_count-stamp<38)$fatal(1,"startup delay too short");get(addr,1);get(8'h3a,1);begin_bus;get(addr|1,1);put(1,1);end_bus;
  read_one(addr,8'h3a,0);read_one(addr,8'h3a,0);read_one(addr,8'h3a,1);
  begin_bus;get(addr,1);get(8'h3b,1);begin_bus;get(addr|1,1);
  live[0]=16'h8000+s;live[1]=16'hffff-s;live[2]=16'h7fff-s;live[3]=16'h0000+s;live[4]=16'h1234+s;live[5]=16'hfedc-s;live[6]=16'h0102+s;
  for(j=0;j<7;j=j+1)shadow[j]=live[j];
  for(b=0;b<14;b=b+1)begin
   // Internal sampling continues; the user-facing bank stays fixed for the whole serial burst.
   for(j=0;j<7;j=j+1)live[j]=live[j]+16'h3111;
   put(b%2?shadow[b/2][7:0]:shadow[b/2][15:8],b==13);
  end
  end_bus;
 end
 // Read-only timeout: stale ready must never be mistaken for a fresh sample.
 read_one(8'hd0,8'h75,8'h68);read_one(8'hd0,8'h3a,1);
 for(p=0;p<3;p=p+1)read_one(8'hd0,8'h3a,0);
 // AD0=1 does not change WHO_AM_I; returning69 must fail.
 read_one(8'hd2,8'h75,8'h69);
 begin_bus;get(8'hd0,0);end_bus;
end
task launch;input ad,cfg;input[7:0]divider;input[2:0]filter;input[1:0]g,a;begin
 ce=1;while(!start_ready)tick;address_ad0=ad;configure=cfg;sample_rate_divider=divider;dlpf=filter;gyro_range=g;accel_range=a;start_valid=1;tick;
 start_valid=0;ce=0;address_ad0=!ad;configure=!cfg;sample_rate_divider=31;dlpf=7;gyro_range=1;accel_range=3;
end endtask
integer k;reg[111:0]expected,held;
initial begin
 repeat(4)tick;rst_n=1;tick;
 for(k=0;k<4;k=k+1)begin
  launch(k%2,k<2,k%2?255:0,k%2?6:0,k%2?3:0,k%2?2:1);
  while(!result_valid)begin tick;if(done_valid)$fatal(1,"unexpected fail%0d",error_code);end
  expected={16'h8000+k[15:0],16'hffff-k[15:0],16'h7fff-k[15:0],16'h0000+k[15:0],16'h1234+k[15:0],16'hfedc-k[15:0],16'h0102+k[15:0]};
  held={accel_x,accel_y,accel_z,temperature,gyro_x,gyro_y,gyro_z};
  if(held!==expected||who_am_i!=8'h68||interrupt_status!=1||polls!=3||error_code)$fatal(1,"coherent signed order/status");
  result_ready=1;repeat(9)begin tick;if(!result_valid||{accel_x,accel_y,accel_z,temperature,gyro_x,gyro_y,gyro_z}!==held)$fatal(1,"CE0 result hold");end
  ce=1;tick;result_ready=0;ce=0;if(!done_valid||error_code)$fatal(1,"result pop");
  done_ready=1;repeat(3)begin tick;if(!done_valid)$fatal(1,"CE0 done hold");end
  ce=1;tick;done_ready=0;ce=0;
 end
 launch(0,0,0,0,0,0);while(!done_valid)begin tick;if(result_valid)$fatal(1,"timeout published sample");end
 if(error_code!=6||polls!=3)$fatal(1,"poll exhaustion");ce=1;done_ready=1;tick;done_ready=0;
 launch(1,0,0,0,0,0);while(!done_valid)begin tick;if(result_valid)$fatal(1,"bad identity published sample");end
 if(error_code!=2||who_am_i!=8'h69)$fatal(1,"identity");ce=1;done_ready=1;tick;done_ready=0;
 launch(0,0,0,0,0,0);while(!done_valid)begin tick;if(result_valid)$fatal(1,"NACK published sample");end
 if(error_code!=1||results!=4||total_starts!=starts||total_stops!=stops)$fatal(1,"terminal/accounting");
 $display("PASS MPU6050 INDEPENDENT HALF=@HALF@ samples4 shadow_updates56 errors3 starts%0d stops%0d tx%0d rx%0d",starts,stops,tx,rx);$finish;
end
initial begin #20000000;$fatal(1,"watchdog");end
endmodule
'''
def main():
 f=json.loads((O/'source_freeze.json').read_text(encoding='utf-8'));fs=sha(O/'source_freeze.json');dep=json.loads((O/'dependency_sha256.json').read_text(encoding='utf-8'))
 for n,d in f.items():assert sha(O/n)==d,n
 for n,d in dep.items():assert sha(P/n)==d,n
 profiles=[]
 for half in [4,13]:
  with tempfile.TemporaryDirectory(prefix='mpu_peer_') as tmp:
   w=Path(tmp);(w/'tb.sv').write_text(TB.replace('@HALF@',str(half)),encoding='utf-8')
   execute(['iverilog','-g2012','-s','tb','-o',w/'sim',O/'mpu6050_imu.sv',*[P/n for n in dep],w/'tb.sv'],w,H/f'compile_{half}.log')
   out=execute(['vvp',w/'sim'],w,H/f'simulation_{half}.log');assert 'PASS MPU6050 INDEPENDENT' in out;profiles.append(dict(half=half,status='PASS',output=out))
 for n,d in f.items():assert sha(O/n)==d,n
 for n,d in dep.items():assert sha(P/n)==d,n
 report=dict(status='PASS',source_freeze_sha256=fs,owner_frozen_inputs=f,dependencies=dep,script_sha256=sha(Path(__file__)),profiles=profiles,logs={p.name:sha(p) for p in H.glob('*.log')},board_tested=False)
 (H/'pin_evidence.json').write_text(json.dumps(report,indent=2)+'\n',encoding='utf-8');print('PASS MPU6050 PEER PIN',len(profiles))
if __name__=='__main__':main()
