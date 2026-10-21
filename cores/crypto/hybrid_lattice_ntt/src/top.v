module top (
    input  wire clk,
    output wire uart_tx_pin,
    output wire status_pass,
    output wire status_fail
);

localparam integer MSG_LEN = 194;
localparam [24:0] REPORT_GAP_RELOAD = 25'd13_500_000;
localparam [1:0] TX_ASSERT    = 2'd0;
localparam [1:0] TX_WAIT_BUSY = 2'd1;
localparam [1:0] TX_WAIT_IDLE = 2'd2;

reg [12:0] reset_count = 13'd0;
wire rst_n = reset_count[12];

wire test_done;
wire test_pass;
wire test_fail;
wire [1:0] phase;
wire [31:0] cycle_count;
wire [31:0] digest;
wire [31:0] kem_ntt_digest;
wire [31:0] dsa_ntt_digest;
wire [31:0] kem_intt_digest;
wire [31:0] dsa_intt_digest;
wire [31:0] kem_flow_digest;
wire [31:0] dsa_flow_digest;
wire [31:0] ops_digest;
wire pipe_done;
wire pipe_pass;
wire pipe_fail;
wire [15:0] pipe_bubble_count;
wire [15:0] pipe_issue_count;
wire [15:0] pipe_pair_mask;
wire [31:0] pipe_signature;
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
wire report_pass;

reg [7:0] tx_data;
reg tx_valid;
wire tx_ready;
wire tx_busy;

reg [7:0] msg_index;
reg report_active;
reg [1:0] tx_state;
reg [24:0] report_gap_count;

hybrid_ntt256_selftest selftest (
    .clk(clk),
    .rst_n(rst_n),
    .test_done(test_done),
    .test_pass(test_pass),
    .test_fail(test_fail),
    .phase(phase),
    .cycle_count(cycle_count),
    .digest(digest),
    .kem_ntt_digest(kem_ntt_digest),
    .dsa_ntt_digest(dsa_ntt_digest),
    .kem_intt_digest(kem_intt_digest),
    .dsa_intt_digest(dsa_intt_digest),
    .kem_flow_digest(kem_flow_digest),
    .dsa_flow_digest(dsa_flow_digest)
);

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

