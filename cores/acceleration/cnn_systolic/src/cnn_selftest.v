// CNN systolic array unit selftest aggregator for GW2A-18C bring-up.
// Each unit drives a deterministic stimulus, folds emitted bytes into an
// FNV-1a 32-bit digest, and compares against a golden constant captured
// from iverilog simulation of the identical RTL.
module cnn_selftest #(
    // Per-unit enable mask: a cleared bit elides that unit's DUT+stimulus
    // (its done bit is tied high, digest stays at the FNV seed 0x811c9dc5).
    // Lets the 16-unit harness be split into smaller placeable images.
    parameter [15:0] UNIT_EN = 16'hFFFF
) (
    input  wire        clk,
    input  wire        rst_n,
    output reg         all_done,
    output reg         all_pass,
    output reg         any_fail,
    input  wire [4:0]  digest_sel,
    output reg  [31:0] digest_q,
    output wire [15:0] done_mask,
    output wire [15:0] pass_mask
);

function [31:0] fnv;
    input [31:0] h;
    input [7:0]  b;
    reg [31:0] x;
    begin
        x = h ^ {24'd0, b};
        // FNV-1a prime 0x01000193 has bits {0,1,4,7,8,24}: shift-add form
        // avoids inferring a 32-bit multiplier (DSP budget on GW2A-18C).
        fnv = x + (x << 1) + (x << 4) + (x << 7) + (x << 8) + (x << 24);
    end
endfunction

// ---------------------------------------------------------------------------
// Beat-rate clock enable. Deep nested fnv() folds (up to 18 chained 32-bit
// shift-adds) cannot settle in one 27 MHz cycle; running every stimulus/beat
// step on ce (1 in 16 clocks) gives all combinational chains ~590 ns.
// DUTs are stalled via their clk_en pins, so the logical beat sequence is
// identical to full-rate simulation.
// ---------------------------------------------------------------------------
reg [3:0] ce_div = 4'd0;
wire ce = (ce_div == 4'd15);
always @(posedge clk) ce_div <= ce_div + 4'd1;

// ---------------------------------------------------------------------------
// Unit 0: pe (LUT multiply path)
// ---------------------------------------------------------------------------
localparam [31:0] EXP_PE = 32'hb865ec67;
reg [7:0]  pe_i = 8'd0;
reg        pe_run = 1'b0;
reg        pe_done = 1'b0;
reg [31:0] pe_dg = 32'h811c9dc5;
wire signed [19:0] pe_y;
// signed stimulus wire: yosys cannot take $signed() of a binop as a port arg
wire signed [7:0] pe_w = pe_i + (pe_i << 2) + (pe_i << 4) + (pe_i << 5) - 8'd128;

generate
if (UNIT_EN[0]) begin : g_u0
pe #(.DATA_WIDTH(8), .WEIGHT_WIDTH(8), .ADDER2_WIDTH(20),
     .OUTPUT_WIDTH(20), .USE_DSP_PE("no")) u_pe_lut (
    .clk(clk), .clk_en(ce || !rst_n),
    .D(pe_i + (pe_i << 2) + (pe_i << 5) + 8'd5),
    .W(pe_w),
    .y_in(20'sd0),
    .y_out(pe_y)
);

always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        pe_i <= 8'd0; pe_run <= 1'b0; pe_done <= 1'b0; pe_dg <= 32'h811c9dc5;
    end else if (ce && !pe_done) begin
        pe_run <= 1'b1;
        if (pe_run) begin
            if (pe_i < 8'd96) begin
                pe_i <= pe_i + 8'd1;
                if (pe_i >= 8'd3) begin
                    pe_dg <= fnv(fnv(pe_dg, pe_y[7:0]), pe_y[15:8]);
                end
            end else begin
                pe_dg <= pe_dg; pe_done <= 1'b1;
            end
        end
    end
end
end else begin : g_u0_off
    always @(posedge clk) pe_done <= 1'b1;
end
endgenerate

// ---------------------------------------------------------------------------
// Unit 1: pe (DSP attribute path) - same stimulus, digest must match unit 0
// ---------------------------------------------------------------------------
localparam [31:0] EXP_PED = 32'hb865ec67;
reg [7:0]  ped_i = 8'd0;
reg        ped_run = 1'b0;
reg        ped_done = 1'b0;
reg [31:0] ped_dg = 32'h811c9dc5;
wire signed [19:0] ped_y;
wire signed [7:0] ped_w = ped_i + (ped_i << 2) + (ped_i << 4) + (ped_i << 5) - 8'd128;

generate
if (UNIT_EN[1]) begin : g_u1
pe #(.DATA_WIDTH(8), .WEIGHT_WIDTH(8), .ADDER2_WIDTH(20),
     .OUTPUT_WIDTH(20), .USE_DSP_PE("yes")) u_pe_dsp (
    .clk(clk), .clk_en(ce || !rst_n),
    .D(ped_i + (ped_i << 2) + (ped_i << 5) + 8'd5),
    .W(ped_w),
    .y_in(20'sd0),
    .y_out(ped_y)
);

always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        ped_i <= 8'd0; ped_run <= 1'b0; ped_done <= 1'b0; ped_dg <= 32'h811c9dc5;
    end else if (ce && !ped_done) begin
        ped_run <= 1'b1;
        if (ped_run) begin
            if (ped_i < 8'd96) begin
                ped_i <= ped_i + 8'd1;
                if (ped_i >= 8'd3) begin
                    ped_dg <= fnv(fnv(ped_dg, ped_y[7:0]), ped_y[15:8]);
                end
            end else begin
                ped_done <= 1'b1;
            end
        end
    end
end
end else begin : g_u1_off
    always @(posedge clk) ped_done <= 1'b1;
end
endgenerate

// ---------------------------------------------------------------------------
// Unit 2: d_manager (ROW=4, DW=8)
// ---------------------------------------------------------------------------
localparam [31:0] EXP_DM = 32'h783b6c25;
reg [5:0]  dm_i = 6'd0;
reg        dm_done = 1'b0;
reg [31:0] dm_dg = 32'h811c9dc5;
wire [3:0][7:0] dm_D;

generate
if (UNIT_EN[2]) begin : g_u2
d_manager #(.PE_ROW_NUM(4), .DATA_WIDTH(8)) u_dm (
    .clk(clk), .clk_en(ce || !rst_n),
    .data({8'((dm_i<<3)+6'd51), 8'((dm_i<<3)+6'd34), 8'((dm_i<<3)+6'd17), 8'((dm_i<<3))}),
    .D(dm_D)
);

always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        dm_i <= 6'd0; dm_done <= 1'b0; dm_dg <= 32'h811c9dc5;
    end else if (ce && !dm_done) begin
        if (dm_i < 6'd40) begin
            dm_i <= dm_i + 6'd1;
            dm_dg <= fnv(fnv(fnv(fnv(dm_dg, dm_D[3]), dm_D[2]), dm_D[1]), dm_D[0]);
        end else begin
            dm_done <= 1'b1;
        end
    end
end
end else begin : g_u2_off
    always @(posedge clk) dm_done <= 1'b1;
end
endgenerate

// ---------------------------------------------------------------------------
// Unit 3: w_manager (ROW=4 COL=2 WW=8 CP=4, wm_test.mem)
// ---------------------------------------------------------------------------
localparam [31:0] EXP_WM = 32'h6a9e1ac5;
reg [5:0]  wm_i = 6'd0;
reg        wm_done = 1'b0;
reg [31:0] wm_dg = 32'h811c9dc5;
wire signed [1:0][3:0][7:0] wm_w;
wire wm_nl = (wm_i[3:0] == 4'd0);

generate
if (UNIT_EN[3]) begin : g_u3
w_manager #(.PE_ROW_NUM(4), .PE_COL_NUM(2), .WEIGHT_WIDTH(8),
            .CYCLE_PERIOD(4), .WEIGHT_FILE("wm_test.mem")) u_wm (
    .clk(clk), .clk_en(ce || !rst_n), .new_line_1(wm_nl), .W_out(wm_w)
);

always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        wm_i <= 6'd0; wm_done <= 1'b0; wm_dg <= 32'h811c9dc5;
    end else if (ce && !wm_done) begin
        if (wm_i < 6'd48) begin
            wm_i <= wm_i + 6'd1;
            wm_dg <= fnv(fnv(fnv(fnv(fnv(fnv(fnv(fnv(wm_dg,
                    wm_w[0][0]), wm_w[0][1]), wm_w[0][2]), wm_w[0][3]),
                    wm_w[1][0]), wm_w[1][1]), wm_w[1][2]), wm_w[1][3]);
        end else begin
            wm_done <= 1'b1;
        end
    end
end
end else begin : g_u3_off
    always @(posedge clk) wm_done <= 1'b1;
end
endgenerate

// ---------------------------------------------------------------------------
// Unit 4: sdp_ram (W=16 D=32) write-then-read
// ---------------------------------------------------------------------------
localparam [31:0] EXP_RAM = 32'h2339d078;
reg [6:0]  ram_i = 7'd0;
reg        ram_done = 1'b0;
reg [31:0] ram_dg = 32'h811c9dc5;
wire [15:0] ram_q;
wire ram_we = (ram_i < 7'd32);
wire ram_re = (ram_i >= 7'd34) && (ram_i < 7'd66);
wire [4:0] ram_wa = ram_i[4:0];
wire [4:0] ram_ra = (ram_i - 7'd34);

generate
if (UNIT_EN[4]) begin : g_u4
sdp_ram #(.WIDTH(16), .DEPTH(32)) u_ram (
    .clk(clk), .clk_en(ce || !rst_n),
    .we(ram_we), .waddr(ram_wa), .wdata({1'b0, ram_i, 1'b0, ~ram_i}),
    .re(ram_re), .raddr(ram_ra), .q(ram_q)
);

always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        ram_i <= 7'd0; ram_done <= 1'b0; ram_dg <= 32'h811c9dc5;
    end else if (ce && !ram_done) begin
        if (ram_i < 7'd70) begin
            ram_i <= ram_i + 7'd1;
            if (ram_i >= 7'd35) begin
                ram_dg <= fnv(fnv(ram_dg, ram_q[7:0]), ram_q[15:8]);
            end
        end else begin
            ram_done <= 1'b1;
        end
    end
end
end else begin : g_u4_off
    always @(posedge clk) ram_done <= 1'b1;
end
endgenerate

// ---------------------------------------------------------------------------
// Unit 5: my_fifo (DW=8 DEPTH=16, same clock both domains)
// ---------------------------------------------------------------------------
localparam [31:0] EXP_FIFO = 32'hd0c7c975;
reg [6:0]  fifo_i = 7'd0;
reg [5:0]  fifo_got = 6'd0;
reg        fifo_done = 1'b0;
reg [31:0] fifo_dg = 32'h811c9dc5;
wire fifo_full, fifo_empty;
wire [7:0] fifo_q;
wire fifo_wr = ce && (fifo_i < 7'd40) && !fifo_full;
wire fifo_rd = ce && (fifo_i >= 7'd48) && !fifo_empty;
reg  fifo_rd_d = 1'b0;
wire [7:0] fifo_din = {1'b0, fifo_i} + ({1'b0, fifo_i} << 2) + ({1'b0, fifo_i} << 3) + ({1'b0, fifo_i} << 4) + 8'd7;

generate
if (UNIT_EN[5]) begin : g_u5
my_fifo #(.DATA_WIDTH(8), .FIFO_DEPTH(16)) u_fifo (
    .rd_clk(clk), .wr_clk(clk), .rst(!rst_n),
    .wr_en(fifo_wr), .din(fifo_din),
    .rd_en(fifo_rd), .dout(fifo_q),
    .full(fifo_full), .empty(fifo_empty)
);

always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        fifo_i <= 7'd0; fifo_got <= 6'd0; fifo_done <= 1'b0;
        fifo_dg <= 32'h811c9dc5; fifo_rd_d <= 1'b0;
    end else if (ce && !fifo_done) begin
        if (fifo_i < 7'd120) fifo_i <= fifo_i + 7'd1;
        fifo_rd_d <= fifo_rd;
        if (fifo_rd_d) begin
            fifo_got <= fifo_got + 6'd1;
            fifo_dg <= fnv(fifo_dg, fifo_q);
        end
        if (fifo_i == 7'd119) fifo_done <= 1'b1;
    end
end
end else begin : g_u5_off
    always @(posedge clk) fifo_done <= 1'b1;
end
endgenerate

// ---------------------------------------------------------------------------
// Unit 6: pe_col (ROW=4 DW=8 WW=8, LUT path)
// ---------------------------------------------------------------------------
localparam [31:0] EXP_COL = 32'hd149a670;
reg [5:0]  col_i = 6'd0;
reg        col_done = 1'b0;
reg [31:0] col_dg = 32'h811c9dc5;
wire signed [19:0] col_y;
wire signed [3:0][7:0] col_w = {8'sd4, 8'sd3, 8'sd2, 8'sd1} + {4{8'(col_i)}};

generate
if (UNIT_EN[6]) begin : g_u6
pe_col #(.PE_ROW_NUM(4), .DATA_WIDTH(8), .WEIGHT_WIDTH(8),
         .OUTPUT_WIDTH(20), .USE_DSP_PE("no")) u_col (
    .clk(clk), .clk_en(ce || !rst_n),
    .D({8'(col_i+(col_i<<1)+(col_i<<2)+6'd38), 8'(col_i+(col_i<<1)+(col_i<<2)+6'd27),
        8'(col_i+(col_i<<1)+(col_i<<2)+6'd16), 8'(col_i+(col_i<<1)+(col_i<<2)+6'd5)}),
    .W(col_w),
    .y_out(col_y)
);

always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        col_i <= 6'd0; col_done <= 1'b0; col_dg <= 32'h811c9dc5;
    end else if (ce && !col_done) begin
        if (col_i < 6'd52) begin
            col_i <= col_i + 6'd1;
            if (col_i >= 6'd16) begin
                col_dg <= fnv(fnv(col_dg, col_y[7:0]), col_y[15:8]);
            end
        end else begin
            col_done <= 1'b1;
        end
    end
end
end else begin : g_u6_off
    always @(posedge clk) col_done <= 1'b1;
end
endgenerate

// ---------------------------------------------------------------------------
// Unit 7: pe_page (ROW=4 COL=2 CP=4, pepage_weight.mem)
// ---------------------------------------------------------------------------
localparam [31:0] EXP_PAGE = 32'hc5bab594;
reg [5:0]  pg_i = 6'd0;
reg        pg_done = 1'b0;
reg [31:0] pg_dg = 32'h811c9dc5;
wire signed [1:0][19:0] pg_y;
wire pg_nl = (pg_i[4:0] == 5'd0);

generate
if (UNIT_EN[7]) begin : g_u7
pe_page #(.PE_ROW_NUM(4), .PE_COL_NUM(2), .DATA_WIDTH(8),
          .WEIGHT_WIDTH(8), .CYCLE_PERIOD(4), .OUTPUT_WIDTH(20),
          .USE_DSP_PE("no"), .WEIGHT_FILE("pepage_weight.mem")) u_page (
    .clk(clk), .clk_en(ce || !rst_n), .new_line_1(pg_nl),
    .data({8'(pg_i+(pg_i<<2)+6'd30), 8'(pg_i+(pg_i<<2)+6'd22), 8'(pg_i+(pg_i<<2)+6'd14), 8'(pg_i+(pg_i<<2)+6'd6)}),
    .y_out(pg_y)
);

always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        pg_i <= 6'd0; pg_done <= 1'b0; pg_dg <= 32'h811c9dc5;
    end else if (ce && !pg_done) begin
        if (pg_i < 6'd60) begin
            pg_i <= pg_i + 6'd1;
            if (pg_i >= 6'd20) begin
                pg_dg <= fnv(fnv(fnv(fnv(pg_dg, pg_y[0][7:0]), pg_y[0][15:8]),
                                 pg_y[1][7:0]), pg_y[1][15:8]);
            end
        end else begin
            pg_done <= 1'b1;
        end
    end
end
end else begin : g_u7_off
    always @(posedge clk) pg_done <= 1'b1;
end
endgenerate

// ---------------------------------------------------------------------------
// Unit 8: max_pool2d (ROW=9 DW=8)
// ---------------------------------------------------------------------------
localparam [31:0] EXP_POOL = 32'h35a02396;
reg [6:0]  pool_i = 7'd0;
reg        pool_done = 1'b0;
reg [31:0] pool_dg = 32'h811c9dc5;
wire [7:0] pool_y;
wire pool_v, pool_nl_o;
wire pool_nl = (pool_i[4:0] == 5'd0) && (pool_i < 7'd96);

generate
if (UNIT_EN[8]) begin : g_u8
max_pool2d #(.PE_ROW_NUM(9), .DATA_WIDTH(8)) u_pool (
    .clk(clk), .clk_en(ce || !rst_n), .rst_n(rst_n),
    .new_line_1(pool_nl), .input_valid(pool_i < 7'd96),
    .data({8'(pool_i+8'd8), 8'(pool_i+(pool_i<<1)+8'd7), 8'(pool_i+8'd6),
           8'(pool_i+(pool_i<<2)+8'd5), 8'(pool_i+8'd4), 8'(pool_i+(pool_i<<3)+8'd3),
           8'(pool_i+8'd2), 8'(pool_i+(pool_i<<1)+(pool_i<<3)+8'd1), 8'(pool_i)}),
    .y_out(pool_y), .new_line_out_1(pool_nl_o), .output_valid(pool_v)
);

always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        pool_i <= 7'd0; pool_done <= 1'b0; pool_dg <= 32'h811c9dc5;
    end else if (ce && !pool_done) begin
        if (pool_i < 7'd110) pool_i <= pool_i + 7'd1;
        if (pool_v) pool_dg <= fnv(pool_dg, pool_y);
        if (pool_i == 7'd109) pool_done <= 1'b1;
    end
end
end else begin : g_u8_off
    always @(posedge clk) pool_done <= 1'b1;
end
endgenerate

// ---------------------------------------------------------------------------
// Unit 9: activation_lut (IW=6 OW=8, lut_test.mem)
// ---------------------------------------------------------------------------
localparam [31:0] EXP_LUT = 32'h830a5f5f;
reg [6:0]  lut_i = 7'd0;
reg        lut_done = 1'b0;
reg [31:0] lut_dg = 32'h811c9dc5;
wire [7:0] lut_q;
wire lut_v;

generate
if (UNIT_EN[9]) begin : g_u9
activation_lut #(.INPUT_WIDTH(6), .OUTPUT_WIDTH(8), .CONV_POSITIVE(1),
                 .LUT_FILE("lut_test.mem")) u_lut (
    .clk(clk), .in_valid(lut_i < 7'd64), .val_in(lut_i[5:0]),
    .out_valid(lut_v), .confidence_out(lut_q)
);

always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        lut_i <= 7'd0; lut_done <= 1'b0; lut_dg <= 32'h811c9dc5;
    end else if (!lut_done) begin
        if (lut_i < 7'd70) lut_i <= lut_i + 7'd1;
        if (lut_v) lut_dg <= fnv(lut_dg, lut_q);
        if (lut_i == 7'd69) lut_done <= 1'b1;
    end
end
end else begin : g_u9_off
    always @(posedge clk) lut_done <= 1'b1;
end
endgenerate

// ---------------------------------------------------------------------------
// Unit 10: input_layer (8x6 image, 3x3, PAGE=2, CPI=1, CPO=2)
// ---------------------------------------------------------------------------
localparam [31:0] EXP_IL = 32'h41c4c21f;
localparam integer IL_COLS = 8;
localparam integer IL_ROWS = 6;
reg [3:0]  il_row = 4'd0;
reg [3:0]  il_x = 4'd0;
reg        il_nl = 1'b0;
reg        il_dv = 1'b0;
reg [15:0] il_wait = 16'd0;
reg        il_done = 1'b0;
reg [31:0] il_dg = 32'h811c9dc5;
reg [15:0] il_cnt = 16'd0;
wire [8:0][1:0][7:0] il_dout;
wire il_ov, il_nlo, il_lbf;

generate
if (UNIT_EN[10]) begin : g_u10
input_layer #(.DATA_WIDTH(8), .PE_PAGE_NUM(2), .PE_ROW_NUM(9),
              .CYCLE_PERIOD_IN(1), .CYCLE_PERIOD_OUT(2),
              .STEP_ROW(1), .STEP_COL(1), .KERNEL_ROW(3), .KERNEL_COL(3),
              .IMG_COL(IL_COLS), .IMG_ROW(IL_ROWS)) u_il (
    .clk(clk), .clk_en(ce || !rst_n), .rst_n(rst_n),
    .new_line_input_1(il_nl), .data_input_valid(il_dv),
    .data_input({8'(il_x + (il_x<<1) + (il_row<<3) - il_row + 8'd2), 8'(il_x + (il_row<<3))}),
    .data_out(il_dout), .line_buf_full(il_lbf),
    .data_out_valid(il_ov), .new_line_out_1(il_nlo)
);

always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        il_row <= 4'd0; il_x <= 4'd0; il_nl <= 1'b0; il_dv <= 1'b0;
        il_wait <= 16'd0; il_done <= 1'b0; il_dg <= 32'h811c9dc5; il_cnt <= 16'd0;
    end else if (ce && !il_done) begin
        il_nl <= 1'b0; il_dv <= 1'b0;
        if (il_row < IL_ROWS) begin
            if (il_x == 0 && !il_nl && il_wait == 16'd0) begin
                il_nl <= 1'b1;          // new-line pulse before row data
            end else if (il_x < IL_COLS) begin
                il_dv <= 1'b1;          // data beats carry il_x = 1..IL_COLS
                il_x <= il_x + 4'd1;
            end else if (il_wait < 16'd24) begin
                il_wait <= il_wait + 16'd1;  // pace rows: line-buffer drain needs ~16 cycles/row
            end else begin
                il_row <= il_row + 4'd1;
                il_x <= 4'd0;
                il_wait <= 16'd0;
            end
        end else begin
            il_wait <= il_wait + 16'd1;
            if (il_wait == 16'd600) il_done <= 1'b1;
        end
        if (il_ov) begin
            il_cnt <= il_cnt + 16'd1;
            il_dg <= fnv(fnv(fnv(fnv(fnv(fnv(fnv(fnv(fnv(fnv(fnv(fnv(fnv(fnv(fnv(fnv(fnv(fnv(
                il_dg,
                il_dout[0][0]), il_dout[0][1]), il_dout[1][0]), il_dout[1][1]),
                il_dout[2][0]), il_dout[2][1]), il_dout[3][0]), il_dout[3][1]),
                il_dout[4][0]), il_dout[4][1]), il_dout[5][0]), il_dout[5][1]),
                il_dout[6][0]), il_dout[6][1]), il_dout[7][0]), il_dout[7][1]),
                il_dout[8][0]), il_dout[8][1]);
        end
    end
end
end else begin : g_u10_off
    always @(posedge clk) il_done <= 1'b1;
end
endgenerate

// ---------------------------------------------------------------------------
// Unit 11: output_layer (PAGE=2 COL=2 ROW=9 CPO=2 CPI=1)
// ---------------------------------------------------------------------------
localparam [31:0] EXP_OL = 32'h46e9e19d;
reg [7:0]  ol_i = 8'd0;
reg        ol_done = 1'b0;
reg [31:0] ol_dg = 32'h811c9dc5;
reg [15:0] ol_cnt = 16'd0;
wire [1:0][7:0] ol_out;
wire ol_v, ol_nlo;
wire ol_nl = (ol_i[5:0] == 6'd0) && (ol_i < 8'd192);
wire signed [1:0][1:0][19:0] ol_pin;

genvar gp, gc;
generate
    for (gp = 0; gp < 2; gp = gp + 1) begin : g_olp
        for (gc = 0; gc < 2; gc = gc + 1) begin : g_olc
            assign ol_pin[gp][gc] = $signed({1'b0, ol_i[7:0]}) +
                                    (gp * 20'sd131) + (gc * 20'sd77) - 20'sd200;
        end
    end
endgenerate

generate
if (UNIT_EN[11]) begin : g_u11
output_layer #(.PE_PAGE_NUM(2), .PE_COL_NUM(2), .PE_ROW_NUM(9),
               .PE_OUT_WIDTH(20), .BIAS_WIDTH(16), .ACC_WIDTH(22),
               .SHIFT_KEY(4), .OUT_WIDTH(8), .CYCLE_PERIOD_OUT(2),
               .CYCLE_PERIOD_IN(1), .IMG_COL(8), .WITH_RELU(1),
               .BIAS_FILE("bias_test.mem")) u_ol (
    .clk(clk), .clk_en(ce || !rst_n), .rst_n(rst_n),
    .new_line_in(ol_nl), .page_y_out(ol_pin),
    .final_out(ol_out), .output_valid(ol_v), .new_line_out_1(ol_nlo)
);

always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        ol_i <= 8'd0; ol_done <= 1'b0; ol_dg <= 32'h811c9dc5; ol_cnt <= 16'd0;
    end else if (ce && !ol_done) begin
        if (ol_i < 8'd220) ol_i <= ol_i + 8'd1;
        if (ol_v) begin
            ol_cnt <= ol_cnt + 16'd1;
            ol_dg <= fnv(fnv(ol_dg, ol_out[0]), ol_out[1]);
        end
        if (ol_i == 8'd219) ol_done <= 1'b1;
    end
end
end else begin : g_u11_off
    always @(posedge clk) ol_done <= 1'b1;
end
endgenerate

// ---------------------------------------------------------------------------
// Unit 12: layer (3x3 conv, PAGE=2 COL=2, weights all-1, bias=8, shift=4)
// ---------------------------------------------------------------------------
localparam [31:0] EXP_LAYR = 32'h9a9aea61;
localparam integer LY_COLS = 8;
localparam integer LY_ROWS = 6;
reg [3:0]  ly_row = 4'd0;
reg [3:0]  ly_x = 4'd0;
reg        ly_nl = 1'b0;
reg        ly_dv = 1'b0;
reg [15:0] ly_wait = 16'd0;
reg        ly_done = 1'b0;
reg [31:0] ly_dg = 32'h811c9dc5;
reg [15:0] ly_cnt = 16'd0;
wire [1:0][7:0] ly_out;
wire ly_v, ly_nlo;

generate
if (UNIT_EN[12]) begin : g_u12
lprnet_layer_direct #(.PE_PAGE_NUM(2), .PE_ROW_NUM(9),
        .KERNEL_COL(3), .KERNEL_ROW(3), .PE_COL_NUM(2),
        .MAX_POOL(0), .WITH_RELU(1), .DATA_WIDTH(8), .WEIGHT_WIDTH(8),
        .CYCLE_PERIOD_OUT(2), .CYCLE_PERIOD_IN(1),
        .IMG_COL(LY_COLS), .IMG_ROW(LY_ROWS), .STEP_ROW(1), .STEP_COL(1),
        .USE_DSP_PE("no"), .SHIFT_KEY(4), .BIAS_WIDTH(16), .OUT_WIDTH(8),
        .WEIGHT_FILE0("weight_layer9_page0.mem"),
        .WEIGHT_FILE1("weight_layer9_page1.mem"),
        .BIAS_FILE("bias_layer9.mem")) u_layer (
    .clk(clk), .clk_en(ce || !rst_n), .rst_n(rst_n),
    .new_line_input_1(ly_nl), .data_input_valid(ly_dv),
    .data_input({8'(ly_x + (ly_x<<1) + (ly_row<<3) - ly_row + 8'd2), 8'(ly_x + (ly_row<<3))}),
    .y_out(ly_out), .new_line_out_1(ly_nlo), .output_valid(ly_v)
);

always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        ly_row <= 4'd0; ly_x <= 4'd0; ly_nl <= 1'b0; ly_dv <= 1'b0;
        ly_wait <= 16'd0; ly_done <= 1'b0; ly_dg <= 32'h811c9dc5; ly_cnt <= 16'd0;
    end else if (ce && !ly_done) begin
        ly_nl <= 1'b0; ly_dv <= 1'b0;
        if (ly_row < LY_ROWS) begin
            if (ly_x == 0 && !ly_nl && ly_wait == 16'd0) begin
                ly_nl <= 1'b1;
            end else if (ly_x < LY_COLS) begin
                ly_dv <= 1'b1;
                ly_x <= ly_x + 4'd1;
            end else if (ly_wait < 16'd24) begin
                ly_wait <= ly_wait + 16'd1;
            end else begin
                ly_row <= ly_row + 4'd1;
                ly_x <= 4'd0;
                ly_wait <= 16'd0;
            end
        end else begin
            ly_wait <= ly_wait + 16'd1;
            if (ly_wait == 16'd800) ly_done <= 1'b1;
        end
        if (ly_v) begin
            ly_cnt <= ly_cnt + 16'd1;
            ly_dg <= fnv(fnv(ly_dg, ly_out[0]), ly_out[1]);
        end
    end
end
end else begin : g_u12_off
    always @(posedge clk) ly_done <= 1'b1;
end
endgenerate

// ---------------------------------------------------------------------------
// Unit 13: extrema_finder (DW=16 COL=2 CPO=4 -> 8 channels)
// ---------------------------------------------------------------------------
localparam [31:0] EXP_EF = 32'h931885aa;
reg [6:0]  ef_i = 7'd0;
reg        ef_done = 1'b0;
reg [31:0] ef_dg = 32'h811c9dc5;
wire signed [15:0] ef_val;
wire [2:0]  ef_ch;
wire ef_v;
wire ef_nl = (ef_i == 7'd0) || (ef_i == 7'd40) || (ef_i == 7'd80);
wire signed [15:0] ef_d0 = $signed({9'd0, ef_i}) + ($signed({9'd0, ef_i}) <<< 4) - 16'sd300;
wire signed [15:0] ef_d1 = $signed({9'd0, ef_i}) + ($signed({9'd0, ef_i}) <<< 2) +
                           ($signed({9'd0, ef_i}) <<< 3) + ($signed({9'd0, ef_i}) <<< 4) - 16'sd100;

generate
if (UNIT_EN[13]) begin : g_u13
extrema_finder #(.DATA_WIDTH(16), .PE_COL_NUM(2), .CYCLE_PERIOD_OUT(4),
                 .CONV_POSITIVE(1)) u_ef (
    .clk(clk), .rst_n(rst_n), .clk_en(ce || !rst_n),
    .data_input_valid((ef_i > 7'd0) && (ef_i < 7'd97) && !ef_nl),
    .new_line_1(ef_nl),
    .data_in($signed({ef_d0, ef_d1})),
    .val_out(ef_val), .val_out_channel(ef_ch), .val_valid(ef_v)
);

always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        ef_i <= 7'd0; ef_done <= 1'b0; ef_dg <= 32'h811c9dc5;
    end else if (ce && !ef_done) begin
        if (ef_i < 7'd110) ef_i <= ef_i + 7'd1;
        if (ef_v) begin
            ef_dg <= fnv(fnv(fnv(ef_dg, ef_val[7:0]), ef_val[15:8]), {5'd0, ef_ch});
        end
        if (ef_i == 7'd109) ef_done <= 1'b1;
    end
end
end else begin : g_u13_off
    always @(posedge clk) ef_done <= 1'b1;
end
endgenerate

// ---------------------------------------------------------------------------
// Unit 14: lprnet_spatial_sum (COL=2 CPO=2 IMG 4x3)
// ---------------------------------------------------------------------------
localparam [31:0] EXP_SSUM = 32'h77330ec1;
reg [3:0]  ss_beat = 4'd8;   // start on the "nl" slot so nl precedes row 0 data
reg [2:0]  ss_row = 3'd0;
reg        ss_nl = 1'b0;
reg        ss_dv = 1'b0;
reg [9:0]  ss_wait = 10'd0;
reg        ss_done = 1'b0;
reg [31:0] ss_dg = 32'h811c9dc5;
wire [6:0] ss_seq = {ss_row, ss_beat}; // global beat index within row
wire signed [1:0][15:0] ss_y;
wire ss_v, ss_nlo;

generate
if (UNIT_EN[14]) begin : g_u14
lprnet_spatial_sum #(.PE_COL_NUM(2), .CYCLE_PERIOD_OUT(2),
                     .IMG_COL(4), .IMG_ROW(3), .DATA_WIDTH(8),
                     .ACC_WIDTH(16)) u_ssum (
    .clk(clk), .clk_en(ce || !rst_n), .rst_n(rst_n),
    .new_line_input_1(ss_nl), .data_input_valid(ss_dv),
    .data_input($signed({8'($signed(ss_seq + (ss_seq<<3) - 7'd40)), 8'($signed(ss_seq + (ss_seq<<2) + 7'd2))})),
    .y_out(ss_y), .new_line_out_1(ss_nlo), .output_valid(ss_v)
);

always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        ss_beat <= 4'd8; ss_row <= 3'd0; ss_nl <= 1'b0; ss_dv <= 1'b0;
        ss_wait <= 10'd0; ss_done <= 1'b0; ss_dg <= 32'h811c9dc5;
    end else if (ce && !ss_done) begin
        ss_nl <= 1'b0; ss_dv <= 1'b0;
        if (ss_row < 3'd3) begin
            if (ss_beat == 4'd8) begin
                ss_nl <= 1'b1;         // pulse before the row's data
                ss_beat <= 4'd0;
            end else begin
                ss_dv <= 1'b1;
                if (ss_beat == 4'd7) ss_row <= ss_row + 3'd1;
                ss_beat <= ss_beat + 4'd1;
            end
        end else begin
            ss_wait <= ss_wait + 10'd1;
            if (ss_wait == 10'd300) ss_done <= 1'b1;
        end
        if (ss_v) begin
            ss_dg <= fnv(fnv(fnv(fnv(ss_dg, ss_y[0][7:0]), ss_y[0][15:8]),
                             ss_y[1][7:0]), ss_y[1][15:8]);
        end
    end
end
end else begin : g_u14_off
    always @(posedge clk) ss_done <= 1'b1;
end
endgenerate

// ---------------------------------------------------------------------------
// Unit 15: lprnet_post_process (COL=2 CPO=2 IMG 4x3, 8 ch, blank=7)
// ---------------------------------------------------------------------------
localparam [31:0] EXP_CTC = 32'hed74208a;
reg [3:0]  ctc_beat = 4'd8;
reg [2:0]  ctc_row = 3'd0;
reg        ctc_nl = 1'b0;
reg        ctc_dv = 1'b0;
reg [9:0]  ctc_wait = 10'd0;
reg        ctc_done = 1'b0;
reg [31:0] ctc_dg = 32'h811c9dc5;
wire [6:0] ctc_seq = {ctc_row, ctc_beat};
wire [1:0] ctc_char;
wire ctc_v, ctc_fs;

generate
if (UNIT_EN[15]) begin : g_u15
lprnet_post_process #(.PE_COL_NUM(2), .CYCLE_PERIOD_OUT(2),
                      .IMG_COL(4), .IMG_ROW(3), .DATA_WIDTH(8),
                      .ACC_WIDTH(16), .CONV_POSITIVE(1),
                      .BLANK_CHAR(7), .VALID_CHAR_NUM(8)) u_ctc (
    .clk(clk), .clk_en(ce || !rst_n), .rst_n(rst_n),
    .new_line_input_1(ctc_nl), .data_input_valid(ctc_dv),
    .data_input($signed({8'($signed(ctc_seq + (ctc_seq<<3) - 7'd40)), 8'($signed(ctc_seq + (ctc_seq<<2) + 7'd2))})),
    .out_char(ctc_char), .out_valid(ctc_v), .frame_start_out(ctc_fs)
);

always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        ctc_beat <= 4'd8; ctc_row <= 3'd0; ctc_nl <= 1'b0; ctc_dv <= 1'b0;
        ctc_wait <= 10'd0; ctc_done <= 1'b0; ctc_dg <= 32'h811c9dc5;
    end else if (ce && !ctc_done) begin
        ctc_nl <= 1'b0; ctc_dv <= 1'b0;
        if (ctc_row < 3'd3) begin
            if (ctc_beat == 4'd8) begin
                ctc_nl <= 1'b1;
                ctc_beat <= 4'd0;
            end else begin
                ctc_dv <= 1'b1;
                if (ctc_beat == 4'd7) ctc_row <= ctc_row + 3'd1;
                ctc_beat <= ctc_beat + 4'd1;
            end
        end else begin
            ctc_wait <= ctc_wait + 10'd1;
            if (ctc_wait == 10'd300) ctc_done <= 1'b1;
        end
        if (ctc_v) ctc_dg <= fnv(ctc_dg, {6'd0, ctc_char});
    end
end
end else begin : g_u15_off
    always @(posedge clk) ctc_done <= 1'b1;
end
endgenerate

// ---------------------------------------------------------------------------
// Aggregation
// ---------------------------------------------------------------------------
wire [15:0] done_w = {ctc_done, ss_done, ef_done, ly_done, ol_done, il_done,
                      lut_done, pool_done, pg_done, col_done, fifo_done,
                      ram_done, wm_done, dm_done, ped_done, pe_done};
assign done_mask = done_w;

function [31:0] exp_digest;
    input [3:0] idx;
    begin
        case (idx)
            4'd0:  exp_digest = EXP_PE;
            4'd1:  exp_digest = EXP_PED;
            4'd2:  exp_digest = EXP_DM;
            4'd3:  exp_digest = EXP_WM;
            4'd4:  exp_digest = EXP_RAM;
            4'd5:  exp_digest = EXP_FIFO;
            4'd6:  exp_digest = EXP_COL;
            4'd7:  exp_digest = EXP_PAGE;
            4'd8:  exp_digest = EXP_POOL;
            4'd9:  exp_digest = EXP_LUT;
            4'd10: exp_digest = EXP_IL;
            4'd11: exp_digest = EXP_OL;
            4'd12: exp_digest = EXP_LAYR;
            4'd13: exp_digest = EXP_EF;
            4'd14: exp_digest = EXP_SSUM;
            4'd15: exp_digest = EXP_CTC;
            default: exp_digest = 32'd0;
        endcase
    end
endfunction

reg [31:0] digests [0:15];
reg [15:0] pass_r;
assign pass_mask = pass_r;

integer ui;
always @(posedge clk) begin
    digests[0]  <= pe_dg;   digests[1]  <= ped_dg;  digests[2]  <= dm_dg;
    digests[3]  <= wm_dg;   digests[4]  <= ram_dg;  digests[5]  <= fifo_dg;
    digests[6]  <= col_dg;  digests[7]  <= pg_dg;   digests[8]  <= pool_dg;
    digests[9]  <= lut_dg;  digests[10] <= il_dg;   digests[11] <= ol_dg;
    digests[12] <= ly_dg;   digests[13] <= ef_dg;   digests[14] <= ss_dg;
    digests[15] <= ctc_dg;
    for (ui = 0; ui < 16; ui = ui + 1) begin
        pass_r[ui] <= done_w[ui] &&
                      (!UNIT_EN[ui] || digests[ui] == exp_digest(ui[3:0]));
    end
end

always @(*) begin
    digest_q = digests[digest_sel[3:0]];
end

// pass/fail latch: pass_r settles one cycle after the last done bit, so the
// verdict is captured one cycle after all_done asserts (sticky, no glitch).
reg verdict_settled;
always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        all_done <= 1'b0; all_pass <= 1'b0; any_fail <= 1'b0;
        verdict_settled <= 1'b0;
    end else if (ce && !all_done) begin
        all_done <= &done_w;
    end else if (!verdict_settled) begin
        verdict_settled <= 1'b1;
        all_pass <= (pass_r === done_w);
        any_fail <= (pass_r !== done_w);
    end
end

endmodule
