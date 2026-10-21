module top (
    input  wire clk,
    output wire uart_tx_pin,
    output wire status_pass,
    output wire status_fail
);

localparam integer MSG_LEN = 87;
localparam [24:0] REPORT_GAP_RELOAD = 25'd13_500_000;
localparam [1:0] TX_ASSERT    = 2'd0;
localparam [1:0] TX_WAIT_BUSY = 2'd1;
localparam [1:0] TX_WAIT_IDLE = 2'd2;

reg [12:0] reset_count = 13'd0;
wire rst_n = reset_count[12];

wire arith_done;
wire arith_pass;
wire arith_fail;
wire [15:0] arith_bubble_count;
wire [15:0] arith_issue_count;
wire [15:0] arith_output_count;
wire [31:0] arith_signature;
wire [31:0] arith_dbg_kem_ntt_digest;
wire [31:0] arith_dbg_dsa_ntt_digest;
wire [31:0] arith_dbg_kem_intt_digest;
wire [31:0] arith_dbg_dsa_intt_digest;

reg [7:0] tx_data;
reg tx_valid;
wire tx_ready;
wire tx_busy;

reg [7:0] msg_index;
reg report_active;
reg [1:0] tx_state;
reg [24:0] report_gap_count;

uart_tx #(
    .CLK_FRE(27),
    .BAUD_RATE(115200)
) uart (
    .clk(clk),
    .rst_n(rst_n),
    .tx_data(tx_data),
    .tx_data_valid(tx_valid),
    .tx_data_ready(tx_ready),
    .tx_pin(uart_tx_pin),
    .tx_busy(tx_busy)
);

ntt256_systolic_state_equiv_monitor state_equiv_monitor (
    .clk(clk),
    .rst_n(rst_n),
    .done(arith_done),
    .pass(arith_pass),
    .fail(arith_fail),
    .bubble_count(arith_bubble_count),
    .issue_count(arith_issue_count),
    .output_count(arith_output_count),
    .signature(arith_signature),
    .dbg_kem_ntt_digest(arith_dbg_kem_ntt_digest),
    .dbg_dsa_ntt_digest(arith_dbg_dsa_ntt_digest),
    .dbg_kem_intt_digest(arith_dbg_kem_intt_digest),
    .dbg_dsa_intt_digest(arith_dbg_dsa_intt_digest)
);

assign status_pass = arith_done && arith_pass && !arith_fail;
assign status_fail = arith_done && arith_fail;

function [7:0] hex_nibble;
    input [3:0] value;
    begin
        if (value < 4'd10) begin
            hex_nibble = 8'h30 + value;
        end else begin
            hex_nibble = 8'h41 + (value - 4'd10);
        end
    end
endfunction

