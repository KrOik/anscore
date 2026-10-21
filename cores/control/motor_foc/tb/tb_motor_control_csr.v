`timescale 1ns/1ps
module tb_motor_control_csr;
reg clk=0;always #5 clk=~clk;
reg rst_n=0,ext=1,rv=0,wr=0,rr=0;reg [7:0] addr=0;reg [31:0] data=0;reg [3:0] strobe=15;
wire ready,valid,error,applied;wire [31:0] result;wire [2:0] hi,lo;
reg [3:0] divider=0;always @(posedge clk)divider<=divider+1'b1;
motor_control_csr #(.BUILD_ID(64'h123456789abcdef0)) dut(clk,rst_n,ext,divider==0,
 1'b0,1'b0,1'b0,1'b0,rv,wr,addr,data,strobe,ready,valid,error,result,rr,hi,lo,applied);
integer updates=0,n,k;reg [31:0] value,held;reg held_error;
always @(posedge clk)if(rst_n)begin if(applied)updates=updates+1;
 #1;if(hi&lo)$fatal(1,"CSR gate overlap");if(!ext&&(hi||lo))$fatal(1,"CSR async inhibit");end
task tick;begin @(posedge clk);#2;@(negedge clk);end endtask
task access;input write;input [7:0] address;input [31:0] payload;input expected_error;begin
 #1;if(!ready)$fatal(1,"CSR ready");wr=write;addr=address;data=payload;rv=1;tick;rv=0;
 while(!valid)tick;
 held=result;held_error=error;
 repeat(2)begin tick;if(!valid||ready||result!==held||error!==held_error)$fatal(1,"CSR held response");end
 if(error!=expected_error)$fatal(1,"CSR error addr%h data%h got%0d",address,payload,error);
 value=result;rr=1;tick;rr=0;
end endtask
task write_reg;input [7:0] a;input [31:0] d;begin access(1,a,d,0);end endtask
task wait_result;begin value=0;while(!value[1])access(0,4,0,0);end endtask
initial begin
 tick;rst_n=1;tick;
 access(0,0,0,0);if(value!=32'h464f4331)$fatal(1,"magic");
 access(0,8,0,0);if(value!=32'h9abcdef0)$fatal(1,"build");
 access(0,8'h80,0,1);access(1,8'h10,2,1);access(0,3,0,1);
 strobe=1;access(1,8'h70,100,1);strobe=15;
 write_reg(8'h40,256);
 for(n=0;n<3;n=n+1)begin
  write_reg(8'h78,n);write_reg(8'h5c,n==1?80:n==2?-40:0);
  write_reg(8'h60,n==1?-60:n==2?60:0);
  write_reg(8'h10,1);
  access(1,8'h78,999,1);access(1,8'h10,1,1);access(1,8'h10,4,1);
  wait_result;
  if(n==2)begin
   #2;ext=0;#1;if(hi||lo)$fatal(1,"fault gate latency");ext=1;repeat(4)tick;
   access(0,20,0,0);if(value!=1)$fatal(1,"live fault cause");
  end
  for(k=0;k<12;k=k+1)begin access(0,8'h80+k*4,0,0);$display("CSRRES %0d %0d %0d",n,k,$signed(value));end
  access(0,36,0,0);if(value!=n+1)$fatal(1,"result serial");
  write_reg(8'h10,2);access(0,8'h80,0,1);
  if(n==0)begin write_reg(8'h10,4);repeat(32)tick;write_reg(8'h10,8);write_reg(8'h10,16);end
 end
 write_reg(8'h10,32);write_reg(8'h10,4);repeat(32)tick;write_reg(8'h10,8);
 access(0,20,0,0);if(value)$fatal(1,"clear live cause");
 if(updates!=3)$fatal(1,"CSR applied count");
 write_reg(8'h40,3);write_reg(8'h78,99);write_reg(8'h10,1);wait_result;
 access(0,8'h80,0,0);if(value!=99)$fatal(1,"error sample ID");
 access(0,8'h84,0,0);if(value!=32)$fatal(1,"outer error snapshot");
 access(0,8'hac,0,0);if(value!=5)$fatal(1,"firstcause snapshot raced controller trip");
 if(updates!=3)$fatal(1,"invalid mode applied PWM");write_reg(8'h10,2);
 write_reg(8'h10,4);repeat(32)tick;write_reg(8'h10,8);
 $display("PASS motor CSR terminal error and firstcause snapshot");
 $display("PASS motor CSR three commands/golden snapshots/held responses/rejects/live fault/recovery");$finish;
end
initial begin #1000000;$fatal(1,"CSR timeout");end
endmodule
