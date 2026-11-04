// SPDX-License-Identifier: Apache-2.0
`timescale 1ns/1ps
module tb_cdf53_block;
    parameter SAMPLE_W=8, BLOCK_LEN=5, INVERSE=0, BLOCKS=10;
    localparam CW=SAMPLE_W+2, TOTAL=BLOCK_LEN*BLOCKS;
    reg clk=0; always #5 clk=~clk;
    reg rst=1, s_valid=0, m_ready=0;
    wire s_ready, m_valid, m_last, m_error;
    reg signed [CW-1:0] s_data=0;
    wire signed [CW-1:0] m_data;
    reg [CW-1:0] input_vec [0:TOTAL-1], expected [0:TOTAL-1];
    reg expected_error [0:TOTAL-1];
    integer sent=0, received=0, cycles=0, stalls=0;
    reg checking=0, was_stalled=0, input_taken=0;
    reg [CW+1:0] held;
    cdf53_block #(.SAMPLE_W(SAMPLE_W),.BLOCK_LEN(BLOCK_LEN),.INVERSE(INVERSE)) dut(.*);

    task reset_core;
        begin
            @(negedge clk); rst=1; s_valid=0; m_ready=0;
            repeat(2) @(negedge clk);
            rst=0;
        end
    endtask
    task send_zero;
        integer done;
        begin
            @(negedge clk); s_valid=1; s_data=0;
            done=0;
            while(!done) begin @(posedge clk); if(s_ready) done=1; end
            @(negedge clk); s_valid=0;
        end
    endtask
    integer k;
    initial begin
        $readmemh("input.mem",input_vec);
        $readmemh("expected.mem",expected);
        $readmemh("error.mem",expected_error);
        reset_core();
        // Cancel a partial load, then a complete block in calculation.
        for(k=0;k<BLOCK_LEN-1;k=k+1) send_zero();
        reset_core();
        for(k=0;k<BLOCK_LEN;k=k+1) send_zero();
        reset_core();
        // Reset a pending stalled result; it must never leak afterward.
        for(k=0;k<BLOCK_LEN;k=k+1) send_zero();
        wait(m_valid);
        repeat(3) @(posedge clk);
        reset_core();
        checking=1;
        while(received<TOTAL) begin
            @(negedge clk);
            m_ready=(cycles%7!=1 && cycles%7!=2 && cycles%7!=3);
            if(input_taken) s_valid=0;
            if(sent<TOTAL && !s_valid) begin
                s_valid=(cycles%5!=2);
                if(s_valid) s_data=input_vec[sent];
            end
        end
        @(negedge clk); s_valid=0; m_ready=1;
        repeat(8) @(posedge clk);
        if(m_valid) $fatal(1,"extra output");
        $display("PASS samples=%0d stalls=%0d reset_load_calc_output=1",received,stalls);
        $finish;
    end
    always @(posedge clk) begin
        cycles=cycles+1;
        if(cycles>200000) $fatal(1,"timeout");
        if(checking && !rst) begin
            input_taken=s_valid && s_ready;
            if(was_stalled && (!m_valid || {m_data,m_last,m_error} !== held))
                $fatal(1,"output changed under backpressure");
            was_stalled=m_valid && !m_ready;
            held={m_data,m_last,m_error};
            if(was_stalled) stalls=stalls+1;
            if(s_valid && s_ready) sent=sent+1;
            if(m_valid && m_ready) begin
                if(received>=TOTAL) $fatal(1,"unexpected output");
                if(m_data !== expected[received] || m_last !== (received%BLOCK_LEN==BLOCK_LEN-1) || m_error !== expected_error[received])
                    $fatal(1,"index=%0d got=%0d last=%b error=%b expected=%0d error=%b",received,$signed(m_data),m_last,m_error,$signed(expected[received]),expected_error[received]);
                received=received+1;
            end
        end else begin was_stalled=0; input_taken=0; end
    end
endmodule
