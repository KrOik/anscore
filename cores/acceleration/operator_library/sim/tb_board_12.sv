`timescale 1ns/1ps
module tb_board_12;
reg clk=0; always #10 clk=~clk;
reg rst_n=0;
wire done; wire [7:0] pass_mask;
wire [31:0] errors,count,digest,max_latency,stalled_beats;
wire neg_done; wire [7:0] neg_mask;
wire [31:0] neg_errors,neg_count,neg_digest,neg_latency,neg_stalls;
acc_board_group_12 dut(.*);
acc_board_group_12 #(.INJECT_ERROR(1)) negative(.clk(clk),.rst_n(rst_n),
 .done(neg_done),.pass_mask(neg_mask),.errors(neg_errors),.count(neg_count),
 .digest(neg_digest),.max_latency(neg_latency),.stalled_beats(neg_stalls));
initial begin
 repeat(4) @(negedge clk); rst_n=1;
 wait(done && neg_done); #1;
 if(pass_mask!==8'hff || errors!==0 || count!==1024 || digest!==32'h1ac1ef29
    || max_latency!==4 || stalled_beats!==1536) $fatal(1,"board group 12 failed");
 if(neg_mask!==8'hfe || neg_errors!==1 || neg_count!==1024) $fatal(1,"negative detector failed");
 $display("PASS board group=12 units=8 mask=%h count=%d digest=%h latency=%d stalls=%d negative=PASS",pass_mask,count,digest,max_latency,stalled_beats);
 $finish;
end
initial begin #60000000; $fatal(1,"board timeout"); end
endmodule
