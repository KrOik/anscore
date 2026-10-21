`timescale 1ns / 1ps
// ips_rle_codec : run-length codec over a byte stream with literal/run token
// packing, an encode and a decode direction, output backpressure, and a sticky
// overflow whenever a run needs more of the encoded run field than this
// configuration carries.
//
// Token packing, one control byte plus one data byte per token:
//     ctrl = { REP, RUN[6:0] }   data = payload byte
//   REP : 1 = repeat token (carries RUN+1 copies of data), 0 = literal token
//         (carries exactly one copy and must have RUN = 0).
//   RUN : run length minus one, so the 7-bit field spans runs of 1..128 bytes.
//
// MAX_RUN is the run capacity this codec configuration advertises.  A run longer
// than MAX_RUN never wraps or truncates silently:
//   * encode (dir = 0): the run is packed as consecutive full MAX_RUN repeat
//     tokens, err_sticky[0] latches and run_ovf counts the continuation bytes that
//     did not fit in the first token, so the emitted stream stays decodable.
//   * decode (dir = 1): a token asking for more than MAX_RUN bytes is still
//     expanded (transparency), but latches err_sticky[1] and counts tok_ovf.
// err_sticky[2] latches protocol violations: a direction change or an in_last
// marker that lands while a token is still in flight, and literal tokens with a
// non-zero run field.  Every counter saturates and latches its own cnt_sat bit, so
// saturation is reported instead of being hidden.
//
// Handshake: in_ready is the accept flag, low while the single-deep output register
// still holds an untouched byte, or while the core has a token burst or a tail
// token in flight; bytes presented while in_ready is low are not consumed.  busy
// flags any in-flight work, out_tok_infl marks a token burst that is still being
// emitted, out_valid/out_byte carry the produced stream (out_valid stays asserted
// until out_ready takes the byte), and run_len exposes the run the encoder is
// currently gathering.  in_last closes the current packet: the encoder emits the
// token for the bytes it holds, including a trailing single byte, and the decoder
// treats an in_last that lands on a control byte as a dangling token.
//
// Every register is gated by clk_en and rst_n is the active-low asynchronous
// reset, per docs/IP_CORE_SOP.md (trap T2).  Only fixed increments and the
// ctrl[6:0] + 1 field decode are used, so there is no DSP (trap T4).
module ips_rle_codec #(
    parameter MAX_RUN = 20
)(
    input  wire        clk,
    input  wire        clk_en,
    input  wire        rst_n,

    input  wire        dir,
    input  wire        in_valid,
    input  wire        in_last,
    input  wire  [7:0] in_byte,
    input  wire        out_ready,

    output wire        in_ready,
    output wire        busy,
    output wire        out_tok_infl,
    output reg         out_valid,
    output reg   [7:0] out_byte,
    output reg   [7:0] run_len,
    output reg   [5:0] tok_cnt,
    output reg   [4:0] lit_cnt,
    output reg   [4:0] run_ovf,
    output reg   [4:0] tok_ovf,
    output reg   [7:0] exp_cnt,
    output reg   [3:0] err_proto,
    output reg   [2:0] err_sticky,
    output reg   [4:0] cnt_sat
);

// Control-byte encodings and the unit quantities the packing arithmetic is built
// from.  These are the values a system integrator re-targets, so they are declared
// here as the datapath steering constants rather than being spread inline.
localparam [7:0] TOK_LIT    = 8'h00;
localparam [7:0] TOK_REP    = 8'h80;
localparam [7:0] RUN_ONE    = 8'h01;
localparam [7:0] EXP_LIT_N  = 8'h01;
localparam [7:0] EXP_LAST   = 8'h01;

localparam [7:0] CAP_MAX    = MAX_RUN;
localparam [7:0] CAP_FIELD  = MAX_RUN - 1;
localparam [4:0] LIM5       = 5'h1F;
localparam [5:0] LIM6       = 6'h3F;
localparam [7:0] LIM8       = 8'hFF;
localparam [3:0] LIM4       = 4'hF;

localparam [1:0] E_RUN  = 2'd0;
localparam [1:0] E_TOKC = 2'd1;
localparam [1:0] E_TOKD = 2'd2;
localparam [1:0] D_CTRL = 2'd0;
localparam [1:0] D_DATA = 2'd1;
localparam [1:0] D_EXP  = 2'd2;

reg       dir_r;
reg [1:0] est;
reg [1:0] dst;
reg       have;
reg       cont_r;
reg       tail_pend;
reg       rep_r;
reg [7:0] prev;
reg [7:0] ctrl_r;
reg [7:0] dbyte;
reg [7:0] exp_len;
reg [7:0] tok_ctrl;
reg [7:0] tok_data;

wire [7:0] run_req   = {1'b0, ctrl_r[6:0]} + RUN_ONE;
wire       slot_free = !out_valid || out_ready;
wire       rx_state  = dir ? ((dst == D_CTRL) || (dst == D_DATA))
                           : ((est == E_RUN) && !tail_pend);
wire       enc_infl  = (est != E_RUN) || tail_pend;
wire       dec_infl  = (dst != D_CTRL);

assign in_ready     = slot_free && rx_state;
assign busy         = out_valid || enc_infl || dec_infl || cont_r || have;
assign out_tok_infl = enc_infl || (rep_r && (dst == D_EXP));

always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        dir_r     <= 1'b0;
        est       <= E_RUN;
        dst       <= D_CTRL;
        have      <= 1'b0;
        cont_r    <= 1'b0;
        tail_pend <= 1'b0;
        rep_r     <= 1'b0;
        prev      <= 8'h00;
        ctrl_r    <= 8'h00;
        dbyte     <= 8'h00;
        exp_len   <= 8'h00;
        tok_ctrl  <= 8'h00;
        tok_data  <= 8'h00;
        out_valid <= 1'b0;
        out_byte  <= 8'h00;
        run_len   <= 8'h00;
        tok_cnt   <= 6'h00;
        lit_cnt   <= 5'h00;
        run_ovf   <= 5'h00;
        tok_ovf   <= 5'h00;
        exp_cnt   <= 8'h00;
        err_proto <= 4'h0;
        err_sticky <= 3'h0;
        cnt_sat   <= 5'h0;
    end else if (clk_en) begin
        if (out_valid && out_ready) begin
            out_valid <= 1'b0;
            if (exp_cnt < LIM8) begin
                exp_cnt <= exp_cnt + 8'h01;
            end else begin
                cnt_sat[4] <= 1'b1;
            end
        end
        if (dir != dir_r) begin
            // Direction change: anything still in flight is a protocol violation.
            dir_r <= dir;
            if (out_valid || enc_infl || dec_infl) begin
                err_sticky[2] <= 1'b1;
                if (err_proto < LIM4) begin
                    err_proto <= err_proto + 4'h1;
                end else begin
                    cnt_sat[3] <= 1'b1;
                end
            end
            est       <= E_RUN;
            dst       <= D_CTRL;
            have      <= 1'b0;
            cont_r    <= 1'b0;
            tail_pend <= 1'b0;
            rep_r     <= 1'b0;
            run_len   <= 8'h00;
            out_valid <= 1'b0;
        end else if (dir == 1'b0) begin
            // ------------------------------- encode -----------------------------
            if (tail_pend && slot_free) begin
                tok_ctrl  <= TOK_LIT;
                tok_data  <= prev;
                tail_pend <= 1'b0;
                est       <= E_TOKC;
            end else if (est == E_RUN) begin
                if (in_valid && slot_free) begin
                    if (!have) begin
                        prev    <= in_byte;
                        run_len <= RUN_ONE;
                        have    <= 1'b1;
                        cont_r  <= 1'b0;
                        if (cont_r && (in_byte == prev)) begin
                            // the previous token filled the run field, so this byte
                            // extends a run that is longer than MAX_RUN
                            err_sticky[0] <= 1'b1;
                            if (run_ovf < LIM5) begin
                                run_ovf <= run_ovf + 5'h01;
                            end else begin
                                cnt_sat[2] <= 1'b1;
                            end
                        end
                        if (in_last) begin
                            tail_pend <= 1'b1;
                            have      <= 1'b0;
                        end
                    end else if (in_byte == prev) begin
                        if (run_len == CAP_FIELD) begin
                            // this byte completes a full-field token
                            tok_ctrl <= TOK_REP | CAP_FIELD;
                            tok_data <= prev;
                            run_len  <= run_len + RUN_ONE;
                            have     <= 1'b0;
                            cont_r   <= ~in_last;
                            est      <= E_TOKC;
                        end else begin
                            run_len <= run_len + RUN_ONE;
                            if (in_last) begin
                                tok_ctrl <= TOK_REP | {1'b0, run_len[6:0]};
                                tok_data <= prev;
                                have     <= 1'b0;
                                cont_r   <= 1'b0;
                                est      <= E_TOKC;
                            end
                        end
                    end else begin
                        if (run_len > RUN_ONE) begin
                            tok_ctrl <= TOK_REP | ({1'b0, run_len[6:0]} - RUN_ONE);
                        end else begin
                            tok_ctrl <= TOK_LIT;
                        end
                        tok_data <= prev;
                        prev     <= in_byte;
                        run_len  <= RUN_ONE;
                        have     <= 1'b1;
                        cont_r   <= 1'b0;
                        est      <= E_TOKC;
                        if (in_last) begin
                            tail_pend <= 1'b1;
                        end
                    end
                end
            end else if (est == E_TOKC) begin
                if (slot_free) begin
                    out_byte  <= tok_ctrl;
                    out_valid <= 1'b1;
                    est       <= E_TOKD;
                end
            end else if (est == E_TOKD) begin
                if (slot_free) begin
                    out_byte  <= tok_data;
                    out_valid <= 1'b1;
                    est       <= E_RUN;
                    if (tok_cnt < LIM6) begin
                        tok_cnt <= tok_cnt + 6'h01;
                    end else begin
                        cnt_sat[0] <= 1'b1;
                    end
                    if (!tok_ctrl[7]) begin
                        if (lit_cnt < LIM5) begin
                            lit_cnt <= lit_cnt + 5'h01;
                        end else begin
                            cnt_sat[1] <= 1'b1;
                        end
                    end
                end
            end
        end else begin
            // ------------------------------- decode -----------------------------
            if (dst == D_CTRL) begin
                if (in_valid && slot_free) begin
                    ctrl_r <= in_byte;
                    rep_r  <= in_byte[7];
                    if (in_last) begin
                        // dangling control byte: its data byte never arrives
                        err_sticky[2] <= 1'b1;
                        if (err_proto < LIM4) begin
                            err_proto <= err_proto + 4'h1;
                        end else begin
                            cnt_sat[3] <= 1'b1;
                        end
                        dst <= D_CTRL;
                    end else begin
                        dst <= D_DATA;
                    end
                end
            end else if (dst == D_DATA) begin
                if (in_valid && slot_free) begin
                    dbyte <= in_byte;
                    dst   <= D_EXP;
                    if (ctrl_r[7]) begin
                        exp_len <= run_req;
                        if (run_req > CAP_MAX) begin
                            err_sticky[1] <= 1'b1;
                            if (tok_ovf < LIM5) begin
                                tok_ovf <= tok_ovf + 5'h01;
                            end else begin
                                cnt_sat[2] <= 1'b1;
                            end
                        end
                    end else begin
                        exp_len <= EXP_LIT_N;
                        if (ctrl_r[6:0] != 7'h00) begin
                            err_sticky[2] <= 1'b1;
                            if (err_proto < LIM4) begin
                                err_proto <= err_proto + 4'h1;
                            end else begin
                                cnt_sat[3] <= 1'b1;
                            end
                        end
                    end
                end
            end else if (dst == D_EXP) begin
                if (slot_free) begin
                    out_byte  <= dbyte;
                    out_valid <= 1'b1;
                    exp_len   <= exp_len - RUN_ONE;
                    if (exp_len == EXP_LAST) begin
                        dst   <= D_CTRL;
                        rep_r <= 1'b0;
                    end
                end
            end
        end
    end
end

endmodule
