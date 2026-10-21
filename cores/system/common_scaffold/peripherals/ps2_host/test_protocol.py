from run_tests import *
P=r'''module tb;
reg clk=0;always #5 clk=~clk;reg rst_n=0,ce=1,abort=0,dev_clk_low=0,dev_data_low=0;
wire ps2_clk_drive_low,ps2_data_drive_low;wire ps2_clk_in=!ps2_clk_drive_low&&!dev_clk_low,ps2_data_in=!ps2_data_drive_low&&!dev_data_low;
reg[7:0]tx_data=0;reg tx_valid=0,tx_done_ready=0;wire tx_ready,tx_done_valid;wire[7:0]tx_error_code,rx_data,rx_error_code;wire rx_valid,rx_error_valid,busy;reg rx_ready=0,rx_error_ready=0;wire[31:0]rx_error_count,rx_overflow_count;
ps2_host #(.CLK_HZ(1000000),.FILTER_CYCLES(3),.RX_FIFO_DEPTH(3),.EDGE_TIMEOUT_CYCLES(2000))dut(.*);
integer cycles=0,i,j,k,checks=0,base_errors=0;reg[7:0]held;
always @(posedge clk)begin cycles=cycles+1;if(cycles>1000000)$fatal(1,"timeout state %d",dut.ts);if(dut.push&&dut.fetch&&dut.wp==dut.rp)$fatal(1,"FIFO collision");end
 task tick;begin @(negedge clk);#1;end endtask
 task waitn;input integer n;integer z;begin for(z=0;z<n;z=z+1)tick;end endtask
 task devbit;input b;begin dev_data_low=!b;dev_clk_low=0;waitn(40);dev_clk_low=1;waitn(40);dev_clk_low=0;end endtask
 task sendrx;input[7:0]v;input integer err;integer z;begin devbit(0);for(z=0;z<8;z=z+1)devbit(v[z]);devbit((~^v)^(err==2));devbit(err!=3);dev_data_low=0;waitn(100);end endtask
 task getrx;input[7:0]v;begin while(!rx_valid)tick;if(rx_data!==v)$fatal(1,"RX wanted %h got %h",v,rx_data);ce=1;rx_ready=1;tick;rx_ready=0;checks=checks+1;end endtask
 task rxerr;input[7:0]v;begin if(!rx_error_valid||rx_error_code!=v)$fatal(1,"RXerror got%h want%h",rx_error_code,v);ce=0;rx_error_ready=1;waitn(4);if(!rx_error_valid)$fatal(1,"RX error CEhold");ce=1;tick;rx_error_ready=0;if(rx_error_valid)$fatal(1,"RXerror ACK");checks=checks+1;end endtask
 task recover;begin dev_clk_low=0;dev_data_low=0;waitn(100);sendrx(8'ha5,0);getrx(8'ha5);end endtask
 task launch;input[7:0]v;begin ce=1;dev_clk_low=0;dev_data_low=0;while(!tx_ready)tick;tx_data=v;tx_valid=1;tick;tx_valid=0;end endtask
 task hostbits;integer z;begin while(ps2_clk_drive_low)tick;waitn(40);for(z=0;z<10;z=z+1)begin dev_clk_low=1;waitn(40);dev_clk_low=0;waitn(40);end end endtask
 task txreport;input[7:0]v;begin while(!tx_done_valid)tick;if(tx_error_code!=v||ps2_clk_drive_low||ps2_data_drive_low)$fatal(1,"TXerror got%h want%h",tx_error_code,v);dev_clk_low=0;dev_data_low=0;ce=0;tx_done_ready=1;waitn(6);if(!tx_done_valid||tx_ready)$fatal(1,"TXDONECEhold");ce=1;tick;tx_done_ready=0;waitn(100);checks=checks+1;end endtask
 initial begin repeat(4)tick;rst_n=1;waitn(100);
 // Paired clock/data spikes shorter than FILTER_CYCLES cannot manufacture a frame.
 for(i=0;i<12;i=i+1)begin dev_clk_low=1;dev_data_low=1;waitn(2);dev_clk_low=0;dev_data_low=0;waitn(20);end
 if(rx_valid||rx_error_valid||dut.rx_active)$fatal(1,"glitch accepted");recover;
 sendrx(8'h53,2);rxerr(2);recover;sendrx(8'hf0,3);rxerr(3);recover;
 devbit(0);devbit(1);dev_data_low=0;waitn(2100);rxerr(6);recover;
 devbit(0);devbit(1);dev_data_low=0;ce=0;abort=1;waitn(10);if(!dut.rx_active)$fatal(1,"CE0abort RX");ce=1;tick;abort=0;rxerr(9);recover;
 // RX sampling continues at CE0; retained queue preserves all four capacity bytes.
 ce=0;base_errors=rx_error_count;for(i=0;i<6;i=i+1)sendrx(i,0);
 if(rx_overflow_count!=2||rx_error_count!=base_errors+2||!rx_error_valid||rx_error_code!=4)$fatal(1,"overflow accounting");
 held=rx_data;waitn(20);if(!rx_valid||rx_data!==held)$fatal(1,"CE0RXhold");ce=1;for(i=0;i<4;i=i+1)getrx(i);rxerr(4);recover;
 launch(8'hff);hostbits;dev_data_low=0;dev_clk_low=1;waitn(40);dev_clk_low=0;txreport(5);recover;
 launch(8'h55);while(dut.ts!=3)tick;ce=0;waitn(2100);txreport(6);recover;
 launch(8'h55);hostbits;ce=0;waitn(2100);txreport(6);recover;
 launch(8'h55);hostbits;dev_data_low=1;dev_clk_low=1;waitn(40);dev_clk_low=0;ce=0;waitn(2100);txreport(6);recover;
 // Device holds DATA low against a transmitted1: explicit wired-AND collision.
 launch(8'hff);while(ps2_clk_drive_low)tick;waitn(40);dev_clk_low=1;waitn(40);dev_data_low=1;dev_clk_low=0;waitn(40);txreport(7);recover;
 for(j=1;j<=5;j=j+1)begin launch(8'h5a);
  if(j==2)while(dut.ts!=2)tick;
  if(j>=3)while(dut.ts!=3)tick;
  if(j>=4)hostbits;
  if(j==5)begin dev_data_low=1;dev_clk_low=1;waitn(20);end
  if(dut.ts!=j)$fatal(1,"state reach%d actual%d",j,dut.ts);
  ce=0;abort=1;waitn(8);if(tx_done_valid)$fatal(1,"CE0abort TX");ce=1;tick;abort=0;txreport(9);recover;
 end
 // Pending TX cannot preempt an incoming start/data frame; request waits for idle qualification.
 dev_data_low=1;waitn(20);tx_valid=1;tx_data=8'hf4;waitn(20);if(ps2_clk_drive_low)$fatal(1,"TX preempted RX start");dev_clk_low=1;waitn(40);dev_clk_low=0;
 for(i=0;i<8;i=i+1)begin devbit(8'h1c>>i&1);if(ps2_clk_drive_low)$fatal(1,"TX/RX collision arbitration");end
 devbit(~^8'h1c);devbit(1);dev_data_low=0;while(!ps2_clk_drive_low)tick;tx_valid=0;abort=1;tick;abort=0;txreport(9);getrx(8'h1c);recover;
 // Device reply must be received while TX completion is held and host CE is off.
 launch(8'hed);hostbits;dev_data_low=1;dev_clk_low=1;waitn(40);dev_clk_low=0;waitn(40);dev_data_low=0;
 while(!tx_done_valid)tick;ce=0;waitn(100);sendrx(8'hfa,0);sendrx(8'haa,0);
 if(!tx_done_valid||tx_error_code!=0||!rx_valid||rx_data!=8'hfa||rx_error_valid)$fatal(1,"held TXDONE lost device reply");
 getrx(8'hfa);getrx(8'haa);txreport(0);recover;
 // A device pulling stop low violates the host stop bit, even if ACK follows low.
 launch(8'h55);while(ps2_clk_drive_low)tick;waitn(40);
 for(i=0;i<10;i=i+1)begin dev_clk_low=1;if(i==9)dev_data_low=1;waitn(40);dev_clk_low=0;waitn(40);end
 txreport(7);recover;
 // Reset in partial RX and active TX overrides CE, releases open-collector pins, clears queue/status.
 devbit(0);ce=0;rst_n=0;tick;if(busy||rx_valid||rx_error_valid||ps2_clk_drive_low||ps2_data_drive_low)$fatal(1,"RXreset");rst_n=1;ce=1;dev_data_low=0;waitn(100);recover;
 launch(8'hff);while(dut.ts!=3)tick;ce=0;rst_n=0;tick;if(busy||tx_done_valid||ps2_clk_drive_low||ps2_data_drive_low)$fatal(1,"TXreset");rst_n=1;ce=1;waitn(100);recover;
 $display("PASS PS2 PROTOCOL checks=%d",checks);$finish;end
endmodule'''
def main():
 out=execute_tb('protocol',P);print(out);(H/'protocol_evidence.json').write_text(json.dumps(dict(status='PASS',rtl_sha256=hashlib.sha256(RTL.read_bytes()).hexdigest(),scope='Glitch filtering, parity/stop/RXtimeout/RXabort, CE0RX FIFO overflow explicit counts and ordered drain, TXnack/BITS ACK RELEASE timeout/collision/all5states abort, RX-priority pending TX arbitration, CE0reset and healthy RX recovery after every error',output=out),indent=2)+'\n')
if __name__=='__main__':main()