ntt256_systolic_stream_selftest pipe_selftest (
    .clk(clk),
    .rst_n(rst_n),
    .done(pipe_done),
    .pass(pipe_pass),
    .fail(pipe_fail),
    .bubble_count(pipe_bubble_count),
    .issue_count(pipe_issue_count),
    .pair_mask(pipe_pair_mask),
    .signature(pipe_signature)
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

assign report_pass = test_done && test_pass && !test_fail &&
    pipe_done && pipe_pass && !pipe_fail &&
    arith_done && arith_pass && !arith_fail;
assign status_pass = report_pass;
assign status_fail = (test_done && test_fail) || (pipe_done && pipe_fail) ||
    (arith_done && arith_fail);
assign ops_digest = kem_ntt_digest ^ dsa_ntt_digest ^ kem_intt_digest ^ dsa_intt_digest ^ 32'h4f505334;

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
    input [31:0] digest_value;
    input [31:0] cycles_value;
    input [31:0] ops_digest_value;
    input [31:0] kem_flow_digest_value;
    input [31:0] dsa_flow_digest_value;
    input [15:0] pipe_bubble_value;
    input [15:0] pipe_pair_value;
    input [31:0] arith_signature_value;
    input [15:0] arith_bubble_value;
    input [15:0] arith_pair_value;
    input [31:0] arith_dbg_kem_ntt_value;
    input [31:0] arith_dbg_dsa_ntt_value;
    input [31:0] arith_dbg_kem_intt_value;
    input [31:0] arith_dbg_dsa_intt_value;
    begin
        case (index)
            7'd0: report_char = "N";
            7'd1: report_char = "2";
            7'd2: report_char = "5";
            7'd3: report_char = "6";
            7'd4: report_char = " ";
            7'd5: report_char = pass ? "P" : "F";
            7'd6: report_char = pass ? "A" : "A";
            7'd7: report_char = pass ? "S" : "I";
            7'd8: report_char = pass ? "S" : "L";
            7'd9: report_char = " ";
            7'd10: report_char = "D";
            7'd11: report_char = "=";
            7'd12: report_char = hex_nibble(digest_value[31:28]);
            7'd13: report_char = hex_nibble(digest_value[27:24]);
            7'd14: report_char = hex_nibble(digest_value[23:20]);
            7'd15: report_char = hex_nibble(digest_value[19:16]);
            7'd16: report_char = hex_nibble(digest_value[15:12]);
            7'd17: report_char = hex_nibble(digest_value[11:8]);
            7'd18: report_char = hex_nibble(digest_value[7:4]);
            7'd19: report_char = hex_nibble(digest_value[3:0]);
            7'd20: report_char = " ";
            7'd21: report_char = "C";
            7'd22: report_char = "=";
            7'd23: report_char = hex_nibble(cycles_value[31:28]);
            7'd24: report_char = hex_nibble(cycles_value[27:24]);
            7'd25: report_char = hex_nibble(cycles_value[23:20]);
            7'd26: report_char = hex_nibble(cycles_value[19:16]);
            7'd27: report_char = hex_nibble(cycles_value[15:12]);
            7'd28: report_char = hex_nibble(cycles_value[11:8]);
            7'd29: report_char = hex_nibble(cycles_value[7:4]);
            7'd30: report_char = hex_nibble(cycles_value[3:0]);
            7'd31: report_char = 8'h0d;
            7'd32: report_char = 8'h0a;
            7'd33: report_char = "O";
            7'd34: report_char = "P";
            7'd35: report_char = "S";
            7'd36: report_char = "4";
            7'd37: report_char = " ";
            7'd38: report_char = pass ? "P" : "F";
            7'd39: report_char = pass ? "A" : "A";
            7'd40: report_char = pass ? "S" : "I";
            7'd41: report_char = pass ? "S" : "L";
            7'd42: report_char = " ";
            7'd43: report_char = "D";
            7'd44: report_char = "=";
            7'd45: report_char = hex_nibble(ops_digest_value[31:28]);
            7'd46: report_char = hex_nibble(ops_digest_value[27:24]);
            7'd47: report_char = hex_nibble(ops_digest_value[23:20]);
            7'd48: report_char = hex_nibble(ops_digest_value[19:16]);
            7'd49: report_char = hex_nibble(ops_digest_value[15:12]);
            7'd50: report_char = hex_nibble(ops_digest_value[11:8]);
            7'd51: report_char = hex_nibble(ops_digest_value[7:4]);
            7'd52: report_char = hex_nibble(ops_digest_value[3:0]);
            7'd53: report_char = 8'h0d;
            7'd54: report_char = 8'h0a;
            7'd55: report_char = "F";
            7'd56: report_char = "L";
            7'd57: report_char = "O";
            7'd58: report_char = "W";
            7'd59: report_char = " ";
            7'd60: report_char = pass ? "P" : "F";
            7'd61: report_char = pass ? "A" : "A";
            7'd62: report_char = pass ? "S" : "I";
            7'd63: report_char = pass ? "S" : "L";
            7'd64: report_char = " ";
            7'd65: report_char = "K";
            7'd66: report_char = "=";
            7'd67: report_char = hex_nibble(kem_flow_digest_value[31:28]);
            7'd68: report_char = hex_nibble(kem_flow_digest_value[27:24]);
            7'd69: report_char = hex_nibble(kem_flow_digest_value[23:20]);
            7'd70: report_char = hex_nibble(kem_flow_digest_value[19:16]);
            7'd71: report_char = hex_nibble(kem_flow_digest_value[15:12]);
            7'd72: report_char = hex_nibble(kem_flow_digest_value[11:8]);
            7'd73: report_char = hex_nibble(kem_flow_digest_value[7:4]);
            7'd74: report_char = hex_nibble(kem_flow_digest_value[3:0]);
            7'd75: report_char = " ";
            7'd76: report_char = "D";
            7'd77: report_char = "=";
            7'd78: report_char = hex_nibble(dsa_flow_digest_value[31:28]);
            7'd79: report_char = hex_nibble(dsa_flow_digest_value[27:24]);
            7'd80: report_char = hex_nibble(dsa_flow_digest_value[23:20]);
            7'd81: report_char = hex_nibble(dsa_flow_digest_value[19:16]);
            7'd82: report_char = hex_nibble(dsa_flow_digest_value[15:12]);
            7'd83: report_char = hex_nibble(dsa_flow_digest_value[11:8]);
            7'd84: report_char = hex_nibble(dsa_flow_digest_value[7:4]);
            7'd85: report_char = hex_nibble(dsa_flow_digest_value[3:0]);
            7'd86: report_char = 8'h0d;
            7'd87: report_char = 8'h0a;
            7'd88: report_char = "P";
            7'd89: report_char = "I";
            7'd90: report_char = "P";
            7'd91: report_char = "E";
            7'd92: report_char = " ";
            7'd93: report_char = pass ? "P" : "F";
            7'd94: report_char = pass ? "A" : "A";
            7'd95: report_char = pass ? "S" : "I";
            7'd96: report_char = pass ? "S" : "L";
            7'd97: report_char = " ";
            7'd98: report_char = "B";
            7'd99: report_char = "=";
            7'd100: report_char = hex_nibble(pipe_bubble_value[15:12]);
            7'd101: report_char = hex_nibble(pipe_bubble_value[11:8]);
            7'd102: report_char = hex_nibble(pipe_bubble_value[7:4]);
            7'd103: report_char = hex_nibble(pipe_bubble_value[3:0]);
            7'd104: report_char = " ";
            7'd105: report_char = "P";
            7'd106: report_char = "=";
            7'd107: report_char = hex_nibble(pipe_pair_value[15:12]);
            7'd108: report_char = hex_nibble(pipe_pair_value[11:8]);
            7'd109: report_char = hex_nibble(pipe_pair_value[7:4]);
            7'd110: report_char = hex_nibble(pipe_pair_value[3:0]);
            7'd111: report_char = 8'h0d;
            7'd112: report_char = 8'h0a;
            7'd113: report_char = "S";
            7'd114: report_char = "Y";
            7'd115: report_char = "S";
            7'd116: report_char = "T";
            7'd117: report_char = " ";
            7'd118: report_char = pass ? "P" : "F";
            7'd119: report_char = pass ? "A" : "A";
            7'd120: report_char = pass ? "S" : "I";
            7'd121: report_char = pass ? "S" : "L";
            7'd122: report_char = " ";
            7'd123: report_char = "D";
            7'd124: report_char = "=";
            7'd125: report_char = hex_nibble(arith_signature_value[31:28]);
            7'd126: report_char = hex_nibble(arith_signature_value[27:24]);
            7'd127: report_char = hex_nibble(arith_signature_value[23:20]);
            8'd128: report_char = hex_nibble(arith_signature_value[19:16]);
            8'd129: report_char = hex_nibble(arith_signature_value[15:12]);
            8'd130: report_char = hex_nibble(arith_signature_value[11:8]);
            8'd131: report_char = hex_nibble(arith_signature_value[7:4]);
            8'd132: report_char = hex_nibble(arith_signature_value[3:0]);
            8'd133: report_char = " ";
            8'd134: report_char = "B";
            8'd135: report_char = "=";
            8'd136: report_char = hex_nibble(arith_bubble_value[15:12]);
            8'd137: report_char = hex_nibble(arith_bubble_value[11:8]);
            8'd138: report_char = hex_nibble(arith_bubble_value[7:4]);
            8'd139: report_char = hex_nibble(arith_bubble_value[3:0]);
            8'd140: report_char = " ";
            8'd141: report_char = "I";
            8'd142: report_char = "=";
            8'd143: report_char = hex_nibble(arith_pair_value[15:12]);
            8'd144: report_char = hex_nibble(arith_pair_value[11:8]);
            8'd145: report_char = hex_nibble(arith_pair_value[7:4]);
            8'd146: report_char = hex_nibble(arith_pair_value[3:0]);
            8'd147: report_char = 8'h0d;
            8'd148: report_char = 8'h0a;
            8'd149: report_char = "F";
            8'd150: report_char = "U";
            8'd151: report_char = "L";
            8'd152: report_char = "L";
            8'd153: report_char = " ";
            8'd154: report_char = pass ? "P" : "F";
            8'd155: report_char = pass ? "A" : "A";
            8'd156: report_char = pass ? "S" : "I";
            8'd157: report_char = pass ? "S" : "L";
            8'd158: report_char = " ";
            8'd159: report_char = "D";
            8'd160: report_char = "=";
            8'd161: report_char = "C";
            8'd162: report_char = "4";
            8'd163: report_char = "0";
            8'd164: report_char = "9";
            8'd165: report_char = "0";
            8'd166: report_char = "C";
            8'd167: report_char = "1";
            8'd168: report_char = "7";
            8'd169: report_char = " ";
            8'd170: report_char = "B";
            8'd171: report_char = "=";
            8'd172: report_char = hex_nibble(arith_bubble_value[15:12]);
            8'd173: report_char = hex_nibble(arith_bubble_value[11:8]);
            8'd174: report_char = hex_nibble(arith_bubble_value[7:4]);
            8'd175: report_char = hex_nibble(arith_bubble_value[3:0]);
            8'd176: report_char = " ";
            8'd177: report_char = "O";
            8'd178: report_char = "=";
            8'd179: report_char = "0";
            8'd180: report_char = "C";
            8'd181: report_char = "0";
            8'd182: report_char = "0";
            8'd183: report_char = " ";
            8'd184: report_char = "L";
            8'd185: report_char = "=";
            8'd186: report_char = "0";
            8'd187: report_char = "0";
            8'd188: report_char = "1";
            8'd189: report_char = "7";
            8'd190: report_char = 8'h0d;
            8'd191: report_char = 8'h0a;
            8'd192: report_char = 8'h0d;
            8'd193: report_char = 8'h0a;
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
        msg_index <= 7'd0;
        report_active <= 1'b0;
        tx_state <= TX_ASSERT;
        report_gap_count <= 25'd0;
    end else begin
        if (test_done && pipe_done && arith_done && !report_active) begin
            if (report_gap_count == 25'd0) begin
                report_active <= 1'b1;
                msg_index <= 7'd0;
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
                                report_pass,
                                digest,
                                cycle_count,
                                ops_digest,
                                kem_flow_digest,
                                dsa_flow_digest,
                                pipe_bubble_count,
                                pipe_pair_mask,
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
                    if (tx_ready) begin
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
