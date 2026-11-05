// SPDX-License-Identifier: Apache-2.0
`timescale 1ns/1ps
module tb_event_interval_recorder;
 parameter integer T=32,E=16,D=4,C=32,G=8,N=1;
 localparam integer IN_W=39+G,EX_W=9+T+E+C+2*G;
 reg clk=0;always #5 clk=~clk;
 reg rst=1,arm_valid=0,reference_event=0,observation_event=0,stop=0,m_ready=0,done_ready=0;
 reg[31:0]arm_window=0;reg[G-1:0]arm_tag=0;
 wire arm_ready,busy,running,m_valid,done_valid,done_error,done_drop_saturated;
 wire[T-1:0]m_interval;wire[E-1:0]m_epoch;wire[1:0]m_status;
 wire[G-1:0]m_tag,done_tag;wire[C-1:0]done_dropped;
 event_interval_recorder #(.TIME_W(T),.EPOCH_W(E),.FIFO_DEPTH(D),.DROP_W(C),.TAG_W(G)) dut(.*);
 reg[IN_W-1:0] stimulus[0:N-1];reg[EX_W-1:0]expected[0:N-1];
 reg ex_arm_ready,ex_busy,ex_running,ex_m_valid,ex_done_valid,ex_done_error,ex_saturated;
 reg[1:0]ex_status;reg[T-1:0]ex_interval;reg[E-1:0]ex_epoch;
 reg[G-1:0]ex_m_tag,ex_done_tag;reg[C-1:0]ex_dropped;
 reg was_stalled=0,done_stalled=0;
 reg[T+E+G+1:0]held_result;
 reg[C+G+1:0]held_done;
 integer i,records=0,stalled=0,done_holds=0,zeros=0,expired=0,no_ref=0;
 initial begin
   $readmemh("stimulus.hex",stimulus);$readmemh("expected.hex",expected);
   for(i=0;i<N;i=i+1)begin
     @(negedge clk);
     {rst,arm_valid,arm_window,arm_tag,reference_event,observation_event,stop,m_ready,done_ready}=stimulus[i];
     {ex_arm_ready,ex_busy,ex_running,ex_m_valid,ex_status,ex_interval,ex_epoch,ex_m_tag,
      ex_done_valid,ex_done_error,ex_dropped,ex_saturated,ex_done_tag}=expected[i];
     @(posedge clk);
     if(!rst)begin
       if(was_stalled && (!m_valid||{m_status,m_interval,m_epoch,m_tag}!==held_result))$fatal(1,"held event mutated cycle%0d",i);
       if(done_stalled && (!done_valid||{done_error,done_dropped,done_drop_saturated,done_tag}!==held_done))$fatal(1,"held done mutated");
       if(m_valid&&m_ready)begin
         records=records+1;if(m_status==0&&m_interval==0)zeros=zeros+1;
         if(m_status==1)no_ref=no_ref+1;if(m_status==2)expired=expired+1;
       end
     end
     #1;
     if({arm_ready,busy,running,m_valid,done_valid}!=={ex_arm_ready,ex_busy,ex_running,ex_m_valid,ex_done_valid})
       $fatal(1,"control cycle%0d got %b exp%b",i,{arm_ready,busy,running,m_valid,done_valid},{ex_arm_ready,ex_busy,ex_running,ex_m_valid,ex_done_valid});
     if(m_valid && {m_status,m_interval,m_epoch,m_tag}!=={ex_status,ex_interval,ex_epoch,ex_m_tag})
       $fatal(1,"event cycle%0d got status%0d dt%0d epoch%0d tag%h expected status%0d dt%0d epoch%0d tag%h",i,m_status,m_interval,m_epoch,m_tag,ex_status,ex_interval,ex_epoch,ex_m_tag);
     if(done_valid && {done_error,done_dropped,done_drop_saturated,done_tag}!=={ex_done_error,ex_dropped,ex_saturated,ex_done_tag})
       $fatal(1,"done mismatch cycle%0d",i);
     was_stalled=m_valid&&!m_ready;held_result={m_status,m_interval,m_epoch,m_tag};
     done_stalled=done_valid&&!done_ready;held_done={done_error,done_dropped,done_drop_saturated,done_tag};
     if(was_stalled)stalled=stalled+1;if(done_stalled)done_holds=done_holds+1;
   end
   if(records==0 ||stalled==0||done_holds==0||zeros==0||expired==0||no_ref==0)$fatal(1,"vacuous coverage");
   $display("PASS event_interval_recorder T=%0d E=%0d D=%0d C=%0d G=%0d cycles=%0d records=%0d held_cycles=%0d done_holds=%0d zero_intervals=%0d no_ref=%0d expired=%0d",T,E,D,C,G,N,records,stalled,done_holds,zeros,no_ref,expired);
   $finish;
 end
 initial begin #10000000;$fatal(1,"TB watchdog");end
endmodule
