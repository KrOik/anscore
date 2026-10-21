`timescale 1ns/1ps
module tb_cip_stream_fifo_demo;
reg clk=0,rst_n=1,clk_en=0;
always #5 clk=~clk;
reg [31:0] s_data=0;
reg [3:0] s_keep=0;
reg s_sof=0,s_last=0,s_valid=0,m_ready=0;
wire s_ready,m_sof,m_last,m_valid;
wire [31:0] m_data;
wire [3:0] m_keep;
integer offered=0,accepted=0,received=0,ticks=0,epoch=0,total_received=0;
reg held=0;
reg [37:0] held_payload;
cip_stream_fifo_demo #(.DEPTH(3)) dut(.*);
always @(negedge clk) if(rst_n) begin
    ticks=ticks+1;clk_en=(ticks%6!=0);m_ready=(ticks%5>1);
    s_valid=(accepted<257);s_data=32'h5ac00000+accepted;
    s_keep=(accepted%4==3)?4'b0011:4'b1111;
    s_sof=(accepted%13==0);s_last=(accepted%13==12);
end
always @(posedge clk) begin
    if(!rst_n) begin accepted=0;received=0;held=0; end
    else begin
        if(held && (!m_valid || {m_sof,m_last,m_keep,m_data} !== held_payload))
            $fatal(1,"integration output unstable");
        if(clk_en && s_valid && s_ready) accepted=accepted+1;
        if(clk_en && m_valid && m_ready) begin
            if(m_data !== (32'h5ac00000+received) || m_sof !== (received%13==0) || m_last !== (received%13==12) ||
                m_keep !== ((received%4==3)?4'b0011:4'b1111)) $fatal(1,"integration mismatch %d",received);
            received=received+1;total_received=total_received+1;
        end
        held=m_valid&&(!clk_en||!m_ready);held_payload={m_sof,m_last,m_keep,m_data};
    end
end
initial begin
    #1;rst_n=0;#17;rst_n=1;
    // Abort an active epoch to prove no stale words/sidebands survive reset.
    wait(accepted>17);#1;rst_n=0;#13;rst_n=1;
    wait(received==257);repeat(20)@(posedge clk);
    if(accepted!=257 || m_valid) $fatal(1,"integration did not drain");
    $display("INTEGRATION PASS final_epoch_words=257 depth=3 CE/backpressure/reset/sidebands");$finish;
end
initial begin #200000;$fatal(1,"integration timeout");end
endmodule
