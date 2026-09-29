// COMM bus/protocol IP unit selftest aggregator for GW2A-18C bring-up.
// Units:
//   U0 uart_rx      looped to on-chip uart_tx + bit-banged framing-error test
//   U1 spi_master   mode-0 master vs internal LFSR loopback slave model
//   U2 i2c_master   vs internal i2c slave model (write/read/nack/stretch)
//   U3 axil_slave   16x32 reg bank driven by harness-side master transactions
//   U4 fifo_async   Gray-ptr FIFO, wr on clk, rd on clk/2 toggle clock
// Each unit folds its captured transaction stream into an FNV-1a digest that
// is compared against an independent Python golden model (tools/golden_model.py).
module comm_selftest #(
    parameter [15:0] UNIT_EN = 16'h001F
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
        // FNV-1a prime 0x01000193 -> shift-add (no DSP)
        fnv = x + (x << 1) + (x << 4) + (x << 7) + (x << 8) + (x << 24);
    end
endfunction

// ce beat: 1 in 16 clks; harness logic and ce-gated DUTs advance on it.
reg [3:0] ce_div = 4'd0;
wire ce = (ce_div == 4'd15);
always @(posedge clk) ce_div <= ce_div + 4'd1;

localparam integer UART_CYCLE = 234;   // 27e6/115200

// ===========================================================================
// Unit 0: uart_rx  (loopback via uart_tx + bit-banged framing-error frame)
// ===========================================================================
// stream = for each of 8 loopback bytes p(i)=i*29+7: {rx, ferr=0}
//          then bit-banged good frame 0x3C {rx,0}, bad frame 0x00 stop=0 {rx,1}
localparam [31:0] EXP_URX = 32'h6bc47dce;

reg [3:0]  u_state;
reg [3:0]  u_idx;
reg        u_txv;
reg        u_ack;
reg        u_done;
reg [31:0] u_dg;
wire [7:0] u_txdata = (u_idx << 5) - (u_idx << 1) - u_idx + 8'd7;
wire       u_tx_ready, u_tx_busy, u_tx_pin;
wire [7:0] u_rx_data;
wire       u_rx_valid, u_rx_ferr;

// bit-bang frame generator (full-speed stimulus, CYCLE ticks per bit)
reg        bb_start;
reg        bb_busy;
reg        bb_line;
reg [15:0] bb_cnt;
reg [3:0]  bb_pos;
reg [9:0]  bb_shift;
wire       u_rx_wire = bb_busy ? bb_line : u_tx_pin;

localparam [3:0] U_SEND    = 4'd0;
localparam [3:0] U_WLAUNCH = 4'd1;
localparam [3:0] U_WAITRX  = 4'd2;
localparam [3:0] U_ACKRX   = 4'd3;

generate
if (UNIT_EN[0]) begin : g_u0
uart_tx #(.CLK_FRE(27), .BAUD_RATE(115200)) u_utx (
    .clk(clk), .rst_n(rst_n),
    .tx_data(u_txdata), .tx_data_valid(u_txv),
    .tx_data_ready(u_tx_ready), .tx_pin(u_tx_pin), .tx_busy(u_tx_busy)
);
uart_rx #(.CLK_FRE(27), .BAUD_RATE(115200)) u_urx (
    .clk(clk), .rst_n(rst_n), .clk_en(1'b1),
    .rx_pin(u_rx_wire),
    .rx_data(u_rx_data), .rx_valid(u_rx_valid),
    .rx_ack(u_ack), .framing_err(u_rx_ferr)
);

