// SPDX-License-Identifier: Apache-2.0
`timescale 1ns/1ps
module tb_burst_cfo_correct;
 parameter integer M=256,T=8,EX=0;
 reg clk=0,rst=1,c_valid=0,s_valid=0,s_last=0,m_ready=0;
 always #5 clk=~clk;
 reg[31:0]c_samples=0,c_threshold_q16=0;
 reg[63:0]c_min_energy=0;
 reg[T-1:0]c_tag=0;
 reg[23:0]s_iq=0;
 wire c_ready,s_ready,m_valid,m_last,multiply_rst_n_view;
 wire[3:0]m_status,state_view;
 wire[23:0]m_iq,m_phase;
 wire[31:0]m_index,m_correction;
 wire[T-1:0]m_tag;
 wire[1:0]m_clip;
 wire signed[17:0]cos_view,sin_view;
 generate if(EX)begin:g_dut
   burst64_cfo dut(.clk(clk),.rst(rst),.c_valid(c_valid),.c_ready(c_ready),.c_samples(c_samples),
     .c_threshold_q16(c_threshold_q16),.c_min_energy(c_min_energy),.c_tag(c_tag),
     .s_valid(s_valid),.s_ready(s_ready),.s_iq(s_iq),.s_last(s_last),.m_valid(m_valid),.m_ready(m_ready),
     .m_status(m_status),.m_iq(m_iq),.m_index(m_index),.m_last(m_last),.m_tag(m_tag),
     .m_clip(m_clip),.m_phase(m_phase),.m_correction(m_correction));
   assign state_view=dut.correct.state;assign cos_view=dut.correct.cos_coeff;assign sin_view=dut.correct.sin_coeff;
   assign multiply_rst_n_view=dut.correct.multiply_rst_n;
   task inject;
     begin force dut.correct.prefix_status=3'd6;@(posedge clk);@(negedge clk);release dut.correct.prefix_status;end
   endtask
   wire prefix_valid=dut.correct.prefix_valid;
 end else begin:g_dut
   burst_cfo_correct #(.MAX_SAMPLES(M),.TAG_W(T)) dut(
     .clk(clk),.rst(rst),.c_valid(c_valid),.c_ready(c_ready),.c_samples(c_samples),
     .c_threshold_q16(c_threshold_q16),.c_min_energy(c_min_energy),.c_tag(c_tag),
     .s_valid(s_valid),.s_ready(s_ready),.s_iq(s_iq),.s_last(s_last),.m_valid(m_valid),.m_ready(m_ready),
     .m_status(m_status),.m_iq(m_iq),.m_index(m_index),.m_last(m_last),.m_tag(m_tag),
     .m_clip(m_clip),.m_phase(m_phase),.m_correction(m_correction));
   assign state_view=dut.state;assign cos_view=dut.cos_coeff;assign sin_view=dut.sin_coeff;
   assign multiply_rst_n_view=dut.multiply_rst_n;
   task inject;
     begin force dut.prefix_status=3'd6;@(posedge clk);@(negedge clk);release dut.prefix_status;end
   endtask
   wire prefix_valid=dut.prefix_valid;
 end endgenerate
 localparam integer BW=4+24+32+1+T+2+24+32;
 wire[BW-1:0]bundle={m_status,m_iq,m_index,m_last,m_tag,m_clip,m_phase,m_correction};
 reg[BW-1:0]saved;
 reg held=0;
 integer commands=0,records=0,samples=0,resets=0,faults=0,held_cycles=0;
 integer input_ii_checks=0,output_ii_checks=0,phase_checks=0,coefficient_checks=0,exact_checks=0,clips=0;
 integer accepted_in_command=0,error_markers=0;
 reg[23:0]accepted_samples[0:M-1];
 time previous_input_time=0,previous_output_time=0;
 reg[23:0]first_phase;
 reg[31:0]first_correction;
 always @(posedge clk)begin
   if(rst)held=0;
   else begin
     if(held &&(!m_valid ||bundle!==saved))$fatal(1,"held record changed");
     held=m_valid &&!m_ready;saved=bundle;if(held)held_cycles=held_cycles+1;
   end
 end
 always @(multiply_rst_n_view)if($time>0 &&multiply_rst_n_view===0 &&clk!==1)
   $fatal(1,"multiplier reset did not originate at rising edge");
 function signed[63:0]rne16;
   input signed[63:0]value;reg signed[63:0]q,r;
   begin
     q=value/65536;r=value%65536;
     if(r<0)begin q=q-1;r=r+65536;end
     if(r>32768 ||(r==32768 &&q%2!=0))q=q+1;
     rne16=q;
   end
 endfunction
 function integer saturate12;
   input signed[63:0]value;
   begin saturate12=value>2047?2047:value< -2048?-2048:value;end
 endfunction
 task reset_now;
   integer count;
   begin
     rst=1;c_valid=0;s_valid=0;m_ready=0;
     repeat(2)begin @(posedge clk);#1;if(c_ready ||s_ready ||m_valid)$fatal(1,"reset validity");end
     @(negedge clk);rst=0;resets=resets+1;count=0;
     while(!c_ready)begin @(negedge clk);count=count+1;if(count>5)$fatal(1,"reset recovery");end
     if(m_valid)$fatal(1,"stale record after reset");
   end
 endtask
 task command(input[31:0]n,threshold,input[63:0]floor,input[T-1:0]tag);
   integer count;
   begin
     @(negedge clk);c_valid=1;c_samples=n;c_threshold_q16=threshold;c_min_energy=floor;c_tag=tag;count=0;
     @(posedge clk);
     while(!c_ready)begin @(negedge clk);count=count+1;if(count>8)$fatal(1,"command deadline");@(posedge clk);end
     if(m_valid ||s_ready)$fatal(1,"command ownership");
     commands=commands+1;accepted_in_command=0;previous_input_time=0;previous_output_time=0;
     @(negedge clk);c_valid=0;c_samples=32'hffffffff;c_threshold_q16=0;c_min_energy=64'hffffffffffffffff;c_tag=~tag;
   end
 endtask
 task sample(input[23:0]iq,input last,input integer expected_ii);
   integer count;
   begin
     s_iq=iq;s_last=last;s_valid=1;count=0;
     @(posedge clk);
     while(!s_ready)begin @(negedge clk);count=count+1;if(count>16)$fatal(1,"sample deadline");@(posedge clk);end
     if(expected_ii)begin
       if(($time-previous_input_time)/10!=expected_ii)$fatal(1,"input II got%0d expected%0d",($time-previous_input_time)/10,expected_ii);
       input_ii_checks=input_ii_checks+1;
     end
     accepted_samples[accepted_in_command]=iq;accepted_in_command=accepted_in_command+1;
     previous_input_time=$time;samples=samples+1;
     @(negedge clk);s_valid=0;s_iq=~iq;s_last=~last;
   end
 endtask
 task expect_result(input[3:0]status,input[31:0]index,input[T-1:0]tag,input[23:0]phase,
   input integer ideal_re,ideal_im,input last,input integer hold_count);
   integer count,x,y,got_re,got_im,clip_re,clip_im;
   reg[23:0]distance;
   reg[31:0]expected_correction;
   reg[63:0]phase_product;
   reg signed[63:0]full_re,full_im,rounded_re,rounded_im;
   real angle,ideal_cos,ideal_sin,delta;
   begin
     c_valid=1;m_ready=0;count=0;
     while(!m_valid)begin
       if(c_ready)$fatal(1,"new command admitted while owned");
       @(negedge clk);count=count+1;if(count>350)$fatal(1,"record deadline state%0d",state_view);
     end
     if(m_status!==status ||m_index!==index ||m_tag!==tag ||m_last!==last ||s_ready ||c_ready)
       $fatal(1,"record metadata status%0d/%0d index%0d/%0d tag%h/%h last%b/%b",m_status,status,m_index,index,m_tag,tag,m_last,last);
     if(status==0)begin
       distance=m_phase-phase;
       if(distance>24'd2 &&distance<24'hfffffe)$fatal(1,"phase distance phase%h ideal%h",m_phase,phase);
       expected_correction=-({{8{m_phase[23]}},m_phase}<<4);
       if(m_correction!==expected_correction)$fatal(1,"correction sign/scale");
       if(index==0)begin first_phase=m_phase;first_correction=m_correction;end
       else if(m_phase!==first_phase ||m_correction!==first_correction)$fatal(1,"burst estimate changed");
       phase_checks=phase_checks+1;
       phase_product=64'(index)*64'(m_correction);
       angle=6.2831853071795864769*$itor($signed(phase_product[31:0]))/4294967296.0;
       ideal_cos=65536.0*$cos(angle);ideal_sin=65536.0*$sin(angle);
       delta=$itor(cos_view)-ideal_cos;if(delta<0)delta=-delta;
       if(delta>1.000001)$fatal(1,"cosine error %f",delta);
       delta=$itor(sin_view)-ideal_sin;if(delta<0)delta=-delta;
       if(delta>1.000001)$fatal(1,"sine error %f",delta);
       coefficient_checks=coefficient_checks+1;
       x=$signed(accepted_samples[index][11:0]);y=$signed(accepted_samples[index][23:12]);
       full_re=64'(x)*64'($signed(cos_view))-64'(y)*64'($signed(sin_view));
       full_im=64'(x)*64'($signed(sin_view))+64'(y)*64'($signed(cos_view));
       rounded_re=rne16(full_re);rounded_im=rne16(full_im);
       clip_re=rounded_re>2047 ||rounded_re< -2048;clip_im=rounded_im>2047 ||rounded_im< -2048;
       got_re=$signed(m_iq[11:0]);got_im=$signed(m_iq[23:12]);
       if(got_re!=saturate12(rounded_re) ||got_im!=saturate12(rounded_im) ||m_clip!=={1'(clip_im),1'(clip_re)})
         $fatal(1,"exact arithmetic/clip got(%0d,%0d,%b) expected(%0d,%0d,%b%b)",got_re,got_im,m_clip,saturate12(rounded_re),saturate12(rounded_im),1'(clip_im),1'(clip_re));
       exact_checks=exact_checks+1;clips=clips+clip_re+clip_im;
       if(got_re-ideal_re>2 ||ideal_re-got_re>2 ||got_im-ideal_im>2 ||ideal_im-got_im>2)
         $fatal(1,"mathematical rotation error index%0d got(%0d,%0d) ideal(%0d,%0d)",index,got_re,got_im,ideal_re,ideal_im);
     end else begin
       if(m_iq!==0 ||m_clip!==0 ||m_phase!==0 ||m_correction!==0)$fatal(1,"error marker not zero");
       error_markers=error_markers+1;
     end
     repeat(hold_count)begin @(negedge clk);if(!m_valid ||c_ready ||s_ready)$fatal(1,"held ownership");end
     m_ready=1;@(posedge clk);
     if(c_ready)$fatal(1,"retirement fallthrough");
     if(status==0 &&index>0)begin
       if(($time-previous_output_time)/10!=103+hold_count)$fatal(1,"output II got%0d expected%0d",($time-previous_output_time)/10,103+hold_count);
       output_ii_checks=output_ii_checks+1;
     end
     previous_output_time=$time;
     @(negedge clk);m_ready=0;c_valid=0;
     if(last)begin if(!c_ready ||m_valid)$fatal(1,"final retirement");end
     else if(c_ready ||s_ready)$fatal(1,"midburst ownership");
     records=records+1;
   end
 endtask
 task fill_constant;
   integer n;
   begin command(32,65536,1,{T{1'b1}});for(n=0;n<32;n=n+1)sample(24'h004003,n==31,n?9:0);end
 endtask
 task wait_state(input[3:0]wanted);
   integer count;
   begin count=0;while(state_view!=wanted)begin
     @(negedge clk);count=count+1;if(count>350)$fatal(1,"state deadline %0d",wanted);
   end end
 endtask
 task recover;
   integer n;
   begin fill_constant();for(n=0;n<32;n=n+1)expect_result(0,n,{T{1'b1}},0,3,4,n==31,n==0?2:0);end
 endtask
 integer fd,rc,op,j,n,vector_records,vector_commands,watchdog;
 reg[63:0]row[0:15];
 reg[2047:0]path;
 initial begin
   if(EX &&(M!=64 ||T!=8))$fatal(1,"example parameters");
   if(!$value$plusargs("vectors=%s",path))$fatal(1,"vectors missing");
   fd=$fopen(path,"r");if(!fd)$fatal(1,"vectors open");
   reset_now();
   while(!$feof(fd))begin
     rc=$fscanf(fd,"%h %h %h %h %h %h %h %h %h %h %h %h %h %h %h %h\n",
       row[0],row[1],row[2],row[3],row[4],row[5],row[6],row[7],row[8],row[9],row[10],row[11],row[12],row[13],row[14],row[15]);
     if(rc!=16)$fatal(1,"vector parse");
     case(row[0])
       1:command(32'(row[1]),32'(row[2]),row[3],T'(row[4]));
       2:sample(24'(row[1]),1'(row[2]),32'(row[3]));
       3:expect_result(4'(row[1]),32'(row[2]),T'(row[3]),24'(row[4]),32'(row[5]),32'(row[6]),1'(row[7]),32'(row[8]));
       4:repeat(row[1])@(negedge clk);
       default:$fatal(1,"unknown vector opcode");
     endcase
   end
   $fclose(fd);vector_records=records;vector_commands=commands;
   // Reset cancels command/input wait, acquisition, every replay stage and held output.
   command(32,65536,1,{T{1'b1}});reset_now();recover();
   command(32,65536,1,{T{1'b1}});sample(24'h004003,0,0);reset_now();recover();
   for(j=3;j<=11;j=j+1)begin fill_constant();wait_state(4'(j));reset_now();recover();end
   fill_constant();watchdog=0;
   while(!g_dut.prefix_valid)begin @(negedge clk);watchdog=watchdog+1;if(watchdog>350)$fatal(1,"prefix result deadline");end
   g_dut.inject();faults=faults+1;
   expect_result(8,0,{T{1'b1}},0,0,0,1,4);recover();
   if(records!=vector_records+12*32+1 ||commands!=vector_commands+24 ||resets!=12 ||faults!=1 ||
      held_cycles==0 ||input_ii_checks==0 ||output_ii_checks==0 ||phase_checks!=coefficient_checks ||phase_checks!=exact_checks)
     $fatal(1,"coverage records%0d commands%0d resets%0d faults%0d",records,commands,resets,faults);
   $display("PASS burst_cfo_correct M=%0d T=%0d EX=%0d records=%0d samples=%0d commands=%0d resets=%0d faults=%0d held=%0d clips=%0d error_markers=%0d input_ii_checks=%0d output_ii_checks=%0d phase_checks=%0d coefficient_checks=%0d exact_checks=%0d",
     M,T,EX,records,samples,commands,resets,faults,held_cycles,clips,error_markers,input_ii_checks,output_ii_checks,phase_checks,coefficient_checks,exact_checks);
   $finish;
 end
 initial begin #20000000;$fatal(1,"finite TB deadline");end
endmodule
