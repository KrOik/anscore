`timescale 1ns/1ps
module tb_img_geo_inverse_map_divider_equiv;
    reg clk = 0;
    always #5 clk = ~clk;
    reg rst_n = 0;
    reg s_valid = 0;
    wire s_ready_old, s_ready_new;
    reg [15:0] s_x = 0, s_y = 0;
    reg s_sof = 0, s_eol = 0, s_eof = 0;
    reg [3:0] s_mode = 0;
    reg [15:0] s_src_width = 4, s_src_height = 3;
    reg [15:0] s_dst_width = 4, s_dst_height = 3;
    reg signed [31:0] s_h00 = 0, s_h01 = 0, s_h02 = 0;
    reg signed [31:0] s_h10 = 0, s_h11 = 0, s_h12 = 0;
    reg signed [31:0] s_h20 = 0, s_h21 = 0, s_h22 = 0;
    reg m_ready = 0;
    wire valid_old, valid_new;
    wire [23:0] x_old, y_old, x_new, y_new;
    wire border_old, border_new;
    wire [3:0] error_old, error_new;
    wire sof_old, eol_old, eof_old, sof_new, eol_new, eof_new;

    integer cycle_no = 0;
    integer enabled_cycles = 0;
    wire clk_en = (cycle_no % 13 != 4) && (cycle_no % 13 != 5) &&
                  (cycle_no % 17 != 9);
    always @(posedge clk) begin
        cycle_no <= cycle_no + 1;
        if (clk_en)
            enabled_cycles <= enabled_cycles + 1;
    end

`define MAP_COMMON \
    .clk(clk), .rst_n(rst_n), .clk_en(clk_en), .s_valid(s_valid), \
    .s_x(s_x), .s_y(s_y), .s_sof(s_sof), .s_eol(s_eol), .s_eof(s_eof), \
    .s_mode(s_mode), .s_src_width(s_src_width), .s_src_height(s_src_height), \
    .s_dst_width(s_dst_width), .s_dst_height(s_dst_height), \
    .s_h00(s_h00), .s_h01(s_h01), .s_h02(s_h02), \
    .s_h10(s_h10), .s_h11(s_h11), .s_h12(s_h12), \
    .s_h20(s_h20), .s_h21(s_h21), .s_h22(s_h22), .m_ready(m_ready)

    img_geo_inverse_map_v89c_baseline old_core (
        `MAP_COMMON, .s_ready(s_ready_old), .m_valid(valid_old),
        .m_x_q8(x_old), .m_y_q8(y_old), .m_border(border_old),
        .m_error(error_old), .m_sof(sof_old), .m_eol(eol_old), .m_eof(eof_old)
    );
    img_geo_inverse_map new_core (
        `MAP_COMMON, .s_ready(s_ready_new), .m_valid(valid_new),
        .m_x_q8(x_new), .m_y_q8(y_new), .m_border(border_new),
        .m_error(error_new), .m_sof(sof_new), .m_eol(eol_new), .m_eof(eof_new)
    );
