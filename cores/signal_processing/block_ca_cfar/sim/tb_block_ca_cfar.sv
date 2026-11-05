// SPDX-License-Identifier: Apache-2.0
`timescale 1ns/1ps
module tb_block_ca_cfar;
 parameter integer N=64,D=8,T=2,G=1,A=8;
 localparam integer SW=D+$clog2(2*T);
 reg clk=0; always #5 clk=~clk;
 reg rst_n=0,c_valid=0,s_valid=0,m_ready=0;
 wire c_ready,s_ready,m_valid;
 reg [31:0] c_length=0;
 reg [A-1:0] c_alpha_num=0,c_alpha_den=1;
 reg [7:0] c_tag=0;
 reg [D-1:0] s_data=0;
 wire [31:0] m_index;
 wire [D-1:0] m_sample;
 wire [SW-1:0] m_noise_sum;
 wire m_eligible,m_detect,m_last,m_error;
 wire [7:0] m_tag;
 block_ca_cfar #(.MAX_SAMPLES(N),.DATA_W(D),.TRAINING(T),.GUARD(G),.ALPHA_W(A)) dut(.*);
 reg [D-1:0] samples[0:N-1];
 integer checks=0,frames=0,stalls=0,errors=0,reset_checks=0;
 longint unsigned mask,amax;
 localparam integer BUNDLE_W=32+D+SW+4+8;
 wire [BUNDLE_W-1:0] bundle={m_index,m_sample,m_noise_sum,m_eligible,m_detect,m_last,m_error,m_tag};

 task command(input reg [31:0] n,input reg[A-1:0] num,den,input reg[7:0] tag);
 begin
   @(negedge clk); while(!c_ready) @(negedge clk);
   c_valid=1;c_length=n;c_alpha_num=num;c_alpha_den=den;c_tag=tag;
   @(posedge clk); @(negedge clk);c_valid=0;
   c_length='1;c_alpha_num='1;c_alpha_den=0;c_tag=~tag;
 end endtask
 task sample(input reg[D-1:0] v);
 begin
   @(negedge clk);while(!s_ready) @(negedge clk);
   s_valid=1;s_data=v;
   @(posedge clk);@(negedge clk);s_valid=0;s_data=~v;
 end endtask
 task hold_and_take;
 reg [BUNDLE_W-1:0] held;
 begin
   held=bundle;
   repeat(3) begin
     @(posedge clk);#1;
     if (!m_valid || bundle!==held || c_ready || s_ready) $fatal(1,"unstable/stall ownership");
     stalls=stalls+1;
   end
   @(negedge clk);m_ready=1;@(posedge clk);@(negedge clk);m_ready=0;
 end endtask
 task frame(input integer n,mode,input reg[A-1:0] num,den);
 integer i,j,eligible;
 longint unsigned sum,lhs,rhs;
 reg detect;
 reg [7:0] tag;
 begin
   tag=frames+8'd9;
   for(i=0;i<n;i=i+1) case(mode)
     0:samples[i]=1;
     1:samples[i]=(i==n/2)?mask:0;
     2:samples[i]=(i%2)?mask:0;
     3:samples[i]=(i*79+23)&mask;
     4:samples[i]=mask;
     default:samples[i]=0;
   endcase
   command(n,num,den,tag);
   for(i=0;i<n;i=i+1) begin
     if(i%3==1) repeat(2) @(negedge clk);
     sample(samples[i]);
   end
   for(i=0;i<n;i=i+1) begin
     @(negedge clk);while(!m_valid) @(negedge clk);
     eligible=(i>=T+G && i+T+G<n);sum=0;
     // Independent reference enumerates absolute cell positions and distance.
     for(j=0;j<n;j=j+1)
       if(eligible && ((j<i-G && j>=i-G-T)||(j>i+G && j<=i+G+T)))
         sum=sum+samples[j];
     lhs=samples[i];lhs=lhs*den;lhs=lhs*(2*T);
     rhs=sum*num;detect=eligible && lhs>rhs;
     if(m_error!==0 || m_index!==i || m_sample!==samples[i] ||
        m_noise_sum!==sum[SW-1:0] || m_eligible!==eligible[0] ||
        m_detect!==detect || m_last!==(i==n-1) || m_tag!==tag)
       $fatal(1,"frame=%0d cell=%0d sample=%h sum=%h/%h eligible=%b detect=%b/%b index=%d tag=%d",frames,i,m_sample,m_noise_sum,sum,m_eligible,m_detect,detect,m_index,m_tag);
     checks=checks+1;hold_and_take;
   end
   @(negedge clk);if(m_valid || !c_ready || s_ready) $fatal(1,"frame drain");
   frames=frames+1;
 end endtask
 task bad_command(input reg[31:0] n,input reg[A-1:0] den);
 begin
   command(n,1,den,8'hc5);
   @(negedge clk);while(!m_valid) @(negedge clk);
   if(!m_error || !m_last || m_eligible || m_detect || m_sample || m_noise_sum || m_index || m_tag!==8'hc5)
     $fatal(1,"bad config response");
   hold_and_take;errors=errors+1;
 end endtask
 task reset_core;
 begin
   @(negedge clk);rst_n=0;c_valid=0;s_valid=0;m_ready=0;#1;
   if(m_valid || c_ready || s_ready) $fatal(1,"reset did not abort valid");
   repeat(2) @(negedge clk);rst_n=1;@(negedge clk);
   if(!c_ready || s_ready || m_valid) $fatal(1,"reset idle");
   reset_checks=reset_checks+1;
 end endtask
 initial begin
   mask=(64'd1<<D)-1;amax=(64'd1<<A)-1;
   reset_core;
   frame(1,0,1,1);
   frame(N,0,1,1); // equality must not detect
   frame(N,1,2,1); // central impulse
   frame(N,2,amax,amax); // full-width products and sums
   frame(N,3,0,amax); // zero multiplier, positive/zero cells
   frame(N,4,amax,1); // nontrivial wide threshold
   frame(N,5,amax,amax); // all zero equality
   if(2*(T+G)<=N) frame(2*(T+G),3,3,2);
   if(2*(T+G)+1<=N) frame(2*(T+G)+1,3,3,2);
   bad_command(0,1);bad_command(N+1,1);bad_command(32'h80000001,1);bad_command(1,0);
   // Reset during loading must hide every old RAM word.
   command(N,1,1,8'h11);
   if(N>1) sample(mask);
   reset_core;
   // Reset during an internal synchronous read, before a result is offered.
   command(1,1,1,8'h22);sample(mask);reset_core;
   // Reset a held output, then accept a fresh frame.
   command(1,1,1,8'h33);sample(mask);
   while(!m_valid) @(negedge clk);
   reset_core;frame(N,3,(A<2)?1:3,(A<2)?1:2);
   if(checks==0 || stalls==0 || errors!=4 || reset_checks!=4) $fatal(1,"coverage");
   $display("PASS N=%0d D=%0d T=%0d G=%0d A=%0d frames=%0d cells=%0d stalled_cycles=%0d errors=%0d resets=%0d",N,D,T,G,A,frames,checks,stalls,errors,reset_checks);
   $finish;
 end
 initial begin #20000000;$fatal(1,"TB watchdog");end
endmodule
