`timescale 1ns/1ps

module tb_isp_ccm_gamma_reference;
    reg clk = 1'b0;
    reg rst_n = 1'b0;
    reg clk_en;
    reg m_ready;
    reg [7:0] r = 8'hff, g = 8'hff, b = 8'hff;
    reg s_valid = 1'b0, s_sof = 1'b0, s_eol = 1'b0;
    wire [23:0] s_data = {r, g, b};
    wire ccm_s_ready, ccm_m_valid, ccm_m_sof, ccm_m_eol;
    wire gamma_s_ready, gamma_raw_m_valid, gamma_raw_m_sof, gamma_raw_m_eol;
    wire [23:0] ccm_m_data, gamma_raw_m_data;
    wire gamma_m_valid, gamma_m_sof, gamma_m_eol;
    wire [23:0] gamma_m_data;
    wire gamma_a0_ready, gamma_a1_ready, gamma_a2_ready;
    reg gamma_a0_valid, gamma_a1_valid, gamma_a2_valid;
    reg [23:0] gamma_a0_data, gamma_a1_data, gamma_a2_data;
    reg gamma_a0_sof, gamma_a1_sof, gamma_a2_sof;
    reg gamma_a0_eol, gamma_a1_eol, gamma_a2_eol;
    wire ccm_s_valid = s_valid && gamma_s_ready;
    wire gamma_s_valid = s_valid && ccm_s_ready;
    reg ccm_cfg_we = 1'b0, ccm_cfg_commit = 1'b0;
    reg [3:0] ccm_cfg_index = 0;
    reg signed [15:0] ccm_cfg_value = 0;
    wire ccm_cfg_ready, ccm_cfg_pending, ccm_cfg_error;
    reg gamma_cfg_we = 1'b0, gamma_cfg_commit = 1'b0, gamma_cfg_enable = 1'b0;
    reg [1:0] gamma_cfg_channel = 0;
    reg [7:0] gamma_cfg_addr = 0, gamma_cfg_value = 0;
    wire gamma_cfg_ready, gamma_cfg_pending, gamma_cfg_error;
    wire [2:0] gamma_cfg_lut_complete;
    wire gamma_active_enable;
    reg [1023:0] infile_name;
    integer infile_fd, scan_count, input_stage, requested_stage;
    integer in_r, in_g, in_b, in_sof, in_eol;
    integer current_stage = -1;
    integer accepted_count = 0, produced_count = 0;
    integer cycle_count = 0, ce_stall_cycles = 0, backpressure_stall_cycles = 0;
    integer vector_index = 0, addr, channel;
    reg blocked_previous = 1'b0;
    reg [51:0] held_payload;
    wire [51:0] output_payload = {
        ccm_m_data, ccm_m_sof, ccm_m_eol,
        gamma_m_data, gamma_m_sof, gamma_m_eol
    };

    // The production CCM now takes four enabled edges. Gamma remains a
    // one-edge primitive; mirror the isolated board candidate's three-stage
    // elastic alignment here so both lanes are compared transaction-for-
    // transaction without changing Gamma's standalone latency.
    assign gamma_a2_ready = !gamma_a2_valid || m_ready;
    assign gamma_a1_ready = !gamma_a1_valid || gamma_a2_ready;
    assign gamma_a0_ready = !gamma_a0_valid || gamma_a1_ready;
    assign gamma_m_valid = gamma_a2_valid;
    assign gamma_m_data = gamma_a2_data;
    assign gamma_m_sof = gamma_a2_sof;
    assign gamma_m_eol = gamma_a2_eol;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            gamma_a0_valid <= 1'b0;
            gamma_a1_valid <= 1'b0;
            gamma_a2_valid <= 1'b0;
            gamma_a0_sof <= 1'b0;
            gamma_a1_sof <= 1'b0;
            gamma_a2_sof <= 1'b0;
            gamma_a0_eol <= 1'b0;
            gamma_a1_eol <= 1'b0;
            gamma_a2_eol <= 1'b0;
        end else if (clk_en) begin
            if (gamma_a2_ready) begin
                gamma_a2_valid <= gamma_a1_valid;
                if (gamma_a1_valid) begin
                    gamma_a2_data <= gamma_a1_data;
                    gamma_a2_sof <= gamma_a1_sof;
                    gamma_a2_eol <= gamma_a1_eol;
                end
            end
            if (gamma_a1_ready) begin
                gamma_a1_valid <= gamma_a0_valid;
                if (gamma_a0_valid) begin
                    gamma_a1_data <= gamma_a0_data;
                    gamma_a1_sof <= gamma_a0_sof;
                    gamma_a1_eol <= gamma_a0_eol;
                end
            end
            if (gamma_a0_ready) begin
                gamma_a0_valid <= gamma_raw_m_valid;
                if (gamma_raw_m_valid) begin
                    gamma_a0_data <= gamma_raw_m_data;
                    gamma_a0_sof <= gamma_raw_m_sof;
                    gamma_a0_eol <= gamma_raw_m_eol;
                end
            end
        end
    end

    always #5 clk = ~clk;
    always @* begin
        clk_en = !((cycle_count % 23 == 6) || (cycle_count % 23 == 7) ||
                   (cycle_count % 23 == 8));
        m_ready = !((cycle_count % 17 >= 4) && (cycle_count % 17 <= 9));
    end

    img_isp_ccm ccm_dut (
        .clk(clk), .rst_n(rst_n), .clk_en(clk_en), .s_data(s_data),
        .s_valid(ccm_s_valid), .s_ready(ccm_s_ready), .s_sof(s_sof), .s_eol(s_eol),
        .m_data(ccm_m_data), .m_valid(ccm_m_valid), .m_ready(m_ready),
        .m_sof(ccm_m_sof), .m_eol(ccm_m_eol),
        .cfg_we(ccm_cfg_we), .cfg_commit(ccm_cfg_commit), .cfg_index(ccm_cfg_index),
        .cfg_value(ccm_cfg_value), .cfg_ready(ccm_cfg_ready),
        .cfg_pending(ccm_cfg_pending), .cfg_error(ccm_cfg_error)
    );

    img_isp_gamma_lut gamma_dut (
        .clk(clk), .rst_n(rst_n), .clk_en(clk_en), .s_data(s_data),
        .s_valid(gamma_s_valid), .s_ready(gamma_s_ready), .s_sof(s_sof), .s_eol(s_eol),
        .m_data(gamma_raw_m_data), .m_valid(gamma_raw_m_valid), .m_ready(gamma_a0_ready),
        .m_sof(gamma_raw_m_sof), .m_eol(gamma_raw_m_eol),
        .cfg_we(gamma_cfg_we), .cfg_channel(gamma_cfg_channel),
        .cfg_addr(gamma_cfg_addr), .cfg_value(gamma_cfg_value),
        .cfg_commit(gamma_cfg_commit), .cfg_enable(gamma_cfg_enable),
        .cfg_ready(gamma_cfg_ready), .cfg_pending(gamma_cfg_pending),
        .cfg_error(gamma_cfg_error), .cfg_lut_complete(gamma_cfg_lut_complete),
        .active_enable(gamma_active_enable)
    );

    function signed [15:0] coeff;
        input integer matrix_id;
        input integer index;
        begin
            if (matrix_id == 1) begin
                case (index)
                    0: coeff = 512;   1: coeff = -256;  2: coeff = 128;
                    3: coeff = -512;  4: coeff = 256;   5: coeff = 512;
                    6: coeff = 1024;  7: coeff = 512;   8: coeff = -2048;
                    9: coeff = 3;    10: coeff = -5;   11: coeff = 12;
                    default: coeff = 0;
                endcase
            end else begin
                case (index)
                    0: coeff = 512;   1: coeff = 0;     2: coeff = 0;
                    3: coeff = -512;  4: coeff = 0;     5: coeff = 0;
                    6: coeff = 0;     7: coeff = 0;     8: coeff = 1024;
                    9: coeff = 0;    10: coeff = 0;   11: coeff = -1;
                    default: coeff = 0;
                endcase
            end
        end
    endfunction

    function [7:0] gamma_value;
        input integer lut_channel;
        input integer lut_address;
        begin
            case (lut_channel)
                0: gamma_value = (lut_address * 3 + 5) & 255;
                1: gamma_value = 255 - lut_address;
                default: gamma_value = lut_address ^ 8'ha5;
            endcase
        end
    endfunction

    task configure_matrix;
        input integer matrix_id;
        integer k;
        begin
            for (k = 0; k < 12; k = k + 1) begin
                @(negedge clk);
                ccm_cfg_we = 1'b1;
                ccm_cfg_index = k;
                ccm_cfg_value = coeff(matrix_id, k);
                begin : wait_matrix_write
                    reg accepted;
                    accepted = 1'b0;
                    while (!accepted) begin
                        @(posedge clk);
                        if (clk_en && ccm_cfg_ready) accepted = 1'b1;
                    end
                end
                @(negedge clk);
                ccm_cfg_we = 1'b0;
            end
            @(negedge clk);
            ccm_cfg_commit = 1'b1;
            begin : wait_matrix_commit
                reg accepted;
                accepted = 1'b0;
                while (!accepted) begin
                    @(posedge clk);
                    if (clk_en && ccm_cfg_ready) accepted = 1'b1;
                end
            end
            @(negedge clk);
            ccm_cfg_commit = 1'b0;
            if (!ccm_cfg_pending)
                $fatal(1, "CCM commit did not become pending");
        end
    endtask

    task configure_gamma;
        integer k, c;
        begin
            for (c = 0; c < 3; c = c + 1) begin
                for (k = 0; k < 256; k = k + 1) begin
                    @(negedge clk);
                    gamma_cfg_we = 1'b1;
                    gamma_cfg_channel = c;
                    gamma_cfg_addr = k;
                    gamma_cfg_value = gamma_value(c, k);
                    begin : wait_gamma_write
                        reg accepted;
                        accepted = 1'b0;
                        while (!accepted) begin
                            @(posedge clk);
                            if (clk_en && gamma_cfg_ready) accepted = 1'b1;
                        end
                    end
                    @(negedge clk);
                    gamma_cfg_we = 1'b0;
                end
            end
            if (gamma_cfg_lut_complete !== 3'b111)
                $fatal(1, "Gamma LUT bank did not complete: %b", gamma_cfg_lut_complete);
            @(negedge clk);
            gamma_cfg_enable = 1'b1;
            gamma_cfg_commit = 1'b1;
            begin : wait_gamma_commit
                reg accepted;
                accepted = 1'b0;
                while (!accepted) begin
                    @(posedge clk);
                    if (clk_en && gamma_cfg_ready) accepted = 1'b1;
                end
            end
            @(negedge clk);
            gamma_cfg_commit = 1'b0;
        end
    endtask

    task send_pixel;
        input [7:0] pixel_r, pixel_g, pixel_b;
        input marker_sof, marker_eol;
        begin
            @(negedge clk);
            r = pixel_r; g = pixel_g; b = pixel_b;
            s_sof = marker_sof; s_eol = marker_eol; s_valid = 1'b1;
            begin : wait_input_accept
                reg accepted;
                accepted = 1'b0;
                while (!accepted) begin
                    @(posedge clk);
                    if (clk_en && ccm_s_ready && gamma_s_ready) accepted = 1'b1;
                end
            end
            accepted_count = accepted_count + 1;
            vector_index = vector_index + 1;
            @(negedge clk);
            s_valid = 1'b0;
        end
    endtask

    always @(posedge clk) begin
        if (!rst_n) begin
            cycle_count <= 0;
            blocked_previous <= 1'b0;
        end else begin
            cycle_count <= cycle_count + 1;
            if (!clk_en) ce_stall_cycles = ce_stall_cycles + 1;
            if (ccm_m_valid && !m_ready) backpressure_stall_cycles = backpressure_stall_cycles + 1;
            if (ccm_s_ready !== gamma_s_ready)
                $fatal(1, "CCM and Gamma input-ready mismatch");
            if (ccm_m_valid !== gamma_m_valid)
                $fatal(1, "CCM and Gamma output-valid mismatch");
            if (blocked_previous && (!ccm_m_valid || output_payload !== held_payload))
                $fatal(1, "CCM/Gamma output changed under backpressure or CE pause");
            blocked_previous = ccm_m_valid && (!m_ready || !clk_en);
            held_payload = output_payload;
            if (clk_en && ccm_m_valid && m_ready) begin
                if (ccm_m_sof !== gamma_m_sof || ccm_m_eol !== gamma_m_eol)
                    $fatal(1, "CCM/Gamma frame marker mismatch");
                $display("OUT %0d %06x %06x %0d %0d %0d %0d", produced_count,
                    ccm_m_data, gamma_m_data, ccm_m_sof, ccm_m_eol, gamma_m_sof, gamma_m_eol);
                produced_count = produced_count + 1;
            end
        end
    end

    initial begin
        infile_name = {1024{1'b0}};
        if (!$value$plusargs("INFILE=%s", infile_name))
            $fatal(1, "missing +INFILE=<path>");
        repeat (3) @(negedge clk);
        rst_n = 1'b1;
        infile_fd = $fopen(infile_name, "r");
        if (infile_fd == 0) $fatal(1, "cannot open vector file");
        scan_count = $fscanf(infile_fd, "%d %h %h %h %d %d",
            input_stage, in_r, in_g, in_b, in_sof, in_eol);
        while (scan_count == 6) begin
            if (input_stage != current_stage) begin
                while (produced_count < accepted_count) @(posedge clk);
                if (input_stage == 1) begin
                    configure_matrix(1);
                    configure_gamma;
                end else if (input_stage == 2) begin
                    configure_matrix(2);
                end
                current_stage = input_stage;
            end
            send_pixel(in_r[7:0], in_g[7:0], in_b[7:0], in_sof[0], in_eol[0]);
            scan_count = $fscanf(infile_fd, "%d %h %h %h %d %d",
                input_stage, in_r, in_g, in_b, in_sof, in_eol);
        end
        $fclose(infile_fd);
        while (produced_count < accepted_count) @(posedge clk);
        if (accepted_count != vector_index || produced_count != vector_index)
            $fatal(1, "transaction count mismatch accepted=%0d produced=%0d vectors=%0d",
                accepted_count, produced_count, vector_index);
        if (ce_stall_cycles == 0 || backpressure_stall_cycles == 0)
            $fatal(1, "test failed to exercise both CE and output backpressure");
        if (ccm_cfg_error || gamma_cfg_error || ccm_cfg_pending || gamma_cfg_pending || !gamma_active_enable)
            $fatal(1, "unexpected final config state CCM=%b Gamma=%b active=%b",
                ccm_cfg_error, gamma_cfg_error, gamma_active_enable);
        @(negedge clk);
        $display("DONE %0d %0d %0d %0d", accepted_count, produced_count,
            ce_stall_cycles, backpressure_stall_cycles);
        $finish;
    end
endmodule