`undef MAP_COMMON

    task compare_outputs;
        begin
            if (!valid_old || !valid_new ||
                x_old !== x_new || y_old !== y_new ||
                border_old !== border_new || error_old !== error_new ||
                sof_old !== sof_new || eol_old !== eol_new || eof_old !== eof_new)
                $fatal(1, "old/new response mismatch mode=%0d old=(%06x,%06x,b%0d,e%0d,%0d%0d%0d) new=(%06x,%06x,b%0d,e%0d,%0d%0d%0d)",
                    s_mode, x_old, y_old, border_old, error_old, sof_old, eol_old, eof_old,
                    x_new, y_new, border_new, error_new, sof_new, eol_new, eof_new);
        end
    endtask

    task transact;
        input integer expected_old_latency;
        input integer expected_new_latency;
        integer watchdog;
        integer base_enabled;
        integer old_latency;
        integer new_latency;
        reg old_seen;
        reg [23:0] old_x_hold, old_y_hold;
        reg old_border_hold;
        reg [3:0] old_error_hold;
        reg old_sof_hold, old_eol_hold, old_eof_hold;
        begin
            @(negedge clk);
            s_valid = 1;
            watchdog = 0;
            begin : wait_accept
                forever begin
                    @(posedge clk);
                    watchdog = watchdog + 1;
                    if (clk_en && s_ready_old && s_ready_new) disable wait_accept;
                    if (watchdog > 20) $fatal(1, "input handshake timeout mode=%0d old_ready=%b new_ready=%b clk_en=%b rst_n=%b old_state=%0d new_state=%0d valid=%b/%b ready=%b", s_mode,s_ready_old,s_ready_new,clk_en,rst_n,old_core.state,new_core.state,valid_old,valid_new,m_ready);
                end
            end
            @(negedge clk);
            s_valid = 0;
            base_enabled = enabled_cycles;
            old_latency = -1;
            new_latency = -1;
            old_seen = 0;
            watchdog = 0;
            begin : wait_responses
                while (!(valid_old && valid_new)) begin
                    if (valid_old && !old_seen) begin
                        old_seen = 1;
                        old_latency = enabled_cycles - base_enabled;
                        old_x_hold = x_old; old_y_hold = y_old;
                        old_border_hold = border_old; old_error_hold = error_old;
                        old_sof_hold = sof_old; old_eol_hold = eol_old; old_eof_hold = eof_old;
                    end
                    if (old_seen &&
                        (!valid_old || x_old !== old_x_hold || y_old !== old_y_hold ||
                         border_old !== old_border_hold || error_old !== old_error_hold ||
                         sof_old !== old_sof_hold || eol_old !== old_eol_hold || eof_old !== old_eof_hold))
                        $fatal(1, "old response changed while m_ready=0");
                    @(negedge clk);
                    watchdog = watchdog + 1;
                    if (watchdog > 2000) $fatal(1, "response timeout mode=%0d", s_mode);
                end
            end
            if (old_latency < 0) old_latency = enabled_cycles - base_enabled;
            new_latency = enabled_cycles - base_enabled;
            compare_outputs();
            if (old_latency != expected_old_latency || new_latency != expected_new_latency)
                $fatal(1, "latency mismatch mode=%0d old=%0d expected=%0d new=%0d expected=%0d",
                    s_mode, old_latency, expected_old_latency, new_latency, expected_new_latency);
            repeat (3) begin
                @(negedge clk);
                compare_outputs();
            end
            m_ready = 1;
            begin : consume_response
                forever begin
                    @(posedge clk);
                    if (clk_en) disable consume_response;
                end
            end
            @(negedge clk);
            m_ready = 0;
        end
    endtask

    task reset_during_divide;
        integer enabled_seen;
        integer watchdog;
        begin
            @(negedge clk);
            s_valid = 1;
            watchdog = 0;
            begin : wait_reset_accept
                forever begin
                    @(posedge clk);
                    watchdog = watchdog + 1;
                    if (clk_en && s_ready_old && s_ready_new) disable wait_reset_accept;
                    if (watchdog > 20) $fatal(1, "reset-vector input handshake timeout");
                end
            end
            @(negedge clk);
            s_valid = 0;
            enabled_seen = 0;
            while (enabled_seen < 17) begin
                @(posedge clk);
                if (clk_en) enabled_seen = enabled_seen + 1;
            end
            @(negedge clk);
            rst_n = 0;
            repeat (2) @(negedge clk);
            if (valid_old || valid_new || s_ready_old || s_ready_new)
                $fatal(1, "reset failed to cancel old/new divider transaction");
            rst_n = 1;
            repeat (2) @(negedge clk);
        end
    endtask

    initial begin
        repeat (3) @(negedge clk);
        rst_n = 1;

        // Asymmetric scale mapping and two independent division operands.
        s_mode=1; s_x=6; s_y=3; s_src_width=4; s_src_height=3;
        s_dst_width=7; s_dst_height=4; s_sof=1; s_eol=0; s_eof=0;
        transact(116,238);

        s_x=1; s_y=1; s_sof=0; s_eol=1; s_eof=0;
        transact(116,238);

        // Q16.16 identity homography, then fractional and signed quotients.
        s_mode=8; s_x=2; s_y=1; s_src_width=4; s_src_height=3;
        s_dst_width=4; s_dst_height=3; s_h00=65536; s_h01=0; s_h02=0;
        s_h10=0; s_h11=65536; s_h12=0; s_h20=0; s_h21=0; s_h22=65536;
        s_sof=0; s_eol=0; s_eof=1;
        transact(116,238);

        s_h00=32768; s_h11=32768; s_h22=65536; s_eof=0;
        transact(116,238);

        s_h00=-32768; s_h11=65536; s_h22=65536;
        transact(116,238);

        s_h00=-65536; s_h11=-65536; s_h22=-65536;
        transact(116,238);

        // Error and no-divider response contracts retain their old cadence.
        s_h22=0; s_h00=65536; s_h11=65536;
        transact(0,0);
        s_mode=7; s_h22=65536; s_h00=65536; s_h11=65536;
        transact(0,0);
        s_mode=9;
        transact(0,0);
        s_mode=0; s_dst_width=5;
        transact(0,0);

        // An asynchronous reset aborts in-flight division; the next command
        // after release must still match the frozen v89c transaction result.
        s_mode=1; s_dst_width=7; s_dst_height=4; s_src_width=4; s_src_height=3;
        s_x=3; s_y=2; s_sof=1; s_eol=1; s_eof=1;
        reset_during_divide();
        transact(116,238);

        $display("GEO89E DIVIDER EQUIV PASS transactions=11 old_latency=116 new_latency=238 reset_abort=1 ce_pause=1 output_hold=1");
        $finish;
    end

    initial begin
        #5000000;
        $fatal(1, "divider equivalence watchdog");
    end
endmodule
