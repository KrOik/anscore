// SPDX-License-Identifier: Apache-2.0
`timescale 1ns/1ps
module tb_chroma_median_suppress;
 parameter W=9,H=7,D=10,T=8,EXAMPLE=0;
 localparam N=W*H,CASES=16,OW=EXAMPLE?3*D+3:3*D+5;
 reg clk=0;always #5 clk=~clk;
 reg rst=1,c_valid=0,c_enable=0,s_valid=0,s_sof=0,s_eol=0,s_last=0,d_ready=0,m_ready=0;
 reg [D-1:0] c_threshold=0;
 reg [3*D-1:0] s_data=0;
 reg [T-1:0] c_tag=0;
 wire c_ready,s_ready,m_valid,m_sof,m_eol,m_last,d_valid,busy;
 wire [2:0] d_error;
 wire [T-1:0] d_tag;
 wire [16:0] d_applied,d_changed;
 wire [OW-1:0] actual;
 wire [T+36:0] done_payload={d_tag,d_changed,d_applied,d_error};
 generate if(EXAMPLE)begin: actual_chain
  wire [3*D-1:0] rgb;
  rgb_chroma_clean #(.WIDTH(W),.HEIGHT(H),.BITS(D),.TAG_W(T)) dut(
   .clk(clk),.rst(rst),.c_valid(c_valid),.c_ready(c_ready),.c_enable(c_enable),
   .c_luma_threshold(c_threshold),.c_tag(c_tag),
   .s_data(s_data),.s_valid(s_valid),.s_ready(s_ready),.s_sof(s_sof),.s_eol(s_eol),.s_last(s_last),
   .m_data(rgb),.m_valid(m_valid),.m_ready(m_ready),.m_sof(m_sof),.m_eol(m_eol),.m_last(m_last),
   .d_valid(d_valid),.d_ready(d_ready),.d_error(d_error),.d_tag(d_tag),
   .d_applied(d_applied),.d_changed(d_changed),.busy(busy));
  assign actual={m_last,m_eol,m_sof,rgb};
 end else begin: core_only
  wire [3*D-1:0] pixel;wire applied,changed;
  assign d_error[2]=1'b0;
  chroma_median_suppress #(.WIDTH(W),.HEIGHT(H),.BITS(D),.TAG_W(T)) dut(
   .clk(clk),.rst(rst),.c_valid(c_valid),.c_ready(c_ready),.c_enable(c_enable),
   .c_luma_threshold(c_threshold),.c_tag(c_tag),
   .s_data(s_data),.s_valid(s_valid),.s_ready(s_ready),.s_sof(s_sof),.s_eol(s_eol),.s_last(s_last),
   .m_data(pixel),.m_valid(m_valid),.m_ready(m_ready),.m_sof(m_sof),.m_eol(m_eol),.m_last(m_last),
   .m_applied(applied),.m_changed(changed),.d_valid(d_valid),.d_ready(d_ready),.d_error(d_error[1:0]),
   .d_tag(d_tag),.d_applied(d_applied),.d_changed(d_changed),.busy(busy));
  assign actual={m_last,m_eol,m_sof,changed,applied,pixel};
 end endgenerate
 reg [D+T:0] configs[0:CASES-1];
 reg [3*D+2:0] input_data[0:CASES*N-1];
 reg [OW-1:0] expected[0:CASES*N-1];
 reg [T+36:0] expected_done[0:CASES-1];
 reg [31:0] counts[0:3];
 integer cycle=0,case_index=0,out_index=0,checked=0,commands=0,done_checks=0,resets=0;
 integer final_hold=0,holds=0,total_applied=0,total_changed=0;
 reg force_hold=0,allow_start=0,held=0;
 reg [OW-1:0] held_payload;
 always @(negedge clk)begin
  m_ready=(!force_hold)&&!(out_index==N-1&&final_hold<4)&&(cycle%5!=0);
 end
 always @(posedge clk)begin
  cycle=cycle+1;if(cycle>500000)$fatal(1,"finite watchdog");
  if(rst)begin held=0;out_index=0;final_hold=0;end
  else begin
   if(c_valid&&c_ready&&!allow_start)$fatal(1,"future START escaped owner");
   if(held&&(!m_valid||actual!==held_payload))$fatal(1,"held output changed");
   held=m_valid&&!m_ready;held_payload=actual;
   if(m_valid&&!m_ready)begin holds=holds+1;if(m_last)final_hold=final_hold+1;end
   if(m_valid&&m_ready)begin
    if(out_index>=N||actual!==expected[case_index*N+out_index])
     $fatal(1,"pixel case=%0d index=%0d got=%h expected=%h",case_index,out_index,actual,expected[case_index*N+out_index]);
    out_index=out_index+1;checked=checked+1;
   end
   if(d_valid&&out_index!=N)$fatal(1,"DONE before final output acceptance");
  end
 end
 task reset_here;
  begin
   @(negedge clk);rst=1;c_valid=0;s_valid=0;d_ready=0;allow_start=0;
   @(posedge clk);#1;
   if(c_ready||s_ready||m_valid||d_valid||busy)$fatal(1,"reset masks");
   repeat(2)@(posedge clk);
   @(negedge clk);rst=0;force_hold=0;resets=resets+1;
  end
 endtask
 task start_case(input integer k);
  begin
   @(negedge clk);case_index=k;out_index=0;final_hold=0;allow_start=1;
   {c_tag,c_threshold,c_enable}=configs[k];c_valid=1;
   @(posedge clk);while(!c_ready)@(posedge clk);commands=commands+1;
   @(negedge clk);c_valid=0;allow_start=0;
   // All command pins change during processing; this frame owns its snapshot.
   c_enable=~c_enable;c_threshold=0;c_tag=~c_tag;
  end
 endtask
 task send_pixels(input integer amount);
  integer i;
  begin
   for(i=0;i<amount;i=i+1)begin
    @(negedge clk);{s_last,s_eol,s_sof,s_data}=input_data[case_index*N+i];s_valid=1;
    @(posedge clk);while(!s_ready)@(posedge clk);
    @(negedge clk);s_valid=0;
    if((i+case_index)%4==0)@(negedge clk);
   end
  end
 endtask
 task send_until_first_output;
  integer i;reg seen;
  begin
   i=0;seen=0;
   while(!seen)begin
    @(negedge clk);
    if(m_valid)begin s_valid=0;seen=1;end
    else begin
     // This cancellation-only source offers on an already-ready capture
     // cycle, so stopping at first output cannot withdraw a blocked offer.
     s_valid=s_ready&&(i<N);
     if(s_valid){s_last,s_eol,s_sof,s_data}=input_data[case_index*N+i];
     @(posedge clk);if(s_valid&&s_ready)i=i+1;
    end
   end
  end
 endtask
 task finish_case(input integer cancel_done);
  reg [T+36:0] snapshot;
  begin
   @(negedge clk);c_valid=1;
   @(posedge clk);while(!d_valid)@(posedge clk);
   #1;if(done_payload!==expected_done[case_index])$fatal(1,"DONE case%0d got%h expected%h",case_index,done_payload,expected_done[case_index]);
   done_checks=done_checks+1;total_applied=total_applied+d_applied;total_changed=total_changed+d_changed;
   snapshot=done_payload;
   repeat(4)begin @(posedge clk);#1;if(!d_valid||done_payload!==snapshot||c_ready||m_valid||s_ready)$fatal(1,"held DONE owner");end
   if(cancel_done)reset_here();
   else begin
    @(negedge clk);c_valid=0;d_ready=1;
    @(posedge clk);@(negedge clk);d_ready=0;
   end
  end
 endtask
 integer epoch,k;
 initial begin
  $readmemh("config.hex",configs);$readmemh("input.hex",input_data);
  $readmemh("golden.hex",expected);$readmemh("done.hex",expected_done);$readmemh("counts.hex",counts);
  if(counts[0]!=CASES||counts[1]!=N)$fatal(1,"vector geometry");
  reset_here();
  force_hold=1;start_case(0);send_pixels(1);reset_here();
  force_hold=1;start_case(0);send_until_first_output();
  if(d_valid)$fatal(1,"held output already DONE");
  repeat(3)@(posedge clk);reset_here();
  for(epoch=0;epoch<2;epoch=epoch+1)begin
   for(k=0;k<CASES;k=k+1)begin
    start_case(k);send_pixels(N);finish_case(epoch==0&&k==CASES-1);
   end
  end
  if(commands!=34||done_checks!=32||checked!=32*N||resets!=4||holds==0||
   total_applied!=2*counts[2]||total_changed!=2*counts[3])$fatal(1,"coverage accounting");
  if(EXAMPLE)$display("PASS CHROMA_RGB W=%0d H=%0d D=%0d commands=%0d done=%0d checked=%0d resets=%0d applied=%0d changed=%0d holds=%0d",W,H,D,commands,done_checks,checked,resets,total_applied,total_changed,holds);
  else $display("PASS CHROMA_MEDIAN W=%0d H=%0d D=%0d T=%0d commands=%0d done=%0d checked=%0d resets=%0d applied=%0d changed=%0d holds=%0d",W,H,D,T,commands,done_checks,checked,resets,total_applied,total_changed,holds);
  $finish;
 end
endmodule
