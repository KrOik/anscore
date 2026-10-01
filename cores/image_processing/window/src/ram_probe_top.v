// ============================================================================
// ram_probe_top -- minimal BSRAM read-back probe: writes values 0..DEPTH-1
// to a (WIDTH x DEPTH) block RAM, then reads each address back and streams
// the value over uart_tx (mirrored to dbg_uart=A11 for LA capture).
// Any read-address permutation shows up directly in the byte sequence.
// ============================================================================
module ram_probe_top #(
    parameter WIDTH = 9,
    parameter DEPTH = 16,
    parameter AW    = (DEPTH > 1) ? $clog2(DEPTH) : 1
)(
    input  wire clk,
    output wire uart_tx,
    output wire dbg_uart
);
reg [12:0] reset_count = 13'd0;
wire rst_n = reset_count[12];
always @(posedge clk) if (!rst_n) reset_count <= reset_count + 13'd1;

// ---------------- RAM (same style as line_buf_ram) ----------------
(* ram_style = "block" *) reg [WIDTH-1:0] mem [0:DEPTH-1];
reg [AW-1:0] wa = 0;
reg [AW-1:0] ra = 0;
reg [WIDTH-1:0] q;
reg        we = 1'b0;
always @(posedge clk) begin
    if (we) mem[wa] <= {{WIDTH-8{1'b0}}, wa[7:0]};
    q <= mem[ra];
end

// ---------------- FSM ----------------
// ph0: write DEPTH words (wa sweeps), then ph1: header AA55, ph2: sweep ra
// while streaming q over UART, ph3: gap then repeat ph1.
localparam PH_W = 3'd0, PH_HDR = 3'd1, PH_RD = 3'd2, PH_GAP = 3'd3;
reg [2:0] ph = PH_W;
reg [AW-1:0] sp = 0;
reg hdr = 1'b0;
reg [24:0] gap = 25'd0;
reg [7:0] tx_data;
reg tx_valid;
wire tx_ready, tx_busy;

uart_tx #(.CLK_FRE(27), .BAUD_RATE(115200)) uart (
    .clk(clk), .rst_n(rst_n),
    .tx_data(tx_data), .tx_data_valid(tx_valid),
    .tx_data_ready(tx_ready), .tx_pin(uart_tx), .tx_busy(tx_busy));
assign dbg_uart = uart_tx;

always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        ph <= PH_W; wa <= 0; ra <= 0; sp <= 0; hdr <= 1'b0; we <= 1'b0;
        tx_valid <= 1'b0; tx_data <= 8'd0; gap <= 25'd0;
    end else begin
        case (ph)
            PH_W: begin
                we <= 1'b1;
                if (wa == DEPTH-1) begin we <= 1'b0; ph <= PH_HDR; end
                else wa <= wa + 1'b1;
            end
            PH_HDR: begin
                if (!tx_valid && tx_ready) begin
                    tx_data <= hdr ? 8'h55 : 8'hAA; tx_valid <= 1'b1;
                end else if (tx_valid && tx_busy) begin
                    tx_valid <= 1'b0;
                    if (hdr) begin ph <= PH_RD; ra <= 0; sp <= 0; end
                    hdr <= ~hdr;
                end
            end
            PH_RD: begin
                // q continuously reflects mem[ra]; move ra with sp
                if (!tx_valid && tx_ready && sp < DEPTH) begin
                    tx_data <= q[7:0]; tx_valid <= 1'b1;
                    sp <= sp + 1'b1;
                    ra <= sp + 1'b1;
                end else if (tx_valid && tx_busy) tx_valid <= 1'b0;
                if (sp == DEPTH) ph <= PH_GAP;
            end
            default: begin
                tx_valid <= 1'b0;
                if (gap == 25'd13_500_000) begin
                    hdr <= 1'b0; ph <= PH_HDR;
                end
            end
        endcase
        if (ph == PH_GAP) gap <= gap + 25'd1; else gap <= 25'd0;
    end
end
endmodule
