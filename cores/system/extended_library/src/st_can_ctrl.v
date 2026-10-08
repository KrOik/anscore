// ============================================================================
// st_can_ctrl -- selftest cell for can_ctrl (wave2 contract).
//
// Drives 4 frames through the internal loopback:
//   F0 id=0x123 DLC=8 data 11 22 33 44 55 66 77 88
//   F1 id=0x456 DLC=3 data A5 5A C3
//   F2 id=0x7FF RTR   DLC=0
//   F3 id=0x000 DLC=8 data 00 FF 00 FF AA 55 F0 0F   (stuff-heavy)
//
// Fold stream per frame:
//   [wire bits sampled by RX monitor, packed MSB-first, final byte 1-padded]
//   {5'b0,id[10:8]}, id[7:0], {3'b0,rtr,dlc}, data[0..dlc-1],
//   rx_crc[14:8], rx_crc[7:0],
//   status = {4'b0, form_err, stuff_err, crc_ok, tx_ack}
// ============================================================================
module st_can_ctrl (
    input  wire        clk,
    input  wire        clk_en,
    input  wire        rst_n,
    input  wire        start,
    output reg         done,
    output reg         pass,
    output reg  [31:0] digest,
    output reg  [15:0] cycles
);

`include "w2_fnv.vh"

localparam [31:0] EXP = 32'hDC301204;   // golden_comm.py: CAN DIGEST

// frame stimulus table -------------------------------------------------------
function [10:0] fr_id;
    input [1:0] f;
    begin
        case (f)
            2'd0: fr_id = 11'h123;
            2'd1: fr_id = 11'h456;
            2'd2: fr_id = 11'h7FF;
            default: fr_id = 11'h000;
        endcase
    end
endfunction
function fr_rtr;
    input [1:0] f;
    begin fr_rtr = (f == 2'd2); end
endfunction
function [3:0] fr_dlc;
    input [1:0] f;
    begin
        case (f)
            2'd0: fr_dlc = 4'd8;
            2'd1: fr_dlc = 4'd3;
            2'd2: fr_dlc = 4'd0;
            default: fr_dlc = 4'd8;
        endcase
    end
endfunction
function [63:0] fr_data;
    input [1:0] f;
    begin
        case (f)
            2'd0: fr_data = {8'h11,8'h22,8'h33,8'h44,8'h55,8'h66,8'h77,8'h88};
            2'd1: fr_data = {8'hA5,8'h5A,8'hC3,40'd0};
            2'd2: fr_data = 64'd0;
            default: fr_data = {8'h00,8'hFF,8'h00,8'hFF,8'hAA,8'h55,8'hF0,8'h0F};
        endcase
    end
endfunction

// DUT ------------------------------------------------------------------------
reg  [1:0]  fidx;
reg         tx_req;
wire        tx_busy, tx_done, tx_ack;
wire        rx_mon_v, rx_mon_b, rx_frm_v, rx_busy;
wire [10:0] rx_id;
wire        rx_rtr;
wire [3:0]  rx_dlc;
wire [63:0] rx_data;
wire [14:0] rx_crc;
wire        rx_crc_ok, rx_stuff_err, rx_form_err;

can_ctrl #(.TQ_DIV(4), .SEG1(4), .SEG2(2)) dut (
    .clk(clk), .clk_en(clk_en || !rst_n), .rst_n(rst_n),
    .rx_pin(1'b1), .tx_pin(), .loopback(1'b1),
    .tx_req(tx_req), .tx_id(fr_id(fidx)), .tx_rtr(fr_rtr(fidx)),
    .tx_dlc(fr_dlc(fidx)), .tx_data(fr_data(fidx)),
    .tx_busy(tx_busy), .tx_done(tx_done), .tx_ack(tx_ack),
    .rx_mon_v(rx_mon_v), .rx_mon_b(rx_mon_b),
    .rx_frm_v(rx_frm_v), .rx_busy(rx_busy),
    .rx_id(rx_id), .rx_rtr(rx_rtr), .rx_dlc(rx_dlc), .rx_data(rx_data),
    .rx_crc(rx_crc), .rx_crc_ok(rx_crc_ok),
    .rx_stuff_err(rx_stuff_err), .rx_form_err(rx_form_err)
);

// selftest FSM ----------------------------------------------------------------
localparam [3:0] C_IDLE  = 4'd0,  C_ISSUE = 4'd1,  C_RUN   = 4'd2,
                 C_PAD   = 4'd3,  C_IDH   = 4'd4,  C_IDL   = 4'd5,
                 C_CTL   = 4'd6,  C_DATA  = 4'd7,  C_CRCH  = 4'd8,
                 C_CRCL  = 4'd9,  C_ST    = 4'd10, C_NEXT  = 4'd11;

reg [3:0]  cs;
reg        running;
reg [7:0]  pshift;
reg [3:0]  pbits;
reg [3:0]  dj;
reg [31:0] dg;
reg        dg_v;                    // debug fold strobe (TB dumps dg_b)
reg [7:0]  dg_b;
reg [31:0] dg_n;                    // scratch for pad fold
// captured rx result
reg [10:0] c_id;
reg        c_rtr;
reg [3:0]  c_dlc;
reg [63:0] c_data;
reg [14:0] c_crc;
reg        c_ok, c_serr, c_ferr, c_ack;

wire [7:0] pad_byte = (pshift << (4'd8 - pbits)) | (8'hFF >> pbits);
// data byte bit index: byte dj of a dlc-byte frame sits at [8*(dlc-1-dj) +: 8];
// widen before <<3 so the shift does not truncate to 4 bits
wire [6:0] cdbit = ({3'b000, c_dlc} - {3'b000, dj} - 7'd1) << 3;

always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        done <= 1'b0; pass <= 1'b0; digest <= 32'd0; cycles <= 16'd0;
        cs <= C_IDLE; fidx <= 2'd0; running <= 1'b0;
        tx_req <= 1'b0; pshift <= 8'd0; pbits <= 4'd0; dj <= 4'd0;
        dg <= 32'h811C9DC5; dg_v <= 1'b0; dg_b <= 8'd0;
        c_id <= 11'd0; c_rtr <= 1'b0; c_dlc <= 4'd0; c_data <= 64'd0;
        c_crc <= 15'd0; c_ok <= 1'b0; c_serr <= 1'b0; c_ferr <= 1'b0;
        c_ack <= 1'b0;
    end else if (clk_en) begin
        dg_v   <= 1'b0;
        tx_req <= 1'b0;
        if (running && !done) cycles <= cycles + 16'd1;
        case (cs)
            C_IDLE: if (start) begin
                running <= 1'b1;
                done    <= 1'b0;
                dg      <= 32'h811C9DC5;
                cycles  <= 16'd0;
                fidx    <= 2'd0;
                pbits   <= 4'd0;
                cs      <= C_ISSUE;
            end
            C_ISSUE: begin
                tx_req <= 1'b1;
                cs     <= C_RUN;
            end
            C_RUN: begin
                if (rx_mon_v) begin
                    if (pbits == 4'd7) begin
                        dg    <= fnv(dg, {pshift[6:0], rx_mon_b});
                        dg_b  <= {pshift[6:0], rx_mon_b};
                        dg_v  <= 1'b1;
                        pbits <= 4'd0;
                    end else begin
                        pshift <= {pshift[6:0], rx_mon_b};
                        pbits  <= pbits + 4'd1;
                    end
                end
                if (rx_frm_v) begin
                    c_id   <= rx_id;
                    c_rtr  <= rx_rtr;
                    c_dlc  <= rx_dlc;
                    c_data <= rx_data;
                    c_crc  <= rx_crc;
                    c_ok   <= rx_crc_ok;
                    c_serr <= rx_stuff_err;
                    c_ferr <= rx_form_err;
                    c_ack  <= tx_ack;
                    cs     <= C_PAD;
                end
            end
            C_PAD: begin
                if (pbits != 4'd0) begin
                    dg   <= fnv(dg, pad_byte);
                    dg_b <= pad_byte;
                    dg_v <= 1'b1;
                end
                pbits <= 4'd0;
                cs    <= C_IDH;
            end
            C_IDH: begin
                dg   <= fnv(dg, {5'b00000, c_id[10:8]});
                dg_b <= {5'b00000, c_id[10:8]};
                dg_v <= 1'b1;
                cs   <= C_IDL;
            end
            C_IDL: begin
                dg   <= fnv(dg, c_id[7:0]);
                dg_b <= c_id[7:0];
                dg_v <= 1'b1;
                cs   <= C_CTL;
            end
            C_CTL: begin
                dg   <= fnv(dg, {3'b000, c_rtr, c_dlc});
                dg_b <= {3'b000, c_rtr, c_dlc};
                dg_v <= 1'b1;
                dj   <= 4'd0;
                cs   <= (c_dlc == 4'd0) ? C_CRCH : C_DATA;
            end
            C_DATA: begin
                dg   <= fnv(dg, c_data[cdbit +: 8]);
                dg_b <= c_data[cdbit +: 8];
                dg_v <= 1'b1;
                if (dj == c_dlc - 4'd1) cs <= C_CRCH;
                else dj <= dj + 4'd1;
            end
            C_CRCH: begin
                dg   <= fnv(dg, {1'b0, c_crc[14:8]});
                dg_b <= {1'b0, c_crc[14:8]};
                dg_v <= 1'b1;
                cs   <= C_CRCL;
            end
            C_CRCL: begin
                dg   <= fnv(dg, c_crc[7:0]);
                dg_b <= c_crc[7:0];
                dg_v <= 1'b1;
                cs   <= C_ST;
            end
            C_ST: begin
                dg   <= fnv(dg, {4'd0, c_ferr, c_serr, c_ok, c_ack});
                dg_b <= {4'd0, c_ferr, c_serr, c_ok, c_ack};
                dg_v <= 1'b1;
                cs   <= C_NEXT;
            end
            C_NEXT: begin
                if (fidx == 2'd3) begin
                    digest <= dg;
                    pass   <= (dg === EXP);
                    done   <= 1'b1;
                    cs     <= C_IDLE;
                end else begin
                    fidx  <= fidx + 2'd1;
                    pbits <= 4'd0;
                    cs    <= C_ISSUE;
                end
            end
            default: cs <= C_IDLE;
        endcase
    end
end

endmodule
