`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// sm2_top.v — 二改新增模块
// SM2 protocol engine on top of:
//   sm2_ecc      — scalar point mul / point add (Jacobian->affine inside)
//   sm2_modn     — modular add/sub/mul over the group order n
//   sm2_mod_inv  — binary-GCD modular inverse (arbitrary odd modulus)
//   sm3_top      — SM3 hash (streaming 64-bit words)
//
// Ops (op_i):
//   0 OP_HASH   : c3_o = SM3(m_buf[0 .. msg_len-1])
//   1 OP_KEYGEN : (rx_o, ry_o) = d * G          (pubkey)
//   2 OP_SIGN   : (sr_o, ss_o) = sign(d, e, k)  (err_o=1 -> retry with new k)
//   3 OP_VERIFY : valid_o = verify(PA, e, r, s)
//   4 OP_ENC    : C1=(rx_o,ry_o), C2->o_buf, C3->c3_o from (PB, k, m_buf)
//   5 OP_DEC    : M->o_buf, valid_o = (SM3(x2||M||y2) == s_in)  from (d, C1)
//
// Parameter load: p_we + p_sel + p_data (256-bit)
//   0:d 1:k 2:e 3:pa_x 4:pa_y 5:r_in 6:s_in(C3 for dec) 7:c1_x 8:c1_y
// Message buffer: m_we + m_addr(byte) + m_data(byte); msg_len via p_sel=9 low9b
// Output buffer read: o_addr -> o_data (C2 after ENC, M after DEC)
// msg_len <= 256 bytes.
//////////////////////////////////////////////////////////////////////////////////
module sm2_top (
    input               clk,
    input               rst_n,

    input               start,
    input  [2:0]        op_i,

    input               p_we,
    input  [3:0]        p_sel,
    input  [255:0]      p_data,

    input               m_we,
    input  [8:0]        m_addr,
    input  [7:0]        m_data,

    input  [8:0]        o_addr,
    output [7:0]        o_data,

    output reg          busy_o,
    output reg          done_o,
    output reg          err_o,
    output reg          valid_o,

    output reg [255:0]  rx_o,
    output reg [255:0]  ry_o,
    output reg [255:0]  sr_o,
    output reg [255:0]  ss_o,
    output reg [255:0]  c3_o
);

localparam OP_HASH   = 3'd0;
localparam OP_KEYGEN = 3'd1;
localparam OP_SIGN   = 3'd2;
localparam OP_VERIFY = 3'd3;
localparam OP_ENC    = 3'd4;
localparam OP_DEC    = 3'd5;

localparam [255:0] P256 = 256'hFFFFFFFE_FFFFFFFF_FFFFFFFF_FFFFFFFF_FFFFFFFF_00000000_FFFFFFFF_FFFFFFFF;
localparam [255:0] N256 = 256'hFFFFFFFE_FFFFFFFF_FFFFFFFF_FFFFFFFF_7203DF6B_21C6052B_53BBF409_39D54123;

// ---------------- parameter registers ---------------------------------------
reg [255:0] d_r, k_r, e_r, pax_r, pay_r, rin_r, sin_r, c1x_r, c1y_r;
reg [8:0]   msg_len;

always @(posedge clk) begin
    if (p_we) begin
        case (p_sel)
            4'd0: d_r   <= p_data;
            4'd1: k_r   <= p_data;
            4'd2: e_r   <= p_data;
            4'd3: pax_r <= p_data;
            4'd4: pay_r <= p_data;
            4'd5: rin_r <= p_data;
            4'd6: sin_r <= p_data;
            4'd7: c1x_r <= p_data;
            4'd8: c1y_r <= p_data;
            4'd9: msg_len <= p_data[8:0];
            default: ;
        endcase
    end
end

// ---------------- message buffers -------------------------------------------
reg [7:0] m_buf [0:255];   // input: plaintext (enc) / ciphertext (dec) / msg (hash)
reg [7:0] o_buf [0:255];   // output: ciphertext (enc) / plaintext (dec)

always @(posedge clk) begin
    if (m_we) m_buf[m_addr] <= m_data;
end
assign o_data = o_buf[o_addr];

// ---------------- submodule: ECC ---------------------------------------------
localparam ECC_PMUL_G = 2'd0;
localparam ECC_PMUL_P = 2'd1;
localparam ECC_PADD   = 2'd2;

reg          ecc_start;
reg  [1:0]   ecc_op;
reg  [255:0] ecc_k, ecc_ax, ecc_ay, ecc_bx, ecc_by;
wire         ecc_busy, ecc_done, ecc_inf, ecc_err;
wire [255:0] ecc_rx, ecc_ry;

sm2_ecc U_ecc(
    .clk(clk), .rst_n(rst_n),
    .start(ecc_start), .op_i(ecc_op), .k_i(ecc_k),
    .ax_i(ecc_ax), .ay_i(ecc_ay), .bx_i(ecc_bx), .by_i(ecc_by),
    .busy_o(ecc_busy), .done_o(ecc_done), .inf_o(ecc_inf), .err_o(ecc_err),
    .rx_o(ecc_rx), .ry_o(ecc_ry), .rz_o()
);

// ---------------- submodule: mod-n arithmetic --------------------------------
localparam MN_ADD = 2'd0;
localparam MN_SUB = 2'd1;
localparam MN_MUL = 2'd2;

reg          mn_start;
reg  [1:0]   mn_op;
reg  [255:0] mn_a, mn_b;
wire         mn_busy, mn_done;
wire [255:0] mn_r;

sm2_modn U_modn(
    .clk(clk), .rst_n(rst_n),
    .start(mn_start), .op_i(mn_op), .a_i(mn_a), .b_i(mn_b), .m_i(N256),
    .busy(mn_busy), .done(mn_done), .r_o(mn_r)
);

// ---------------- submodule: mod-n inverse -----------------------------------
reg          iv_start;
reg  [255:0] iv_a;
wire         iv_busy, iv_done, iv_err;
wire [255:0] iv_r;

sm2_mod_inv U_inv(
    .clk(clk), .rst_n(rst_n),
    .start(iv_start), .a_i(iv_a), .m_i(N256),
    .busy(iv_busy), .done(iv_done), .err(iv_err), .r_o(iv_r)
);

// ---------------- submodule: SM3 ---------------------------------------------
reg  [63:0]  h_d;
wire [7:0]   h_vb;
wire         h_vld, h_lst;
wire         h_rdy;
wire [255:0] h_res;
wire         h_rvld;

sm3_top U_sm3(
    .clk(clk), .rst_n(rst_n),
    .msg_inpt_d_i(h_d), .msg_inpt_vld_byte_i(h_vb),
    .msg_inpt_vld_i(h_vld), .msg_inpt_lst_i(h_lst),
    .msg_inpt_rdy_o(h_rdy),
    .cmprss_otpt_res_o(h_res), .cmprss_otpt_vld_o(h_rvld)
);

// ---------------- SM3 stream feeder ------------------------------------------
// feed_mode:
//   FEED_KDF : stream = x2(32B) || y2(32B) || ct32be(4B)          -> 68 B
//   FEED_C3  : stream = x2(32B) || src[0..msg_len-1] || y2(32B)   -> 64+len B
//   FEED_MSG : stream = m_buf[0..msg_len-1]                       -> len B
localparam FEED_KDF = 2'd0;
localparam FEED_C3  = 2'd1;
localparam FEED_MSG = 2'd2;

reg        feed_go;
reg  [1:0] feed_mode;
reg        feed_src_o;    // FEED_C3: 0 -> m_buf, 1 -> o_buf
wire       feed_done;

reg        f_active;
reg        f_dld;           // h_d holds the word for current f_pos
reg [15:0] f_pos, f_total;
reg [1:0]  f_mode;
reg        f_src_o;

reg [255:0] x2_r, y2_r;     // shared secret point for enc/dec
reg [31:0]  ct_r;           // KDF counter (big-endian on the wire)
reg [255:0] sig_r_r;        // scratch: r / R
reg [255:0] t_r, u_r;       // scratch: mod-n temps
reg [255:0] p1x_r, p1y_r;   // verify: s*G
reg [4:0]   grp_r;          // KDF group index
reg [4:0]   xb_r;           // byte index inside XOR group
reg [255:0] kdf_r;          // current KDF block

// byte read from the selected virtual stream
function [7:0] byte_at(input [15:0] p);
    reg [15:0] q;
    begin
        byte_at = 8'h00;
        if (f_mode == FEED_KDF) begin
            if (p < 16'd32)      byte_at = x2_r[255 - (p << 3) -: 8];
            else if (p < 16'd64) byte_at = y2_r[255 - ((p - 16'd32) << 3) -: 8];
            else if (p < 16'd68) byte_at = ct_r[31 - ((p - 16'd64) << 3) -: 8];
        end else if (f_mode == FEED_C3) begin
            if (p < 16'd32)
                byte_at = x2_r[255 - (p << 3) -: 8];
            else if (p < (16'd32 + {7'd0, msg_len}))
                byte_at = f_src_o ? o_buf[p - 16'd32] : m_buf[p - 16'd32];
            else begin
                q = p - 16'd32 - {7'd0, msg_len};
                if (q < 16'd32) byte_at = y2_r[255 - (q << 3) -: 8];
            end
        end else begin // FEED_MSG
            if (p < {7'd0, msg_len}) byte_at = m_buf[p];
        end
    end
endfunction

// feeder: one 64-bit word per accepted beat
wire [15:0] f_rem    = f_total - f_pos;                 // bytes remaining
wire        f_last   = (f_rem <= 16'd8);
wire [7:0]  f_vb     = (f_rem >= 16'd8) ? 8'hFF
                                          : (8'hFF << (4'd8 - f_rem[3:0]));

// NOTE: the word is assembled procedurally inside the clocked block below.
// (iverilog does not re-evaluate continuous-assign wires when regs that are
// only read inside a called function change, so a wire-based f_word can go
// stale across feed-mode switches.)
//
// sm3_pad_core ingests on EVERY cycle msg_inpt_vld_i is high and emits the
// word the following cycle unconditionally.  The expansion core guarantees
// that whenever pad rdy is high its next state still accepts a word (rdy is
// deasserted one cycle early for exactly this reason).  So vld must be
// combinational: asserted only in cycles where rdy is already high.  h_d is
// preloaded one word ahead so the data is stable while vld is asserted.
assign h_vld = f_active && f_dld && h_rdy;
assign h_vb  = f_vb;
// pad FSM samples lst without qualifying by vld, so lst must only be
// asserted on cycles where vld is actually high
assign h_lst = h_vld && f_last;

always @(posedge clk or negedge rst_n) begin
    if (~rst_n) begin
        f_active <= 0; f_dld <= 0; f_pos <= 0; f_total <= 0;
        f_mode <= 0; f_src_o <= 0; h_d <= 0;
    end else begin
        if (feed_go && !f_active) begin
            f_active <= 1'b1;
            f_dld    <= 1'b0;
            f_pos    <= 0;
            f_mode   <= feed_mode;
            f_src_o  <= feed_src_o;
            f_total  <= (feed_mode == FEED_KDF) ? 16'd68 :
                        (feed_mode == FEED_C3)  ? (16'd64 + {7'd0, msg_len}) :
                                                  {7'd0, msg_len};
        end else if (f_active && !f_dld) begin
            h_d   <= {byte_at(16'd0), byte_at(16'd1), byte_at(16'd2),
                      byte_at(16'd3), byte_at(16'd4), byte_at(16'd5),
                      byte_at(16'd6), byte_at(16'd7)};
            f_dld <= 1'b1;
        end else if (f_active && h_rdy) begin
            // current word is being ingested this cycle (h_vld == 1);
            // preload the next word
            h_d <= {byte_at(f_pos + 16'd8),  byte_at(f_pos + 16'd9),
                    byte_at(f_pos + 16'd10), byte_at(f_pos + 16'd11),
                    byte_at(f_pos + 16'd12), byte_at(f_pos + 16'd13),
                    byte_at(f_pos + 16'd14), byte_at(f_pos + 16'd15)};
            if (f_last) f_active <= 1'b0;
            else        f_pos <= f_pos + 16'd8;
        end
    end
end

assign feed_done = f_active && f_dld && h_rdy && f_last;  // last word ingested this edge

// ---------------- main sequencer ---------------------------------------------
localparam S_IDLE     = 6'd0;

localparam S_KG_GO    = 6'd1;
localparam S_KG_W     = 6'd2;

localparam S_SG_ECCW  = 6'd3;
localparam S_SG_R     = 6'd4;
localparam S_SG_RW    = 6'd5;
localparam S_SG_RD    = 6'd6;
localparam S_SG_RDW   = 6'd7;
localparam S_SG_KRD   = 6'd8;
localparam S_SG_KRDW  = 6'd9;
localparam S_SG_INV   = 6'd10;
localparam S_SG_INVW  = 6'd11;
localparam S_SG_SMUL  = 6'd12;
localparam S_SG_SMULW = 6'd13;

localparam S_V_CHK    = 6'd14;
localparam S_V_T      = 6'd15;
localparam S_V_TW     = 6'd16;
localparam S_V_ECC1W  = 6'd17;
localparam S_V_ECC2W  = 6'd18;
localparam S_V_ECC3W  = 6'd19;
localparam S_V_R      = 6'd20;
localparam S_V_RW     = 6'd21;
localparam S_V_FIN    = 6'd22;

localparam S_E_ECC1W  = 6'd23;
localparam S_E_ECC2W  = 6'd24;
localparam S_E_H3     = 6'd25;
localparam S_E_H3W    = 6'd26;
localparam S_E_KDF    = 6'd27;
localparam S_E_KDFW   = 6'd28;
localparam S_E_KDFD   = 6'd42;
localparam S_E_XOR    = 6'd29;
localparam S_E_NEXT   = 6'd30;

localparam S_D_ECCW   = 6'd31;
localparam S_D_H3     = 6'd32;
localparam S_D_H3W    = 6'd33;
localparam S_D_KDF    = 6'd34;
localparam S_D_KDFW   = 6'd35;
localparam S_D_KDFD   = 6'd43;
localparam S_D_XOR    = 6'd36;
localparam S_D_NEXT   = 6'd37;
localparam S_D_FIN    = 6'd38;

localparam S_H_GO     = 6'd39;
localparam S_H_W      = 6'd40;
localparam S_H_FIN    = 6'd41;

localparam S_FIN      = 6'd62;
localparam S_ERR      = 6'd63;

reg [5:0] state;

// number of KDF groups = ceil(msg_len/32)
wire [4:0] ngrp = {2'b0, msg_len[8:5]} + ((|msg_len[4:0]) ? 5'd1 : 5'd0);

// XOR-pass helpers
wire [8:0] xor_idx  = {grp_r[3:0], 5'd0} + {4'd0, xb_r};
wire [7:0] dig_byte = kdf_r[255 - (xb_r << 3) -: 8];

always @(posedge clk or negedge rst_n) begin
    if (~rst_n) begin
        state <= S_IDLE;
        busy_o <= 0; done_o <= 0; err_o <= 0; valid_o <= 0;
        rx_o <= 0; ry_o <= 0; sr_o <= 0; ss_o <= 0; c3_o <= 0;
        ecc_start <= 0; ecc_op <= 0; ecc_k <= 0;
        ecc_ax <= 0; ecc_ay <= 0; ecc_bx <= 0; ecc_by <= 0;
        mn_start <= 0; mn_op <= 0; mn_a <= 0; mn_b <= 0;
        iv_start <= 0; iv_a <= 0;
        feed_go <= 0; feed_mode <= 0; feed_src_o <= 0;
        x2_r <= 0; y2_r <= 0; ct_r <= 0;
        sig_r_r <= 0; t_r <= 0; u_r <= 0;
        p1x_r <= 0; p1y_r <= 0; grp_r <= 0; xb_r <= 0; kdf_r <= 0;
    end else begin
        done_o    <= 1'b0;
        ecc_start <= 1'b0;
        mn_start  <= 1'b0;
        iv_start  <= 1'b0;
        feed_go   <= 1'b0;
        case (state)
            // ------------------------------------------------------------------
            S_IDLE: begin
                err_o <= 1'b0; valid_o <= 1'b0;
                if (start) begin
                    busy_o <= 1'b1;
                    case (op_i)
                        OP_HASH:   state <= S_H_GO;
                        OP_KEYGEN: state <= S_KG_GO;
                        OP_SIGN:   begin
                            ecc_start <= 1'b1;
                            ecc_op    <= ECC_PMUL_G;
                            ecc_k     <= k_r;
                            state     <= S_SG_ECCW;
                        end
                        OP_VERIFY: state <= S_V_CHK;
                        OP_ENC: begin
                            ecc_start <= 1'b1;
                            ecc_op    <= ECC_PMUL_G;
                            ecc_k     <= k_r;
                            state     <= S_E_ECC1W;
                        end
                        OP_DEC: begin
                            ecc_start <= 1'b1;
                            ecc_op    <= ECC_PMUL_P;
                            ecc_k     <= d_r;
                            ecc_ax    <= c1x_r;
                            ecc_ay    <= c1y_r;
                            state     <= S_D_ECCW;
                        end
                        default: state <= S_FIN;
                    endcase
                end
            end

            // ---------------- KEYGEN: PA = d*G --------------------------------
            S_KG_GO: begin
                ecc_start <= 1'b1;
                ecc_op    <= ECC_PMUL_G;
                ecc_k     <= d_r;
                state     <= S_KG_W;
            end
            S_KG_W: begin
                if (ecc_done) begin
                    rx_o  <= ecc_rx; ry_o <= ecc_ry;
                    err_o <= ecc_err | ecc_inf;
                    state <= S_FIN;
                end
            end

            // ---------------- SIGN ---------------------------------------------
            S_SG_ECCW: begin                       // (x1,y1) = k*G
                if (ecc_done) begin
                    if (ecc_err | ecc_inf) state <= S_ERR;
                    else begin
                        x2_r    <= ecc_rx;        // reuse x2_r as x1
                        mn_a    <= e_r;           // r = (e + x1) mod n
                        mn_b    <= ecc_rx;
                        mn_op   <= MN_ADD;
                        mn_start<= 1'b1;
                        state   <= S_SG_RW;
                    end
                end
            end
            S_SG_RW: begin
                if (mn_done) begin
                    sig_r_r <= mn_r;
                    // reject if r == 0 or r + k == n
                    if (mn_r == 0 || (mn_r + k_r) == N256) state <= S_ERR;
                    else begin
                        mn_a     <= mn_r;         // t = r*d mod n
                        mn_b     <= d_r;
                        mn_op    <= MN_MUL;
                        mn_start <= 1'b1;
                        state    <= S_SG_RDW;
                    end
                end
            end
            S_SG_RDW: begin
                if (mn_done) begin
                    t_r      <= mn_r;
                    mn_a     <= k_r;              // u = k - t mod n
                    mn_b     <= mn_r;
                    mn_op    <= MN_SUB;
                    mn_start <= 1'b1;
                    state    <= S_SG_KRDW;
                end
            end
            S_SG_KRDW: begin
                if (mn_done) begin
                    u_r      <= mn_r;
                    iv_a     <= d_r + 256'd1;     // w = (1+d)^-1 mod n
                    iv_start <= 1'b1;
                    state    <= S_SG_INVW;
                end
            end
            S_SG_INVW: begin
                if (iv_done) begin
                    if (iv_err) state <= S_ERR;
                    else begin
                        t_r      <= iv_r;
                        mn_a     <= iv_r;         // s = w*u mod n
                        mn_b     <= u_r;
                        mn_op    <= MN_MUL;
                        mn_start <= 1'b1;
                        state    <= S_SG_SMULW;
                    end
                end
            end
            S_SG_SMULW: begin
                if (mn_done) begin
                    if (mn_r == 0) state <= S_ERR;   // s == 0 -> retry
                    else begin
                        sr_o  <= sig_r_r;
                        ss_o  <= mn_r;
                        state <= S_FIN;
                    end
                end
            end

            // ---------------- VERIFY -------------------------------------------
            S_V_CHK: begin
                // require 1 <= r,s <= n-1
                if (rin_r == 0 || rin_r >= N256 || sin_r == 0 || sin_r >= N256) begin
                    valid_o <= 1'b0;
                    state   <= S_FIN;
                end else begin
                    mn_a     <= rin_r;            // t = (r + s) mod n
                    mn_b     <= sin_r;
                    mn_op    <= MN_ADD;
                    mn_start <= 1'b1;
                    state    <= S_V_TW;
                end
            end
            S_V_TW: begin
                if (mn_done) begin
                    if (mn_r == 0) begin          // t == 0 -> invalid
                        valid_o <= 1'b0;
                        state   <= S_FIN;
                    end else begin
                        t_r       <= mn_r;
                        ecc_start <= 1'b1;        // P1 = s*G
                        ecc_op    <= ECC_PMUL_G;
                        ecc_k     <= sin_r;
                        state     <= S_V_ECC1W;
                    end
                end
            end
            S_V_ECC1W: begin
                if (ecc_done) begin
                    if (ecc_err | ecc_inf) begin valid_o <= 0; state <= S_FIN; end
                    else begin
                        p1x_r     <= ecc_rx;
                        p1y_r     <= ecc_ry;
                        ecc_start <= 1'b1;        // P2 = t*PA
                        ecc_op    <= ECC_PMUL_P;
                        ecc_k     <= t_r;
                        ecc_ax    <= pax_r;
                        ecc_ay    <= pay_r;
                        state     <= S_V_ECC2W;
                    end
                end
            end
            S_V_ECC2W: begin
                if (ecc_done) begin
                    if (ecc_err | ecc_inf) begin valid_o <= 0; state <= S_FIN; end
                    else begin
                        ecc_start <= 1'b1;        // (x1',y1') = P1 + P2
                        ecc_op    <= ECC_PADD;
                        ecc_ax    <= p1x_r;
                        ecc_ay    <= p1y_r;
                        ecc_bx    <= ecc_rx;
                        ecc_by    <= ecc_ry;
                        state     <= S_V_ECC3W;
                    end
                end
            end
            S_V_ECC3W: begin
                if (ecc_done) begin
                    if (ecc_err | ecc_inf) begin valid_o <= 0; state <= S_FIN; end
                    else begin
                        mn_a     <= e_r;          // R = (e + x1') mod n
                        mn_b     <= ecc_rx;
                        mn_op    <= MN_ADD;
                        mn_start <= 1'b1;
                        state    <= S_V_RW;
                    end
                end
            end
            S_V_RW: begin
                if (mn_done) begin
                    u_r   <= mn_r;
                    state <= S_V_FIN;
                end
            end
            S_V_FIN: begin
                valid_o <= (u_r == rin_r);
                state   <= S_FIN;
            end

            // ---------------- ENCRYPT ------------------------------------------
            S_E_ECC1W: begin                       // C1 = k*G
                if (ecc_done) begin
                    if (ecc_err | ecc_inf) state <= S_ERR;
                    else begin
                        rx_o      <= ecc_rx;
                        ry_o      <= ecc_ry;
                        ecc_start <= 1'b1;        // (x2,y2) = k*PB
                        ecc_op    <= ECC_PMUL_P;
                        ecc_k     <= k_r;
                        ecc_ax    <= pax_r;
                        ecc_ay    <= pay_r;
                        state     <= S_E_ECC2W;
                    end
                end
            end
            S_E_ECC2W: begin
                if (ecc_done) begin
                    if (ecc_err | ecc_inf) state <= S_ERR;
                    else begin
                        x2_r       <= ecc_rx;
                        y2_r       <= ecc_ry;
                        feed_go    <= 1'b1;       // C3 = SM3(x2||M||y2)
                        feed_mode  <= FEED_C3;
                        feed_src_o <= 1'b0;
                        state      <= S_E_H3W;
                    end
                end
            end
            S_E_H3W: begin
                if (feed_done) state <= S_E_H3;
            end
            S_E_H3: begin
                if (h_rvld) begin
                    c3_o  <= h_res;
                    grp_r <= 0;
                    state <= S_E_KDF;
                end
            end
            S_E_KDF: begin
                if (grp_r >= ngrp || ngrp == 0) begin
                    state <= S_FIN;
                end else begin
                    ct_r      <= {27'd0, grp_r} + 32'd1;
                    feed_go   <= 1'b1;
                    feed_mode <= FEED_KDF;
                    state     <= S_E_KDFW;
                end
            end
            S_E_KDFW: begin
                if (feed_done) state <= S_E_KDFD;
            end
            S_E_KDFD: begin                        // wait for KDF block digest
                if (h_rvld) begin
                    kdf_r <= h_res;
                    xb_r  <= 0;
                    state <= S_E_XOR;
                end
            end
            S_E_XOR: begin                         // one byte per cycle
                if (xor_idx < msg_len)
                    o_buf[xor_idx[7:0]] <= m_buf[xor_idx[7:0]] ^ dig_byte;
                if (xb_r == 5'd31 || (xor_idx + 9'd1) >= {7'd0, msg_len})
                    state <= S_E_NEXT;
                else
                    xb_r <= xb_r + 5'd1;
            end
            S_E_NEXT: begin
                grp_r <= grp_r + 5'd1;
                state <= S_E_KDF;
            end

            // ---------------- DECRYPT ------------------------------------------
            S_D_ECCW: begin                        // (x2,y2) = d*C1
                if (ecc_done) begin
                    if (ecc_err | ecc_inf) state <= S_ERR;
                    else begin
                        x2_r  <= ecc_rx;
                        y2_r  <= ecc_ry;
                        grp_r <= 0;
                        state <= S_D_KDF;
                    end
                end
            end
            S_D_KDF: begin
                if (grp_r >= ngrp || ngrp == 0) begin
                    feed_go    <= 1'b1;           // u = SM3(x2||M||y2)
                    feed_mode  <= FEED_C3;
                    feed_src_o <= 1'b1;
                    state      <= S_D_H3W;
                end else begin
                    ct_r      <= {27'd0, grp_r} + 32'd1;
                    feed_go   <= 1'b1;
                    feed_mode <= FEED_KDF;
                    state     <= S_D_KDFW;
                end
            end
            S_D_KDFW: begin
                if (feed_done) state <= S_D_KDFD;
            end
            S_D_KDFD: begin
                if (h_rvld) begin
                    kdf_r <= h_res;
                    xb_r  <= 0;
                    state <= S_D_XOR;
                end
            end
            S_D_XOR: begin
                if (xor_idx < msg_len)
                    o_buf[xor_idx[7:0]] <= m_buf[xor_idx[7:0]] ^ dig_byte;
                if (xb_r == 5'd31 || (xor_idx + 9'd1) >= {7'd0, msg_len})
                    state <= S_D_NEXT;
                else
                    xb_r <= xb_r + 5'd1;
            end
            S_D_NEXT: begin
                grp_r <= grp_r + 5'd1;
                state <= S_D_KDF;
            end
            S_D_H3W: begin
                if (feed_done) state <= S_D_H3;
            end
            S_D_H3: begin
                if (h_rvld) begin
                    c3_o    <= h_res;
                    valid_o <= (h_res == sin_r);  // sin_r holds expected C3
                    state   <= S_D_FIN;
                end
            end
            S_D_FIN: state <= S_FIN;

            // ---------------- HASH ---------------------------------------------
            S_H_GO: begin
                feed_go   <= 1'b1;
                feed_mode <= FEED_MSG;
                state     <= S_H_W;
            end
            S_H_W: begin
                if (feed_done) state <= S_H_FIN;
            end
            S_H_FIN: begin
                if (h_rvld) begin
                    c3_o  <= h_res;
                    state <= S_FIN;
                end
            end

            // ---------------- finish -------------------------------------------
            S_FIN: begin
                busy_o <= 1'b0; done_o <= 1'b1;
                state  <= S_IDLE;
            end
            S_ERR: begin
                err_o  <= 1'b1;
                busy_o <= 1'b0; done_o <= 1'b1;
                state  <= S_IDLE;
            end
            default: state <= S_IDLE;
        endcase
    end
end

endmodule
