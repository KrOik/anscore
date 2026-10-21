`timescale 1ns/1ps
// Group integration smoke: one captured frame -> internal statistics/LUTs ->
// internally replayed output. Python owns the independent numerical model.
module tb_histogram_group;
    parameter integer FRAME_WIDTH=12, FRAME_HEIGHT=8;
    parameter integer TILE_WIDTH=4, TILE_HEIGHT=4;
    parameter integer ADAPTIVE=1, FRAME_COUNT=7, FRACTION_BITS=8;
    localparam integer PIXELS=FRAME_WIDTH*FRAME_HEIGHT;
    reg clk=0;
    always #5 clk=~clk;
    reg rst_n=0, clk_en=1;
    reg start_valid=0, s_valid=0, m_ready=0, done_ready=0;
    reg [15:0] start_tag=0, start_clip_limit=0;
    reg [7:0] s_gray=0;
    reg s_sof=0, s_eol=0;
    wire start_ready, s_ready, m_valid, m_sof, m_eol, m_last, m_error;
    wire [7:0] m_gray, done_error_code;
    wire [15:0] m_tag, done_count, done_tag;
    wire done_valid, done_error, busy;
    reg [7:0] samples [0:PIXELS*FRAME_COUNT-1];
    // bits 15:0 clip, bits 17:16 framing mode, bit 18 invalid config.
    reg [31:0] configs [0:FRAME_COUNT-1];
    // SystemVerilog strings avoid silently truncating long Windows paths.
    string input_path, config_path;
    integer frame_number=-1, i, f, cycles=0;
    reg [31:0] prng=32'h5EA1D00D;
    reg [29:0] previous_output;
    reg [40:0] previous_done;
    reg output_hold=0, done_hold=0;

    generate if (ADAPTIVE) begin: adaptive_dut
        img_hist_clahe_frame #(.FRAME_WIDTH(FRAME_WIDTH),
            .FRAME_HEIGHT(FRAME_HEIGHT), .TILE_WIDTH(TILE_WIDTH),
            .TILE_HEIGHT(TILE_HEIGHT), .FRACTION_BITS(FRACTION_BITS),
            .COUNT_WIDTH(16), .TAG_WIDTH(16)) dut (.*);
    end else begin: global_dut
        img_hist_he_frame #(.FRAME_WIDTH(FRAME_WIDTH),
            .FRAME_HEIGHT(FRAME_HEIGHT), .COUNT_WIDTH(16), .TAG_WIDTH(16)) dut (.*);
    end endgenerate

    // Deterministic CE pauses and output backpressure exercise every phase.
    always @(negedge clk) begin
        if (rst_n) begin
            prng <= {prng[30:0],prng[31]^prng[21]^prng[1]^prng[0]};
            clk_en <= prng[0] || prng[3];
            m_ready <= prng[4] || prng[7];
        end
    end

    always @(posedge clk) begin
        cycles <= cycles+1;
        if (cycles>2000000) $fatal(1,"group timeout frame=%0d",frame_number);
        if (!rst_n) begin
            output_hold <= 0; done_hold <= 0;
        end else begin
            if (!clk_en && (start_ready || s_ready))
                $fatal(1,"ready asserted while CE=0");
            if (output_hold && (!m_valid ||
                {m_gray,m_sof,m_eol,m_last,m_tag,m_error} !== previous_output))
                $fatal(1,"output changed under backpressure / CE pause");
            if (done_hold && (!done_valid ||
                {done_error,done_error_code,done_count,done_tag} !== previous_done))
                $fatal(1,"completion changed under backpressure / CE pause");
            output_hold <= m_valid && (!m_ready || !clk_en);
            previous_output <= {m_gray,m_sof,m_eol,m_last,m_tag,m_error};
            done_hold <= done_valid && (!done_ready || !clk_en);
            previous_done <= {done_error,done_error_code,done_count,done_tag};
            if (clk_en && m_valid && m_ready)
                $display("O %0d %0d %0d %0d %0d %0d %0d", frame_number,
                    m_gray,m_sof,m_eol,m_last,m_tag,m_error);
            if (clk_en && done_valid && done_ready)
                $display("D %0d %0d %0d %0d %0d", frame_number,
                    done_error,done_error_code,done_count,done_tag);
        end
    end

    task automatic command(input [15:0] tag_value,input [15:0] clip_value);
        begin
            @(negedge clk);
            start_valid=1; start_tag=tag_value; start_clip_limit=clip_value;
            do @(posedge clk); while (!(clk_en && start_ready));
            @(negedge clk);
            start_valid=0;
            // Poison live config after acceptance: the complete operation
            // must use its latched command, including during output stalls.
            start_tag=16'hDEAD; start_clip_limit=16'hFFFF;
        end
    endtask

    task automatic pixel(input [7:0] value,input sof_value,input eol_value);
        begin
            @(negedge clk);
            s_valid=1; s_gray=value; s_sof=sof_value; s_eol=eol_value;
            do @(posedge clk); while (!(clk_en && s_ready));
            @(negedge clk); s_valid=0;
        end
    endtask

    initial begin
        if (!$value$plusargs("INPUT=%s",input_path) ||
            !$value$plusargs("CONFIG=%s",config_path))
            $fatal(1,"INPUT/CONFIG files are required");
        $readmemh(input_path,samples);
        $readmemh(config_path,configs);
        repeat(4) @(negedge clk);
        rst_n=1;

        // Cancel a partially captured frame by reset, then immediately use a
        // different tag. RAM is not reset: a stale transaction must not escape.
        command(16'hFFFE,16'd2);
        for(i=0;i<3;i=i+1) pixel(i[7:0],i==0,i%FRAME_WIDTH==FRAME_WIDTH-1);
        @(negedge clk); rst_n=0; clk_en=0;
        repeat(3) @(negedge clk);
        rst_n=1;

        for(f=0;f<FRAME_COUNT;f=f+1) begin
            frame_number=f;
            command(16'h0100+f,configs[f][15:0]);
            if (!configs[f][18]) begin
                for(i=0;i<PIXELS;i=i+1) begin
                    pixel(samples[f*PIXELS+i],
                        (i==0) && configs[f][17:16]!=1,
                        (i%FRAME_WIDTH==FRAME_WIDTH-1) ^
                            (configs[f][17:16]==2 && i==FRAME_WIDTH-1));
                    if(i%7==3) repeat(2) @(negedge clk);
                end
            end
            do @(posedge clk); while (!done_valid);
            repeat(11) @(posedge clk);
            @(negedge clk); done_ready=1;
            do @(posedge clk); while (!(clk_en && done_valid));
            @(negedge clk); done_ready=0;
        end
        repeat(10) @(posedge clk);
        $display("TB_COMPLETE frames=%0d cycles=%0d",FRAME_COUNT,cycles);
        $finish;
    end
endmodule
