// SPDX-License-Identifier: Apache-2.0
`timescale 1ns/1ps
module tb_occupied_spectral_bandwidth;
 parameter integer N=17,D=16,T=8,IQ=0;
 localparam integer SW=D+((N>1)?$clog2(N):0);
 reg clk=0,rst=1,c_valid=0,s_valid=0,m_ready=0;
 always #5 clk=~clk;
 reg[31:0]c_bins=0,s_word=0;
 reg[15:0]c_occupied_num=1,c_occupied_den=1;
 reg[T-1:0]c_tag=0;
 wire c_ready,s_ready,m_valid;
 wire[1:0]m_status;
 wire[31:0]m_low,m_high,m_span;
 wire[SW-1:0]m_total,m_retained,m_below,m_above;
 wire[T-1:0]m_tag;
 generate if(IQ)begin:iq_chain
   iq_occupied_bandwidth dut(.clk(clk),.rst(rst),.c_valid(c_valid),.c_ready(c_ready),.c_bins(c_bins),
     .c_occupied_num(c_occupied_num),.c_occupied_den(c_occupied_den),.c_tag(c_tag),
     .s_valid(s_valid),.s_ready(s_ready),.s_iq(s_word),.m_valid(m_valid),.m_ready(m_ready),
     .m_status(m_status),.m_low(m_low),.m_high(m_high),.m_span(m_span),.m_total(m_total),
     .m_retained(m_retained),.m_below(m_below),.m_above(m_above),.m_tag(m_tag));
 end else begin:power_core
   occupied_spectral_bandwidth #(.MAX_BINS(N),.DATA_W(D),.TAG_W(T)) dut(
     .clk(clk),.rst(rst),.c_valid(c_valid),.c_ready(c_ready),.c_bins(c_bins),
     .c_occupied_num(c_occupied_num),.c_occupied_den(c_occupied_den),.c_tag(c_tag),
     .s_valid(s_valid),.s_ready(s_ready),.s_power(s_word[D-1:0]),.m_valid(m_valid),.m_ready(m_ready),
     .m_status(m_status),.m_low(m_low),.m_high(m_high),.m_span(m_span),.m_total(m_total),
     .m_retained(m_retained),.m_below(m_below),.m_above(m_above),.m_tag(m_tag));
 end endgenerate
 localparam integer BUNDLE_W=2+96+4*SW+T;
 wire[BUNDLE_W-1:0]bundle={m_status,m_low,m_high,m_span,m_total,m_retained,m_below,m_above,m_tag};
 reg[BUNDLE_W-1:0]saved;
 reg held=0;
 integer records=0,samples=0,commands=0,held_cycles=0,resets=0,latency_checks=0;
 time last_input_time;
 always @(posedge clk)begin
   if(rst)held=0;
   else begin
     if(held &&(!m_valid ||bundle!==saved))$fatal(1,"output changed under stall");
     held=m_valid &&!m_ready;saved=bundle;
     if(held)held_cycles=held_cycles+1;
   end
 end
 task reset_now;
   begin
     rst=1;c_valid=0;s_valid=0;m_ready=0;
     @(posedge clk);#1;
     if(c_ready ||s_ready ||m_valid)$fatal(1,"reset validity");
     @(negedge clk);rst=0;resets=resets+1;
     if(m_valid)$fatal(1,"reset left pending output");
   end
 endtask
 task command(input[31:0]n,input[15:0]num,den,input[T-1:0]tag);
   begin
     @(negedge clk);c_valid=1;c_bins=n;c_occupied_num=num;c_occupied_den=den;c_tag=tag;
     @(posedge clk);if(!c_ready ||s_ready)$fatal(1,"command ownership");commands=commands+1;
     @(negedge clk);c_valid=0;c_bins=32'h80000001;c_occupied_num=0;c_occupied_den=0;c_tag=~tag;
   end
 endtask
 task sample(input[31:0]word);
   begin
     s_valid=1;s_word=word;
     @(posedge clk);
     while(!s_ready)begin @(negedge clk);@(posedge clk);end
     samples=samples+1;last_input_time=$time;
     @(negedge clk);s_valid=0;s_word=32'hffffffff;
   end
 endtask
 task expect_result(input[1:0]status,input[31:0]lo,hi,span,
   input[63:0]total,retained,below,above,input[T-1:0]tag);
   integer watchdog,expected_latency;
   begin
     // Hold unrelated next inputs high; neither may transfer before retirement.
     s_valid=1;c_valid=1;m_ready=0;watchdog=0;
     while(!m_valid)begin
       if(c_ready ||s_ready)$fatal(1,"extra input admitted while processing");
       @(negedge clk);watchdog=watchdog+1;
       if(watchdog>3*N+30)$fatal(1,"bounded output latency");
     end
     if(m_status!==status ||m_low!==lo ||m_high!==hi ||m_span!==span ||m_tag!==tag ||
        64'(m_total)!==total ||64'(m_retained)!==retained ||64'(m_below)!==below ||64'(m_above)!==above)
       $fatal(1,"result status%0d lo%0d hi%0d span%0d total%0d retained%0d below%0d above%0d",m_status,m_low,m_high,m_span,m_total,m_retained,m_below,m_above);
     if(status==0 ||status==3)begin
       expected_latency=(status==3)?(IQ?4:0):(IQ?10:6)+3*hi;
       if(($time-last_input_time)/10!=expected_latency)
         $fatal(1,"latency got%0d expected%0d",($time-last_input_time)/10,expected_latency);
       latency_checks=latency_checks+1;
     end
     repeat(4)begin @(negedge clk);if(c_ready ||s_ready ||!m_valid)$fatal(1,"held ownership");end
     m_ready=1;@(posedge clk);if(c_ready ||s_ready)$fatal(1,"retirement fallthrough");
     @(negedge clk);m_ready=0;c_valid=0;s_valid=0;
     if(!c_ready ||m_valid)$fatal(1,"retirement failed");records=records+1;
   end
 endtask
 localparam[31:0]TEST_WORD=IQ?32'h00040003:32'd1;
 localparam[63:0]TEST_POWER=IQ?64'd25:64'd1;
 task recover;
   begin
     command(1,99,100,{T{1'b1}});sample(TEST_WORD);
     expect_result(0,0,0,1,TEST_POWER,TEST_POWER,0,0,{T{1'b1}});
   end
 endtask
 integer fd,rc,i;
 reg[63:0]op,a,b,c,d,e,f,g,h,j;
 reg[4095:0]vector_file;
 initial begin
   if(!$value$plusargs("vectors=%s",vector_file))$fatal(1,"missing vectors");
   fd=$fopen(vector_file,"r");if(!fd)$fatal(1,"cannot read vectors");
   @(negedge clk);reset_now();
   while(!$feof(fd))begin
     rc=$fscanf(fd,"%h %h %h %h %h %h %h %h %h %h\n",op,a,b,c,d,e,f,g,h,j);
     if(rc!=10)$fatal(1,"malformed vector row %0d",rc);
     case(op)
       1:command(a[31:0],b[15:0],c[15:0],d[T-1:0]);
       2:sample(a[31:0]);
       3:expect_result(a[1:0],b[31:0],c[31:0],d[31:0],e,f,g,h,j[T-1:0]);
       4:repeat(a)@(negedge clk);
       default:$fatal(1,"unknown operation");
     endcase
   end
   $fclose(fd);
   // Cancel partial capture, registered product, RAM read, and held response.
   command((N>1)?2:1,1,1,1);if(N>1)sample(TEST_WORD);reset_now();recover();
   command(1,1,1,1);sample(TEST_WORD);repeat(IQ?5:1)@(negedge clk);reset_now();recover();
   command(1,1,1,1);sample(TEST_WORD);repeat(IQ?8:4)@(negedge clk);reset_now();recover();
   command(1,1,1,1);sample(TEST_WORD);while(!m_valid)@(negedge clk);reset_now();recover();
   if(records!=21 ||commands!=25 ||resets!=5 ||held_cycles==0 ||latency_checks!=15)$fatal(1,"coverage accounting");
   $display("PASS occupied_spectral_bandwidth N=%0d D=%0d T=%0d IQ=%0d records=%0d samples=%0d commands=%0d held_cycles=%0d resets=%0d latency_checks=%0d",N,D,T,IQ,records,samples,commands,held_cycles,resets,latency_checks);
   $finish;
 end
 initial begin #20000000;$fatal(1,"finite TB deadline");end
endmodule