function [7:0] report_char;
    input [7:0] index;
    input pass;
    input [31:0] signature_value;
    input [15:0] bubble_value;
    input [15:0] issue_value;
    input [31:0] kem_ntt_value;
    input [31:0] dsa_ntt_value;
    input [31:0] kem_intt_value;
    input [31:0] dsa_intt_value;
    begin
        case (index)
            8'd0: report_char = "S";
            8'd1: report_char = "Y";
            8'd2: report_char = "S";
            8'd3: report_char = "T";
            8'd4: report_char = " ";
            8'd5: report_char = pass ? "P" : "F";
            8'd6: report_char = pass ? "A" : "A";
            8'd7: report_char = pass ? "S" : "I";
            8'd8: report_char = pass ? "S" : "L";
            8'd9: report_char = " ";
            8'd10: report_char = "D";
            8'd11: report_char = "=";
            8'd12: report_char = hex_nibble(signature_value[31:28]);
            8'd13: report_char = hex_nibble(signature_value[27:24]);
            8'd14: report_char = hex_nibble(signature_value[23:20]);
            8'd15: report_char = hex_nibble(signature_value[19:16]);
            8'd16: report_char = hex_nibble(signature_value[15:12]);
            8'd17: report_char = hex_nibble(signature_value[11:8]);
            8'd18: report_char = hex_nibble(signature_value[7:4]);
            8'd19: report_char = hex_nibble(signature_value[3:0]);
            8'd20: report_char = " ";
            8'd21: report_char = "B";
            8'd22: report_char = "=";
            8'd23: report_char = hex_nibble(bubble_value[15:12]);
            8'd24: report_char = hex_nibble(bubble_value[11:8]);
            8'd25: report_char = hex_nibble(bubble_value[7:4]);
            8'd26: report_char = hex_nibble(bubble_value[3:0]);
            8'd27: report_char = " ";
            8'd28: report_char = "I";
            8'd29: report_char = "=";
            8'd30: report_char = hex_nibble(issue_value[15:12]);
            8'd31: report_char = hex_nibble(issue_value[11:8]);
            8'd32: report_char = hex_nibble(issue_value[7:4]);
            8'd33: report_char = hex_nibble(issue_value[3:0]);
            8'd34: report_char = 8'h0d;
            8'd35: report_char = 8'h0a;
            8'd36: report_char = "D";
            8'd37: report_char = "B";
            8'd38: report_char = "G";
            8'd39: report_char = " ";
            8'd40: report_char = "K";
            8'd41: report_char = "=";
            8'd42: report_char = hex_nibble(kem_ntt_value[31:28]);
            8'd43: report_char = hex_nibble(kem_ntt_value[27:24]);
            8'd44: report_char = hex_nibble(kem_ntt_value[23:20]);
            8'd45: report_char = hex_nibble(kem_ntt_value[19:16]);
            8'd46: report_char = hex_nibble(kem_ntt_value[15:12]);
            8'd47: report_char = hex_nibble(kem_ntt_value[11:8]);
            8'd48: report_char = hex_nibble(kem_ntt_value[7:4]);
            8'd49: report_char = hex_nibble(kem_ntt_value[3:0]);
            8'd50: report_char = " ";
            8'd51: report_char = "D";
            8'd52: report_char = "=";
            8'd53: report_char = hex_nibble(dsa_ntt_value[31:28]);
            8'd54: report_char = hex_nibble(dsa_ntt_value[27:24]);
            8'd55: report_char = hex_nibble(dsa_ntt_value[23:20]);
            8'd56: report_char = hex_nibble(dsa_ntt_value[19:16]);
            8'd57: report_char = hex_nibble(dsa_ntt_value[15:12]);
            8'd58: report_char = hex_nibble(dsa_ntt_value[11:8]);
            8'd59: report_char = hex_nibble(dsa_ntt_value[7:4]);
            8'd60: report_char = hex_nibble(dsa_ntt_value[3:0]);
            8'd61: report_char = " ";
            8'd62: report_char = "K";
            8'd63: report_char = "I";
            8'd64: report_char = "=";
            8'd65: report_char = hex_nibble(kem_intt_value[31:28]);
            8'd66: report_char = hex_nibble(kem_intt_value[27:24]);
            8'd67: report_char = hex_nibble(kem_intt_value[23:20]);
            8'd68: report_char = hex_nibble(kem_intt_value[19:16]);
            8'd69: report_char = hex_nibble(kem_intt_value[15:12]);
            8'd70: report_char = hex_nibble(kem_intt_value[11:8]);
            8'd71: report_char = hex_nibble(kem_intt_value[7:4]);
            8'd72: report_char = hex_nibble(kem_intt_value[3:0]);
            8'd73: report_char = " ";
            8'd74: report_char = "D";
            8'd75: report_char = "I";
            8'd76: report_char = "=";
            8'd77: report_char = hex_nibble(dsa_intt_value[31:28]);
            8'd78: report_char = hex_nibble(dsa_intt_value[27:24]);
            8'd79: report_char = hex_nibble(dsa_intt_value[23:20]);
            8'd80: report_char = hex_nibble(dsa_intt_value[19:16]);
            8'd81: report_char = hex_nibble(dsa_intt_value[15:12]);
            8'd82: report_char = hex_nibble(dsa_intt_value[11:8]);
            8'd83: report_char = hex_nibble(dsa_intt_value[7:4]);
            8'd84: report_char = hex_nibble(dsa_intt_value[3:0]);
            8'd85: report_char = 8'h0d;
            8'd86: report_char = 8'h0a;
            default: report_char = 8'h00;
        endcase
    end
endfunction

always @(posedge clk) begin
    if (!rst_n) begin
        reset_count <= reset_count + 13'd1;
    end
end

always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        tx_data <= 8'd0;
        tx_valid <= 1'b0;
        msg_index <= 8'd0;
        report_active <= 1'b0;
        tx_state <= TX_ASSERT;
        report_gap_count <= 25'd0;
    end else begin
        if (arith_done && !report_active) begin
            if (report_gap_count == 25'd0) begin
                report_active <= 1'b1;
                msg_index <= 8'd0;
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
                            tx_data <= report_char(
                                msg_index,
                                arith_pass && !arith_fail,
                                arith_signature,
                                arith_bubble_count,
                                arith_issue_count,
                                arith_dbg_kem_ntt_digest,
                                arith_dbg_dsa_ntt_digest,
                                arith_dbg_kem_intt_digest,
                                arith_dbg_dsa_intt_digest
                            );
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
                    if (!tx_busy) begin
                        msg_index <= msg_index + 8'd1;
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
