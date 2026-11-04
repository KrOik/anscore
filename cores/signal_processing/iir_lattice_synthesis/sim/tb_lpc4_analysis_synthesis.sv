// SPDX-License-Identifier: Apache-2.0
`timescale 1ns/1ps
module tb_lpc4_analysis_synthesis;
    reg clk=0;always #5 clk=~clk;
    reg rst=1,correlation_valid=0,excitation_valid=0,excitation_last=0,sample_ready=0;
    reg signed [15:0] correlation=0,excitation=0;
    reg [7:0] excitation_tag=0;
    wire correlation_ready,configuration_done,configuration_error,configured,model_rejected,excitation_ready;
    wire [1:0] model_error;
    wire sample_valid,sample_last,sample_clipped;
    wire signed [23:0] sample;
    wire [7:0] sample_tag;
    integer cycles=0,outputs=0,rejections=0,configurations=0;
    lpc4_analysis_synthesis dut(.*);
    always @(posedge clk) begin
        cycles=cycles+1;if(cycles>10000)$fatal(1,"integration timeout");
        if(!rst) begin
            if(configuration_done) begin configurations=configurations+1;if(configuration_error)$fatal(1,"unexpected config error");end
            if(model_rejected) begin rejections=rejections+1;if(model_error!=1)$fatal(1,"unexpected model error");end
        end
    end
    task put_r(input integer value);
        begin
            @(negedge clk);correlation_valid=1;correlation=value;
            @(posedge clk);while(!correlation_ready)@(posedge clk);
            @(negedge clk);correlation_valid=0;
        end
    endtask
    task excitation_and_result(input integer value,expected);
        begin
            @(negedge clk);excitation_valid=1;excitation=value;excitation_last=outputs==7;excitation_tag=outputs;
            @(posedge clk);while(!excitation_ready)@(posedge clk);
            @(negedge clk);excitation_valid=0;
            wait(sample_valid);
            repeat(3) begin
                @(negedge clk);
                if(!sample_valid || sample!==expected || sample_clipped || sample_last!==(outputs==7) || sample_tag!==8'(outputs))
                    $fatal(1,"integration output=%0d got=%0d expected=%0d",outputs,sample,expected);
            end
            sample_ready=1;@(posedge clk);@(negedge clk);sample_ready=0;outputs=outputs+1;
        end
    endtask
    initial begin
        repeat(3)@(negedge clk);rst=0;
        put_r(16);put_r(8);put_r(4);put_r(2);put_r(1);
        wait(configured);if(!configuration_done)$fatal(1,"model completion missing");
        excitation_and_result(16,16);excitation_and_result(0,8);
        excitation_and_result(0,4);excitation_and_result(0,2);
        // A rejected r0=0 model must preserve the existing AR(1) history.
        put_r(0);put_r(0);put_r(0);put_r(0);put_r(0);
        wait(rejections==1);
        excitation_and_result(0,1);excitation_and_result(0,0);
        excitation_and_result(0,0);excitation_and_result(0,0);
        if(configurations!=1)$fatal(1,"bad model partially reconfigured filter");
        $display("PASS LPC analysis/synthesis outputs=%0d valid_models=%0d rejected_models=%0d",outputs,configurations,rejections);$finish;
    end
endmodule
