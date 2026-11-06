// SPDX-License-Identifier: Apache-2.0
`timescale 1ns/1ps
module tb_two_token_attention;
    reg clk=0;always #5 clk=~clk;
    reg rst=1,q_valid=0,m_ready=0;wire q_ready,m_valid,m_channel,m_last,config_fault;
    reg [7:0] q_data=0,q_tag=0;wire signed [7:0] m_data;wire [7:0] m_tag;wire [2:0] m_error;
    two_token_attention dut(.*);
    integer i,j,k,expected;
    initial begin
        repeat(3)@(negedge clk);rst=0;
        for(i=0;i<3;i=i+1)begin
            @(negedge clk);q_data=i==0?0:i==1?128:255;q_tag=i+1;q_valid=1;
            do @(posedge clk);while(!q_ready);
            @(negedge clk);q_valid=0;
            for(j=0;j<2;j=j+1)begin
                wait(m_valid);expected=i==0?-62:i==1?0:62;if(j)expected=-expected;
                for(k=0;k<4;k=k+1)begin
                    if(m_data!==8'(expected)||m_channel!==1'(j)||m_last!==(j==1)||m_tag!=i+1||m_error!=0||q_ready||config_fault)$fatal(1,"example i=%0d j=%0d",i,j);
                    @(negedge clk);
                end
                m_ready=1;@(negedge clk);m_ready=0;
            end
        end
        $display("PASS two_token_attention queries=3 outputs=6");$finish;
    end
    initial begin repeat(20000)@(posedge clk);$fatal(1,"watchdog");end
endmodule
