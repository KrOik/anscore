// SPDX-License-Identifier: Apache-2.0
`timescale 1ns/1ps
module tb_paired_spectral_coherence;
 parameter integer N=17,K=4,T=8,EX=0;
 localparam integer A=(K>1)?$clog2(K):0,PW=32+A,CW=33+A;
 reg clk=0,rst=1,c_valid=0,s_valid=0,m_ready=0;
 always #5 clk=~clk;
 reg[31:0]c_bins=0,c_averages=0;
 reg[T-1:0]c_tag=0;
 reg[63:0]s_xy=0;
 reg s_x_last=0,s_y_last=0,x_valid=0,y_valid=0;
 wire c_ready,s_ready,m_valid,x_ready,y_ready;
 wire[2:0]m_status;
 wire[31:0]m_index;
 wire m_last;
 wire[T-1:0]m_tag;
 wire[PW-1:0]m_sxx,m_syy;
 wire signed[CW-1:0]m_cross_re,m_cross_im;
 wire[16:0]m_coherence_q16;
 wire[4:0]state_view;
 wire helper_reset_view,mac_valid_view,div_valid_view;
 generate if(EX)begin:g_dut
   dual_fft_coherence64 dut(.clk(clk),.rst(rst),.c_valid(c_valid),.c_ready(c_ready),
     .c_bins(c_bins),.c_averages(c_averages),.c_tag(c_tag),
     .x_valid(x_valid),.x_ready(x_ready),.x_data(s_xy[31:0]),.x_last(s_x_last),
     .y_valid(y_valid),.y_ready(y_ready),.y_data(s_xy[63:32]),.y_last(s_y_last),
     .m_valid(m_valid),.m_ready(m_ready),.m_status(m_status),.m_index(m_index),.m_last(m_last),
     .m_tag(m_tag),.m_sxx(m_sxx),.m_syy(m_syy),.m_cross_re(m_cross_re),
     .m_cross_im(m_cross_im),.m_coherence_q16(m_coherence_q16));
   assign s_ready=0;
   assign state_view=dut.instrument.state;
   assign helper_reset_view=dut.instrument.helper_rst_n;
   assign mac_valid_view=dut.instrument.mac_valid;
   assign div_valid_view=dut.instrument.div_valid;
   task inject(input integer kind);
     begin
       if(kind==0)begin
         force dut.instrument.mac_flags=2'b01;
         @(posedge clk);@(negedge clk);release dut.instrument.mac_flags;
       end else begin
         force dut.instrument.div_flags=2'b01;
         @(posedge clk);@(negedge clk);release dut.instrument.div_flags;
       end
     end
   endtask
 end else begin:g_dut
   paired_spectral_coherence #(.MAX_BINS(N),.MAX_AVERAGES(K),.TAG_W(T)) dut(
     .clk(clk),.rst(rst),.c_valid(c_valid),.c_ready(c_ready),.c_bins(c_bins),
     .c_averages(c_averages),.c_tag(c_tag),.s_valid(s_valid),.s_ready(s_ready),
     .s_xy(s_xy),.s_x_last(s_x_last),.s_y_last(s_y_last),.m_valid(m_valid),.m_ready(m_ready),
     .m_status(m_status),.m_index(m_index),.m_last(m_last),.m_tag(m_tag),
     .m_sxx(m_sxx),.m_syy(m_syy),.m_cross_re(m_cross_re),.m_cross_im(m_cross_im),
     .m_coherence_q16(m_coherence_q16));
   assign x_ready=0;assign y_ready=0;
   assign state_view=dut.state;
   assign helper_reset_view=dut.helper_rst_n;
   assign mac_valid_view=dut.mac_valid;
   assign div_valid_view=dut.div_valid;
   task inject(input integer kind);
     begin
       if(kind==0)begin
         force dut.mac_flags=2'b01;
         @(posedge clk);@(negedge clk);release dut.mac_flags;
       end else begin
         force dut.div_flags=2'b01;
         @(posedge clk);@(negedge clk);release dut.div_flags;
       end
     end
   endtask
 end endgenerate
 localparam integer BW=3+32+1+T+2*PW+2*CW+17;
 wire[BW-1:0]bundle={m_status,m_index,m_last,m_tag,m_sxx,m_syy,m_cross_re,m_cross_im,m_coherence_q16};
 reg[BW-1:0]saved;
 reg held=0;
 integer records=0,samples=0,commands=0,held_cycles=0,resets=0,faults=0;
 integer max_result_wait=0,skew_samples=0,last_sample_cycle=0,cycle=0,ii8_checks=0;
 always @(posedge clk)begin
   cycle=cycle+1;
   if(rst)held=0;
   else begin
     if(held &&(!m_valid ||bundle!==saved))$fatal(1,"output changed under stall");
     held=m_valid &&!m_ready;saved=bundle;
     if(held)held_cycles=held_cycles+1;
   end
 end
 always @(helper_reset_view)if(helper_reset_view===0 &&clk!==1)
   $fatal(1,"helper reset changed outside rising edge");
 task reset_now;
   integer count;
   begin
     rst=1;c_valid=0;s_valid=0;x_valid=0;y_valid=0;m_ready=0;
     repeat(2)begin @(posedge clk);#1;
       if(c_ready ||s_ready ||x_ready ||y_ready ||m_valid)$fatal(1,"reset validity");
     end
     @(negedge clk);rst=0;resets=resets+1;count=0;
     while(!c_ready)begin
       @(negedge clk);count=count+1;if(count>4)$fatal(1,"reset bridge recovery");
     end
     if(m_valid ||!helper_reset_view)$fatal(1,"reset left pending result");
     last_sample_cycle=0;
   end
 endtask
 task command(input[31:0]n,k,input[T-1:0]tag);
   begin
     @(negedge clk);c_valid=1;c_bins=n;c_averages=k;c_tag=tag;
     @(posedge clk);if(!c_ready ||s_ready ||m_valid)$fatal(1,"command ownership");
     commands=commands+1;last_sample_cycle=0;
     @(negedge clk);c_valid=0;c_bins=32'h80000001;c_averages=0;c_tag=~tag;
   end
 endtask
 task sample(input[63:0]word,input xl,yl);
   integer ticks,delay_x,delay_y;
   reg done_x,done_y;
   begin
     s_xy=word;s_x_last=xl;s_y_last=yl;
     if(EX)begin
       // Independent lane delays change every pair. Each lane retains its
       // data/last until its own external handshake, including ready stalls.
       delay_x=samples%3;delay_y=(samples+1)%3;ticks=0;done_x=0;done_y=0;
       x_valid=(delay_x==0);y_valid=(delay_y==0);
       while(!done_x ||!done_y)begin
         @(posedge clk);
         if(x_valid &&x_ready)done_x=1;
         if(y_valid &&y_ready)done_y=1;
         @(negedge clk);ticks=ticks+1;
         x_valid=!done_x &&ticks>=delay_x;y_valid=!done_y &&ticks>=delay_y;
         if(ticks>30)$fatal(1,"paired adapter input deadline");
       end
       skew_samples=skew_samples+1;
     end else begin
       s_valid=1;@(posedge clk);
       while(!s_ready)begin @(negedge clk);@(posedge clk);end
       if(last_sample_cycle!=0 &&cycle-last_sample_cycle==8)ii8_checks=ii8_checks+1;
       last_sample_cycle=cycle;
       @(negedge clk);s_valid=0;
     end
     samples=samples+1;s_xy=64'hffffffffffffffff;s_x_last=~xl;s_y_last=~yl;
   end
 endtask
 task expect_result(input[2:0]status,input[31:0]index,input[63:0]xx,yy,re,im,
                    input[16:0]q,input last,input[T-1:0]tag);
   integer watchdog;
   begin
     c_valid=1;m_ready=0;watchdog=0;
     while(!m_valid)begin
       if(c_ready)$fatal(1,"new command admitted before retirement");
       @(negedge clk);watchdog=watchdog+1;
       if(watchdog>320)$fatal(1,"bounded per-bin output latency");
     end
     if(watchdog>max_result_wait)max_result_wait=watchdog;
     if(m_status!==status ||m_index!==index ||m_last!==last ||m_tag!==tag ||
        64'(m_sxx)!==xx ||64'(m_syy)!==yy ||64'($signed(m_cross_re))!==re ||
        64'($signed(m_cross_im))!==im ||m_coherence_q16!==q)
       $fatal(1,"result status%0d idx%0d xx%0d yy%0d re%0d im%0d q%0d last%0d tag%h expected status%0d idx%0d xx%0d yy%0d re%0d im%0d q%0d last%0d tag%h",
         m_status,m_index,m_sxx,m_syy,m_cross_re,m_cross_im,m_coherence_q16,m_last,m_tag,
         status,index,xx,yy,$signed(re),$signed(im),q,last,tag);
     repeat(4)begin
       @(negedge clk);
       if(c_ready ||s_ready ||x_ready ||y_ready ||!m_valid)$fatal(1,"held output ownership");
     end
     m_ready=1;@(posedge clk);if(c_ready)$fatal(1,"retirement fallthrough");
     @(negedge clk);m_ready=0;c_valid=0;
     if(last &&(!c_ready ||m_valid))$fatal(1,"retirement failed");
     records=records+1;
   end
 endtask
 task wait_state(input[4:0]wanted);
   integer count;
   begin
     count=0;
     while(state_view!=wanted)begin
       @(negedge clk);count=count+1;if(count>320)$fatal(1,"state deadline %0d",wanted);
     end
   end
 endtask
 localparam[63:0]TEST_WORD=64'h0003fffc00040003; // Y=jX, cross=+25j.
 task recover;
   begin
     command(1,1,{T{1'b1}});sample(TEST_WORD,1,1);
     expect_result(0,0,25,25,0,25,65536,1,{T{1'b1}});
   end
 endtask
 integer fd,rc,i,vector_records,vector_commands;
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
       1:command(a[31:0],b[31:0],c[T-1:0]);
       2:sample(a,b[0],c[0]);
       3:expect_result(a[2:0],b[31:0],c,d,e,f,g[16:0],h[0],j[T-1:0]);
       4:repeat(a)@(negedge clk);
       default:$fatal(1,"unknown operation");
     endcase
   end
   $fclose(fd);vector_records=records;vector_commands=commands;
   // Synchronous external reset cancels every major lifetime and old helper
   // work. RAM is not reset: each following first segment overwrites its bins.
   command(1,1,1);reset_now();recover();
   command(1,1,1);sample(TEST_WORD,1,1);wait_state(3);reset_now();recover();
   command(1,1,1);sample(TEST_WORD,1,1);wait_state(10);reset_now();recover();
   command(1,1,1);sample(TEST_WORD,1,1);wait_state(13);reset_now();recover();
   command(1,1,1);sample(TEST_WORD,1,1);wait_state(14);reset_now();recover();
   // Explicit fault injection tests impossible-on-legal-data ARITH paths.
   // In the adapter profile a second pair occupies both prefetch slots.
   command(EX?2:1,1,1);sample(TEST_WORD,!EX,!EX);
   if(EX)sample(TEST_WORD,1,1);
   wait_state(5);while(!mac_valid_view)@(negedge clk);
   g_dut.inject(0);faults=faults+1;
   expect_result(5,0,0,0,0,0,0,1,1);recover();
   command((N>1)?2:1,1,1);sample(TEST_WORD,N==1,N==1);
   if(N>1)sample(TEST_WORD,1,1);
   wait_state(13);while(!div_valid_view)@(negedge clk);
   g_dut.inject(1);faults=faults+1;
   expect_result(5,0,0,0,0,0,0,1,1);recover();
   if(records!=vector_records+9 ||commands!=vector_commands+14 ||resets!=6 ||faults!=2 ||
      held_cycles==0 ||(EX &&skew_samples==0) ||(!EX &&N>1 &&ii8_checks==0))
     $fatal(1,"coverage accounting records%0d commands%0d resets%0d faults%0d",records,commands,resets,faults);
   $display("PASS paired_spectral_coherence N=%0d K=%0d T=%0d EX=%0d records=%0d samples=%0d commands=%0d held_cycles=%0d resets=%0d faults=%0d max_result_wait=%0d skew_samples=%0d ii8_checks=%0d",
     N,K,T,EX,records,samples,commands,held_cycles,resets,faults,max_result_wait,skew_samples,ii8_checks);
   $finish;
 end
 initial begin #10000000;$fatal(1,"finite TB deadline");end
endmodule
