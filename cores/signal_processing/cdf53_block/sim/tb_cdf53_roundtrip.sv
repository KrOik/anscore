// SPDX-License-Identifier: Apache-2.0
`timescale 1ns/1ps
module tb_cdf53_roundtrip;
    reg clk=0; always #5 clk=~clk;
    reg rst=1, s_valid=0, m_ready=0;
    reg signed [15:0] s_data=0;
    wire s_ready, m_valid, m_last, m_error;
    wire signed [17:0] m_data;
    reg signed [15:0] samples[0:63];
    integer i, sent=0, received=0, cycles=0, stalls=0;
    reg taken=0, stalled=0;
    reg [19:0] held;
    cdf53_roundtrip dut(.*);
    initial begin
        for(i=0;i<64;i=i+1) samples[i]=(i%3==0) ? -32768 : ((i%3==1) ? 32767 : -17*i);
        repeat(3) @(negedge clk); rst=0;
        while(received<64) begin
            @(negedge clk);
            m_ready=(cycles%11>4);
            if(taken) s_valid=0;
            if(!s_valid && sent<64 && cycles%3!=0) begin s_valid=1; s_data=samples[sent]; end
        end
        @(negedge clk); s_valid=0; m_ready=1;
        repeat(6) @(posedge clk);
        if(m_valid) $fatal(1,"extra chain output");
        $display("PASS roundtrip samples=%0d stalls=%0d",received,stalls); $finish;
    end
    always @(posedge clk) begin
        cycles=cycles+1;
        if(cycles>10000) $fatal(1,"roundtrip timeout");
        if(!rst) begin
            taken=s_valid && s_ready;
            if(taken) sent=sent+1;
            if(stalled && (!m_valid || {m_data,m_last,m_error} !== held)) $fatal(1,"chain stall stability");
            stalled=m_valid && !m_ready;
            held={m_data,m_last,m_error};
            if(stalled) stalls=stalls+1;
            if(m_valid && m_ready) begin
                if(received>=64 || m_data !== {{2{samples[received][15]}},samples[received]} || m_error || m_last !== (received%16==15))
                    $fatal(1,"chain reconstruction index=%0d",received);
                received=received+1;
            end
        end
    end
endmodule
