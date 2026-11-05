// SPDX-License-Identifier: Apache-2.0
`timescale 1ns/1ps
module tb_fixedpoint_ldlt;
 parameter integer N=4,W=16,F=8;
 reg clk=0;always #5 clk=~clk;
 reg rst=1,c_valid=0,s_valid=0,m_ready=0;
 wire c_ready,s_ready,m_valid;
 reg [31:0] c_dimension=0;reg[7:0] c_tag=0;
 reg signed[W-1:0] s_data=0;
 wire [1:0] m_status;wire[31:0]m_row,m_column;
 wire signed[W-1:0]m_data;wire m_diagonal,m_last;wire[7:0]m_tag;
 fixedpoint_ldlt #(.MAX_N(N),.DATA_W(W),.FRAC(F)) dut(.*);
 integer fd,rc,kind,a,b,c,d,e,f,g,checks=0,stalls=0,commands=0,resets=0,waits;
 reg [2047:0] vector_path;
 localparam integer BW=2+64+W+2+8;
 wire[BW-1:0] bundle={m_status,m_row,m_column,m_data,m_diagonal,m_last,m_tag};
 reg[BW-1:0] held;
 task command(input [31:0] dim,input [7:0] tag);
 begin
   @(negedge clk);waits=0;
   while(!c_ready) begin @(negedge clk);waits=waits+1;if(waits>20000)$fatal(1,"c_ready timeout");end
   c_valid=1;c_dimension=dim;c_tag=tag;
   @(posedge clk);@(negedge clk);c_valid=0;c_dimension='1;c_tag=~tag;commands=commands+1;
 end endtask
 task sample(input integer data);
 begin
   @(negedge clk);waits=0;
   while(!s_ready)begin @(negedge clk);waits=waits+1;if(waits>20000)$fatal(1,"s_ready timeout");end
   s_valid=1;s_data=data;
   @(posedge clk);@(negedge clk);s_valid=0;s_data=~data;
 end endtask
 task check(input integer status,row,column,data,diagonal,last,tag);
 integer h;
 begin
   @(negedge clk);waits=0;
   while(!m_valid)begin @(negedge clk);waits=waits+1;if(waits>20000)$fatal(1,"result timeout");end
   if(m_status!==status[1:0] || m_row!==row || m_column!==column ||
      m_data!==data[W-1:0] || m_diagonal!==diagonal[0] || m_last!==last[0] ||m_tag!==tag[7:0])
      $fatal(1,"response %0d got status=%0d row=%0d col=%0d value=%0d diag=%b last=%b tag=%h expected %0d %0d %0d %0d %0d %0d %h",checks,m_status,m_row,m_column,m_data,m_diagonal,m_last,m_tag,status,row,column,data,diagonal,last,tag);
   held=bundle;c_valid=1;c_dimension=0;c_tag=8'hfa;
   for(h=0;h<2+checks%3;h=h+1)begin
     @(posedge clk);#1;
     if(!m_valid ||bundle!==held ||c_ready ||s_ready)$fatal(1,"stall payload or ownership");
     stalls=stalls+1;
   end
   @(negedge clk);c_valid=0;m_ready=1;
   @(posedge clk);@(negedge clk);m_ready=0;checks=checks+1;
 end endtask
 task reset_service;
 begin
   @(negedge clk);rst=1;c_valid=0;s_valid=0;m_ready=0;
   @(posedge clk);#1;if(m_valid ||c_ready ||s_ready)$fatal(1,"reset cancellation");
   @(negedge clk);rst=0;@(negedge clk);
   if(!c_ready||m_valid||s_ready)$fatal(1,"reset recovery");resets=resets+1;
 end endtask
 initial begin
   if(!$value$plusargs("vectors=%s",vector_path))$fatal(1,"missing vector path");
   reset_service;
   fd=$fopen(vector_path,"r");if(!fd)$fatal(1,"missing vectors");
   while(!$feof(fd))begin
     rc=$fscanf(fd,"%d %d %d %d %d %d %d %d\n",kind,a,b,c,d,e,f,g);
     if(rc!=8)$fatal(1,"bad vector line");
     case(kind)
       0:command(a,b);
       1:begin if(checks%3==1)repeat(2)@(negedge clk);sample(a);end
       2:check(a,b,c,d,e,f,g);
       default:$fatal(1,"bad record type");
     endcase
   end
   $fclose(fd);
   // Cancellation during a partial load; payload RAM is deliberately not reset.
   command(N,8'hd1);if(N>1)sample(1<<F);reset_service;
   // A held successful result is cancelled.
   command(1,8'hd2);sample(1<<F);while(!m_valid)@(negedge clk);reset_service;
   // Cancel an actual active shared-divider calculation.
   if(N>1)begin
     command(2,8'hd3);sample(1<<F);sample(1<<(F-1));sample(1<<F);
     waits=0;while(!dut.div_m_ready)begin @(negedge clk);waits=waits+1;if(waits>20000)$fatal(1,"divider reset setup");end
     reset_service;
   end
   command(1,8'hd4);sample(1<<F);check(0,0,0,1<<F,1,1,8'hd4);
   if(checks==0||stalls==0||resets<3)$fatal(1,"vacuous coverage");
   $display("PASS fixedpoint_ldlt N=%0d W=%0d F=%0d commands=%0d records=%0d stalled_cycles=%0d resets=%0d",N,W,F,commands,checks,stalls,resets);
   $finish;
 end
 initial begin #100000000;$fatal(1,"TB watchdog");end
endmodule
