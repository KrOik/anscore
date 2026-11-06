// SPDX-License-Identifier: Apache-2.0
`timescale 1ns/1ps
module tb_symbol_evm_measure;
 parameter integer D=16,M=17,T=8,EX=0;
 localparam integer A=(M>1)?$clog2(M):0,RW=2*D+A,EW=2*D+1+A,PW=2*D+1;
 reg clk=0,rst=1,c_valid=0,s_valid=0,s_last=0,m_ready=0;
 always #5 clk=~clk;
 reg[31:0]c_symbols=0;
 reg[T-1:0]c_tag=0;
 reg[2*D-1:0]s_rx=0,s_ref=0;
 wire c_ready,s_ready,m_valid,m_clip;
 wire[2:0]m_status,state_view;
 wire[31:0]m_symbols,m_peak_index,m_evm2_q16,m_qam_faults,m_qam_over_range;
 wire[T-1:0]m_tag;
 wire[EW-1:0]m_error_energy;
 wire[RW-1:0]m_reference_energy;
 wire[PW-1:0]m_peak_error;
 wire div_valid_view,helper_rst_n_view;
 generate if(EX)begin:g_dut
   qam16_evm dut(.clk(clk),.rst(rst),.c_valid(c_valid),.c_ready(c_ready),.c_symbols(c_symbols),.c_tag(c_tag),
     .s_valid(s_valid),.s_ready(s_ready),.s_rx(s_rx),.s_last(s_last),.m_valid(m_valid),.m_ready(m_ready),
     .m_status(m_status),.m_symbols(m_symbols),.m_tag(m_tag),.m_error_energy(m_error_energy),
     .m_reference_energy(m_reference_energy),.m_peak_error(m_peak_error),.m_peak_index(m_peak_index),
     .m_evm2_q16(m_evm2_q16),.m_clip(m_clip),.m_qam_faults(m_qam_faults),.m_qam_over_range(m_qam_over_range));
   assign state_view=dut.measure.state;assign div_valid_view=dut.measure.div_valid;
   assign helper_rst_n_view=dut.helper_rst_n;
   task inject(input integer kind);
     begin
       if(kind==0)begin force dut.measure.norm_overflow=1'b1;
         @(posedge clk);@(negedge clk);release dut.measure.norm_overflow;
       end else begin force dut.measure.div_flags=2'b10;
         @(posedge clk);@(negedge clk);release dut.measure.div_flags;
       end
     end
   endtask
 end else begin:g_dut
   symbol_evm_measure #(.DATA_W(D),.MAX_SYMBOLS(M),.TAG_W(T)) dut(
     .clk(clk),.rst(rst),.c_valid(c_valid),.c_ready(c_ready),.c_symbols(c_symbols),.c_tag(c_tag),
     .s_valid(s_valid),.s_ready(s_ready),.s_rx(s_rx),.s_ref(s_ref),.s_last(s_last),
     .m_valid(m_valid),.m_ready(m_ready),.m_status(m_status),.m_symbols(m_symbols),.m_tag(m_tag),
     .m_error_energy(m_error_energy),.m_reference_energy(m_reference_energy),.m_peak_error(m_peak_error),
     .m_peak_index(m_peak_index),.m_evm2_q16(m_evm2_q16),.m_clip(m_clip));
   assign m_qam_faults=0;assign m_qam_over_range=0;
   assign state_view=dut.state;assign div_valid_view=dut.div_valid;assign helper_rst_n_view=1;
   task inject(input integer kind);
     begin
       if(kind==0)begin force dut.norm_overflow=1'b1;
         @(posedge clk);@(negedge clk);release dut.norm_overflow;
       end else begin force dut.div_flags=2'b10;
         @(posedge clk);@(negedge clk);release dut.div_flags;
       end
     end
   endtask
 end endgenerate
 localparam integer BW=3+32+T+EW+RW+PW+32+32+1+64;
 wire[BW-1:0]bundle={m_status,m_symbols,m_tag,m_error_energy,m_reference_energy,m_peak_error,
   m_peak_index,m_evm2_q16,m_clip,m_qam_faults,m_qam_over_range};
 reg[BW-1:0]saved;
 reg held=0;
 integer commands=0,records=0,samples=0,resets=0,faults=0,held_cycles=0;
 integer timing_checks=0,ii_checks=0,max_wait=0,clips=0,zero_reference=0;
 time last_input_time=0,previous_input_time=0;
 always @(posedge clk)begin
   if(rst)held=0;
   else begin
     if(held &&(!m_valid ||bundle!==saved))$fatal(1,"held response changed");
     held=m_valid &&!m_ready;saved=bundle;if(held)held_cycles=held_cycles+1;
   end
 end
 always @(helper_rst_n_view)if($time>0 &&helper_rst_n_view===0 &&clk!==1)
   $fatal(1,"asynchronous demapper reset did not originate at a rising edge");
 task reset_now;
   integer count;
   begin
     rst=1;c_valid=0;s_valid=0;m_ready=0;
     repeat(2)begin @(posedge clk);#1;if(c_ready ||s_ready ||m_valid)$fatal(1,"reset validity");end
     @(negedge clk);rst=0;resets=resets+1;count=0;
     while(!c_ready)begin @(negedge clk);count=count+1;if(count>4)$fatal(1,"reset recovery");end
     if(m_valid)$fatal(1,"old response after reset");
   end
 endtask
 task command(input[31:0]n,input[T-1:0]tag);
   integer count;
   begin
     @(negedge clk);c_valid=1;c_symbols=n;c_tag=tag;count=0;
     @(posedge clk);
     while(!c_ready)begin @(negedge clk);count=count+1;if(count>8)$fatal(1,"command deadline");@(posedge clk);end
     if(m_valid ||s_ready)$fatal(1,"command ownership");
     commands=commands+1;previous_input_time=0;
     @(negedge clk);c_valid=0;c_symbols=32'hffffffff;c_tag=~tag;
   end
 endtask
 task sample(input[2*D-1:0]rx_value,ref_value,input last,check_ii);
   integer count;
   begin
     s_rx=rx_value;s_ref=ref_value;s_last=last;s_valid=1;count=0;
     @(posedge clk);
     while(!s_ready)begin @(negedge clk);count=count+1;if(count>200)$fatal(1,"sample deadline");@(posedge clk);end
     if(check_ii)begin
       if(($time-previous_input_time)/10!=8+EX)$fatal(1,"symbol II got%0d expected%0d",($time-previous_input_time)/10,8+EX);
       ii_checks=ii_checks+1;
     end
     previous_input_time=$time;last_input_time=$time;samples=samples+1;
     @(negedge clk);s_valid=0;s_rx=~rx_value;s_ref=~ref_value;s_last=~last;
   end
 endtask
 task expect_result(input[2:0]status,input[31:0]count_value,input[T-1:0]tag,
   input[63:0]error_value,reference_value,peak_value,input[31:0]peak_position,ratio,
   input clip_value,input[31:0]qam_faults,qam_over_range,input check_timing);
   integer count,expected_latency;
   begin
     c_valid=1;m_ready=0;count=0;
     while(!m_valid)begin
       if(c_ready)$fatal(1,"command admitted while owned");
       @(negedge clk);count=count+1;if(count>200)$fatal(1,"result deadline");
     end
     if(count>max_wait)max_wait=count;
     if(m_status!==status ||m_symbols!==count_value ||m_tag!==tag ||
        64'(m_error_energy)!==error_value ||64'(m_reference_energy)!==reference_value ||
        64'(m_peak_error)!==peak_value ||m_peak_index!==peak_position ||m_evm2_q16!==ratio ||m_clip!==clip_value ||
        m_qam_faults!==qam_faults ||m_qam_over_range!==qam_over_range)
       $fatal(1,"result status%0d/%0d n%0d/%0d tag%h/%h E%0d/%0d R%0d/%0d peak%0d/%0d pos%0d/%0d q%0d/%0d clip%0d/%0d qam%0d/%0d over%0d/%0d",
         m_status,status,m_symbols,count_value,m_tag,tag,m_error_energy,error_value,m_reference_energy,reference_value,
         m_peak_error,peak_value,m_peak_index,peak_position,m_evm2_q16,ratio,m_clip,clip_value,
         m_qam_faults,qam_faults,m_qam_over_range,qam_over_range);
     if(check_timing)begin
       expected_latency=(status==3?8:EW+1+16+9)+EX;
       if(($time-last_input_time)/10!=expected_latency)
         $fatal(1,"final sample latency got%0d expected%0d",($time-last_input_time)/10,expected_latency);
       timing_checks=timing_checks+1;
     end
     repeat(4)begin @(negedge clk);if(!m_valid ||c_ready ||s_ready)$fatal(1,"held ownership");end
     m_ready=1;@(posedge clk);if(c_ready)$fatal(1,"retirement fallthrough");
     @(negedge clk);m_ready=0;c_valid=0;
     if(!c_ready ||m_valid)$fatal(1,"final retirement");
     records=records+1;clips=clips+clip_value;zero_reference=zero_reference+(status==3);
   end
 endtask
 task wait_state(input[2:0]wanted);
   integer count;
   begin count=0;while(state_view!=wanted)begin
     @(negedge clk);count=count+1;if(count>200)$fatal(1,"state deadline %0d",wanted);
   end end
 endtask
 localparam[2*D-1:0]TEST_RX=(2*D)'((64'd4<<D)|64'd3);
 localparam[2*D-1:0]TEST_REF=(2*D)'((64'd2<<D)|64'd1);
 task fill_one;
   begin command(1,{T{1'b1}});sample(TEST_RX,TEST_REF,1,0);end
 endtask
 task recover;
   begin
     fill_one();
     expect_result(0,1,{T{1'b1}},EX?1:8,EX?18:5,EX?1:8,0,EX?3641:104858,0,0,0,1);
   end
 endtask
 integer fd,rc,op,j,w,vector_records,vector_commands,watchdog;
 reg[63:0]row[0:15];
 reg[2047:0]path;
 initial begin
   if(EX &&(D!=8 ||M!=1024 ||T!=8))$fatal(1,"example parameters");
   if(!$value$plusargs("vectors=%s",path))$fatal(1,"vectors missing");
   fd=$fopen(path,"r");if(!fd)$fatal(1,"vectors open");
   reset_now();
   while(!$feof(fd))begin
     rc=$fscanf(fd,"%h %h %h %h %h %h %h %h %h %h %h %h %h %h %h %h\n",
       row[0],row[1],row[2],row[3],row[4],row[5],row[6],row[7],row[8],row[9],row[10],row[11],row[12],row[13],row[14],row[15]);
     if(rc!=16)$fatal(1,"vector parse");
     case(row[0])
       1:command(32'(row[1]),T'(row[2]));
       2:sample((2*D)'(row[1]),(2*D)'(row[2]),1'(row[3]),1'(row[4]));
       3:expect_result(3'(row[1]),32'(row[2]),T'(row[3]),row[4],row[5],row[6],32'(row[7]),32'(row[8]),
           1'(row[9]),32'(row[10]),32'(row[11]),1'(row[12]));
       4:repeat(row[1])@(negedge clk);
       default:$fatal(1,"unknown vector opcode");
     endcase
   end
   $fclose(fd);vector_records=records;vector_commands=commands;
   // Cancel the input wait, every active computation phase, and a held result.
   command(1,{T{1'b1}});reset_now();recover();
   for(j=2;j<=6;j=j+1)begin fill_one();wait_state(3'(j));reset_now();recover();end
   if(EX)begin
     // Physical input has reached the actual demapper but not the frame core.
     fill_one();reset_now();recover();
   end
   fill_one();wait_state(3);g_dut.inject(0);faults=faults+1;
   expect_result(4,1,{T{1'b1}},0,0,0,0,0,0,0,0,0);recover();
   fill_one();wait_state(5);watchdog=0;
   while(!div_valid_view)begin @(negedge clk);watchdog=watchdog+1;if(watchdog>200)$fatal(1,"divider result deadline");end
   g_dut.inject(1);faults=faults+1;
   expect_result(4,1,{T{1'b1}},0,0,0,0,0,0,0,0,0);recover();
   if(records!=vector_records+10+EX ||commands!=vector_commands+16+2*EX ||resets!=7+EX ||faults!=2 ||
      held_cycles==0 ||timing_checks==0 ||(M>1 &&ii_checks==0))
     $fatal(1,"coverage records%0d commands%0d resets%0d faults%0d timing%0d II%0d",records,commands,resets,faults,timing_checks,ii_checks);
   $display("PASS symbol_evm_measure D=%0d M=%0d T=%0d EX=%0d records=%0d samples=%0d commands=%0d resets=%0d faults=%0d held=%0d clips=%0d zero_reference=%0d timing_checks=%0d ii_checks=%0d max_wait=%0d",
     D,M,T,EX,records,samples,commands,resets,faults,held_cycles,clips,zero_reference,timing_checks,ii_checks,max_wait);
   $finish;
 end
 initial begin #5000000;$fatal(1,"finite TB deadline");end
endmodule
