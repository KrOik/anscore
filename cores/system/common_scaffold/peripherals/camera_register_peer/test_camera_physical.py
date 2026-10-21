"""Independent edge-level transcripts; no owner model or test imports."""
import hashlib,json,sys,tempfile
from pathlib import Path
H=Path(__file__).resolve().parent;P=H.parents[1];O=P/'peripherals/camera_register_sequencer'
sys.path.insert(0,str(P/'integration'))
from tooling import execute

def sha(p):return hashlib.sha256(p.read_bytes()).hexdigest()
TB=r'''
`timescale 1ns/1ps
module tb;
reg clk=0;always #5 clk=~clk;
reg rst_n=0,ce=0,start_valid=0,done_ready=0;
reg[6:0]device_address=7'h30;reg sccb_mode=@SCCB@,register_address_16=@WIDE@;
wire start_ready,descriptor_ready,busy,done_valid,scl_drive_low,sda_drive_low;
reg descriptor_valid=0;reg[1:0]descriptor_op=0;reg[15:0]descriptor_register=0;
reg[7:0]descriptor_data=0,descriptor_mask=0;reg[31:0]descriptor_delay=0;
wire[31:0]descriptor_index,completed;wire[7:0]last_read,retries;wire[3:0]error_code;
reg low=0;wire scl_in=!scl_drive_low,sda_in=!(sda_drive_low||low);
camera_register_sequencer #(.HALF_PERIOD_CYCLES(@HALF@),.STRETCH_TIMEOUT_CYCLES(80),.MAX_DESCRIPTORS(3),.MAX_RETRIES(1))dut(.*);
integer all_starts=0,all_stops=0;
always @(negedge sda_in)if(rst_n&&scl_in)all_starts=all_starts+1;
always @(posedge sda_in)if(rst_n&&scl_in)all_stops=all_stops+1;
integer starts=0,stops=0,tx=0,rx=0,clocks=0;always @(posedge clk)clocks=clocks+1;
task tick;begin @(negedge clk);#1;end endtask
task begin_bus;begin : seek forever begin @(negedge sda_in);if(scl_in)begin starts=starts+1;disable seek;end end end endtask
task end_bus;begin : seek forever begin @(posedge sda_in);if(scl_in)begin stops=stops+1;disable seek;end end end endtask
task get;input[7:0]expected;input ack;reg[7:0]v;integer b;begin
 v=0;for(b=0;b<8;b=b+1)begin @(posedge scl_in);v={v[6:0],sda_in};@(negedge scl_in);end
 if(v!==expected)$fatal(1,"byte %h expected %h",v,expected);tx=tx+1;
 low=ack;@(posedge scl_in);@(negedge scl_in);low=0;
end endtask
task put;input[7:0]v;integer b;begin
 for(b=7;b>=0;b=b-1)begin low=!v[b];@(posedge scl_in);@(negedge scl_in);end
 low=0;@(posedge scl_in);if(sda_in!==1'b1)$fatal(1,"final ninth bit not released");@(negedge scl_in);rx=rx+1;
end endtask
task pointer;begin
 get(8'h60,@ACK@);if(@WIDE@)get(8'h12,1);get(8'h34,1);
end endtask
task verify_read;input[7:0]v;begin
 begin_bus;pointer;if(@SCCB@)end_bus;begin_bus;get(8'h61,@ACK@);put(v);end_bus;
end endtask
initial begin
 wait(rst_n);
 // I2C requires ACK and retries the whole descriptor after STOP. SCCB ignores high DC.
 if(!@SCCB@)begin begin_bus;get(8'h60,0);end_bus;end
 begin_bus;pointer;get(8'h5a,@ACK@);end_bus;
 verify_read(8'h70);verify_read(8'ha5);
end
task descriptor;input[1:0]op;input[31:0]d;begin
 while(!descriptor_ready)tick;
 ce=1;descriptor_valid=1;descriptor_op=op;descriptor_register=@REG@;descriptor_data=op==0?8'h5a:8'ha0;descriptor_mask=8'hf0;descriptor_delay=d;
 tick;descriptor_valid=0;ce=0;descriptor_op=3;descriptor_register=16'hffff;descriptor_data=0;descriptor_mask=0;descriptor_delay=0;
end endtask
integer stamp;reg[83:0]held;
initial begin
 repeat(4)tick;rst_n=1;ce=0;start_valid=1;repeat(3)tick;if(busy||!start_ready)$fatal(1,"CE0 start consumed");
 ce=1;tick;ce=0;start_valid=0;device_address=0;sccb_mode=!@SCCB@;register_address_16=!@WIDE@;
 repeat(3)tick;if(descriptor_index||completed||starts)$fatal(1,"fetch stall");
 descriptor(0,0);while(!descriptor_ready)tick;
 if(completed!=1||descriptor_index!=1||retries!=(!@SCCB@))$fatal(1,"write retry accounting");
 descriptor(1,0);while(!descriptor_ready)tick;
 if(completed!=2||descriptor_index!=2||last_read!=8'ha5||retries!=1)$fatal(1,"masked verify retry");
 descriptor(2,37);stamp=clocks;while(!descriptor_ready)tick;
 if(clocks-stamp<38||completed!=3||descriptor_index!=3)$fatal(1,"delay");
 descriptor(3,0);while(!done_valid)tick;
 if(error_code||completed!=3||descriptor_index!=3||retries)$fatal(1,"END boundary");
 if(starts!=(@SCCB@?5:6)||stops!=(@SCCB@?5:4)||rx!=2)$fatal(1,"counts starts%0d stops%0d",starts,stops);
 if(all_starts!=starts||all_stops!=stops)$fatal(1,"unexpected physical START/STOP");
 held={descriptor_index,completed,last_read,retries,error_code};done_ready=1;
 repeat(9)begin tick;if(!done_valid||{descriptor_index,completed,last_read,retries,error_code}!==held)$fatal(1,"CE0 done consumed");end
 ce=1;tick;done_ready=0;if(done_valid||busy)$fatal(1,"done pop");
 $display("PASS CAMERA INDEPENDENT HALF=@HALF@ SCCB=@SCCB@ WIDE=@WIDE@ starts%0d stops%0d tx%0d rx%0d",starts,stops,tx,rx);$finish;
end
initial begin #10000000;$fatal(1,"watchdog");end
endmodule
'''
def main():
 f=json.loads((O/'source_freeze.json').read_text(encoding='utf-8'));fs=sha(O/'source_freeze.json')
 dep=json.loads((O/'dependency_sha256.json').read_text(encoding='utf-8'))
 for n,d in f.items():assert sha(O/n)==d,n
 for n,d in dep.items():assert sha(P/n)==d,n
 profiles=[]
 for half in [4,13]:
  for sccb,wide in [(0,0),(0,1),(1,0)]:
   label=f'h{half}_s{sccb}_w{wide}'
   text=TB
   for k,v in dict(HALF=half,SCCB=sccb,WIDE=wide,ACK=0 if sccb else 1,REG="16'h1234" if wide else "16'h0034").items():text=text.replace('@'+k+'@',str(v))
   with tempfile.TemporaryDirectory(prefix='camera_peer_') as tmp:
    w=Path(tmp);(w/'tb.sv').write_text(text,encoding='utf-8')
    execute(['iverilog','-g2012','-s','tb','-o',w/'sim',O/'camera_register_sequencer.sv',*[P/n for n in dep],w/'tb.sv'],w,H/f'compile_{label}.log')
    out=execute(['vvp',w/'sim'],w,H/f'simulation_{label}.log');assert 'PASS CAMERA INDEPENDENT' in out
    profiles.append(dict(label=label,status='PASS',output=out))
 for n,d in f.items():assert sha(O/n)==d,n
 for n,d in dep.items():assert sha(P/n)==d,n
 report=dict(status='PASS',source_freeze_sha256=fs,owner_frozen_inputs=f,dependencies=dep,script_sha256=sha(Path(__file__)),profiles=profiles,logs={p.name:sha(p) for p in H.glob('*.log')},board_tested=False)
 (H/'pin_evidence.json').write_text(json.dumps(report,indent=2)+'\n',encoding='utf-8');print('PASS CAMERA PEER PIN',len(profiles))
if __name__=='__main__':main()
