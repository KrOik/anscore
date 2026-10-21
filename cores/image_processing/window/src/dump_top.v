// ============================================================================
// dump_top -- diagnostic board top: run img_stim -> win3x3_gen exactly as
// selftest unit 0 does (ce = clk/16), buffer every emitted window's 9 taps
// in BSRAM, then replay all bytes over uart_tx for LA/serial capture.
// Bytes: 0xAA 0x55 header, then 256 windows x 9 taps (tap0..tap8, row-major).
// ============================================================================
module dump_top (
    input  wire clk,
    output wire uart_tx,
    output wire dbg_uart
);
localparam IMG_W = 16;
localparam IMG_H = 16;
localparam NBYTES = IMG_W * IMG_H * 9;          // 2304

reg [12:0] reset_count = 13'd0;
wire rst_n = reset_count[12];
always @(posedge clk) if (!rst_n) reset_count <= reset_count + 13'd1;

reg [3:0] ce_div = 4'd0;
wire ce = (ce_div == 4'd15);
always @(posedge clk) ce_div <= ce_div + 4'd1;

// ---------------- DUT (identical wiring to selftest U0) ----------------
wire [7:0]  s_pix;
wire        s_pv, s_nl;
wire [71:0] w_win;
wire        w_v, w_nlo, w_done;

img_stim #(.IMG_W(IMG_W), .IMG_H(IMG_H)) u_stim (
    .clk(clk), .clk_en(ce || !rst_n), .rst_n(rst_n),
    .pix(s_pix), .pix_valid(s_pv), .new_line(s_nl), .stim_done());
win3x3_gen #(.IMG_W(IMG_W), .IMG_H(IMG_H)) u_dut (
    .clk(clk), .clk_en(ce || !rst_n), .rst_n(rst_n),
    .pix(s_pix), .pix_valid(s_pv), .new_line(s_nl),
    .win(w_win), .win_valid(w_v), .new_line_out(w_nlo), .done(w_done));

// ---------------- capture buffer ----------------
(* ram_style = "block" *) reg [7:0] wbuf [0:NBYTES-1];
reg [11:0] wp = 12'd0;              // write pointer (bytes)
reg [3:0]  bcnt = 4'd0;             // byte count within window
reg        capturing = 1'b0;
reg [71:0] wlat = 72'd0;

always @(posedge clk) begin
    if (ce && w_v && !capturing) begin
        wlat <= w_win;
        capturing <= 1'b1;
        bcnt <= 4'd0;
    end else if (capturing) begin
        wbuf[wp] <= wlat[7:0];
        wlat <= {8'd0, wlat[71:8]};
        wp <= wp + 12'd1;
        if (bcnt == 4'd8) capturing <= 1'b0;
        else bcnt <= bcnt + 4'd1;
    end
end

// ---------------- UART replay ----------------
wire tx_ready, tx_busy;
reg [7:0] tx_data;
reg tx_valid;
reg [11:0] rp = 12'd0;              // read pointer
reg [2:0]  phase = 3'd0;            // 0 wait done,1 hdr,2 stream,3 idle
reg        hdr_b = 1'b0;
reg [24:0] gap_cnt = 25'd0;

uart_tx #(.CLK_FRE(27), .BAUD_RATE(115200)) uart (
    .clk(clk), .rst_n(rst_n),
    .tx_data(tx_data), .tx_data_valid(tx_valid),
    .tx_data_ready(tx_ready), .tx_pin(uart_tx), .tx_busy(tx_busy));

// registered read of buffer for replay
reg [7:0] rd_q;
always @(posedge clk) rd_q <= wbuf[rp];

always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        phase <= 3'd0; rp <= 12'd0; tx_valid <= 1'b0; tx_data <= 8'd0;
        hdr_b <= 1'b0; gap_cnt <= 25'd0;
    end else begin
        case (phase)
            3'd0: begin
                tx_valid <= 1'b0;
                if (w_done && !capturing) phase <= 3'd1;
            end
            3'd1: begin                                // header 0xAA 0x55
                if (!tx_valid && tx_ready) begin
                    tx_data <= hdr_b ? 8'h55 : 8'hAA;
                    tx_valid <= 1'b1;
                end else if (tx_valid && tx_busy) begin
                    tx_valid <= 1'b0;
                    if (hdr_b) phase <= 3'd2;
                    hdr_b <= ~hdr_b;
                end
            end
            3'd2: begin                                // stream buffer
                if (!tx_valid && tx_ready && (rp < NBYTES)) begin
                    tx_data <= rd_q;
                    tx_valid <= 1'b1;
                    rp <= rp + 12'd1;
                end else if (tx_valid && tx_busy) begin
                    tx_valid <= 1'b0;
                end
                if (rp == NBYTES) phase <= 3'd3;
            end
            default: begin
                tx_valid <= 1'b0;
                // repeat the dump every ~0.5 s so LA capture can't miss it
                if (gap_cnt == 25'd13_500_000) begin
                    rp <= 12'd0;
                    hdr_b <= 1'b0;
                    phase <= 3'd1;
                end
            end
        endcase
        if (phase == 3'd3) gap_cnt <= gap_cnt + 25'd1;
        else               gap_cnt <= 25'd0;
    end
end

assign dbg_uart = uart_tx;
endmodule
