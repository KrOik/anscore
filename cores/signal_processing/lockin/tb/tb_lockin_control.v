`timescale 1ns/1ps
module tb_lockin_control;
 parameter SIN_FILE="",COS_FILE="";
 reg clk=0;always #5 clk=~clk;
 reg rst_n=0,rv=0,rw=0,rr=0;reg[7:0] addr=0;reg[31:0] data=0;reg[3:0] strb=15;
 wire ready,valid,error;wire[31:0] result;wire[7:0] probe;
 reg[31:0] got,status,low;reg[63:0] first,last,previous_last=0;integer run,lane;
 lockin_control #(.BUILD_ID(64'h123456789abcdef0),.SIN_FILE(SIN_FILE),.COS_FILE(COS_FILE))
  dut(clk,rst_n,rv,rw,addr,data,strb,ready,valid,error,result,rr,probe);
 task bus(input bit write,input[7:0] a,input[31:0] d,input bit expect_error);
 reg[31:0] held;
 begin
  @(negedge clk);rv=1;rw=write;addr=a;data=d;
  do @(posedge clk);while(!ready);
  @(negedge clk);rv=0;
  wait(valid);#1;held=result;got=result;
  if(!write&&!error&&a>=8'h80)$display("CSR_WORD run=%0d address=%0d value=%0d",run,a,got);
  if(error!==expect_error)$fatal(1,"CSR error addr=%h got=%b",a,error);
  repeat(3)begin @(negedge clk);if(!valid||result!==held||ready)$fatal(1,"CSR response stall");end
  rr=1;@(negedge clk);rr=0;
 end endtask
 task put(input[3:0] n,input[31:0] d);begin bus(1,8'h40+n*4,d,0);end endtask
 task wait_done;begin
  status=0;
  while(!status[1])begin bus(0,4,0,0);status=got;end
 end endtask
 initial begin
  repeat(4)@(negedge clk);rst_n=1;
  bus(0,0,0,0);if(got!=32'h4c4f434b)$fatal(1,"magic");
  bus(0,20,0,0);if(got!=32'h9abcdef0)$fatal(1,"build");
  bus(0,8'h80,0,1);bus(1,16,1,1);bus(0,1,0,1);bus(1,0,0,1);
  put(0,32'h01000000);put(1,4);put(2,8);put(3,100);put(4,10000);
  put(5,{16'd4000,16'd1000});put(6,{16'd24000,16'd12000});
  put(7,{8'd96,8'd192,8'd32,8'd0});put(8,0);put(9,0);
  put(10,32'h80008000);put(11,32'h80008000);put(12,0);
  bus(1,12,1,0);
  // Queue an operation during the active measurement.
  put(3,101);bus(1,12,1,0);bus(1,8'h4c,102,1);
  bus(1,12,1,1);
  for(run=100;run<=101;run=run+1)begin
   wait_done;
   bus(0,8'h80,0,0);if(got!=run)$fatal(1,"queued id");
   bus(0,8'h84,0,0);if(got)$fatal(1,"measurement error");
   bus(0,8'h88,0,0);bus(0,8'h8c,0,0);bus(0,8'h94,0,0);
   bus(0,8'h90,0,0);if(got!=256)$fatal(1,"accepted count");
   bus(0,8'h98,0,0);low=got;bus(0,8'h9c,0,0);first={got,low};
   bus(0,8'ha0,0,0);low=got;bus(0,8'ha4,0,0);last={got,low};
   if(last-first!=1020||first<=previous_last)$fatal(1,"CSR timestamps");
   previous_last=last;
   for(lane=0;lane<4;lane=lane+1)begin
    bus(0,8'hb0+lane*12,0,0);
    $display("CSR_IQ run=%0d lane=%0d i=%0d q=%0d",run,lane,$signed(got[15:0]),$signed(got[31:16]));
    bus(0,8'hb4+lane*12,0,0);low=got;
    bus(0,8'hb8+lane*12,0,0);
    $display("CSR_POLAR run=%0d lane=%0d amplitude=%0d phase=%0d",run,lane,low,$signed(got));
   end
   bus(0,8'h80,0,0);if(got!=run)$fatal(1,"result changed before ack");
   bus(1,16,1,0);
  end
  bus(0,8'h80,0,1);
  put(3,102);put(4,0);bus(1,12,1,0);wait_done;
  bus(0,8'h84,0,0);if(got!=128)$fatal(1,"timeout error");
  bus(0,8'hb0,0,0);if(got)$fatal(1,"failed data");
  bus(1,16,1,0);bus(0,8,0,0);if(got!=3)$fatal(1,"version/duplicate launch");
  $display("PASS CSR atomic queue/held response/results/errors/ack");$finish;
 end
 initial begin #3000000;$fatal(1,"CSR timeout");end
endmodule
