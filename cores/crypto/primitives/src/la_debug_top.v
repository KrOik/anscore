// la_debug_top.v -- board debug variant: identical selftest + report FSM as
// top.v, with internal signals mirrored to the fx2lafw LA header pins so the
// UART report can be captured/decoded even when the FTDI COM path is broken.
//   D0=A11 uart_tx   D1=B11 all_done   D2=N6 status_pass   D3=D11 status_fail
//   D4=N9 ce         D5=N7 rst_n       D6=L9 tx_busy       D7=N8 heartbeat
module la_debug_top #(
    parameter [7:0] UNIT_EN = 8'h1F
) (
    input  wire clk,
    output wire dbg_uart,
    output wire dbg_done,
    output wire dbg_pass,
    output wire dbg_fail,
    output wire dbg_ce,
    output wire dbg_rstn,
    output wire dbg_busy,
    output wire dbg_hb,
    output wire uart_tx
);

localparam integer MSG_LEN = 192;
localparam [24:0] REPORT_GAP_RELOAD = 25'd13_500_000;
localparam [1:0] TX_ASSERT    = 2'd0;
localparam [1:0] TX_WAIT_BUSY = 2'd1;
localparam [1:0] TX_WAIT_IDLE = 2'd2;

reg [12:0] reset_count = 13'd0;
wire rst_n = reset_count[12];

wire all_done, all_pass, any_fail;
wire [15:0] done_mask, pass_mask;
wire [31:0] digest_q;
wire [4:0]  digest_sel;

reg [7:0] tx_data;
reg tx_valid;
wire tx_ready;
wire tx_busy;

reg [9:0] msg_index;
reg report_active;
reg [1:0] tx_state;
reg [24:0] report_gap_count;

assign digest_sel = (msg_index >= 10'd32) ? {1'b0, (msg_index - 10'd32) >> 5} : 5'd0;

crypto_selftest #(.UNIT_EN(UNIT_EN)) selftest (
    .clk(clk), .rst_n(rst_n),
    .all_done(all_done), .all_pass(all_pass), .any_fail(any_fail),
    .digest_sel(digest_sel), .digest_q(digest_q),
    .done_mask(done_mask), .pass_mask(pass_mask)
);

uart_tx #(.CLK_FRE(27), .BAUD_RATE(115200)) uart (
    .clk(clk), .rst_n(rst_n),
    .tx_data(tx_data), .tx_data_valid(tx_valid),
    .tx_data_ready(tx_ready), .tx_pin(uart_tx), .tx_busy(tx_busy)
);

function [7:0] hex_nibble;
    input [3:0] value;
    begin
        if (value < 4'd10) hex_nibble = 8'h30 + value;
        else               hex_nibble = 8'h41 + (value - 4'd10);
    end
endfunction

function [31:0] unit_name;
    input [3:0] u;
    begin
        case (u)
            4'd0:  unit_name = "AESB";
            4'd1:  unit_name = "SHAB";
            4'd2:  unit_name = "CRC8";
            4'd3:  unit_name = "CR16";
            4'd4:  unit_name = "CR32";
            default: unit_name = "????";
        endcase
    end
endfunction

function [7:0] report_char;
    input [9:0]  index;
    input [15:0] done_v;
    input [15:0] pass_v;
    input [31:0] dg;
    reg [3:0]  unit;
    reg [4:0]  pos;
    reg [31:0] nm;
    begin
        unit = (index - 10'd32) >> 5;
        pos  = (index - 10'd32) & 5'd31;
        nm   = unit_name(unit);
        if (index < 10'd32) begin
            case (index)
                10'd0:  report_char = "C";
                10'd1:  report_char = "R";
                10'd2:  report_char = "Y";
                10'd3:  report_char = "P";
                10'd4:  report_char = "T";
                10'd5:  report_char = " ";
                10'd6:  report_char = "M";
                10'd7:  report_char = "=";
                10'd8:  report_char = hex_nibble(done_v[15:12]);
                10'd9:  report_char = hex_nibble(done_v[11:8]);
                10'd10: report_char = hex_nibble(done_v[7:4]);
                10'd11: report_char = hex_nibble(done_v[3:0]);
                10'd12: report_char = " ";
                10'd13: report_char = "P";
                10'd14: report_char = "=";
                10'd15: report_char = hex_nibble(pass_v[15:12]);
                10'd16: report_char = hex_nibble(pass_v[11:8]);
                10'd17: report_char = hex_nibble(pass_v[7:4]);
                10'd18: report_char = hex_nibble(pass_v[3:0]);
                10'd30: report_char = 8'h0d;
                10'd31: report_char = 8'h0a;
                default: report_char = " ";
            endcase
        end else begin
            case (pos)
                5'd0:  report_char = "U";
                5'd1:  report_char = hex_nibble(unit);
                5'd2:  report_char = " ";
                5'd3:  report_char = nm[31:24];
                5'd4:  report_char = nm[23:16];
                5'd5:  report_char = nm[15:8];
                5'd6:  report_char = nm[7:0];
                5'd7:  report_char = " ";
                5'd8:  report_char = !UNIT_EN[unit] ? "S" :
                                     (pass_v[unit] ? "P" : (done_v[unit] ? "F" : "X"));
                5'd9:  report_char = " ";
                5'd10: report_char = "D";
                5'd11: report_char = "=";
                5'd12: report_char = hex_nibble(dg[31:28]);
                5'd13: report_char = hex_nibble(dg[27:24]);
                5'd14: report_char = hex_nibble(dg[23:20]);
                5'd15: report_char = hex_nibble(dg[19:16]);
                5'd16: report_char = hex_nibble(dg[15:12]);
                5'd17: report_char = hex_nibble(dg[11:8]);
                5'd18: report_char = hex_nibble(dg[7:4]);
                5'd19: report_char = hex_nibble(dg[3:0]);
                5'd30: report_char = 8'h0d;
                5'd31: report_char = 8'h0a;
                default: report_char = " ";
            endcase
        end
    end
endfunction

always @(posedge clk) begin
    if (!rst_n) reset_count <= reset_count + 13'd1;
end

always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        tx_data <= 8'd0;
        tx_valid <= 1'b0;
        msg_index <= 10'd0;
        report_active <= 1'b0;
        tx_state <= TX_ASSERT;
        report_gap_count <= 25'd0;
    end else begin
        if (all_done && !report_active) begin
            if (report_gap_count == 25'd0) begin
                report_active <= 1'b1;
                msg_index <= 10'd0;
                tx_state <= TX_ASSERT;
                tx_valid <= 1'b0;
            end else begin
                report_gap_count <= report_gap_count - 25'd1;
                tx_valid <= 1'b0;
            end
        end else if (report_active) begin
            case (tx_state)
                TX_ASSERT: begin
                    if (msg_index < MSG_LEN) begin
                        if (tx_ready) begin
                            tx_data <= report_char(msg_index, done_mask, pass_mask, digest_q);
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

reg [23:0] hb_cnt = 24'd0;
always @(posedge clk) hb_cnt <= hb_cnt + 24'd1;

assign dbg_uart = uart_tx;
assign dbg_done = all_done;
assign dbg_pass = all_done && all_pass;
assign dbg_fail = all_done && any_fail;
assign dbg_ce   = selftest.ce;
assign dbg_rstn = rst_n;
assign dbg_busy = tx_busy;
assign dbg_hb   = hb_cnt[23];

endmodule
