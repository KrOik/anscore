`timescale 1ns/1ps
module tb_img_hist_accumulator_bram;
    localparam integer W=4, H=2, N=W*H;
    reg clk=0;
    always #5 clk=~clk;
    reg rst_n=0, clk_en=1;
    reg start_valid=0;
    wire start_ready;
    reg [15:0] start_tag=0;
    reg s_valid=0;
    wire s_ready;
    reg [7:0] s_gray=0;
    reg s_sof=0, s_eol=0;
    wire done_valid;
    reg done_ready=0;
    wire done_error;
    wire [7:0] done_error_code;
    wire [3:0] done_count;
    wire [15:0] done_tag;
    reg rd_req_valid=0;
    wire rd_req_ready;
    reg [7:0] rd_req_bin=0;
    wire rd_rsp_valid;
    reg rd_rsp_ready=0;
    wire [7:0] rd_rsp_bin;
    wire [3:0] rd_rsp_count;
    wire [15:0] rd_rsp_tag;
    wire rd_rsp_error, busy;

    img_hist_accumulator #(.FRAME_WIDTH(W), .FRAME_HEIGHT(H),
        .COUNT_WIDTH(4), .TAG_WIDTH(16)) dut (.*);

    reg done_hold=0, rsp_hold=0;
    reg [39:0] previous_done;
    reg [28:0] previous_rsp;
    integer cycles=0;
    always @(posedge clk) begin
        cycles <= cycles+1;
        if (cycles>20000) $fatal(1,"accumulator timeout");
        if (!rst_n) begin
            done_hold <= 0;
            rsp_hold <= 0;
        end else begin
            if (done_hold && (!done_valid ||
                {done_error,done_error_code,done_count,done_tag} !== previous_done))
                $fatal(1,"done changed under CE/backpressure");
            if (rsp_hold && (!rd_rsp_valid ||
                {rd_rsp_bin,rd_rsp_count,rd_rsp_tag,rd_rsp_error} !== previous_rsp))
                $fatal(1,"read response changed under CE/backpressure");
            done_hold <= done_valid && (!done_ready || !clk_en);
            rsp_hold <= rd_rsp_valid && (!rd_rsp_ready || !clk_en);
            previous_done <= {done_error,done_error_code,done_count,done_tag};
            previous_rsp <= {rd_rsp_bin,rd_rsp_count,rd_rsp_tag,rd_rsp_error};
            if (!clk_en && (start_ready || s_ready || rd_req_ready))
                $fatal(1,"ready asserted while clk_en=0");
        end
    end

    task automatic begin_frame(input [15:0] tag_value);
        begin
            @(negedge clk); start_valid=1; start_tag=tag_value;
            do @(posedge clk); while (!(clk_en && start_ready));
            @(negedge clk); start_valid=0;
        end
    endtask

    task automatic send_pixel(input [7:0] value, input sof_value,
                              input eol_value, input pause_first);
        begin
            @(negedge clk);
            s_valid=1; s_gray=value; s_sof=sof_value; s_eol=eol_value;
            if (pause_first) begin
                clk_en=0;
                repeat(2) @(negedge clk);
                if (s_ready) $fatal(1,"s_ready during CE pause");
                clk_en=1;
            end
            do @(posedge clk); while (!(clk_en && s_ready));
            @(negedge clk); s_valid=0;
        end
    endtask

    task automatic send_frame(input [15:0] tag_value, input integer mode);
        integer i;
        reg [7:0] value;
        begin
            begin_frame(tag_value);
            for (i=0;i<N;i=i+1) begin
                if (mode==0) value=(i<5) ? 8'd42 : 8'd7;
                else if (mode==1) value=8'd42;
                else value=8'd13;
                send_pixel(value, (i==0 && mode!=2), (i%W==W-1), i==2);
            end
        end
    endtask

    task automatic expect_done(input [15:0] tag_value,
                               input error_value, input [7:0] code_value,
                               input [3:0] count_value);
        begin
            do @(posedge clk); while (!done_valid);
            if ({done_error,done_error_code,done_count,done_tag} !==
                {error_value,code_value,count_value,tag_value})
                $fatal(1,"done mismatch got=%b want=%b",
                    {done_error,done_error_code,done_count,done_tag},
                    {error_value,code_value,count_value,tag_value});
            repeat(3) @(posedge clk);
            if (!done_valid) $fatal(1,"done did not hold under backpressure");
            @(negedge clk); done_ready=1;
            do @(posedge clk); while (!(clk_en && done_valid && done_ready));
            @(negedge clk); done_ready=0;
        end
    endtask

    task automatic read_expect(input [7:0] bin_value,
                               input [3:0] count_value, input error_value,
                               input [15:0] tag_value);
        begin
            @(negedge clk); rd_req_valid=1; rd_req_bin=bin_value;
            do @(posedge clk); while (!(clk_en && rd_req_ready));
            @(negedge clk); rd_req_valid=0;
            do @(posedge clk); while (!rd_rsp_valid);
            if ({rd_rsp_bin,rd_rsp_count,rd_rsp_tag,rd_rsp_error} !==
                {bin_value,count_value,tag_value,error_value})
                $fatal(1,"readback bin=%0d got=%h/%0d/%h/%b expected=%h/%0d/%h/%b",
                    bin_value,rd_rsp_bin,rd_rsp_count,rd_rsp_tag,rd_rsp_error,
                    bin_value,count_value,tag_value,error_value);
            repeat(3) @(posedge clk);
            if (!rd_rsp_valid) $fatal(1,"read response did not hold under backpressure");
            @(negedge clk); rd_rsp_ready=1;
            do @(posedge clk); while (!(clk_en && rd_rsp_valid && rd_rsp_ready));
            @(negedge clk); rd_rsp_ready=0;
        end
    endtask

    initial begin
        repeat(4) @(negedge clk); rst_n=1;

        // Repeated-bin accumulation and backpressured completion/readback.
        send_frame(16'h1001,0);
        expect_done(16'h1001,0,0,4'd8);
        read_expect(8'd42,4'd5,0,16'h1001);
        read_expect(8'd7,4'd3,0,16'h1001);

        // A new frame clears every bin: the old bin 7 must now read as zero.
        send_frame(16'h1002,1);
        expect_done(16'h1002,0,0,4'd8);
        read_expect(8'd42,4'd8,0,16'h1002);
        read_expect(8'd7,4'd0,0,16'h1002);

        // Bad SOF is explicit, poisons histogram validity, and readback errors.
        send_frame(16'h1003,2);
        expect_done(16'h1003,1,8'h02,4'd8);
        read_expect(8'd13,4'd0,1,16'h1003);

        $display("PASS tb_img_hist_accumulator_bram cycles=%0d",cycles);
        $finish;
    end
endmodule
