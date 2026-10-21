`timescale 1ns/1ps
module tb_cip_cdc;
reg src_clk=0,dst_clk=0,rst_n=1,src_ce=1,dst_ce=1;
always #5 src_clk=~src_clk;
always #7 dst_clk=~dst_clk;
reg [31:0] s_data=0;
reg s_valid=0,m_ready=0;
wire s_ready,m_valid;
wire [31:0] m_data;
integer sent=0,received=0,src_ticks=0,dst_ticks=0;
reg previous_hold=0;
reg [31:0] previous_data=0;
cip_cdc_mailbox dut(.*);
reg slow_level=0;
wire synced,local_rst_n;
cip_bit_sync bitsync(.clk(src_clk),.rst_n(rst_n),.clk_en(src_ce),.async_in(slow_level),.sync_out(synced));
cip_reset_sync resetsync(.clk(src_clk),.async_rst_n(rst_n),.sync_rst_n(local_rst_n));
always @(negedge src_clk) begin
    if (rst_n) begin
        src_ticks=src_ticks+1; src_ce=(src_ticks%7!=0);
        s_valid=(sent<48); s_data=32'h10203040+sent;
    end
end
always @(posedge src_clk) begin
    if(rst_n && src_ce && s_valid && s_ready) sent=sent+1;
end
always @(negedge dst_clk) begin
    if(rst_n) begin
        dst_ticks=dst_ticks+1; dst_ce=(dst_ticks%5!=0); m_ready=(dst_ticks%4!=0);
    end
end
always @(posedge dst_clk) begin
    if(!rst_n) previous_hold=0;
    else begin
        if(previous_hold && (!m_valid || m_data !== previous_data)) $fatal(1,"mailbox unstable under stall");
        if(dst_ce && m_valid && m_ready) begin
            if(m_data !== (32'h10203040+received)) $fatal(1,"mailbox sequence mismatch %d",received);
            received=received+1;
        end
        previous_hold=m_valid && (!dst_ce || !m_ready);
        previous_data=m_data;
    end
end
initial begin
    #1; rst_n=0; #2;
    if(local_rst_n !== 0) $fatal(1,"reset assertion");
    #15; rst_n=1;
    @(posedge src_clk); #1; if(local_rst_n !== 0) $fatal(1,"early reset release");
    @(posedge src_clk); #1; if(local_rst_n !== 1) $fatal(1,"reset release latency");
    @(negedge src_clk); slow_level=1;
    wait(synced===1);
    wait(received==48);
    repeat(20) @(posedge dst_clk);
    if(sent!=48 || received!=48) $fatal(1,"mailbox counts");
    #1; rst_n=0; #1;
    if(local_rst_n !== 0 || m_valid !== 0 || synced !== 0) $fatal(1,"reset recovery");
    $display("CDC PASS transfers=48 asynchronous_clocks=10ns/14ns");
    $finish;
end
initial begin #200000; $fatal(1,"CDC timeout"); end
endmodule