// bit-bang stimulus: not part of the digest path -> full clk rate allowed
always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        bb_busy  <= 1'b0;
        bb_line  <= 1'b1;
        bb_cnt   <= 16'd0;
        bb_pos   <= 4'd0;
        bb_shift <= 10'h3FF;
    end else begin
        if (bb_start && !bb_busy) begin
            bb_busy  <= 1'b1;
            bb_line  <= 1'b0;                      // start bit
            bb_cnt   <= 16'd0;
            bb_pos   <= 4'd0;
            bb_shift <= (u_idx == 4'd8) ? {1'b1, 8'h3C, 1'b0}
                                        : {1'b0, 8'h00, 1'b0}; // bad stop
        end else if (bb_busy) begin
            if (bb_pos < 4'd10) begin
                if (bb_cnt == UART_CYCLE - 1) begin
                    bb_cnt   <= 16'd0;
                    bb_pos   <= bb_pos + 4'd1;
                    bb_line  <= bb_shift[1];
                    bb_shift <= {1'b1, bb_shift[9:1]};
                end else bb_cnt <= bb_cnt + 16'd1;
            end else begin
                // inter-frame gap
                bb_line <= 1'b1;
                if (bb_cnt == 16'd400) begin
                    bb_cnt  <= 16'd0;
                    bb_busy <= 1'b0;
                end else bb_cnt <= bb_cnt + 16'd1;
            end
        end
    end
end

always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        u_state <= U_SEND; u_idx <= 4'd0; u_txv <= 1'b0; u_ack <= 1'b0;
        u_done  <= 1'b0;   u_dg  <= 32'h811c9dc5; bb_start <= 1'b0;
    end else if (ce && !u_done) begin
        bb_start <= 1'b0;
        case (u_state)
            U_SEND: begin
                if (u_idx < 4'd8) begin
                    // RX may finish voting before TX completes its stop
                    // bit. Do not mistake the previous frame's busy for
                    // acceptance of this next byte.
                    if (!u_txv && u_tx_ready) u_txv <= 1'b1;
                    // tx accepts within 1 clk and stays busy for the whole
                    // frame -> use tx_busy as the accept indicator so the
                    // held txv cannot retrigger a second frame
                    if (u_txv && u_tx_busy) begin
                        u_txv   <= 1'b0;
                        u_state <= U_WAITRX;
                    end
                end else if (u_idx < 4'd10) begin
                    if (!bb_busy) begin
                        bb_start <= 1'b1;
                        u_state  <= U_WLAUNCH;
                    end
                end else begin
                    u_done <= 1'b1;
                end
            end
            U_WLAUNCH: begin
                if (bb_busy) u_state <= U_WAITRX;
            end
            U_WAITRX: begin
                if (u_rx_valid) begin
                    u_dg    <= fnv(fnv(u_dg, u_rx_data), {7'd0, u_rx_ferr});
                    u_ack   <= 1'b1;
                    u_state <= U_ACKRX;
                end
            end
            U_ACKRX: begin
                u_ack <= 1'b0;
                if (!u_rx_valid) begin
                    u_idx   <= u_idx + 4'd1;
                    u_state <= U_SEND;
                end
            end
            default: u_state <= U_SEND;
        endcase
    end
end
end else begin : g_u0_off
    assign u_tx_ready = 1'b0; assign u_tx_busy = 1'b0; assign u_tx_pin = 1'b1;
    assign u_rx_data = 8'd0; assign u_rx_valid = 1'b0; assign u_rx_ferr = 1'b0;
    always @(posedge clk) begin u_done <= 1'b1; u_dg <= 32'h811c9dc5; end
end
endgenerate

// ===========================================================================
// Unit 1: spi_master mode-0 vs LFSR loopback slave
// ===========================================================================
// per transfer idx: nbits = {8,16,32}, tx = {A5, 3C5A, C0FFEE11}
// stream per transfer: master rx bytes (MSB first) then slave captured bytes
localparam [31:0] EXP_SPIM = 32'he4107f07;

reg [3:0]  s_state;
reg [1:0]  s_idx;
reg        s_start;
reg        s_capack;
reg [2:0]  s_fb;        // fold byte counter
reg        s_done;
reg [31:0] s_dg;
wire [5:0] s_nbits = (s_idx == 2'd0) ? 6'd8 : (s_idx == 2'd1) ? 6'd16 : 6'd32;
wire [31:0] s_txw  = (s_idx == 2'd0) ? 32'h000000A5 :
                     (s_idx == 2'd1) ? 32'h00003C5A : 32'hC0FFEE11;
wire [2:0] s_nb    = (s_idx == 2'd0) ? 3'd1 : (s_idx == 2'd1) ? 3'd2 : 3'd4;
wire [31:0] s_rxw;
wire        s_m_done, s_m_busy, s_sclk, s_mosi, s_miso, s_csn;
wire [31:0] s_capdata;
wire [5:0]  s_capbits;
wire        s_capvalid;

localparam [3:0] S_ISSUE  = 4'd0;
localparam [3:0] S_WDONE  = 4'd1;
localparam [3:0] S_FOLDM  = 4'd2;
localparam [3:0] S_WCAP   = 4'd3;
localparam [3:0] S_FOLDC  = 4'd4;
localparam [3:0] S_NEXT   = 4'd5;
localparam [3:0] S_WCLR   = 4'd6;

generate
if (UNIT_EN[1]) begin : g_u1
spi_master #(.CPOL(0), .CPHA(0), .SCLK_DIV(4)) u_spim (
    .clk(clk), .rst_n(rst_n), .clk_en(ce || !rst_n),
    .start(s_start), .nbits(s_nbits), .tx_data(s_txw),
    .rx_data(s_rxw), .busy(s_m_busy), .done(s_m_done),
    .sclk(s_sclk), .mosi(s_mosi), .miso(s_miso), .cs_n(s_csn)
);
spi_slave_model #(.SEED(8'hB7)) u_spis (
    .clk(clk), .rst_n(rst_n),
    .sclk(s_sclk), .mosi(s_mosi), .miso(s_miso), .cs_n(s_csn),
    .cap_data(s_capdata), .cap_bits(s_capbits),
    .cap_valid(s_capvalid), .cap_ack(s_capack)
);

always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        s_state <= S_ISSUE; s_idx <= 2'd0; s_start <= 1'b0; s_capack <= 1'b0;
        s_fb    <= 3'd0;    s_done <= 1'b0; s_dg <= 32'h811c9dc5;
    end else if (ce && !s_done) begin
        s_start  <= 1'b0;
        s_capack <= 1'b0;
        case (s_state)
            S_ISSUE: begin
                s_start <= 1'b1;
                s_state <= S_WCLR;
            end
            S_WCLR: begin                  // wait until old done clears
                if (!s_m_done) s_state <= S_WDONE;
            end
            S_WDONE: begin
                if (s_m_done) begin
                    s_fb    <= 3'd0;
                    s_state <= S_FOLDM;
                end
            end
            S_FOLDM: begin                     // fold master rx, MSB first
                s_dg <= fnv(s_dg, s_rxw[(s_nb * 8 - s_fb * 8 - 1) -: 8]);
                if (s_fb == s_nb - 3'd1) s_state <= S_WCAP;
                else s_fb <= s_fb + 3'd1;
            end
            S_WCAP: begin
                if (s_capvalid) begin
                    s_fb    <= 3'd0;
                    s_state <= S_FOLDC;
                end
            end
            S_FOLDC: begin                     // fold slave capture, MSB first
                s_dg <= fnv(s_dg, s_capdata[(s_nb * 8 - s_fb * 8 - 1) -: 8]);
                if (s_fb == s_nb - 3'd1) begin
                    s_capack <= 1'b1;
                    s_state  <= S_NEXT;
                end else s_fb <= s_fb + 3'd1;
            end
            S_NEXT: begin
                if (s_idx == 2'd2) s_done <= 1'b1;
                else begin
                    s_idx   <= s_idx + 2'd1;
                    s_state <= S_ISSUE;
                end
            end
            default: s_state <= S_ISSUE;
        endcase
    end
end
end else begin : g_u1_off
    assign s_rxw = 32'd0; assign s_m_done = 1'b0; assign s_m_busy = 1'b0;
    assign s_sclk = 1'b0; assign s_mosi = 1'b0; assign s_csn = 1'b1;
    assign s_capdata = 32'd0; assign s_capbits = 6'd0; assign s_capvalid = 1'b0;
    always @(posedge clk) begin s_done <= 1'b1; s_dg <= 32'h811c9dc5; end
end
endgenerate

// ===========================================================================
// Unit 2: i2c_master vs internal slave model
// ===========================================================================
// T0: write 0x42 {DE,AD,BE,EF}     fold: status, cnt, cbuf[0..3]
// T1: read  0x42 len=5             fold: rx bytes (as received), status
// T2: write 0x55 {99} -> addr NACK fold: status(=1)
// T3: write 0x42 {11,22,33} +stretch fold: status, cnt, cbuf[0..2]
localparam [31:0] EXP_I2CM = 32'hd6a89792;

reg [3:0]  i_state;
reg [1:0]  i_idx;
reg        i_start;
reg        i_txv;
reg        i_rxack;
reg [3:0]  i_fb;
reg        i_stretch;
reg        i_done;
reg [31:0] i_dg;

wire i_m_sda_oe, i_m_scl_oe, i_s_sda_oe, i_s_scl_oe;
wire i_sda = ~(i_m_sda_oe | i_s_sda_oe);
wire i_scl = ~(i_m_scl_oe | i_s_scl_oe);
wire i_tx_ready, i_busy, i_m_done, i_nack;
wire [7:0] i_rx_data;
wire       i_rx_valid;
wire [7:0] i_cap_byte;
wire [4:0] i_slv_cnt;
reg  [3:0] i_cap_sel;
wire       i_addr_seen;

wire [6:0] i_addr = (i_idx == 2'd2) ? 7'h55 : 7'h42;
wire       i_rw   = (i_idx == 2'd1);
wire [4:0] i_len  = (i_idx == 2'd0) ? 5'd4 : (i_idx == 2'd1) ? 5'd5 :
                    (i_idx == 2'd2) ? 5'd1 : 5'd3;
// write data table: T0 {DE,AD,BE,EF}, T2 {99}, T3 {11,22,33}
function [7:0] i_wbyte;
    input [1:0] t;
    input [3:0] b;
    begin
        case (t)
            2'd0: i_wbyte = (b == 4'd0) ? 8'hDE : (b == 4'd1) ? 8'hAD :
                            (b == 4'd2) ? 8'hBE : 8'hEF;
            2'd2: i_wbyte = 8'h99;
            2'd3: i_wbyte = (b == 4'd0) ? 8'h11 : (b == 4'd1) ? 8'h22 : 8'h33;
            default: i_wbyte = 8'h00;
        endcase
    end
endfunction

localparam [3:0] I_START  = 4'd0;
localparam [3:0] I_RUN    = 4'd1;
localparam [3:0] I_STATUS = 4'd2;
localparam [3:0] I_CNT    = 4'd3;
localparam [3:0] I_CAP    = 4'd4;
localparam [3:0] I_NEXT   = 4'd5;
localparam [3:0] I_WCLR   = 4'd6;

generate
if (UNIT_EN[2]) begin : g_u2
i2c_master #(.QDIV(64)) u_i2cm (
    .clk(clk), .rst_n(rst_n), .clk_en(ce || !rst_n),
    .start(i_start), .addr(i_addr), .rw(i_rw), .len(i_len),
    .tx_data(i_wbyte(i_idx, i_fb)), .tx_valid(i_txv), .tx_ready(i_tx_ready),
    .rx_data(i_rx_data), .rx_valid(i_rx_valid), .rx_ack(i_rxack),
    .busy(i_busy), .done(i_m_done), .nack(i_nack),
    .sda_in(i_sda), .scl_in(i_scl), .sda_oe(i_m_sda_oe), .scl_oe(i_m_scl_oe)
);
i2c_slave_model #(.ADDR(7'h42), .STRETCH_BYTE(4'd1),
                  .STRETCH_TICKS(16'd2000)) u_i2cs (
    .clk(clk), .rst_n(rst_n), .stretch_en(i_stretch),
    .sda_in(i_sda), .scl_in(i_scl),
    .sda_oe(i_s_sda_oe), .scl_oe(i_s_scl_oe),
    .cap_sel(i_cap_sel), .cap_byte(i_cap_byte),
    .byte_cnt(i_slv_cnt), .addr_seen(i_addr_seen)
);

always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        i_state <= I_START; i_idx <= 2'd0; i_start <= 1'b0; i_txv <= 1'b0;
        i_rxack <= 1'b0; i_fb <= 4'd0; i_stretch <= 1'b0; i_cap_sel <= 4'd0;
        i_done  <= 1'b0; i_dg <= 32'h811c9dc5;
    end else if (ce && !i_done) begin
        i_start <= 1'b0;
        i_rxack <= 1'b0;
        case (i_state)
            I_START: begin
                i_start   <= 1'b1;
                i_fb      <= 4'd0;
                i_stretch <= (i_idx == 2'd3);
                i_state   <= I_WCLR;
            end
            I_WCLR: begin                  // wait until old done clears
                if (!i_m_done) i_state <= I_RUN;
            end
            I_RUN: begin
                // feed write bytes while master asks
                if (i_tx_ready && !i_txv && !i_rw)
                    i_txv <= 1'b1;
                if (i_txv && i_tx_ready) begin
                    i_txv <= 1'b0;
                    i_fb  <= i_fb + 4'd1;
                end
                // fold read bytes as they arrive
                if (i_rx_valid && !i_rxack) begin
                    i_dg    <= fnv(i_dg, i_rx_data);
                    i_rxack <= 1'b1;
                end
                if (i_m_done) begin
                    i_txv   <= 1'b0;
                    i_state <= I_STATUS;
                end
            end
            I_STATUS: begin                     // fold {7'd0,nack}
                i_dg <= fnv(i_dg, {7'd0, i_nack});
                if (!i_rw && !i_nack) begin
                    i_state   <= I_CNT;
                end else begin
                    i_state <= I_NEXT;
                end
            end
            I_CNT: begin                        // fold slave byte count
                i_dg      <= fnv(i_dg, {3'd0, i_slv_cnt});
                i_cap_sel <= 4'd0;
                i_fb      <= 4'd0;
                i_state   <= I_CAP;
            end
            I_CAP: begin                        // fold captured write bytes
                i_dg      <= fnv(i_dg, i_cap_byte);
                i_cap_sel <= i_cap_sel + 4'd1;
                if (i_fb == i_slv_cnt[3:0] - 4'd1) i_state <= I_NEXT;
                else i_fb <= i_fb + 4'd1;
            end
            I_NEXT: begin
                if (i_idx == 2'd3) i_done <= 1'b1;
                else begin
                    i_idx   <= i_idx + 2'd1;
                    i_state <= I_START;
                end
            end
            default: i_state <= I_START;
        endcase
    end
end
end else begin : g_u2_off
    assign i_m_sda_oe = 1'b0; assign i_m_scl_oe = 1'b0;
    assign i_s_sda_oe = 1'b0; assign i_s_scl_oe = 1'b0;
    assign i_tx_ready = 1'b0; assign i_busy = 1'b0; assign i_m_done = 1'b0;
    assign i_nack = 1'b0; assign i_rx_data = 8'd0; assign i_rx_valid = 1'b0;
    assign i_cap_byte = 8'd0; assign i_slv_cnt = 5'd0; assign i_addr_seen = 1'b0;
    always @(posedge clk) begin i_done <= 1'b1; i_dg <= 32'h811c9dc5; end
end
endgenerate

// ===========================================================================
// Unit 3: axil_slave reg bank exercised by harness master FSM
// ===========================================================================
// ops: W 0x0C DEADBEEF/F, W 0x1C 12345678/5, R 0x0C, R 0x1C,
//      W 0x80 55/F (SLVERR), R 0x40 (SLVERR), R 0x05 (SLVERR), R 0x00
// fold: writes -> {6'd0,bresp}; reads -> rdata LSB..MSB, {6'd0,rresp}
localparam [31:0] EXP_AXIL = 32'h9b3a6985;

reg [3:0]  a_state;
reg [2:0]  a_idx;
reg        a_awv, a_wv, a_bready, a_arv, a_rready;
reg [2:0]  a_fb;
reg        a_done;
reg [31:0] a_dg;
wire       a_awready, a_wready, a_bvalid, a_arready, a_rvalid;
wire [1:0] a_bresp, a_rresp;
wire [31:0] a_rdata;

function [7:0] a_addr;
    input [2:0] o;
    begin
        case (o)
            3'd0: a_addr = 8'h0C; 3'd1: a_addr = 8'h1C;
            3'd2: a_addr = 8'h0C; 3'd3: a_addr = 8'h1C;
            3'd4: a_addr = 8'h80; 3'd5: a_addr = 8'h40;
            3'd6: a_addr = 8'h05; default: a_addr = 8'h00;
        endcase
    end
endfunction
wire a_is_wr = (a_idx == 3'd0) || (a_idx == 3'd1) || (a_idx == 3'd4);
wire [31:0] a_wdata = (a_idx == 3'd0) ? 32'hDEADBEEF :
                      (a_idx == 3'd1) ? 32'h12345678 : 32'h00000055;
wire [3:0]  a_wstrb = (a_idx == 3'd1) ? 4'b0101 : 4'b1111;

localparam [3:0] A_ISSUE = 4'd0;
localparam [3:0] A_WAITW = 4'd1;
localparam [3:0] A_BRESP = 4'd2;
localparam [3:0] A_WAITR = 4'd3;
localparam [3:0] A_RFOLD = 4'd4;
localparam [3:0] A_RRESP = 4'd5;
localparam [3:0] A_NEXT  = 4'd6;

generate
if (UNIT_EN[3]) begin : g_u3
axil_slave u_axil (
    .clk(clk), .rst_n(rst_n), .clk_en(ce || !rst_n),
    .awvalid(a_awv), .awready(a_awready), .awaddr(a_addr(a_idx)),
    .wvalid(a_wv), .wready(a_wready), .wdata(a_wdata), .wstrb(a_wstrb),
    .bvalid(a_bvalid), .bready(a_bready), .bresp(a_bresp),
    .arvalid(a_arv), .arready(a_arready), .araddr(a_addr(a_idx)),
    .rvalid(a_rvalid), .rready(a_rready), .rdata(a_rdata), .rresp(a_rresp)
);

always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        a_state <= A_ISSUE; a_idx <= 3'd0;
        a_awv <= 1'b0; a_wv <= 1'b0; a_bready <= 1'b0;
        a_arv <= 1'b0; a_rready <= 1'b0; a_fb <= 3'd0;
        a_done <= 1'b0; a_dg <= 32'h811c9dc5;
    end else if (ce && !a_done) begin
        case (a_state)
            A_ISSUE: begin
                if (a_is_wr) begin
                    a_awv   <= 1'b1;
                    a_wv    <= 1'b1;
                    a_state <= A_WAITW;
                end else begin
                    a_arv   <= 1'b1;
                    a_state <= A_WAITR;
                end
            end
            A_WAITW: begin
                if (a_awv && a_awready) a_awv <= 1'b0;
                if (a_wv  && a_wready)  a_wv  <= 1'b0;
                if (!a_awv && !a_wv) begin
                    a_bready <= 1'b1;
                    a_state  <= A_BRESP;
                end
            end
            A_BRESP: begin
                if (a_bvalid) begin
                    a_dg     <= fnv(a_dg, {6'd0, a_bresp});
                    a_bready <= 1'b0;
                    a_state  <= A_NEXT;
                end
            end
            A_WAITR: begin
                if (a_arv && a_arready) begin
                    a_arv <= 1'b0;
                end else if (!a_arv && a_rvalid) begin
                    a_fb    <= 3'd0;
                    a_state <= A_RFOLD;
                end
            end
            A_RFOLD: begin                      // rdata bytes LSB first
                a_dg <= fnv(a_dg, a_rdata[{a_fb, 3'd0} +: 8]);
                if (a_fb == 3'd3) a_state <= A_RRESP;
                else a_fb <= a_fb + 3'd1;
            end
            A_RRESP: begin
                a_dg     <= fnv(a_dg, {6'd0, a_rresp});
                a_rready <= 1'b1;
                a_state  <= A_NEXT;
            end
            A_NEXT: begin
                a_rready <= 1'b0;
                a_bready <= 1'b0;
                if (a_idx == 3'd7) a_done <= 1'b1;
                else begin
                    a_idx   <= a_idx + 3'd1;
                    a_state <= A_ISSUE;
                end
            end
            default: a_state <= A_ISSUE;
        endcase
    end
end
end else begin : g_u3_off
    assign a_awready = 1'b0; assign a_wready = 1'b0; assign a_bvalid = 1'b0;
    assign a_arready = 1'b0; assign a_rvalid = 1'b0;
    assign a_bresp = 2'd0; assign a_rresp = 2'd0; assign a_rdata = 32'd0;
    always @(posedge clk) begin a_done <= 1'b1; a_dg <= 32'h811c9dc5; end
end
endgenerate

// ===========================================================================
// Unit 4: fifo_async - wr on clk, rd on clk/2, 40 bytes p(i)=i*29+5
// ===========================================================================
// rd gated until (w_i>=24 or full-stall>32); digest folds 40 read bytes
// then {7'd0,full_seen}
localparam [31:0] EXP_FIFO = 32'hb5fc9b84;

wire       rdclk;              // clk/2 from the rPLL, on the global clock net
wire       rdclk_lock;
reg [5:0]  f_wi;
reg        f_full_seen;
reg [7:0]  f_fc;
wire       f_full, f_empty;
wire [7:0] f_dout;
wire [7:0] f_din   = (f_wi << 5) - (f_wi << 1) - f_wi + 8'd5;
wire       f_wren  = (f_wi < 6'd40) && !f_full;
wire       f_rdgo  = (f_wi >= 6'd24) || (f_fc > 8'd32);
// rd-domain regs carry power-on inits: the rPLL CLKOUT may not be toggling
// while rd_rst_n is asserted (before LOCK), so no posedge can execute the
// async-reset branch; init values make simulation match hardware power-on.
reg        f_rden    = 1'b0;
reg        f_rdpend  = 1'b0;
reg        f_rdcap   = 1'b0;
reg [1:0]  f_rdgo_s  = 2'b00;
reg [1:0]  f_fseen_s = 2'b00;
reg [5:0]  f_rcnt    = 6'd0;
reg        f_rddone  = 1'b0;
reg [31:0] f_dg      = 32'h811c9dc5;
reg [1:0]  f_rddone_s;
reg        f_done;

generate
if (UNIT_EN[4]) begin : g_u4
// read-domain reset: held until the rPLL locks so the rd FSM / pointers are
// not clocked by an unstable CLKOUT.
wire rd_rst_n = rst_n && rdclk_lock;
fifo_async #(.DW(8), .AW(4)) u_fifo (
    .wr_clk(clk), .wr_rst_n(rst_n), .wr_en(f_wren), .din(f_din),
    .full(f_full),
    .rd_clk(rdclk), .rd_rst_n(rd_rst_n), .rd_en(f_rden), .dout(f_dout),
    .empty(f_empty)
);

// read clock = clk/2 (a genuine second domain; phase-aligned but half rate)
// from the rPLL: CLKOUT lands on the global clock network, so rd-domain
// registers see a real, low-skew clock. (Fabric FF -> BUFG left rdclk dead
// on hardware; raw fabric clock gave same-domain hold violations in STA;
// CLKDIV2 only reaches the sector HCLK network and could not route.)
rPLL #(
    .FCLKIN("27"),                  // 27 MHz input
    .IDIV_SEL(1),                   // PFD = 27/2 = 13.5 MHz (3-500)
    .FBDIV_SEL(0),                  // CLKOUT = PFD*1 = 13.5 MHz
    .ODIV_SEL(64)                   // VCO = 13.5*64 = 864 MHz (500-1250)
) u_rdclk_pll (
    .CLKOUT(rdclk),
    .CLKOUTP(), .CLKOUTD(), .CLKOUTD3(),
    .LOCK(rdclk_lock),
    .CLKIN(clk),
    .CLKFB(1'b0), .FBDSEL(6'b0), .IDSEL(6'b0), .ODSEL(6'b0),
    .PSDA(4'b0), .DUTYDA(4'b0), .FDLY(4'b0),
    .RESET(1'b0), .RESET_P(1'b0)
);

// write domain FSM (full rate)
always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        f_wi        <= 6'd0;
        f_full_seen <= 1'b0;
        f_fc        <= 8'd0;
        f_rddone_s  <= 2'b00;
        f_done      <= 1'b0;
    end else begin
        if (f_wren) f_wi <= f_wi + 6'd1;
        if (f_full && (f_wi < 6'd40)) begin
            f_full_seen <= 1'b1;
            if (f_fc != 8'hFF) f_fc <= f_fc + 8'd1;
        end
        f_rddone_s <= {f_rddone_s[0], f_rddone};
        if (f_rddone_s[1]) f_done <= 1'b1;
    end
end

// read domain FSM (rdclk)
always @(posedge rdclk or negedge rd_rst_n) begin
    if (!rd_rst_n) begin
        f_rden    <= 1'b0;
        f_rdpend  <= 1'b0;
        f_rdcap   <= 1'b0;
        f_rdgo_s  <= 2'b00;
        f_fseen_s <= 2'b00;
        f_rcnt    <= 6'd0;
        f_rddone  <= 1'b0;
        f_dg      <= 32'h811c9dc5;
    end else begin
        f_rdgo_s  <= {f_rdgo_s[0], f_rdgo};
        f_fseen_s <= {f_fseen_s[0], f_full_seen};
        f_rden    <= 1'b0;
        f_rdcap   <= f_rdpend;
        if (f_rdpend) f_rdpend <= 1'b0;
        // dout is registered: it holds the popped byte one rdclk after rd_en
        if (f_rdcap) begin
            f_dg     <= fnv(f_dg, f_dout);
            f_rcnt   <= f_rcnt + 6'd1;
            if (f_rcnt == 6'd39) begin
                f_dg     <= fnv(fnv(f_dg, f_dout), {7'd0, f_fseen_s[1]});
                f_rddone <= 1'b1;
            end
        end else if (!f_rdpend && f_rdgo_s[1] && !f_empty && (f_rcnt < 6'd40)) begin
            f_rden   <= 1'b1;
            f_rdpend <= 1'b1;
        end
    end
end
end else begin : g_u4_off
    assign f_full = 1'b0; assign f_empty = 1'b1; assign f_dout = 8'd0;
    always @(posedge clk) begin f_done <= 1'b1; f_dg <= 32'h811c9dc5; end
end
endgenerate

// ===========================================================================
// Aggregation
// ===========================================================================
wire [15:0] done_w = {11'h7FF, f_done, a_done, i_done, s_done, u_done};
assign done_mask = done_w;

function [31:0] exp_digest;
    input [3:0] idx;
    begin
        case (idx)
            4'd0: exp_digest = EXP_URX;
            4'd1: exp_digest = EXP_SPIM;
            4'd2: exp_digest = EXP_I2CM;
            4'd3: exp_digest = EXP_AXIL;
            4'd4: exp_digest = EXP_FIFO;
            default: exp_digest = 32'h811c9dc5;
        endcase
    end
endfunction

reg [31:0] digests [0:15];
reg [15:0] pass_r;
assign pass_mask = pass_r;

integer ui;
always @(posedge clk) begin
    digests[0] <= u_dg; digests[1] <= s_dg; digests[2] <= i_dg;
    digests[3] <= a_dg; digests[4] <= f_dg;
    for (ui = 5; ui < 16; ui = ui + 1) digests[ui] <= 32'h811c9dc5;
    for (ui = 0; ui < 16; ui = ui + 1) begin
        pass_r[ui] <= done_w[ui] &&
                      (!UNIT_EN[ui] || (digests[ui] === exp_digest(ui[3:0])));
    end
end

always @(*) begin
    digest_q = digests[digest_sel[3:0]];
end

reg verdict_settled;
reg [2:0] settle_cnt;
always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        all_done <= 1'b0; all_pass <= 1'b0; any_fail <= 1'b0;
        verdict_settled <= 1'b0; settle_cnt <= 3'd0;
    end else if (!all_done) begin
        if (ce) all_done <= &done_w;
    end else if (!verdict_settled) begin
        // digests[] and pass_r are registered: wait a few cycles after
        // all_done so the verdict sees settled values, never a transient.
        settle_cnt <= settle_cnt + 3'd1;
        if (settle_cnt == 3'd5) begin
            verdict_settled <= 1'b1;
            all_pass <= (pass_r === done_w);
            any_fail <= (pass_r !== done_w);
        end
    end
end

endmodule
