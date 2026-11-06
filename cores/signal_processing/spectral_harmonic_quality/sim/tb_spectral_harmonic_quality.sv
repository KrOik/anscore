`timescale 1ns/1ps
module tb_spectral_harmonic_quality;
 parameter integer L=8,H=8,T=8,EX=0;
 localparam integer SW=32+L-1,QW=SW+17;
 reg clk=0;always #5 clk=~clk;
 reg rst=1,c_valid=0,s_valid=0,m_ready=0,s_last=0,s_invalid=0;
 reg[31:0]c_log2n=0,c_harmonics=0,c_radius=0,c_search_low=0,c_search_high=0,s_data=0;
 reg[T-1:0]c_tag=0;
 wire c_ready,s_ready,m_valid;
 wire[2:0]m_status,m_ratio_valid;
 wire[T-1:0]m_tag;
 wire[31:0]m_log2n,m_harmonics,m_radius,m_search_low,m_search_high,m_fund_bin,m_peak_power;
 wire[12:0]m_received;
 wire[SW-1:0]m_total,m_fund,m_harm,m_residual;
 wire[H*SW-1:0]m_components;
 wire[QW-1:0]m_thd2_q16,m_snr_q16,m_sinad_q16;
 generate if(EX)begin:g
   iq_spectral_harmonic_quality #(.MAX_LOG2N(L),.MAX_HARMONICS(H),.TAG_W(T)) dut(
     .clk(clk),.rst(rst),.c_valid(c_valid),.c_ready(c_ready),.c_log2n(c_log2n),
     .c_harmonics(c_harmonics),.c_radius(c_radius),.c_search_low(c_search_low),.c_search_high(c_search_high),.c_tag(c_tag),
     .s_valid(s_valid),.s_ready(s_ready),.s_iq(s_data),.s_last(s_last),.s_invalid(s_invalid),
     .m_valid(m_valid),.m_ready(m_ready),.m_status(m_status),.m_tag(m_tag),.m_log2n(m_log2n),
     .m_harmonics(m_harmonics),.m_radius(m_radius),.m_search_low(m_search_low),.m_search_high(m_search_high),
     .m_received(m_received),.m_fund_bin(m_fund_bin),.m_peak_power(m_peak_power),
     .m_total(m_total),.m_fund(m_fund),.m_harm(m_harm),.m_residual(m_residual),.m_components(m_components),
     .m_thd2_q16(m_thd2_q16),.m_snr_q16(m_snr_q16),.m_sinad_q16(m_sinad_q16),.m_ratio_valid(m_ratio_valid));
   wire[4:0]core_state=dut.instrument.state;
   wire divider_valid=dut.instrument.div_valid;
   task fault_on;begin force dut.instrument.div_flags=2'b01;end endtask
   task fault_off;begin release dut.instrument.div_flags;end endtask
 end else begin:g
   spectral_harmonic_quality #(.MAX_LOG2N(L),.MAX_HARMONICS(H),.TAG_W(T)) dut(
     .clk(clk),.rst(rst),.c_valid(c_valid),.c_ready(c_ready),.c_log2n(c_log2n),
     .c_harmonics(c_harmonics),.c_radius(c_radius),.c_search_low(c_search_low),.c_search_high(c_search_high),.c_tag(c_tag),
     .s_valid(s_valid),.s_ready(s_ready),.s_power(s_data),.s_last(s_last),.s_invalid(s_invalid),
     .m_valid(m_valid),.m_ready(m_ready),.m_status(m_status),.m_tag(m_tag),.m_log2n(m_log2n),
     .m_harmonics(m_harmonics),.m_radius(m_radius),.m_search_low(m_search_low),.m_search_high(m_search_high),
     .m_received(m_received),.m_fund_bin(m_fund_bin),.m_peak_power(m_peak_power),
     .m_total(m_total),.m_fund(m_fund),.m_harm(m_harm),.m_residual(m_residual),.m_components(m_components),
     .m_thd2_q16(m_thd2_q16),.m_snr_q16(m_snr_q16),.m_sinad_q16(m_sinad_q16),.m_ratio_valid(m_ratio_valid));
   wire[4:0]core_state=dut.state;
   wire divider_valid=dut.div_valid;
   task fault_on;begin force dut.div_flags=2'b01;end endtask
   task fault_off;begin release dut.div_flags;end endtask
 end endgenerate
 localparam integer BUNDLE_W=3+T+7*32+13+4*SW+H*SW+3*QW+3;
 wire[BUNDLE_W-1:0]bundle={m_status,m_tag,m_log2n,m_harmonics,m_radius,m_search_low,m_search_high,
   m_received,m_fund_bin,m_peak_power,m_total,m_fund,m_harm,m_residual,m_components,
   m_thd2_q16,m_snr_q16,m_sinad_q16,m_ratio_valid};
 reg[BUNDLE_W-1:0]held_bundle;
 reg[31:0]sample_data[0:4095];
 reg sample_last[0:4095],sample_invalid[0:4095];
 reg[31:0]el,eh,er,elo,ehi,etag,estatus,ereceived,ebin,epeak,evalid;
 reg[SW-1:0]etotal,efund,eharm,eresidual;
 reg[QW-1:0]ethd,esnr,esinad;
 reg[H*SW-1:0]ecomponents;
 integer fd,scanned,case_id,action,target,count,i,j,waited;
 integer cases_done=0,commands=0,responses=0,resets=1,faults=0,samples=0,held=0,ii1=0,max_wait=0;
 integer accepted_this_case=0;
 reg canceled=0;
 reg[1023:0]vector_path;
 reg prior_offer=0;
 reg[33:0]prior_input;
 reg prior_command_offer=0;
 reg[160+T-1:0]prior_command;
 reg have_case=0;
 always @(posedge clk)begin
   if(rst)begin prior_offer<=0;prior_command_offer<=0;end
   else begin
     if(c_valid &&c_ready)commands<=commands+1;
     if(s_valid &&s_ready)begin samples<=samples+1;accepted_this_case<=accepted_this_case+1;end
     if(m_valid &&m_ready)responses<=responses+1;
     if(prior_offer &&(!s_valid ||{s_data,s_last,s_invalid}!==prior_input))
       $fatal(1,"input source changed a stalled offer");
     prior_offer<=s_valid &&!s_ready;
     prior_input<={s_data,s_last,s_invalid};
     if(prior_command_offer &&(!c_valid ||
        {c_log2n,c_harmonics,c_radius,c_search_low,c_search_high,c_tag}!==prior_command))
       $fatal(1,"command source changed a stalled offer");
     prior_command_offer<=c_valid &&!c_ready;
     prior_command<={c_log2n,c_harmonics,c_radius,c_search_low,c_search_high,c_tag};
   end
 end
 task read_case;
   begin
     scanned=$fscanf(fd,"%h %h %h %h %h %h %h %h %h %h %h %h %h %h %h %h %h %h %h %h %h %h %h\n",
       case_id,action,target,el,eh,er,elo,ehi,etag,count,estatus,ereceived,ebin,epeak,etotal,efund,eharm,eresidual,
       ethd,esnr,esinad,evalid,ecomponents);
     have_case=scanned!=-1;
     if(have_case)begin
       if(scanned!=23 ||count<0 ||count>4096 ||case_id!=cases_done)$fatal(1,"malformed vector header %0d",scanned);
       for(i=0;i<count;i=i+1)begin
         scanned=$fscanf(fd,"%h %h %h\n",sample_data[i],sample_last[i],sample_invalid[i]);
         if(scanned!=3)$fatal(1,"malformed sample");
       end
     end
   end
 endtask
 task offer_command;
   begin
     @(negedge clk);
     c_log2n=el;c_harmonics=eh;c_radius=er;c_search_low=elo;c_search_high=ehi;c_tag=etag[T-1:0];c_valid=1;
   end
 endtask
 task command;
   integer timeout;
   begin
     timeout=0;
     if(!c_valid)offer_command();
     while(!c_ready)begin @(negedge clk);timeout=timeout+1;if(timeout>32)$fatal(1,"idle did not return");end
     @(posedge clk);if(!c_ready)$fatal(1,"command not accepted");
     @(negedge clk);c_valid=0;
     c_log2n=32'h80000000;c_harmonics=32'hffffffff;c_radius=32'hfedcba98;
     c_search_low=32'hdeadbeef;c_search_high=32'h01234567;c_tag=~c_tag;
   end
 endtask
 task send_samples;
   integer k,ticks;
   begin:send_body
     for(k=0;k<count;k=k+1)begin
       if(canceled)disable send_body;
       @(negedge clk);
       if(canceled)disable send_body;
       if(case_id%2 &&k%7==2)begin s_valid=0;@(negedge clk);end
       if(canceled)disable send_body;
       s_valid=1;s_data=sample_data[k];s_last=sample_last[k];s_invalid=sample_invalid[k];ticks=0;
       begin:await_sample
         forever begin
           @(posedge clk);
           if(canceled ||rst)disable send_body;
           if(s_ready)begin
             if(ticks==0 &&k>0)ii1=ii1+1;
             disable await_sample;
           end
           if(k>0)$fatal(1,"collection failed II1 readiness");
           ticks=ticks+1;if(ticks>64)$fatal(1,"unexpected sample backpressure case %0d",case_id);
         end
       end
     end
     @(negedge clk);s_valid=0;s_last=0;s_invalid=0;
   end
 endtask
 task cancel_at_state;
   integer ticks;
   begin
     ticks=0;
     while(g.core_state!=target ||(target==3 &&accepted_this_case<3))begin
       @(negedge clk);ticks=ticks+1;
       if(ticks>20000)$fatal(1,"cancel state %0d not reached",target);
     end
     canceled=1;c_valid=0;s_valid=0;rst=1;
     repeat(2)@(negedge clk);
     rst=0;resets=resets+1;
     repeat(3)@(negedge clk);
     if(m_valid ||!c_ready)$fatal(1,"cancel did not discard service");
   end
 endtask
 task inject_fault;
   integer ticks;
   begin
     ticks=0;
     while(!(g.core_state==11 &&g.divider_valid))begin
       @(negedge clk);ticks=ticks+1;
       if(ticks>20000)$fatal(1,"divider result not reached");
     end
     g.fault_on();faults=faults+1;
     @(negedge clk);g.fault_off();
   end
 endtask
 task compare_result;
   begin
     if(m_status!==estatus[2:0] ||m_tag!==etag[T-1:0] ||m_log2n!==el ||m_harmonics!==eh ||
       m_radius!==er ||m_search_low!==elo ||m_search_high!==ehi ||m_received!==ereceived[12:0] ||
       m_fund_bin!==ebin ||m_peak_power!==epeak ||m_total!==etotal ||m_fund!==efund ||
       m_harm!==eharm ||m_residual!==eresidual ||m_components!==ecomponents ||
       m_thd2_q16!==ethd ||m_snr_q16!==esnr ||m_sinad_q16!==esinad ||m_ratio_valid!==evalid[2:0])begin
       $display("case=%0d status %h/%h received %h/%h peak %h/%h F %h/%h H %h/%h R %h/%h",case_id,
         m_status,estatus,m_received,ereceived,m_fund_bin,ebin,m_fund,efund,m_harm,eharm,m_residual,eresidual);
       $display("total %h/%h components %h/%h ratios %h %h %h / %h %h %h valid %h/%h",m_total,etotal,
         m_components,ecomponents,m_thd2_q16,m_snr_q16,m_sinad_q16,ethd,esnr,esinad,m_ratio_valid,evalid);
       $fatal(1,"oracle mismatch");
     end
   end
 endtask
 initial begin
   if(!$value$plusargs("vectors=%s",vector_path))$fatal(1,"missing vectors");
   fd=$fopen(vector_path,"r");if(fd==0)$fatal(1,"cannot open vectors");
   repeat(3)@(negedge clk);rst=0;repeat(3)@(negedge clk);
   read_case();
   while(have_case)begin
       accepted_this_case=0;canceled=0;m_ready=0;
       command();
       if(action==1)begin
         fork send_samples();cancel_at_state();join
         s_valid=0;cases_done=cases_done+1;read_case();
       end else begin
         if(action==2)begin fork send_samples();inject_fault();join end
         else send_samples();
         waited=0;
         while(!m_valid)begin
           @(negedge clk);waited=waited+1;
           if(waited> (1<<el)/2+320+8)$fatal(1,"response service budget exceeded");
         end
         if(waited>max_wait)max_wait=waited;
         compare_result();held_bundle=bundle;
         // The next REAL vector is offered while the old response is held.
         // Its source remains asserted through retirement until command() in
         // the next loop accepts it. No blocked source offer is withdrawn.
         cases_done=cases_done+1;read_case();
         if(have_case)offer_command();
         repeat(5)begin
           @(negedge clk);held=held+1;
           if(!m_valid ||bundle!==held_bundle ||c_ready ||s_ready)$fatal(1,"held output/ownership violated");
         end
         m_ready=1;
         @(posedge clk);if(!m_valid)$fatal(1,"response disappeared");
         @(negedge clk);m_ready=0;
       end
   end
   $fclose(fd);
   repeat(4)@(negedge clk);
   if(m_valid ||!c_ready)$fatal(1,"final idle missing");
   $display("PASS spectral_harmonic_quality cases=%0d commands=%0d responses=%0d resets=%0d faults=%0d samples=%0d held=%0d ii1=%0d max_wait=%0d",
      cases_done,commands,responses,resets,faults,samples,held,ii1,max_wait);
   $finish;
 end
 initial begin #1000000000;$fatal(1,"global finite watchdog");end
endmodule
