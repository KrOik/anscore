// Silicon semantics probe for the GW5A MULT12X12 hard multiplier.
//
// The OSS flow keeps this cell only when it is instantiated directly (see
// gw5a_hardip2), and the vendor deck declares it as a black box, so nothing in
// simulation says what the cell ACTUALLY computes.  This design streams the
// product of a fixed operand table over the dock UART; the host compares the
// silicon bytes against a model and thereby measures operand signedness,
// effective width and pipeline behaviour.
//
// Frame: one 0xA5 header byte, then for each of TAB_LEN entries the three
// bytes of its 24-bit product, LSB byte first.  115200 8N1, 434 clk/bit.
`default_nettype none

module mul12_silicon_probe(input wire clk, output wire uart_tx);
    localparam integer TAB_LEN = 10;
    localparam integer MSG_LEN = 1 + 3 * TAB_LEN;      // 31 bytes
    localparam CLKS_PER_BIT = 434;
`ifdef MULPROBE_FAST_PACE
    // sim hook only: 0.4 ms/byte keeps a whole frame inside a testbench run
    localparam [24:0] PACE = 25'd20_000;
`else
    localparam [24:0] PACE = 25'd5_000_000;            // 0.1 s per byte
`endif

    function [11:0] op_a;
        input [3:0] i;
        case (i)
            4'd0: op_a = 12'h003;   //   3
            4'd1: op_a = 12'h0FF;   // 255
            4'd2: op_a = 12'h3FF;   //1023
            4'd3: op_a = 12'h800;   // -2048 if signed
            4'd4: op_a = 12'hFFF;   //    -1 if signed
            4'd5: op_a = 12'h001;
            4'd6: op_a = 12'h7FF;
            4'd7: op_a = 12'hAAA;   // -1336 if signed
            4'd8: op_a = 12'h555;
            default: op_a = 12'h02B;
        endcase
    endfunction

    function [11:0] op_b;
        input [3:0] i;
        case (i)
            4'd0: op_b = 12'h003;
            4'd1: op_b = 12'h002;
            4'd2: op_b = 12'h004;
            4'd3: op_b = 12'h003;
            4'd4: op_b = 12'h003;
            4'd5: op_b = 12'h800;   // signedness discriminator, low side
            4'd6: op_b = 12'h002;
            4'd7: op_b = 12'h003;
            4'd8: op_b = 12'h003;
            default: op_b = 12'h00D;
        endcase
    endfunction

    // entry whose operands must be presented while byte p is sent: the product
    // for byte p is captured during byte p-1, so p itself selects the entry
    function [3:0] entry_for;
        input [5:0] p;
        entry_for = (p == 6'd0) ? 4'd0 : ((p - 6'd1) / 6'd3);
    endfunction

    reg [5:0]  pos = 6'd0;
    reg [11:0] a_r = op_a(4'd0);
    reg [11:0] b_r = op_b(4'd0);
    wire [23:0] p_raw;
    reg  [23:0] p_q = 24'd0;

    MULT12X12 #(.AREG_CLK("BYPASS"), .BREG_CLK("BYPASS"),
                .PREG_CLK("BYPASS"), .OREG_CLK("BYPASS")) dut (
        .DOUT(p_raw), .A(a_r), .B(b_r),
        .CLK({clk, clk}), .CE(2'b11), .RESET(2'b00)
    );
    always @(posedge clk) p_q <= p_raw;

    reg [7:0] byte_out;
    always @(*) begin
        case (pos)
            6'd0:    byte_out = 8'hA5;
            6'd1:    byte_out = p_q[7:0];
            6'd2:    byte_out = p_q[15:8];
            6'd3:    byte_out = p_q[23:16];
            6'd4:    byte_out = p_q[7:0];
            6'd5:    byte_out = p_q[15:8];
            6'd6:    byte_out = p_q[23:16];
            6'd7:    byte_out = p_q[7:0];
            6'd8:    byte_out = p_q[15:8];
            6'd9:    byte_out = p_q[23:16];
            6'd10:   byte_out = p_q[7:0];
            6'd11:   byte_out = p_q[15:8];
            6'd12:   byte_out = p_q[23:16];
            6'd13:   byte_out = p_q[7:0];
            6'd14:   byte_out = p_q[15:8];
            6'd15:   byte_out = p_q[23:16];
            6'd16:   byte_out = p_q[7:0];
            6'd17:   byte_out = p_q[15:8];
            6'd18:   byte_out = p_q[23:16];
            6'd19:   byte_out = p_q[7:0];
            6'd20:   byte_out = p_q[15:8];
            6'd21:   byte_out = p_q[23:16];
            6'd22:   byte_out = p_q[7:0];
            6'd23:   byte_out = p_q[15:8];
            6'd24:   byte_out = p_q[23:16];
            6'd25:   byte_out = p_q[7:0];
            6'd26:   byte_out = p_q[15:8];
            6'd27:   byte_out = p_q[23:16];
            6'd28:   byte_out = p_q[7:0];
            6'd29:   byte_out = p_q[15:8];
            default: byte_out = p_q[23:16];
        endcase
    end

    reg        tx = 1'b1;
    reg        sending = 1'b0;
    reg [3:0]  bitidx = 4'd0;
    reg [8:0]  bitclk = 9'd0;
    reg [9:0]  shift = 10'h3FF;
    reg [24:0] pace = 25'd0;

    always @(posedge clk) begin
        if (!sending) begin
            tx <= 1'b1;
            if (pace == PACE - 1) begin
                pace    <= 25'd0;
                sending <= 1'b1;
                shift   <= {1'b1, byte_out, 1'b0};
                bitidx  <= 4'd0;
                bitclk  <= 9'd0;
                pos     <= (pos == MSG_LEN - 1) ? 6'd0 : pos + 6'd1;
                a_r     <= op_a(entry_for((pos == MSG_LEN - 1) ? 6'd0
                                         : pos + 6'd1));
                b_r     <= op_b(entry_for((pos == MSG_LEN - 1) ? 6'd0
                                         : pos + 6'd1));
            end else begin
                pace <= pace + 25'd1;
            end
        end else begin
            tx <= shift[0];
            if (bitclk == CLKS_PER_BIT - 1) begin
                bitclk <= 9'd0;
                shift  <= {1'b1, shift[9:1]};
                if (bitidx == 4'd9) begin
                    sending <= 1'b0;
                    bitidx  <= 4'd0;
                end else begin
                    bitidx <= bitidx + 4'd1;
                end
            end else begin
                bitclk <= bitclk + 9'd1;
            end
        end
    end

    assign uart_tx = tx;
endmodule
