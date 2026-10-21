"""Abort/reset every parser phase, terminal immutability, CE-disabled reset."""
from run_tests import HERE,RTL,packet,execute
from pathlib import Path
import hashlib,json,tempfile
TB=r'''module tb;
reg clk=0;always #5 clk=~clk;
reg rst_n=0,ce=1,start_valid=0,cfg_check_sequence=0,abort=0;
reg s_last=0,h_ready=0,m_ready=0,p_ready=0,done_ready=0;
reg enable_input=0,block_h=0,block_m=0,block_p=0,force_off=0,terminal_input=1;
wire[7:0]s_data;wire s_valid;reg[7:0]bytes_in[0:9];integer tx=0;
assign s_data=bytes_in[tx<10?tx:9];assign s_valid=enable_input&&tx<10;
always @*s_last=terminal_input&&tx==9;
wire start_ready,s_ready,h_valid,h_short,h_corrected,m_valid,m_first,m_last;
wire[1:0]h_vc,m_vc,p_vc;wire[5:0]h_dt,m_dt,p_dt;wire[15:0]h_word_count;
wire[7:0]m_data,p_error_code,error_code;wire p_valid,p_error,p_header_valid,p_short,p_corrected,p_last;
wire[15:0]p_word_count,p_payload_bytes,p_crc_calculated,p_crc_received;
wire done_valid,done_error,busy;wire[31:0]packet_count,corrected_count,crc_error_count;
wire[3:0]frame_active,line_active;
csi2_packet_rx dut(.*);
wire[25:0]htoken={h_vc,h_dt,h_word_count,h_short,h_corrected};
wire[17:0]mtoken={m_vc,m_dt,m_first,m_last,m_data};
wire[84:0]ptoken={p_vc,p_dt,p_word_count,p_short,p_corrected,p_payload_bytes,p_crc_calculated,p_crc_received,p_last,p_error,p_error_code,p_header_valid};
reg held_h=0,held_m=0,held_p=0;reg[25:0]prev_h;reg[17:0]prev_m;reg[84:0]prev_p;
integer cyc=0,hits_h=0,hits_m=0,hits_p=0,phase=0,kind=0,recoveries=0,aborts=0,resets=0;
always @(negedge clk)begin
cyc=cyc+1;ce=!force_off&&cyc%11>1;
h_ready=!block_h&&cyc%9<6;m_ready=!block_m&&cyc%7<4;p_ready=!block_p&&cyc%13<8;
if(cyc>200000)$fatal(1,"protocol timeout %d %d %d",kind,phase,dut.state);
end
always @(posedge clk)begin
if(!rst_n)begin held_h=0;held_m=0;held_p=0;end
else begin
 if(!(ce&&abort))begin
 if(held_h&&(!h_valid||htoken!==prev_h))$fatal(1,"protocol hhold");
 if(held_m&&(!m_valid||mtoken!==prev_m))$fatal(1,"protocol mhold");
 end
 if(held_p&&(!p_valid||ptoken!==prev_p))$fatal(1,"protocol phold");
 held_h=h_valid&&!(ce&&(h_ready||abort));held_m=m_valid&&!(ce&&(m_ready||abort));held_p=p_valid&&!(ce&&p_ready);
 prev_h=htoken;prev_m=mtoken;prev_p=ptoken;
 if(ce&&s_valid&&s_ready)tx<=tx+1;
 if(ce&&!abort&&h_valid&&h_ready)hits_h=hits_h+1;
 if(ce&&!abort&&m_valid&&m_ready)begin
 if(m_data!==bytes_in[4+hits_m]||m_first!==(hits_m==0)||m_last!==(hits_m==3)||m_vc!=2||m_dt!=43)$fatal(1,"protocol payload");hits_m=hits_m+1;
 end
 if(ce&&p_valid&&p_ready)hits_p=hits_p+1;
end end
task tick;begin @(negedge clk);#1;end endtask
task accepted_edge;begin
begin:wait_ce while(1)begin @(posedge clk);if(ce)begin tick;disable wait_ce;end end end
end endtask
task start_stream;begin
tx=0;hits_h=0;hits_m=0;hits_p=0;start_valid=1;enable_input=1;
begin:wait_start while(1)begin @(posedge clk);if(ce&&start_ready)begin tick;disable wait_start;end end end
start_valid=0;
end endtask
function target;
input integer n;
begin case(n)
0,1,2,3:target=dut.state==1&&dut.header_index==n;
4:target=dut.state==2;
5:target=dut.state==3;
6:target=dut.state==4&&!dut.payload_valid;
7:target=dut.state==4&&dut.payload_valid;
8:target=dut.state==5;
9:target=dut.state==6;
10,11:target=dut.state==7;
12:target=dut.state==8;
default:target=0;
endcase end endfunction
task ack_done;begin
enable_input=0;done_ready=1;
begin:wait_done while(1)begin @(posedge clk);if(ce&&done_valid)begin tick;disable wait_done;end end end
done_ready=0;
end endtask
task healthy;begin
block_h=0;block_m=0;block_p=0;terminal_input=1;abort=0;force_off=0;
start_stream;while(!done_valid)tick;
if(done_error||error_code||hits_h!=1||hits_m!=4||hits_p!=1||packet_count!=1||corrected_count||crc_error_count)$fatal(1,"recovery %d",recoveries);
repeat(6)tick;if(!done_valid||p_valid||m_valid||h_valid)$fatal(1,"recovery hold");
ack_done;recoveries=recoveries+1;
end endtask
reg[84:0]saved_report;reg[8:0]saved_done;
initial begin
$readmemh("BYTE_FILE",bytes_in);repeat(3)tick;rst_n=1;tick;
// Abort all active states; final report already committed wins over abort.
for(phase=0;phase<12;phase=phase+1)begin
block_h=phase==5;block_m=phase==7;block_p=1;terminal_input=phase!=10;
start_stream;while(!target(phase))tick;
enable_input=0;
// An abort presented with CE=0 must not alter registered state/tokens.
force_off=1;ce=0;tick;abort=1;repeat(3)tick;
if(!target(phase))$fatal(1,"CE-off abort advanced");
force_off=0;accepted_edge;abort=0;
if(phase<10)begin
if(!p_valid||!p_error||p_error_code!=9||!p_last)$fatal(1,"abort packet phase %d",phase);
end else if(!p_valid||p_error||p_error_code)$fatal(1,"committed report changed");
saved_report=ptoken;repeat(7)tick;
if(!p_valid||ptoken!==saved_report)$fatal(1,"abort report unstable");
block_p=0;while(!done_valid)tick;
if(done_error!==(phase!=11)||error_code!==(phase==11?8'd0:8'd9))$fatal(1,"abort stream phase %d error %h",phase,error_code);
saved_done={done_error,error_code};abort=1;repeat(6)tick;abort=0;
if(!done_valid||saved_done!=={done_error,error_code})$fatal(1,"late abort changed done");
ack_done;aborts=aborts+1;healthy;
end
// Reset at every active state plus final report and held DONE, with CE=0.
kind=1;
for(phase=0;phase<13;phase=phase+1)begin
block_h=phase==5;block_m=phase==7;block_p=phase<12;terminal_input=1;
start_stream;while(!target(phase))tick;
enable_input=0;force_off=1;ce=0;tick;rst_n=0;repeat(3)tick;
if(busy||h_valid||m_valid||p_valid||done_valid||s_ready||start_ready)$fatal(1,"reset outputs");
rst_n=1;tick;
if(dut.state!=0||packet_count||corrected_count||crc_error_count||frame_active||line_active)$fatal(1,"CE-off reset state");
force_off=0;tick;resets=resets+1;healthy;
end
// Idle abort inhibits start without creating an orphan terminal event.
enable_input=0;abort=1;start_valid=1;repeat(7)tick;
if(dut.state!=0||done_valid||p_valid||start_ready)$fatal(1,"idle abort");
abort=0;start_valid=0;healthy;
$display("CSI2 PROTOCOL PASS ABORT_PHASES=%d CE_OFF_RESETS=%d RECOVERY_FRAMES=%d",aborts,resets,recoveries);$finish;
end endmodule'''
def main():
 source_sha=hashlib.sha256(RTL.read_bytes()).hexdigest()
 with tempfile.TemporaryDirectory(prefix='csi2_packet_protocol_') as temp:
  d=Path(temp);p=d/'bytes.hex';p.write_text('\n'.join(f'{b:02x}' for b in packet(2,43,bytes([0x19,0x38,0xff,0]))))
  (d/'tb.sv').write_text(TB.replace('BYTE_FILE',p.as_posix()))
  execute(['iverilog','-g2012','-s','tb','-o',d/'sim.vvp',RTL,d/'tb.sv'],HERE,HERE/'protocol_compile.log')
  out=execute(['vvp',d/'sim.vvp'],HERE,HERE/'protocol_simulation.log')
  assert 'CSI2 PROTOCOL PASS' in out
 assert source_sha==hashlib.sha256(RTL.read_bytes()).hexdigest()
 (HERE/'protocol_evidence.json').write_text(json.dumps(dict(status='PASS',source_sha256=source_sha,abort_phases=12,ce_disabled_resets=13,successful_recovery_frames=26,simulation=out.strip()),indent=2)+'\n')
 print(out.strip(),flush=True)
if __name__=='__main__':main()
