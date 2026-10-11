// ============================================================================
// ip25k_top -- Tang Primer 25K (GW5A-LV25MG121NES) port-check image for the
// IP library that was qualified on the Tang Primer 20K (GW2A-18C).
//
// It hosts 13 packaged cores behind their existing golden selftest harnesses
// (w2_selftest subset + crypto_selftest) and reports every unit digest on
// UART.  Each harness folds its own FNV-1a digest, so the reported value is
// device-independent: a match proves the core behaves identically on GW5A.
//
// Report cycle, repeated every ~0.5 s once all units are done.  25 chars/line:
//   "U<ii> <TAG> <V> D=<8hex>   \r\n"   ii = wave2 unit index (hex)
//   "C<k>  <TAG> <V> D=<8hex>   \r\n"   k  = crypto unit index (hex)
//   "IP25K DONE dd pp PASS      \r\n"   (or FAIL)
//   V = P done+pass, F done+fail, X not done
//
// clk     : 50 MHz board osc (E2)
// uart_tx : C3, 115200 8N1
// led     : L6
// ============================================================================
module ip25k_top #(
    parameter integer CLK_DIV2 = 1,        // 1: whole design runs off a /2 FF (25 MHz)
    parameter [39:0]  W2_MASK  = 40'hE3_18_08_00_00,
    parameter [7:0]   CR_MASK  = 8'h1F,
    parameter integer CLK_FRE  = 25        // domain frequency seen by uart_tx
) (
    input  wire clk,
    output wire uart_tx,
    output wire led
);

    localparam [3:0] NUNITS  = 4'd13;      // 8 wave2 + 5 crypto
    localparam [4:0] LINELEN = 5'd25;
    localparam [24:0] GAP_RELOAD = 25'd12_500_000;

    // ---------------- domain clock / POR ------------------------------------
    reg div_q = 1'b0;
    always @(posedge clk) div_q <= ~div_q;
    wire dclk = (CLK_DIV2 != 0) ? div_q : clk;

    reg [13:0] reset_count = 14'd0;
    always @(posedge dclk) if (!rst_n) reset_count <= reset_count + 14'd1;
    wire rst_n = reset_count[13];           // ~0.67 ms POR, then held

    // ---------------- selftest harnesses (read-only reuse) -------------------
    wire        w2_done_all, w2_pass_all, w2_fail_any;
    wire [39:0] w2_done_mask, w2_pass_mask;
    reg  [5:0]  w2_sel;
    wire [31:0] w2_digest;

    wire        cr_done_all, cr_pass_all, cr_fail_any;
    wire [15:0] cr_done_mask, cr_pass_mask;
    reg  [4:0]  cr_sel;
    wire [31:0] cr_digest;

    w2_selftest #(.UNIT_EN(W2_MASK)) u_w2 (
        .clk(dclk), .rst_n(rst_n),
        .all_done(w2_done_all), .all_pass(w2_pass_all), .any_fail(w2_fail_any),
        .digest_sel(w2_sel), .digest_q(w2_digest),
        .done_mask(w2_done_mask), .pass_mask(w2_pass_mask)
    );

    crypto_selftest #(.UNIT_EN(CR_MASK)) u_cr (
        .clk(dclk), .rst_n(rst_n),
        .all_done(cr_done_all), .all_pass(cr_pass_all), .any_fail(cr_fail_any),
        .digest_sel(cr_sel), .digest_q(cr_digest),
        .done_mask(cr_done_mask), .pass_mask(cr_pass_mask)
    );

    wire all_done = w2_done_all && cr_done_all;
    wire all_pass = w2_pass_all && cr_pass_all;

    // ---------------- report walk -------------------------------------------
    reg [3:0]  line;
    reg [4:0]  pos;
    reg [31:0] dig_lat;
    reg [7:0]  tx_data;
    reg        tx_valid;
    wire       tx_ready, tx_busy;

    // line -> wave2 unit index (kept in sync with doc/UNIT_TABLE.md)
    function [5:0] w2_unit;
        input [3:0] l;
        begin
            case (l)
                4'd0: w2_unit = 6'd19;   // CRP  img_crop
                4'd1: w2_unit = 6'd27;   // PWM  pwm_gen
                4'd2: w2_unit = 6'd28;   // QEI  qei_dec
                4'd3: w2_unit = 6'd32;   // CRC  crc32_eth
                4'd4: w2_unit = 6'd33;   // PRBS prbs31
                4'd5: w2_unit = 6'd37;   // TMR  tmr_voter
                4'd6: w2_unit = 6'd38;   // WDT  wdt_win
                4'd7: w2_unit = 6'd39;   // LFSR lfsr_prng
                default: w2_unit = 6'd19;
            endcase
        end
    endfunction

    function [31:0] tag_field;
        input [3:0] l;
        begin
            case (l)
                4'd0:  tag_field = "CRP ";
                4'd1:  tag_field = "PWM ";
                4'd2:  tag_field = "QEI ";
                4'd3:  tag_field = "CRC ";
                4'd4:  tag_field = "PRBS";
                4'd5:  tag_field = "TMR ";
                4'd6:  tag_field = "WDT ";
                4'd7:  tag_field = "LFSR";
                4'd8:  tag_field = "AESB";
                4'd9:  tag_field = "SHAB";
                4'd10: tag_field = "CRC8";
                4'd11: tag_field = "CR16";
                4'd12: tag_field = "CR32";
                default: tag_field = "????";
            endcase
        end
    endfunction

    wire       u_done = (line < 4'd8) ? w2_done_mask[w2_unit(line)]
                                      : cr_done_mask[line - 4'd8];
    wire       u_pass = (line < 4'd8) ? w2_pass_mask[w2_unit(line)]
                                      : cr_pass_mask[line - 4'd8];
    wire [31:0] u_dig = (line < 4'd8) ? w2_digest : cr_digest;

    always @(*) begin
        if (line < 4'd8) begin
            w2_sel = w2_unit(line);
            cr_sel = 5'd0;
        end else begin
            w2_sel = 6'd19;
            cr_sel = {1'b0, line} - 5'd8;
        end
    end

    // done / pass totals for the summary line
    reg [7:0] cnt_done, cnt_pass;
    reg [7:0] si;
    always @(*) begin
        cnt_done = 8'd0;
        cnt_pass = 8'd0;
        for (si = 8'd0; si < 8'd8; si = si + 8'd1) begin
            if (w2_done_mask[w2_unit(si[3:0])]) begin
                cnt_done = cnt_done + 8'd1;
                if (w2_pass_mask[w2_unit(si[3:0])]) cnt_pass = cnt_pass + 8'd1;
            end
        end
        for (si = 8'd0; si < 8'd5; si = si + 8'd1) begin
            if (cr_done_mask[si[2:0]]) begin
                cnt_done = cnt_done + 8'd1;
                if (cr_pass_mask[si[2:0]]) cnt_pass = cnt_pass + 8'd1;
            end
        end
    end

    function [7:0] hexn;
        input [3:0] n;
        begin
            if (n < 4'd10) hexn = 8'h30 + n;
            else           hexn = 8'h41 + (n - 4'd10);
        end
    endfunction

    reg [5:0] idx_disp;
    reg [31:0] tf;
    reg [7:0] msg;

    always @(*) begin
        msg = 8'h20;
        idx_disp = 6'd0;
        tf = 32'h0;
        if (line == NUNITS) begin
            case (pos)
                5'd0:  msg = "I";
                5'd1:  msg = "P";
                5'd2:  msg = "2";
                5'd3:  msg = "5";
                5'd4:  msg = "K";
                5'd5:  msg = " ";
                5'd6:  msg = "D";
                5'd7:  msg = "O";
                5'd8:  msg = "N";
                5'd9:  msg = "E";
                5'd10: msg = " ";
                5'd11: msg = hexn(cnt_done[7:4]);
                5'd12: msg = hexn(cnt_done[3:0]);
                5'd13: msg = " ";
                5'd14: msg = "p";
                5'd15: msg = hexn(cnt_pass[7:4]);
                5'd16: msg = hexn(cnt_pass[3:0]);
                5'd17: msg = " ";
                5'd18: msg = all_pass ? "P" : "F";
                5'd19: msg = all_pass ? "A" : "A";
                5'd20: msg = all_pass ? "S" : "I";
                5'd21: msg = all_pass ? "S" : "L";
                5'd22: msg = " ";
                5'd23: msg = 8'h0d;
                5'd24: msg = 8'h0a;
                default: msg = 8'h20;
            endcase
        end else begin
            idx_disp = (line < 4'd8) ? w2_unit(line) : {2'b00, (line - 4'd8)};
            tf       = tag_field(line);
            case (pos)
                5'd0:  msg = (line < 4'd8) ? "U" : "C";
                5'd1:  msg = hexn(idx_disp[5:4]);
                5'd2:  msg = hexn(idx_disp[3:0]);
                5'd3:  msg = " ";
                5'd4:  msg = tf[31:24];
                5'd5:  msg = tf[23:16];
                5'd6:  msg = tf[15:8];
                5'd7:  msg = tf[7:0];
                5'd8:  msg = " ";
                5'd9:  msg = (!u_done) ? "X" : (u_pass ? "P" : "F");
                5'd10: msg = " ";
                5'd11: msg = "D";
                5'd12: msg = "=";
                5'd13: msg = hexn(dig_lat[31:28]);
                5'd14: msg = hexn(dig_lat[27:24]);
                5'd15: msg = hexn(dig_lat[23:20]);
                5'd16: msg = hexn(dig_lat[19:16]);
                5'd17: msg = hexn(dig_lat[15:12]);
                5'd18: msg = hexn(dig_lat[11:8]);
                5'd19: msg = hexn(dig_lat[7:4]);
                5'd20: msg = hexn(dig_lat[3:0]);
                5'd21: msg = " ";
                5'd22: msg = " ";
                5'd23: msg = 8'h0d;
                5'd24: msg = 8'h0a;
                default: msg = 8'h20;
            endcase
        end
    end

    // ---------------- emit FSM ----------------------------------------------
    localparam [1:0] S_GAP = 2'd0, S_SET = 2'd1, S_HAND = 2'd2;
    reg [1:0]  st;
    reg [24:0] gap;
    wire last_char  = (pos == LINELEN - 5'd1);
    wire last_line  = (line == NUNITS);

    always @(posedge dclk or negedge rst_n) begin
        if (!rst_n) begin
            st <= S_GAP;  line <= 4'd0;  pos <= 5'd0;
            tx_data <= 8'h20; tx_valid <= 1'b0;
            dig_lat <= 32'h0; gap <= 25'd0;
        end else begin
            case (st)
                S_GAP: begin
                    tx_valid <= 1'b0;
                    if (!all_done) begin
                        gap <= 25'd0;
                    end else if (gap >= GAP_RELOAD) begin
                        gap  <= 25'd0;
                        line <= 4'd0;
                        pos  <= 5'd0;
                        st   <= S_SET;
                    end else begin
                        gap <= gap + 25'd1;
                    end
                end
                S_SET: begin
                    tx_data  <= msg;
                    tx_valid <= 1'b1;
                    if (pos == 5'd8) dig_lat <= u_dig;
                    st <= S_HAND;
                end
                S_HAND: begin
                    if (tx_ready) begin
                        tx_valid <= 1'b0;
                        pos <= last_char ? 5'd0 : (pos + 5'd1);
                        if (last_char) begin
                            if (last_line) st <= S_GAP;
                            else           st <= S_SET;
                            line <= line + 4'd1;
                        end else begin
                            st <= S_SET;
                        end
                    end
                end
                default: st <= S_GAP;
            endcase
        end
    end

    uart_tx #(
        .CLK_FRE(CLK_FRE),
        .BAUD_RATE(115200)
    ) u_uart (
        .clk(dclk), .rst_n(rst_n),
        .tx_data(tx_data), .tx_data_valid(tx_valid), .tx_data_ready(tx_ready),
        .tx_pin(uart_tx), .tx_busy(tx_busy)
    );

    assign led = (~all_done) | tx_busy;

endmodule
