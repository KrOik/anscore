"""Independent ADS1115 pin-slave transaction tests; no owner model imports."""
from pathlib import Path
import sys,tempfile,json,hashlib
H=Path(__file__).resolve().parent;P=H.parents[1];O=P/'peripherals/ads1115_adc'
sys.path.insert(0,str(P/'integration'))
from tooling import execute
TB=r'''
`timescale 1ns/1ps
module tb;
reg clk=0;always #5 clk=~clk;
reg rst_n=0,ce=0,start_valid=0,result_ready=0,done_ready=0;
reg[6:0]device_address=7'h48;reg[2:0]mux=0,pga=0,data_rate=0;
wire start_ready,result_valid,busy,done_valid;wire signed[15:0]sample;wire[15:0]config_readback;wire[31:0]polls;wire[3:0]error_code;
wire scl_drive_low,sda_drive_low;reg slave_low=0;wire scl_in=!scl_drive_low,sda_in=!(sda_drive_low||slave_low);
ads1115_adc #(.HALF_PERIOD_CYCLES(@HALF@),.STRETCH_TIMEOUT_CYCLES(80),.MAX_POLLS(3))dut(.*);
reg[15:0]configs[0:23],values[0:23];reg[6:0]addresses[0:23];integer starts=0,stops=0,k,j;reg slave_done=0;
task tick;begin @(negedge clk);#1;end endtask
task start;begin:scan forever begin @(negedge sda_in);if(scl_in)begin starts=starts+1;disable scan;end end end endtask
task stop;begin:scan forever begin @(posedge sda_in);if(scl_in)begin stops=stops+1;disable scan;end end end endtask
task recv;input[7:0]want;input nack;integer b;reg[7:0]got;begin
 got=0;for(b=0;b<8;b=b+1)begin @(posedge scl_in);got={got[6:0],sda_in};@(negedge scl_in);end
 if(got!==want)$fatal(1,"wire got%h want%h",got,want);
 slave_low=!nack;@(posedge scl_in);@(negedge scl_in);slave_low=0;
end endtask
task send;input[7:0]v;input last;integer b;begin
 for(b=7;b>=0;b=b-1)begin slave_low=!v[b];@(posedge scl_in);@(negedge scl_in);end
 slave_low=0;@(posedge scl_in);if(sda_in!==last)$fatal(1,"master ACK/NACK");@(negedge scl_in);
end endtask
task write_config;input[6:0]a;input[15:0]v;input fail;begin
 start;recv({a,1'b0},0);recv(1,0);recv(v[15:8],fail);
 if(!fail)recv(v[7:0],0);stop;
end endtask
task read_word;input[6:0]a;input[7:0]ptr;input[15:0]v;begin
 start;recv({a,1'b0},0);recv(ptr,0);start;recv({a,1'b1},0);send(v[15:8],0);send(v[7:0],1);stop;
end endtask
initial begin
 $readmemh("configs.hex",configs);$readmemh("values.hex",values);$readmemh("addresses.hex",addresses);wait(rst_n);
 for(k=0;k<24;k=k+1)begin
  write_config(addresses[k],configs[k],0);
  // A busy OS sample must only cause another config read, never rewrite OS.
  read_word(addresses[k],1,configs[k]&16'h7fff);if(k==23)read_word(addresses[k],1,configs[k]&16'h7fff);read_word(addresses[k],1,configs[k]);read_word(addresses[k],0,values[k]);
 end
 write_config(7'h48,16'h8103,0);repeat(3)read_word(7'h48,1,16'h0103);
 start;recv(8'h90,1);stop;
 write_config(7'h48,16'h8103,1);slave_done=1;
end
task command;input integer n;begin
 while(!start_ready)tick;device_address=addresses[n];mux=configs[n][14:12];pga=configs[n][11:9];data_rate=configs[n][7:5];
 ce=1;start_valid=1;tick;start_valid=0;ce=0;
 device_address=7'h4b;mux=7;pga=7;data_rate=7;
end endtask
task done;input[3:0]err;begin
 while(!done_valid)tick;if(error_code!=err)$fatal(1,"error code got%0d expected%0d",error_code,err);
 done_ready=1;repeat(8)begin tick;if(!done_valid||error_code!=err)$fatal(1,"CE0 held done");end
 ce=1;tick;done_ready=0;ce=0;
end endtask
integer c,oldstarts;
initial begin
 repeat(4)tick;rst_n=1;start_valid=1;repeat(8)tick;if(starts||busy)$fatal(1,"CE0 command accepted");start_valid=0;
 for(c=0;c<24;c=c+1)begin
  command(c);while(!result_valid&&!done_valid)tick;
  if(!result_valid||sample!==values[c]||config_readback!==configs[c]||polls!=(c==23?3:2))$fatal(1,"conversion data/config/polls case%0d",c);
  result_ready=1;repeat(9)begin tick;if(!result_valid||sample!==values[c]||config_readback!==configs[c]||polls!=(c==23?3:2)||done_valid)$fatal(1,"CE0 held result");end
  ce=1;tick;result_ready=0;ce=0;done(0);
 end
 command(0);done(6);if(polls!=3)$fatal(1,"MAX_POLLS accounting");
 command(0);done(1);command(0);done(1);
 oldstarts=starts;while(!start_ready)tick;device_address=7'h47;ce=1;start_valid=1;tick;start_valid=0;ce=0;done(8);if(starts!=oldstarts)$fatal(1,"invalid address touched bus");
 while(!slave_done)tick;
 rst_n=0;tick;if(result_valid||done_valid||scl_drive_low||sda_drive_low)$fatal(1,"reset outputs");
 $display("PASS ADS1115 INDEPENDENT HALF=@HALF@ cases24 starts%0d stops%0d signed_neg12",starts,stops);$finish;
end
initial begin #10000000;$fatal(1,"watchdog");end
endmodule
'''
def sha(p):return hashlib.sha256(p.read_bytes()).hexdigest()
def main():
 frozen=json.loads((O/'source_freeze.json').read_text(encoding='utf-8'));freeze_sha=sha(O/'source_freeze.json')
 for n,d in frozen.items():assert sha(O/n)==d,n
 sources=[O/'ads1115_adc.sv',P/'peripherals/i2c_eeprom/i2c_eeprom_phy.sv'];before={p.relative_to(P).as_posix():sha(p) for p in sources}
 configs=[0x8103|((n%8)<<12)|(((n*3)%8)<<9)|(((n*5)%8)<<5) for n in range(24)]
 values=[[-32768,-1,0,32767][n%4]&65535 for n in range(24)];addresses=[0x48+n%4 for n in range(24)];rows=[]
 for half in [4,13]:
  with tempfile.TemporaryDirectory(prefix='ads1115_peer_') as td:
   p=Path(td);(p/'tb.sv').write_text(TB.replace('@HALF@',str(half)),encoding='utf-8')
   for name,data in [('configs',configs),('values',values),('addresses',addresses)]: (p/(name+'.hex')).write_text('\n'.join((f'{v:02x}' if name=='addresses' else f'{v:04x}') for v in data),encoding='utf-8')
   execute(['iverilog','-g2012','-s','tb','-o',p/'sim',*sources,p/'tb.sv'],p,H/f'compile_{half}.log');out=execute(['vvp',p/'sim'],p,H/f'simulation_{half}.log');assert 'PASS ADS1115 INDEPENDENT' in out;print(out.strip(),flush=True);rows.append(dict(half=half,status='PASS',output=out))
 assert before=={p.relative_to(P).as_posix():sha(p) for p in sources}
 for n,d in frozen.items():assert sha(O/n)==d,n
 assert sha(O/'source_freeze.json')==freeze_sha
 (H/'pin_evidence.json').write_text(json.dumps(dict(status='PASS',source_freeze_sha256=freeze_sha,owner_frozen_inputs=frozen,sources=before,script_sha256=sha(Path(__file__)),profiles=rows,configuration_cases=24,mux_encodings=list(range(8)),pga_encodings=list(range(8)),data_rate_encodings=list(range(8)),scope='Physical digital I2C task model; OS0->OS1 progression, no early data/retrigger, all descriptor fields, signed limits, CE0/backpressure, timeout, NACK and invalid address. No analog or board claim.'),indent=2)+'\n',encoding='utf-8')
if __name__=='__main__':main()
