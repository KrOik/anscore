`timescale 1ns/1ps
module tb_img_dh_iter_div_signed64;
reg clk=0;always #5 clk=~clk;
reg rst_n=0,ce=1,start=0;
reg signed [63:0] a=0,b=1;
wire busy,done,accept,operands_ready,subtract;
wire signed [63:0] q;
wire [6:0] initial_bit,bit_index;
wire [63:0] am,bm,qm;
wire [64:0] rem_now,trial;
img_dh_iter_div_signed64 dut(.clk(clk),.rst_n(rst_n),.clk_en(ce),.start(start),.dividend(a),.divisor(b),
 .busy(busy),.done(done),.quotient(q),.start_accept(accept),.debug_operands_ready(operands_ready),
 .debug_start_bit_index(initial_bit),.debug_bit_index(bit_index),.debug_dividend_magnitude(am),
 .debug_divisor_magnitude(bm),.debug_quotient_magnitude(qm),.debug_remainder(rem_now),
 .debug_shifted_remainder(trial),.debug_subtract_divisor(subtract));
integer cases=0,pause_count=0,commit_count=0,ignored_starts=0,i;
reg [63:0] seed=64'h132790afde53c18b,ra,rb;
function [63:0] rng(input [63:0] x);
reg [63:0] t;begin t=x^(x<<13);t=t^(t>>7);rng=t^(t<<17);end endfunction
function [1200:0] state_snapshot;
begin state_snapshot={busy,done,q,dut.phase,dut.byte_index,dut.bit_index,
 dut.dividend_negative,dut.divisor_negative,dut.quotient_negative,
 dut.carry_a,dut.carry_b,dut.borrow,dut.finish_carry,
 dut.dividend_operand,dut.divisor_operand,dut.dividend_magnitude,dut.divisor_magnitude,
 dut.quotient_magnitude,dut.remainder,dut.trial_work,dut.divisor_work,dut.difference_q,
 dut.finish_work,dut.finish_q,dut.debug_start_bit_index};end endfunction
task tick;begin @(posedge clk);#1;end endtask
task divide_case(input [63:0] x,y);
reg [63:0] ax,by,expected,refrem,refq,shift_a,exprem,expq;
reg [64:0] reftrial;
reg [1200:0] snapshot;
reg commit;
integer enabled,cycles,bits;begin
 if(y==0)$fatal(1,"invalid fixture divisor");
 ax=x[63] ? (~x+64'd1) : x;by=y[63] ? (~y+64'd1) : y;
 expected=ax/by;if(x[63]^y[63])expected=~expected+64'd1;
 @(negedge clk);ce=1;start=1;a=x;b=y;
 #1;if(!accept)$fatal(1,"start not accepted");tick();
 if(!busy || done || operands_ready || initial_bit!==63)$fatal(1,"start state");
 enabled=0;cycles=0;bits=0;refrem=0;refq=0;shift_a=ax;
 while(!done)begin
  @(negedge clk);cycles=cycles+1;ce=(cycles%7!=2 && cycles%7!=3);
  a=~x^cycles;b=y+cycles+1;start=(cycles%11==0);
  #1;if(accept)$fatal(1,"busy accepted new start");if(start)ignored_starts=ignored_starts+1;
  snapshot=state_snapshot();commit=ce && dut.phase==3;
  if(commit)begin
   reftrial={1'b0,refrem}*2+shift_a[63];
   if(subtract!==(reftrial>={1'b0,by}))$fatal(1,"borrow mismatch");
   exprem=(reftrial>={1'b0,by}) ? reftrial-by : reftrial;
   expq={refq[62:0],(reftrial>={1'b0,by})};
  end
  tick();
  if(!ce)begin if(state_snapshot()!==snapshot)$fatal(1,"CE changed registers");pause_count=pause_count+1;end
  else begin
   enabled=enabled+1;
   if(enabled==8 && (!operands_ready || am!==ax || bm!==by))$fatal(1,"normalization");
   if(commit)begin
    if(rem_now!=={1'b0,exprem} || qm!==expq)$fatal(1,"restoring step");
    refrem=exprem;refq=expq;shift_a=shift_a<<1;bits=bits+1;commit_count=commit_count+1;
   end
  end
  if(cycles>1100)$fatal(1,"timeout");
 end
 if(enabled!=656 || busy || q!==expected || rem_now!=={1'b0,(ax%by)} || qm!==(ax/by) || bits!=64)
  $fatal(1,"result a=%h b=%h q=%h expected=%h latency=%0d bits=%0d",x,y,q,expected,enabled,bits);
 @(negedge clk);ce=0;start=0;snapshot=state_snapshot();tick();
 if(state_snapshot()!==snapshot)$fatal(1,"done hold on CE pause");
 @(negedge clk);ce=1;tick();if(done || busy || q!==expected)$fatal(1,"done clear/result hold");
 cases=cases+1;
end endtask
initial begin
 repeat(3)tick();@(negedge clk);rst_n=1;
 divide_case(0,1);divide_case(1,1);divide_case(-64'd1,1);divide_case(1,-64'd1);
 divide_case(64'h8000000000000000,-64'd1);divide_case(64'h8000000000000000,1);
 divide_case(64'h7fffffffffffffff,64'h8000000000000000);
 divide_case(64'h8000000000000000,64'h8000000000000000);
 divide_case(64'h7fffffffffffffff,3);divide_case(-64'd123456789,64'd32768);
 divide_case(64'h100000000,64'hffffffff);divide_case(64'hffffffff,64'h100000000);
 divide_case(64'h1000000000000,64'hff);divide_case(64'h7fff0000ffff0000,64'h10001);
 divide_case(64'hffffffff00000000,64'hffff000000000001);divide_case(64'h0101010101010101,64'h101);
 for(i=0;i<256;i=i+1)begin seed=rng(seed);ra=seed;seed=rng(seed);rb=seed;if(rb==0)rb=1;divide_case(ra,rb);end
 @(negedge clk);ce=1;start=1;a=-987654321;b=97;tick();
 @(negedge clk);start=0;repeat(15)tick();@(negedge clk);rst_n=0;tick();
 if(busy || done || q!==0)$fatal(1,"mid-operation reset");
 $display("DIVIDER_BYTE_TEST PASS cases=%0d latency_ce=656 commits=%0d ce_pauses=%0d busy_starts=%0d reset=1",cases,commit_count,pause_count,ignored_starts);$finish;
end
initial begin #10000000;$fatal(1,"test timed out");end
endmodule
