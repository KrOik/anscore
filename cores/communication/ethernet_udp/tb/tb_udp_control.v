`timescale 1ns/1ps
module tb_udp_control;
 reg clk=0;always #5 clk=~clk;
 reg rst_n=0,rv=0,rw=0,rr=0;reg[7:0] addr=0;reg[31:0] data=0;reg[3:0] strb=15;
 wire ready,valid,error;wire[31:0] result;wire[7:0] probe;
 reg[31:0] got,status,low;reg[63:0] first,last,previous_last=0;integer run,lane;
 udp_control #(.BUILD_ID(64'h123456789abcdef0)) dut(clk,rst_n,rv,rw,addr,data,strb,ready,valid,error,result,rr,probe);
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
 task put(input[2:0] n,input[31:0] d);begin bus(1,8'h40+n*4,d,0);end endtask
 task wait_done;begin
  status=0;while(!status[1])begin bus(0,4,0,0);status=got;end
 end endtask
 initial begin
  repeat(4)@(negedge clk);rst_n=1;
  bus(0,0,0,0);if(got!=32'h55445031)$fatal(1,"CSR identity");
  bus(0,20,0,0);if(got!=32'h9abcdef0)$fatal(1,"build ID");
  bus(0,8'h80,0,1);bus(1,16,1,1);bus(0,1,0,1);bus(1,0,0,1);
  put(0,{16'd37,16'd3});put(1,32'h12340000);
  strb=3;put(1,32'h00005678);strb=15;
  put(2,200000);put(3,0);put(4,100);bus(1,12,1,0);
  put(0,{16'd7,16'd2});put(1,32'h87654321);put(4,101);bus(1,12,1,0);
  bus(1,8'h50,999,1);bus(1,12,1,1);
  bus(0,8'h40,0,0);if(got!={16'd37,16'd3})$fatal(1,"active config changed while busy");
  for(run=100;run<=101;run=run+1)begin
   wait_done;
   bus(0,8'h80,0,0);if(got!=run)$fatal(1,"result ID");
   bus(0,8'h84,0,0);if(got)$fatal(1,"replay error");
   bus(0,8'h88,0,0);
   for(lane=0;lane<6;lane=lane+1)bus(0,8'h8c+lane*4,0,0);
   bus(0,8'h80,0,0);if(got!=run)$fatal(1,"result coherence");
   bus(1,16,1,0);
  end
  bus(0,8'h80,0,1);
  put(2,0);put(4,102);bus(1,12,1,0);wait_done;
  bus(0,8'h84,0,0);if(got!=1)$fatal(1,"invalid timeout");
  bus(0,8'h94,0,0);if(got)$fatal(1,"invalid command has bytes");
  bus(1,16,1,0);bus(0,8,0,0);if(got!=3)$fatal(1,"version");
  $display("PASS UDP CSR atomic queue/byte strobes/held responses/results/errors/ACK");$finish;
 end
 initial begin #30000000;$fatal(1,"CSR timeout");end
endmodule
