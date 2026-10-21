`timescale 1ns/1ps

module tb_img_filter_standalone_generated;
    localparam PIXEL_W = 8;
    reg clk = 1'b0;
    reg rst_n = 1'b0;
    reg clk_en;
    reg m_ready;
    reg [9*PIXEL_W-1:0] s_taps = {9*PIXEL_W{1'b1}};
    reg [PIXEL_W-1:0] cfg_threshold = {PIXEL_W{1'b1}};
    reg cfg_invert = 1'b0;
    reg s_valid = 1'b0;
    reg s_sof = 1'b0;
    reg s_eol = 1'b0;

    wire [PIXEL_W-1:0] mean_data, gaussian_data, median_data;
    wire [PIXEL_W-1:0] sobel_data, prewitt_data, threshold_data;
    wire [PIXEL_W-1:0] erode_all_data, dilate_all_data;
    wire [PIXEL_W-1:0] erode_asym_data, dilate_asym_data;
    wire signed [PIXEL_W+3:0] sobel_gx, sobel_gy, prewitt_gx, prewitt_gy;
    wire [PIXEL_W+3:0] sobel_mag, prewitt_mag;

    wire mean_ready, gaussian_ready, median_ready, sobel_ready, prewitt_ready;
    wire threshold_ready, erode_all_ready, dilate_all_ready;
    wire erode_asym_ready, dilate_asym_ready;
    wire mean_valid, gaussian_valid, median_valid, sobel_valid, prewitt_valid;
    wire threshold_valid, erode_all_valid, dilate_all_valid;
    wire erode_asym_valid, dilate_asym_valid;
    wire mean_sof, mean_eol, gaussian_sof, gaussian_eol, median_sof, median_eol;
    wire sobel_sof, sobel_eol, prewitt_sof, prewitt_eol;
    wire threshold_sof, threshold_eol, erode_all_sof, erode_all_eol;
    wire dilate_all_sof, dilate_all_eol, erode_asym_sof, erode_asym_eol;
    wire dilate_asym_sof, dilate_asym_eol;

    integer cycle_count = 0;
    integer accepted_count = 0;
    integer produced_count = 0;
    integer ce_stall_cycles = 0;
    integer backpressure_stall_cycles = 0;
    integer input_fd, scan_count;
    integer file_done = 0;
    integer input_index = 0;
    integer threshold_i, invert_i, sof_i, eol_i;
    reg [7:0] t0, t1, t2, t3, t4, t5, t6, t7, t8;
    reg blocked_previous = 1'b0;
    reg [171:0] previous_payload;
    reg [1023:0] file_name;
    wire [171:0] output_payload = {
        mean_data, mean_sof, mean_eol,
        gaussian_data, gaussian_sof, gaussian_eol,
        median_data, median_sof, median_eol,
        sobel_data, sobel_gx, sobel_gy, sobel_mag, sobel_sof, sobel_eol,
        prewitt_data, prewitt_gx, prewitt_gy, prewitt_mag, prewitt_sof, prewitt_eol,
        threshold_data, threshold_sof, threshold_eol,
        erode_all_data, erode_all_sof, erode_all_eol,
        dilate_all_data, dilate_all_sof, dilate_all_eol,
        erode_asym_data, erode_asym_sof, erode_asym_eol,
        dilate_asym_data, dilate_asym_sof, dilate_asym_eol
    };

    always #5 clk = ~clk;

    // Periodic clock-enable pauses and downstream stalls exercise the native
    // CE-qualified ready/valid contract while keeping all DUTs in lockstep.
    always @* begin
        clk_en = !((cycle_count % 23 == 7) || (cycle_count % 23 == 8) ||
                   (cycle_count % 23 == 9));
        m_ready = !((cycle_count % 17 >= 5) && (cycle_count % 17 <= 9));
    end

    always @(posedge clk) begin
        if (!rst_n) begin
            cycle_count <= 0;
            blocked_previous <= 1'b0;
        end else begin
            cycle_count <= cycle_count + 1;
            if (!clk_en)
                ce_stall_cycles = ce_stall_cycles + 1;
            if (mean_valid && !m_ready)
                backpressure_stall_cycles = backpressure_stall_cycles + 1;

            if (mean_ready !== gaussian_ready || mean_ready !== median_ready ||
                mean_ready !== sobel_ready || mean_ready !== prewitt_ready ||
                mean_ready !== threshold_ready || mean_ready !== erode_all_ready ||
                mean_ready !== dilate_all_ready || mean_ready !== erode_asym_ready ||
                mean_ready !== dilate_asym_ready)
                $fatal(1, "input ready mismatch across modules");
            if (mean_valid !== gaussian_valid || mean_valid !== median_valid ||
                mean_valid !== sobel_valid || mean_valid !== prewitt_valid ||
                mean_valid !== threshold_valid || mean_valid !== erode_all_valid ||
                mean_valid !== dilate_all_valid || mean_valid !== erode_asym_valid ||
                mean_valid !== dilate_asym_valid)
                $fatal(1, "output valid mismatch across modules");

            if (blocked_previous && (!mean_valid || output_payload !== previous_payload))
                $fatal(1, "payload changed while output was stalled");
            blocked_previous <= mean_valid && (!m_ready || !clk_en);
            previous_payload <= output_payload;

            if (clk_en && mean_valid && m_ready) begin
                if (mean_sof !== gaussian_sof || mean_sof !== median_sof ||
                    mean_sof !== sobel_sof || mean_sof !== prewitt_sof ||
                    mean_sof !== threshold_sof || mean_sof !== erode_all_sof ||
                    mean_sof !== dilate_all_sof || mean_sof !== erode_asym_sof ||
                    mean_sof !== dilate_asym_sof ||
                    mean_eol !== gaussian_eol || mean_eol !== median_eol ||
                    mean_eol !== sobel_eol || mean_eol !== prewitt_eol ||
                    mean_eol !== threshold_eol || mean_eol !== erode_all_eol ||
                    mean_eol !== dilate_all_eol || mean_eol !== erode_asym_eol ||
                    mean_eol !== dilate_asym_eol)
                    $fatal(1, "frame marker mismatch across modules");
                $display("OUT %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d",
                    produced_count, mean_sof, mean_eol,
                    mean_data, gaussian_data, median_data,
                    sobel_data, $signed(sobel_gx), $signed(sobel_gy), sobel_mag,
                    prewitt_data, $signed(prewitt_gx), $signed(prewitt_gy), prewitt_mag,
                    threshold_data, erode_all_data, dilate_all_data,
                    erode_asym_data, dilate_asym_data);
                produced_count = produced_count + 1;
            end
        end
    end

    img_filter_mean3x3 #(.PIXEL_W(PIXEL_W)) mean_dut (
        .clk(clk), .rst_n(rst_n), .clk_en(clk_en), .s_taps(s_taps),
        .s_valid(s_valid), .s_sof(s_sof), .s_eol(s_eol), .s_ready(mean_ready),
        .m_data(mean_data), .m_valid(mean_valid), .m_sof(mean_sof), .m_eol(mean_eol), .m_ready(m_ready)
    );
    img_filter_gaussian3x3 #(.PIXEL_W(PIXEL_W)) gaussian_dut (
        .clk(clk), .rst_n(rst_n), .clk_en(clk_en), .s_taps(s_taps),
        .s_valid(s_valid), .s_sof(s_sof), .s_eol(s_eol), .s_ready(gaussian_ready),
        .m_data(gaussian_data), .m_valid(gaussian_valid), .m_sof(gaussian_sof), .m_eol(gaussian_eol), .m_ready(m_ready)
    );
    img_filter_median3x3 #(.PIXEL_W(PIXEL_W)) median_dut (
        .clk(clk), .rst_n(rst_n), .clk_en(clk_en), .s_taps(s_taps),
        .s_valid(s_valid), .s_sof(s_sof), .s_eol(s_eol), .s_ready(median_ready),
        .m_data(median_data), .m_valid(median_valid), .m_sof(median_sof), .m_eol(median_eol), .m_ready(m_ready)
    );
    img_edge_sobel3x3 #(.PIXEL_W(PIXEL_W), .MAG_SHIFT(0)) sobel_dut (
        .clk(clk), .rst_n(rst_n), .clk_en(clk_en), .s_taps(s_taps),
        .s_valid(s_valid), .s_sof(s_sof), .s_eol(s_eol), .s_ready(sobel_ready),
        .m_data(sobel_data), .m_gx(sobel_gx), .m_gy(sobel_gy), .m_magnitude(sobel_mag),
        .m_valid(sobel_valid), .m_sof(sobel_sof), .m_eol(sobel_eol), .m_ready(m_ready)
    );
    img_edge_prewitt3x3 #(.PIXEL_W(PIXEL_W), .MAG_SHIFT(2)) prewitt_dut (
        .clk(clk), .rst_n(rst_n), .clk_en(clk_en), .s_taps(s_taps),
        .s_valid(s_valid), .s_sof(s_sof), .s_eol(s_eol), .s_ready(prewitt_ready),
        .m_data(prewitt_data), .m_gx(prewitt_gx), .m_gy(prewitt_gy), .m_magnitude(prewitt_mag),
        .m_valid(prewitt_valid), .m_sof(prewitt_sof), .m_eol(prewitt_eol), .m_ready(m_ready)
    );
    img_filter_threshold #(.PIXEL_W(PIXEL_W)) threshold_dut (
        .clk(clk), .rst_n(rst_n), .clk_en(clk_en), .s_data(s_taps[4*PIXEL_W +: PIXEL_W]),
        .cfg_threshold(cfg_threshold), .cfg_invert(cfg_invert), .s_valid(s_valid),
        .s_sof(s_sof), .s_eol(s_eol), .s_ready(threshold_ready), .m_data(threshold_data),
        .m_valid(threshold_valid), .m_sof(threshold_sof), .m_eol(threshold_eol), .m_ready(m_ready)
    );
    img_morph_erode3x3 #(.PIXEL_W(PIXEL_W), .SE_MASK(9'h1ff)) erode_all_dut (
        .clk(clk), .rst_n(rst_n), .clk_en(clk_en), .s_taps(s_taps),
        .s_valid(s_valid), .s_sof(s_sof), .s_eol(s_eol), .s_ready(erode_all_ready),
        .m_data(erode_all_data), .m_valid(erode_all_valid), .m_sof(erode_all_sof), .m_eol(erode_all_eol), .m_ready(m_ready)
    );
    img_morph_dilate3x3 #(.PIXEL_W(PIXEL_W), .SE_MASK(9'h1ff)) dilate_all_dut (
        .clk(clk), .rst_n(rst_n), .clk_en(clk_en), .s_taps(s_taps),
        .s_valid(s_valid), .s_sof(s_sof), .s_eol(s_eol), .s_ready(dilate_all_ready),
        .m_data(dilate_all_data), .m_valid(dilate_all_valid), .m_sof(dilate_all_sof), .m_eol(dilate_all_eol), .m_ready(m_ready)
    );
    // Asymmetric SE_MASK verifies that dilation reflects the SE offsets.
    img_morph_erode3x3 #(.PIXEL_W(PIXEL_W), .SE_MASK(9'b000000011)) erode_asym_dut (
        .clk(clk), .rst_n(rst_n), .clk_en(clk_en), .s_taps(s_taps),
        .s_valid(s_valid), .s_sof(s_sof), .s_eol(s_eol), .s_ready(erode_asym_ready),
        .m_data(erode_asym_data), .m_valid(erode_asym_valid), .m_sof(erode_asym_sof), .m_eol(erode_asym_eol), .m_ready(m_ready)
    );
    img_morph_dilate3x3 #(.PIXEL_W(PIXEL_W), .SE_MASK(9'b000000011)) dilate_asym_dut (
        .clk(clk), .rst_n(rst_n), .clk_en(clk_en), .s_taps(s_taps),
        .s_valid(s_valid), .s_sof(s_sof), .s_eol(s_eol), .s_ready(dilate_asym_ready),
        .m_data(dilate_asym_data), .m_valid(dilate_asym_valid), .m_sof(dilate_asym_sof), .m_eol(dilate_asym_eol), .m_ready(m_ready)
    );

    initial begin
        input_fd = 0;
        file_name = {1024{1'b0}};
        if (!$value$plusargs("INFILE=%s", file_name))
            $fatal(1, "missing +INFILE=<path>");
        s_valid = 1'b0;
        #30 rst_n = 1'b1;
        input_fd = $fopen(file_name, "r");
        if (input_fd == 0)
            $fatal(1, "cannot open vector file");
        scan_count = $fscanf(input_fd,
            "%h %h %h %h %h %h %h %h %h %d %d %d %d",
            t0, t1, t2, t3, t4, t5, t6, t7, t8,
            threshold_i, invert_i, sof_i, eol_i);
        while (scan_count == 13) begin
            @(negedge clk);
            s_taps = {t8, t7, t6, t5, t4, t3, t2, t1, t0};
            cfg_threshold = threshold_i[PIXEL_W-1:0];
            cfg_invert = invert_i[0];
            s_sof = sof_i[0];
            s_eol = eol_i[0];
            s_valid = 1'b1;
            begin : wait_accept
                reg accepted;
                accepted = 1'b0;
                while (!accepted) begin
                    @(posedge clk);
                    if (mean_ready)
                        accepted = 1'b1;
                end
            end
            accepted_count = accepted_count + 1;
            input_index = input_index + 1;
            @(negedge clk);
            s_valid = 1'b0;
            scan_count = $fscanf(input_fd,
                "%h %h %h %h %h %h %h %h %h %d %d %d %d",
                t0, t1, t2, t3, t4, t5, t6, t7, t8,
                threshold_i, invert_i, sof_i, eol_i);
        end
        $fclose(input_fd);
        file_done = 1;
        while (produced_count < accepted_count)
            @(posedge clk);
        if (accepted_count != input_index)
            $fatal(1, "internal accepted counter mismatch");
        if (ce_stall_cycles == 0 || backpressure_stall_cycles == 0)
            $fatal(1, "test did not exercise both CE pauses and backpressure");
        @(negedge clk);
        $display("DONE %0d %0d %0d %0d", accepted_count, produced_count,
            ce_stall_cycles, backpressure_stall_cycles);
        $finish;
    end
endmodule
