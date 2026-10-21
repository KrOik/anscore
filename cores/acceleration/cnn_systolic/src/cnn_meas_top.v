// CNN measurement top: drives lprnet_layer_direct (full conv layer) and a
// standalone input_layer with the same 6x8x2ch stimulus at FULL 27 MHz rate
// (clk_en=1). Measures cycle-accurate timing with hardware counters and
// captures the raw output byte streams, then reports everything on UART.
//
// Report layout (MSG_LEN bytes):
//   0..63   "MEAS T=<lat_il>,<lat_ly>,<il_span>,<ly_span> G=<gmin>,<gmax> N=<n_il>,<n_ly>,<n_nlo> F=<frame>\r\n"
//   64..66  "IL>"
//   67..786 720 raw bytes: 40 windows x 18B (r=0..8, ch0 then ch1)
//   787..788 \r\n
//   789..791 "LY>"
//   792..951 160 raw bytes: 80 beats x 2B (ch0 then ch1)
//   952..953 \r\n
module cnn_meas_top #(
    parameter integer USE_PLL = 0
) (
    input  wire clk,
    output wire uart_tx_pin,
    output wire status_done
);

wire dclk;
wire pll_lock;
generate
if (USE_PLL) begin : g_pll
    meas_pll u_pll (.clock_in(clk), .clock_out(dclk), .locked(pll_lock));
end else begin : g_nopll
    assign dclk = clk;
    assign pll_lock = 1'b1;
end
endgenerate

localparam integer IMG_COLS = 8;
localparam integer IMG_ROWS = 6;
localparam integer ROW_GAP  = 24;
localparam integer MSG_LEN  = 954;
localparam [24:0] REPORT_GAP_RELOAD = 25'd13_500_000;

localparam [1:0] TX_ASSERT    = 2'd0;
localparam [1:0] TX_WAIT_BUSY = 2'd1;
localparam [1:0] TX_WAIT_IDLE = 2'd2;

reg [12:0] reset_count = 13'd0;
wire rst_n = reset_count[12] && pll_lock;

// ---------------------------------------------------------------------------
// Stimulus: same pattern as selftest LAYR unit but at full clock rate.
// Per row: nl pulse, then 8 dv beats (x=1..8), then ROW_GAP idle clks.
// ---------------------------------------------------------------------------
reg [3:0]  st_row = 4'd0;
reg [4:0]  st_x = 5'd0;
reg [6:0]  st_wait = 7'd0;
reg        st_nl_d = 1'b0;
reg        stim_nl = 1'b0;
reg        stim_dv = 1'b0;
wire [15:0] stim_data = {8'(st_x + (st_x<<1) + (st_row<<3) - st_row + 8'd2),
                         8'(st_x + (st_row<<3))};

// ---------------------------------------------------------------------------
// DUTs
// ---------------------------------------------------------------------------
wire [143:0] il_dout;
wire il_ov, il_nlo, il_lbf;
wire [15:0] ly_out16;
wire ly_v, ly_nlo;

