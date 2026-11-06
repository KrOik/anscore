// SPDX-License-Identifier: Apache-2.0
`timescale 1ns/1ps
module tb_repeated_half_sync;
 parameter integer D=16,L=3,M=127,T=8,EX=0;
 localparam integer A=(L>1)?$clog2(L):0,CW=2*D+1+A;
 localparam integer LM=CW+(3*CW+9)/8+1;
 reg clk=0,rst=1,c_valid=0,s_valid=0,s_last=0,m_ready=0;
 always #5 clk=~clk;
 reg[31:0]c_samples=0,c_threshold_q16=0,c_hold=0;
 reg[63:0]c_min_energy=0;
 reg[T-1:0]c_tag=0;
 reg[2*D-1:0]s_iq=0;
 wire c_ready,s_ready,m_valid,m_qual,m_event,m_last,m_zero;
 wire[2:0]m_status;
 wire[31:0]m_end,m_start,m_event_start;
 wire[T-1:0]m_tag;
 wire[CW-1:0]m_energy;
 wire signed[CW-1:0]m_cross_re,m_cross_im;
 wire[23:0]m_phase;
 wire[4:0]state_view;
 wire[1:0]angle_state_view;
 wire helper_reset_view,mac_valid_view;
 generate if(EX)begin:g_dut
   sync12_phase dut(.clk(clk),.rst(rst),.c_valid(c_valid),.c_ready(c_ready),
     .c_samples(c_samples),.c_threshold_q16(c_threshold_q16),.c_hold(c_hold),
     .c_min_energy(c_min_energy),.c_tag(c_tag),.s_valid(s_valid),.s_ready(s_ready),.s_iq(s_iq),.s_last(s_last),
     .m_valid(m_valid),.m_ready(m_ready),.m_status(m_status),.m_end(m_end),.m_start(m_start),
     .m_event_start(m_event_start),.m_qual(m_qual),.m_event(m_event),.m_last(m_last),.m_tag(m_tag),
     .m_phase(m_phase),.m_zero(m_zero));
   assign m_energy=0;assign m_cross_re=0;assign m_cross_im=0;
   assign state_view=dut.detector.state;assign helper_reset_view=dut.detector.helper_rst_n;
   assign mac_valid_view=dut.detector.mac_valid;assign angle_state_view=dut.phase_core.state;
   task inject(input integer kind);
     begin
       if(kind==0)begin
         force dut.detector.mac_flags=2'b01;
         @(posedge clk);@(negedge clk);release dut.detector.mac_flags;
       end else begin
         force dut.detector.metric_bad=1'b1;
         @(posedge clk);@(negedge clk);release dut.detector.metric_bad;
       end
     end
   endtask
 end else begin:g_dut
   repeated_half_sync #(.DATA_W(D),.L(L),.MAX_SAMPLES(M),.TAG_W(T)) dut(
     .clk(clk),.rst(rst),.c_valid(c_valid),.c_ready(c_ready),.c_samples(c_samples),
     .c_threshold_q16(c_threshold_q16),.c_hold(c_hold),.c_min_energy(c_min_energy),.c_tag(c_tag),
     .s_valid(s_valid),.s_ready(s_ready),.s_iq(s_iq),.s_last(s_last),
     .m_valid(m_valid),.m_ready(m_ready),.m_status(m_status),.m_end(m_end),.m_start(m_start),
     .m_event_start(m_event_start),.m_qual(m_qual),.m_event(m_event),.m_last(m_last),.m_tag(m_tag),
     .m_energy(m_energy),.m_cross_re(m_cross_re),.m_cross_im(m_cross_im));
   assign m_phase=0;assign m_zero=0;assign angle_state_view=0;
   assign state_view=dut.state;assign helper_reset_view=dut.helper_rst_n;assign mac_valid_view=dut.mac_valid;
   task inject(input integer kind);
     begin
       if(kind==0)begin
         force dut.mac_flags=2'b01;
         @(posedge clk);@(negedge clk);release dut.mac_flags;
       end else begin
         force dut.metric_bad=1'b1;
         @(posedge clk);@(negedge clk);release dut.metric_bad;
       end
     end
   endtask
 end endgenerate
 localparam integer BW=3+96+3+T+3*CW+25;
 wire[BW-1:0]bundle={m_status,m_end,m_start,m_event_start,m_qual,m_event,m_last,m_tag,
   m_energy,m_cross_re,m_cross_im,m_phase,m_zero};
 reg[BW-1:0]saved;
 reg held=0;
 integer commands=0,samples=0,records=0,resets=0,held_cycles=0,faults=0;
 integer events=0,qualified=0,phase_checks=0,timing_checks=0,warmup_ii9_checks=0,max_wait=0,stall_budget=4;
 time last_input_time=0,previous_input_time=0;
 reg[63:0]captured_floor;
 integer accepted_in_command=0;
 always @(posedge clk)begin
   if(rst)held=0;
   else begin
     if(held &&(!m_valid ||bundle!==saved))$fatal(1,"output changed under stall");
     held=m_valid &&!m_ready;saved=bundle;if(held)held_cycles=held_cycles+1;
   end
 end
 always @(helper_reset_view)if(helper_reset_view===0 &&clk!==1)
   $fatal(1,"async helper reset changed outside rising edge");
 task reset_now;
   integer count;
   begin
     rst=1;c_valid=0;s_valid=0;m_ready=0;
     repeat(2)begin @(posedge clk);#1;if(c_ready ||s_ready ||m_valid)$fatal(1,"reset validity");end
     @(negedge clk);rst=0;resets=resets+1;count=0;
     while(!c_ready)begin @(negedge clk);count=count+1;if(count>4)$fatal(1,"reset bridge recovery");end
     if(m_valid ||!helper_reset_view)$fatal(1,"reset left old result");
   end
 endtask
 task command(input[31:0]n,threshold,hold_count,input[63:0]floor_value,input[T-1:0]tag);
   begin
     @(negedge clk);c_valid=1;c_samples=n;c_threshold_q16=threshold;c_hold=hold_count;
     c_min_energy=floor_value;c_tag=tag;
     @(posedge clk);if(!c_ready ||m_valid ||s_ready)$fatal(1,"command ownership");
     commands=commands+1;accepted_in_command=0;previous_input_time=0;captured_floor=floor_value;
     @(negedge clk);c_valid=0;c_samples=32'h80000001;c_threshold_q16=0;c_hold=0;
     c_min_energy=64'hffffffffffffffff;c_tag=~tag;
   end
 endtask
 task sample(input[2*D-1:0]word,input last);
   integer count;
   begin
     s_iq=word;s_last=last;s_valid=1;count=0;
     @(posedge clk);
     while(!s_ready)begin
       @(negedge clk);count=count+1;if(count>400)$fatal(1,"input deadline");@(posedge clk);
     end
     if(accepted_in_command>0 &&accepted_in_command<2*L &&$time-previous_input_time==90)
       warmup_ii9_checks=warmup_ii9_checks+1;
     previous_input_time=$time;last_input_time=$time;samples=samples+1;accepted_in_command=accepted_in_command+1;
     @(negedge clk);s_valid=0;s_iq=~word;s_last=~last;
   end
 endtask
 task expect_result(input[2:0]status,input[31:0]end_index,start_index,event_start,
   input qual,event_flag,last,input[T-1:0]tag,input[63:0]energy_value,re,im,
   input[23:0]phase,input zero_flag,input check_timing);
   integer count,expected_latency;
   reg[23:0]distance;
   begin
     c_valid=1;m_ready=0;count=0;
     while(!m_valid)begin
       if(c_ready)$fatal(1,"new batch admitted while owned");
       @(negedge clk);count=count+1;if(count>400)$fatal(1,"bounded result deadline");
     end
     if(count>max_wait)max_wait=count;
     if(m_status!==status ||m_end!==end_index ||m_start!==start_index ||m_event_start!==event_start ||
        m_qual!==qual ||m_event!==event_flag ||m_last!==last ||m_tag!==tag ||
        (!EX &&(64'(m_energy)!==energy_value ||64'($signed(m_cross_re))!==re ||64'($signed(m_cross_im))!==im)))
       $fatal(1,"result got status%0d end%0d start%0d es%0d q%0d event%0d last%0d tag%h E%0d P(%0d,%0d) expected status%0d end%0d start%0d es%0d q%0d event%0d last%0d tag%h E%0d P(%0d,%0d)",
         m_status,m_end,m_start,m_event_start,m_qual,m_event,m_last,m_tag,m_energy,m_cross_re,m_cross_im,
         status,end_index,start_index,event_start,qual,event_flag,last,tag,energy_value,$signed(re),$signed(im));
     if(EX)begin
       distance=m_phase-phase;if(distance>24'h800000)distance=-distance;
       if(m_zero!==zero_flag ||distance>2)$fatal(1,"mathematical phase got%h expected%h dist%0d zero%0d/%0d",m_phase,phase,distance,m_zero,zero_flag);
       if((zero_flag ||re==0 ||im==0) &&m_phase!==phase)$fatal(1,"axis/zero phase must be exact");
       phase_checks=phase_checks+1;
     end
     if(check_timing)begin
       expected_latency=((status==7 ||energy_value<captured_floor)?8:13+4*LM)+(EX?26:0);
       if(($time-last_input_time)/10!=expected_latency)
         $fatal(1,"latency got%0d expected%0d",($time-last_input_time)/10,expected_latency);
       timing_checks=timing_checks+1;
     end
     repeat(stall_budget)begin @(negedge clk);if(!m_valid ||c_ready)$fatal(1,"held ownership");end
     m_ready=1;@(posedge clk);if(c_ready)$fatal(1,"retirement fallthrough");
     @(negedge clk);m_ready=0;c_valid=0;
     if(last &&(!c_ready ||m_valid))$fatal(1,"final retirement failed");
     records=records+1;events=events+event_flag;qualified=qualified+qual;
   end
 endtask
 task wait_state(input[4:0]wanted);
   integer count;
   begin count=0;while(state_view!=wanted)begin
     @(negedge clk);count=count+1;if(count>400)$fatal(1,"state deadline %0d",wanted);
   end end
 endtask
 localparam[2*D-1:0]TEST_WORD=(2*D)'((64'd4<<D)|64'd3);
 task fill_window(input integer extra);
   integer index;
   begin
     command(2*L+extra,65536,1,0,{T{1'b1}});
     for(index=0;index<2*L;index=index+1)sample(TEST_WORD,(extra==0 &&index==2*L-1));
   end
 endtask
 task recover;
   begin
     fill_window(0);
     expect_result(0,2*L-1,0,0,1,1,1,{T{1'b1}},2*L*25,L*25,0,0,0,1);
   end
 endtask
 integer fd,rc,i,vector_commands,vector_records;
 reg[63:0]op,a,b,c,d,e,f,g,h,j,k,l,u,v,w,z;
 reg[4095:0]vector_file;
 initial begin
   if(!$value$plusargs("vectors=%s",vector_file))$fatal(1,"missing vectors");
   fd=$fopen(vector_file,"r");if(!fd)$fatal(1,"cannot read vectors");
   @(negedge clk);reset_now();
   while(!$feof(fd))begin
     rc=$fscanf(fd,"%h %h %h %h %h %h %h %h %h %h %h %h %h %h %h %h\n",op,a,b,c,d,e,f,g,h,j,k,l,u,v,w,z);
     if(rc!=16)$fatal(1,"malformed row %0d",rc);
     case(op)
       1:command(a[31:0],b[31:0],c[31:0],d,e[T-1:0]);
       2:sample(a[2*D-1:0],b[0]);
       3:expect_result(a[2:0],b[31:0],c[31:0],d[31:0],e[0],f[0],g[0],h[T-1:0],j,k,l,u[23:0],v[0],1);
       4:repeat(a)@(negedge clk);
       5:expect_result(a[2:0],b[31:0],c[31:0],d[31:0],e[0],f[0],g[0],h[T-1:0],j,k,l,u[23:0],v[0],0);
       default:$fatal(1,"unknown operation");
     endcase
   end
   $fclose(fd);vector_commands=commands;vector_records=records;
   // Partial RAM/history, MAC, serial multiply and held-output cancellation.
   command(2*L+1,65536,1,0,1);sample(TEST_WORD,0);wait_state(1);reset_now();recover();
   command(2*L,65536,1,0,1);sample(TEST_WORD,0);wait_state(4);reset_now();recover();
   fill_window(0);wait_state(9);reset_now();recover();
   fill_window(0);wait_state(10);reset_now();recover();
   fill_window(0);while(!m_valid)@(negedge clk);reset_now();recover();
   if(EX)begin
     fill_window(0);while(angle_state_view!=1)@(negedge clk);reset_now();recover();
   end
   // Explicit impossible-on-legal-input faults test fatal helper flush/recovery.
   command(2*L,65536,1,0,{T{1'b1}});sample(TEST_WORD,0);wait_state(5);
   while(!mac_valid_view)@(negedge clk);g_dut.inject(0);faults=faults+1;
   expect_result(6,0,0,0,0,0,1,{T{1'b1}},0,0,0,0,1,0);recover();
   fill_window(0);wait_state(10);g_dut.inject(1);faults=faults+1;
   expect_result(6,2*L-1,0,0,0,0,1,{T{1'b1}},0,0,0,0,1,0);recover();
   if(EX)begin
     // Real composition under simultaneous input and output backpressure:
     // the next core result must wait while the earlier phase+metadata holds.
     command(2*L+3,65536,2,0,{T{1'b1}});stall_budget=260;
     fork
       begin:concurrent_input
         integer q;
         for(q=0;q<2*L+3;q=q+1)sample(TEST_WORD,q==2*L+2);
       end
       begin:concurrent_output
         integer q;
         for(q=0;q<4;q=q+1)begin
           expect_result(0,2*L-1+q,q,0,1,q==1,q==3,{T{1'b1}},2*L*25,L*25,0,0,0,0);
           stall_budget=4;
         end
       end
     join
   end
   if(records!=vector_records+9+5*EX ||commands!=vector_commands+14+3*EX ||resets!=6+EX ||faults!=2 ||
      held_cycles==0 ||events==0 ||qualified==0 ||warmup_ii9_checks==0 ||timing_checks==0 ||(EX &&phase_checks!=records))
     $fatal(1,"coverage records%0d commands%0d resets%0d faults%0d phase%0d",records,commands,resets,faults,phase_checks);
   $display("PASS repeated_half_sync D=%0d L=%0d M=%0d T=%0d EX=%0d records=%0d samples=%0d commands=%0d resets=%0d faults=%0d held=%0d events=%0d qualified=%0d phase_checks=%0d timing_checks=%0d warmup_ii9=%0d max_wait=%0d",
     D,L,M,T,EX,records,samples,commands,resets,faults,held_cycles,events,qualified,phase_checks,timing_checks,warmup_ii9_checks,max_wait);
   $finish;
 end
 initial begin #15000000;$fatal(1,"finite TB deadline");end
endmodule