input_layer #(
    .DATA_WIDTH(8), .PE_PAGE_NUM(2), .PE_ROW_NUM(9),
    .KERNEL_COL(3), .KERNEL_ROW(3),
    .CYCLE_PERIOD_IN(1), .CYCLE_PERIOD_OUT(2),
    .STEP_COL(1), .STEP_ROW(1),
    .IMG_COL(IMG_COLS), .IMG_ROW(IMG_ROWS)
) u_il (
    .clk(dclk), .clk_en(1'b1), .rst_n(rst_n),
    .new_line_input_1(stim_nl),
    .data_input_valid(stim_dv),
    .data_input(stim_data),
    .data_out(il_dout),
    .line_buf_full(il_lbf),
    .data_out_valid(il_ov),
    .new_line_out_1(il_nlo)
);

lprnet_layer_direct #(
    .PE_PAGE_NUM(2), .PE_ROW_NUM(9),
    .KERNEL_COL(3), .KERNEL_ROW(3), .PE_COL_NUM(2),
    .MAX_POOL(0), .WITH_RELU(1), .DATA_WIDTH(8), .WEIGHT_WIDTH(8),
    .CYCLE_PERIOD_OUT(2), .CYCLE_PERIOD_IN(1),
    .IMG_COL(IMG_COLS), .IMG_ROW(IMG_ROWS), .STEP_ROW(1), .STEP_COL(1),
    .USE_DSP_PE("no"), .SHIFT_KEY(4), .BIAS_WIDTH(16), .OUT_WIDTH(8),
    .WEIGHT_FILE0("weight_layer9_page0.mem"),
    .WEIGHT_FILE1("weight_layer9_page1.mem"),
    .BIAS_FILE("bias_layer9.mem")
) u_layer (
    .clk(dclk), .clk_en(1'b1), .rst_n(rst_n),
    .new_line_input_1(stim_nl),
    .data_input_valid(stim_dv),
    .data_input(stim_data),
    .y_out(ly_out16),
    .new_line_out_1(ly_nlo),
    .output_valid(ly_v)
);

// ---------------------------------------------------------------------------
// Timing counters (all in 27 MHz clock cycles)
// ---------------------------------------------------------------------------
reg [15:0] frame_clk = 16'd0;
reg        running = 1'b0;
reg        meas_done = 1'b0;
reg        got_dv0 = 1'b0;
reg        got_il0 = 1'b0;
reg        got_ly0 = 1'b0;
reg [15:0] t_dv0 = 16'd0;
reg [15:0] t_il0 = 16'd0;
reg [15:0] t_il_last = 16'd0;
reg [15:0] t_ly0 = 16'd0;
reg [15:0] t_ly_last = 16'd0;
reg [15:0] t_ly_prev = 16'd0;
reg [15:0] gap_min = 16'hffff;
reg [15:0] gap_max = 16'd0;
reg [15:0] n_il = 16'd0;
reg [15:0] n_il_nl = 16'd0;
reg [15:0] n_ly = 16'd0;
reg [15:0] n_nlo = 16'd0;
reg [15:0] fram_r = 16'd0;

wire [15:0] gap_now = frame_clk - t_ly_prev;

// ---------------------------------------------------------------------------
// Capture buffers (word-wide, one write per event). Read port is synchronous
// (il_rd_word / ly_rd_word prefetch regs) so yosys maps them to BSRAM.
// ---------------------------------------------------------------------------
// il_win split into 4 x 36-bit banks (BSRAM max port width is 36);
// ly_w padded to 18 bits (narrowest fitting port width).
(* ram_style = "block" *) reg [35:0] il_w0 [0:63];
(* ram_style = "block" *) reg [35:0] il_w1 [0:63];
(* ram_style = "block" *) reg [35:0] il_w2 [0:63];
(* ram_style = "block" *) reg [35:0] il_w3 [0:63];
reg [5:0]   il_wc = 6'd0;
(* ram_style = "block" *) reg [17:0]  ly_w [0:127];
reg [6:0]   ly_wc = 7'd0;
reg [35:0]  il_rd0, il_rd1, il_rd2, il_rd3;
reg [17:0]  ly_rd_word;
reg [5:0]   il_raddr;
reg [6:0]   ly_raddr;
wire [143:0] il_rd_word = {il_rd3, il_rd2, il_rd1, il_rd0};
wire rep_start;
wire il_pf, ly_pf;

// ---------------------------------------------------------------------------
// Stimulus + counters + capture
// ---------------------------------------------------------------------------
always @(posedge dclk or negedge rst_n) begin
    if (!rst_n) begin
        st_row <= 4'd0; st_x <= 5'd0; st_wait <= 7'd0; st_nl_d <= 1'b0;
        stim_nl <= 1'b0; stim_dv <= 1'b0;
        frame_clk <= 16'd0; running <= 1'b0; meas_done <= 1'b0;
        got_dv0 <= 1'b0; got_il0 <= 1'b0; got_ly0 <= 1'b0;
        t_dv0 <= 16'd0; t_il0 <= 16'd0; t_il_last <= 16'd0;
        t_ly0 <= 16'd0; t_ly_last <= 16'd0; t_ly_prev <= 16'd0;
        gap_min <= 16'hffff; gap_max <= 16'd0;
        n_il <= 16'd0; n_il_nl <= 16'd0; n_ly <= 16'd0; n_nlo <= 16'd0;
        fram_r <= 16'd0;
        il_wc <= 6'd0; ly_wc <= 7'd0;
    end else begin
        stim_nl <= 1'b0;
        stim_dv <= 1'b0;
        if (!meas_done) begin
            // stimulus
            if (st_row < IMG_ROWS) begin
                if (st_x == 0 && !st_nl_d && st_wait == 0) begin
                    stim_nl <= 1'b1;
                    st_nl_d <= 1'b1;
                end else if (st_x < IMG_COLS) begin
                    stim_dv <= 1'b1;
                    st_x <= st_x + 5'd1;
                end else if (st_wait < ROW_GAP) begin
                    st_wait <= st_wait + 7'd1;
                end else begin
                    st_row <= st_row + 4'd1;
                    st_x <= 5'd0;
                    st_wait <= 7'd0;
                    st_nl_d <= 1'b0;
                end
            end
            // frame clock
            if (stim_nl && !running) begin
                running <= 1'b1;
                frame_clk <= 16'd1;
            end else if (running) begin
                frame_clk <= frame_clk + 16'd1;
            end
            // event timestamps
            if (stim_dv && !got_dv0) begin
                got_dv0 <= 1'b1;
                t_dv0 <= frame_clk;
            end
            if (il_nlo) n_il_nl <= n_il_nl + 16'd1;
            if (ly_nlo) n_nlo <= n_nlo + 16'd1;
            if (il_ov) begin
                n_il <= n_il + 16'd1;
                t_il_last <= frame_clk;
                if (!got_il0) begin
                    got_il0 <= 1'b1;
                    t_il0 <= frame_clk;
                end
                if (il_wc < 6'd40) il_wc <= il_wc + 6'd1;
            end
            if (ly_v) begin
                n_ly <= n_ly + 16'd1;
                t_ly_last <= frame_clk;
                if (!got_ly0) begin
                    got_ly0 <= 1'b1;
                    t_ly0 <= frame_clk;
                end else begin
                    if (gap_now < gap_min) gap_min <= gap_now;
                    if (gap_now > gap_max) gap_max <= gap_now;
                end
                t_ly_prev <= frame_clk;
                if (ly_wc < 7'd80) ly_wc <= ly_wc + 7'd1;
            end
            // done when all expected events seen or timeout
            if ((n_ly == 16'd80 && n_il == 16'd40) || frame_clk == 16'hff00) begin
                meas_done <= 1'b1;
                fram_r <= frame_clk;
            end
        end
    end
end

assign status_done = meas_done;

// ---------------------------------------------------------------------------
// UART report
// ---------------------------------------------------------------------------
reg [7:0]  tx_data;
reg        tx_valid;
wire       tx_ready;
wire       tx_busy;
reg [9:0]  msg_index;
reg        report_active;
reg [1:0]  tx_state;
reg [24:0] report_gap_count;

// Readout pointers for the raw dump regions (advanced in lockstep with
// msg_index so no division is needed).
reg [5:0] il_r_w;
reg [4:0] il_r_b;
reg [6:0] ly_r_w;
reg       ly_r_b;

// Report entry pulse (same condition that sets report_active) and readout
// prefetch conditions, evaluated at the TX_WAIT_IDLE -> next-char edge.
assign rep_start = meas_done && !report_active && (report_gap_count == 25'd0);
// Prefetch the next word one byte before the word boundary: the read
// address register adds one pipeline stage, so the word lands in time
// for byte 0 of the next window/beat.
assign il_pf = report_active && (tx_state == TX_WAIT_IDLE) && tx_ready &&
               (msg_index >= 10'd67) && (msg_index < 10'd786) &&
               (il_r_b == 5'd16);
assign ly_pf = report_active && (tx_state == TX_WAIT_IDLE) && tx_ready &&
               (msg_index >= 10'd792) && (msg_index < 10'd951) && !ly_r_b;

// Memory ports must live in pure posedge blocks (no async reset) or the
// frontend lowers them to registers instead of $mem cells. The read side
// uses a dedicated address register so yosys sees a clean sync-read RAM.
always @(posedge dclk) begin
    if (il_ov && il_wc < 6'd40) begin
        il_w0[il_wc] <= il_dout[35:0];
        il_w1[il_wc] <= il_dout[71:36];
        il_w2[il_wc] <= il_dout[107:72];
        il_w3[il_wc] <= il_dout[143:108];
    end
    if (ly_v && ly_wc < 7'd80) ly_w[ly_wc] <= {2'b00, ly_out16};
    if (rep_start) begin
        il_raddr <= 6'd0;
        ly_raddr <= 7'd0;
    end else begin
        if (il_pf) il_raddr <= il_r_w + 6'd1;
        if (ly_pf) ly_raddr <= ly_r_w + 7'd1;
    end
    il_rd0 <= il_w0[il_raddr];
    il_rd1 <= il_w1[il_raddr];
    il_rd2 <= il_w2[il_raddr];
    il_rd3 <= il_w3[il_raddr];
    ly_rd_word <= ly_w[ly_raddr];
end

wire [7:0] il_dump_byte = il_rd_word[{il_r_b, 3'b000} +: 8];
wire [7:0] ly_dump_byte = ly_r_b ? ly_rd_word[15:8] : ly_rd_word[7:0];
wire unused_ly_pad = &{1'b0, ly_rd_word[17:16]};

uart_tx #(
    .CLK_FRE(USE_PLL ? 54 : 27),
    .BAUD_RATE(115200)
) uart (
    .clk(dclk),
    .rst_n(rst_n),
    .tx_data(tx_data),
    .tx_data_valid(tx_valid),
    .tx_data_ready(tx_ready),
    .tx_pin(uart_tx_pin),
    .tx_busy(tx_busy)
);

function [7:0] hex_nibble;
    input [3:0] value;
    begin
        if (value < 4'd10) hex_nibble = 8'h30 + value;
        else               hex_nibble = 8'h41 + (value - 4'd10);
    end
endfunction

function [7:0] meas_char;
    input [9:0] index;
    reg [15:0] lat_il, lat_ly, il_sp, ly_sp;
    begin
        lat_il = t_il0 - t_dv0;
        lat_ly = t_ly0 - t_dv0;
        il_sp  = t_il_last - t_il0;
        ly_sp  = t_ly_last - t_ly0;
        case (index)
            10'd0:  meas_char = "M";
            10'd1:  meas_char = "E";
            10'd2:  meas_char = "A";
            10'd3:  meas_char = "S";
            10'd4:  meas_char = " ";
            10'd5:  meas_char = "T";
            10'd6:  meas_char = "=";
            10'd7:  meas_char = hex_nibble(lat_il[15:12]);
            10'd8:  meas_char = hex_nibble(lat_il[11:8]);
            10'd9:  meas_char = hex_nibble(lat_il[7:4]);
            10'd10: meas_char = hex_nibble(lat_il[3:0]);
            10'd11: meas_char = ",";
            10'd12: meas_char = hex_nibble(lat_ly[15:12]);
            10'd13: meas_char = hex_nibble(lat_ly[11:8]);
            10'd14: meas_char = hex_nibble(lat_ly[7:4]);
            10'd15: meas_char = hex_nibble(lat_ly[3:0]);
            10'd16: meas_char = ",";
            10'd17: meas_char = hex_nibble(il_sp[15:12]);
            10'd18: meas_char = hex_nibble(il_sp[11:8]);
            10'd19: meas_char = hex_nibble(il_sp[7:4]);
            10'd20: meas_char = hex_nibble(il_sp[3:0]);
            10'd21: meas_char = ",";
            10'd22: meas_char = hex_nibble(ly_sp[15:12]);
            10'd23: meas_char = hex_nibble(ly_sp[11:8]);
            10'd24: meas_char = hex_nibble(ly_sp[7:4]);
            10'd25: meas_char = hex_nibble(ly_sp[3:0]);
            10'd26: meas_char = " ";
            10'd27: meas_char = "G";
            10'd28: meas_char = "=";
            10'd29: meas_char = hex_nibble(gap_min[15:12]);
            10'd30: meas_char = hex_nibble(gap_min[11:8]);
            10'd31: meas_char = hex_nibble(gap_min[7:4]);
            10'd32: meas_char = hex_nibble(gap_min[3:0]);
            10'd33: meas_char = ",";
            10'd34: meas_char = hex_nibble(gap_max[15:12]);
            10'd35: meas_char = hex_nibble(gap_max[11:8]);
            10'd36: meas_char = hex_nibble(gap_max[7:4]);
            10'd37: meas_char = hex_nibble(gap_max[3:0]);
            10'd38: meas_char = " ";
            10'd39: meas_char = "N";
            10'd40: meas_char = "=";
            10'd41: meas_char = hex_nibble(n_il[15:12]);
            10'd42: meas_char = hex_nibble(n_il[11:8]);
            10'd43: meas_char = hex_nibble(n_il[7:4]);
            10'd44: meas_char = hex_nibble(n_il[3:0]);
            10'd45: meas_char = ",";
            10'd46: meas_char = hex_nibble(n_ly[15:12]);
            10'd47: meas_char = hex_nibble(n_ly[11:8]);
            10'd48: meas_char = hex_nibble(n_ly[7:4]);
            10'd49: meas_char = hex_nibble(n_ly[3:0]);
            10'd50: meas_char = ",";
            10'd51: meas_char = hex_nibble(n_nlo[15:12]);
            10'd52: meas_char = hex_nibble(n_nlo[11:8]);
            10'd53: meas_char = hex_nibble(n_nlo[7:4]);
            10'd54: meas_char = hex_nibble(n_nlo[3:0]);
            10'd55: meas_char = " ";
            10'd56: meas_char = "F";
            10'd57: meas_char = "=";
            10'd58: meas_char = hex_nibble(fram_r[15:12]);
            10'd59: meas_char = hex_nibble(fram_r[11:8]);
            10'd60: meas_char = hex_nibble(fram_r[7:4]);
            10'd61: meas_char = hex_nibble(fram_r[3:0]);
            10'd62: meas_char = 8'h0d;
            10'd63: meas_char = 8'h0a;
            default: meas_char = " ";
        endcase
    end
endfunction

wire [7:0] tx_char =
    (msg_index < 10'd64)   ? meas_char(msg_index) :
    (msg_index == 10'd64)  ? "I" :
    (msg_index == 10'd65)  ? "L" :
    (msg_index == 10'd66)  ? ">" :
    (msg_index < 10'd787)  ? il_dump_byte :
    (msg_index == 10'd787) ? 8'h0d :
    (msg_index == 10'd788) ? 8'h0a :
    (msg_index == 10'd789) ? "L" :
    (msg_index == 10'd790) ? "Y" :
    (msg_index == 10'd791) ? ">" :
    (msg_index < 10'd952)  ? ly_dump_byte :
    (msg_index == 10'd952) ? 8'h0d : 8'h0a;

always @(posedge clk) begin
    if (!rst_n) begin
        reset_count <= reset_count + 13'd1;
    end
end

always @(posedge dclk or negedge rst_n) begin
    if (!rst_n) begin
        tx_data <= 8'd0;
        tx_valid <= 1'b0;
        msg_index <= 10'd0;
        report_active <= 1'b0;
        tx_state <= TX_ASSERT;
        report_gap_count <= 25'd0;
        il_r_w <= 6'd0; il_r_b <= 5'd0;
        ly_r_w <= 7'd0; ly_r_b <= 1'b0;
    end else begin
        if (meas_done && !report_active) begin
            if (report_gap_count == 25'd0) begin
                report_active <= 1'b1;
                msg_index <= 10'd0;
                tx_state <= TX_ASSERT;
                tx_valid <= 1'b0;
                il_r_w <= 6'd0; il_r_b <= 5'd0;
                ly_r_w <= 7'd0; ly_r_b <= 1'b0;
            end else begin
                report_gap_count <= report_gap_count - 25'd1;
                tx_valid <= 1'b0;
            end
        end else if (report_active) begin
            case (tx_state)
                TX_ASSERT: begin
                    if (msg_index < MSG_LEN) begin
                        if (tx_ready) begin
                            tx_data <= tx_char;
                            tx_valid <= 1'b1;
                            tx_state <= TX_WAIT_BUSY;
                        end else begin
                            tx_valid <= 1'b0;
                        end
                    end else begin
                        tx_valid <= 1'b0;
                        report_active <= 1'b0;
                        report_gap_count <= REPORT_GAP_RELOAD;
                    end
                end

                TX_WAIT_BUSY: begin
                    if (tx_busy) begin
                        tx_valid <= 1'b0;
                        tx_state <= TX_WAIT_IDLE;
                    end else begin
                        tx_valid <= 1'b1;
                    end
                end

                TX_WAIT_IDLE: begin
                    tx_valid <= 1'b0;
                    if (tx_ready) begin
                        msg_index <= msg_index + 10'd1;
                        // advance dump readout pointers with the byte index
                        if (msg_index >= 10'd67 && msg_index < 10'd786) begin
                            if (il_r_b == 5'd17) begin
                                il_r_b <= 5'd0;
                                il_r_w <= il_r_w + 6'd1;
                            end else begin
                                il_r_b <= il_r_b + 5'd1;
                            end
                        end
                        if (msg_index >= 10'd792 && msg_index < 10'd951) begin
                            ly_r_b <= !ly_r_b;
                            if (ly_r_b) ly_r_w <= ly_r_w + 7'd1;
                        end
                        tx_state <= TX_ASSERT;
                    end
                end

                default: begin
                    tx_valid <= 1'b0;
                    tx_state <= TX_ASSERT;
                end
            endcase
        end else begin
            tx_valid <= 1'b0;
        end
    end
end

endmodule
