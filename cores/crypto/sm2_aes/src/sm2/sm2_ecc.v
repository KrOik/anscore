`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// sm2_ecc.v — 二改新增模块
// Scalar point multiplication / point addition sequencer for the SM2 curve
// (sm2p256v1) on top of the vendored microcoded datapath point_cal_top
// (single-ALU configuration).
//
// Ops:
//   OP_PMUL_G : R = k * G
//   OP_PMUL_P : R = k * P     (P = (ax_i, ay_i), affine)
//   OP_PADD   : R = A + B     (A = (ax_i, ay_i), B = (bx_i, by_i), affine)
//
// Result is converted to affine coordinates (rx_o, ry_o) via a binary
// extended-GCD modular inversion (sm2_mod_inv).
// inf_o  : result is the point at infinity (k=0, or A=-B)
// err_o  : inversion failed / internal error
//
// Microcode: Jacobian point double / mixed Jacobian-affine point add lists
// ported from the vendored testbench tasks, serialized onto lane 0.
// (The original 3-lane issue relies on parallel read-old/write-new
// semantics; the serialized order below preserves that by scheduling a
// writer after all readers of the same register within a round.)
//////////////////////////////////////////////////////////////////////////////////
module sm2_ecc #(
    // JAC_ONLY=1: skip the embedded modular inverter and return the raw
    // Jacobian result (rx_o,ry_o,rz_o).  Used by the resource-constrained
    // board image; the host then performs z^{-1} and the affine scaling.
    parameter JAC_ONLY = 0
)(
    input               clk,
    input               rst_n,

    input               start,
    input  [1:0]        op_i,
    input  [255:0]      k_i,
    input  [255:0]      ax_i,
    input  [255:0]      ay_i,
    input  [255:0]      bx_i,
    input  [255:0]      by_i,

    output reg          busy_o,
    output reg          done_o,
    output reg          inf_o,
    output reg          err_o,
    output reg [255:0]  rx_o,
    output reg [255:0]  ry_o,
    output reg [255:0]  rz_o
);

localparam OP_PMUL_G = 2'd0;
localparam OP_PMUL_P = 2'd1;
localparam OP_PADD   = 2'd2;

// SM2 curve parameters
localparam [255:0] P256 = 256'hFFFFFFFE_FFFFFFFF_FFFFFFFF_FFFFFFFF_FFFFFFFF_00000000_FFFFFFFF_FFFFFFFF;
localparam [255:0] GX   = 256'h32C4AE2C_1F198119_5F990446_6A39C994_8FE30BBF_F2660BE1_715A4589_334C74C7;
localparam [255:0] GY   = 256'hBC3736A2_F4F6779C_59BDCEE3_6B692153_D0A9877C_C62A4740_02DF32E5_2139F0A0;

// instruction fields (see point_cal_top)
localparam [1:0] OP_MUL = 2'b00, OP_ADD = 2'b01, OP_SUB = 2'b10, OP_NUL = 2'b11;
localparam [1:0] T_CAL = 2'b00, T_UPD = 2'b01, T_FIN = 2'b10, T_NUL = 2'b11;

// operand register ids
localparam [3:0] R_X2=4'd0, R_Y2=4'd1, R_Z2=4'd2, R_T0=4'd3, R_T1=4'd4, R_T2=4'd5;
localparam [3:0] R_X0=4'd6, R_Y0=4'd7, R_Z0=4'd8, R_X1=4'd9, R_Y1=4'd10, R_Z1=4'd11;
localparam [3:0] R_NUL=4'd15;

// ---------------- microcode ROM (serialized onto lane 0) --------------------
// idx  0..21 : point double, full (first double after point load)
//        1..21: point double, fast (Z^2 already precomputed in T2)
// idx 22..40 : point add, full
// idx 23..40 : point add, fast (T2=Z0^2, T0=Z0*Y1 precomputed by prior double)
// idx 41..44 : affine conversion (cnst_x1 must hold z^{-1})
function [15:0] uc_rom(input [5:0] idx);
    case (idx)
        // ---- point double ----
        6'd0 : uc_rom = {OP_MUL,T_CAL,R_Z0,R_Z0,R_T2};   // T2 = Z0^2
        6'd1 : uc_rom = {OP_SUB,T_CAL,R_X0,R_T2,R_X2};   // X2 = X0 - T2
        6'd2 : uc_rom = {OP_ADD,T_CAL,R_X0,R_T2,R_Y2};   // Y2 = X0 + T2
        6'd3 : uc_rom = {OP_MUL,T_CAL,R_Y2,R_X2,R_Y2};   // Y2 = Y2*X2
        6'd4 : uc_rom = {OP_MUL,T_CAL,R_Y0,R_Y0,R_T0};   // T0 = Y0^2
        6'd5 : uc_rom = {OP_MUL,T_CAL,R_Y0,R_Z0,R_Z2};   // Z2 = Y0*Z0
        6'd6 : uc_rom = {OP_ADD,T_CAL,R_T0,R_T0,R_T0};   // T0 = 2*T0
        6'd7 : uc_rom = {OP_ADD,T_CAL,R_Y2,R_Y2,R_T2};   // T2 = 2*Y2
        6'd8 : uc_rom = {OP_ADD,T_CAL,R_Z2,R_Z2,R_Z2};   // Z2 = 2*Z2
        6'd9 : uc_rom = {OP_ADD,T_CAL,R_Y2,R_T2,R_Y2};   // Y2 = Y2 + T2
        6'd10: uc_rom = {OP_MUL,T_CAL,R_Y2,R_Y2,R_T2};   // T2 = Y2^2
        6'd11: uc_rom = {OP_MUL,T_CAL,R_T0,R_T0,R_T1};   // T1 = T0^2   (before T0 update)
        6'd12: uc_rom = {OP_MUL,T_CAL,R_T0,R_X0,R_T0};   // T0 = T0*X0
        6'd13: uc_rom = {OP_ADD,T_CAL,R_T0,R_T0,R_T0};   // T0 = 2*T0
        6'd14: uc_rom = {OP_ADD,T_CAL,R_T0,R_T0,R_X2};   // X2 = 2*T0
        6'd15: uc_rom = {OP_SUB,T_CAL,R_T2,R_X2,R_X2};   // X2 = T2 - X2
        6'd16: uc_rom = {OP_ADD,T_CAL,R_T1,R_T1,R_T1};   // T1 = 2*T1
        6'd17: uc_rom = {OP_SUB,T_CAL,R_T0,R_X2,R_T0};   // T0 = T0 - X2
        6'd18: uc_rom = {OP_MUL,T_CAL,R_Y2,R_T0,R_Y2};   // Y2 = Y2*T0
        6'd19: uc_rom = {OP_MUL,T_CAL,R_Z2,R_Z2,R_T2};   // T2 = Z2^2  (precompute)
        6'd20: uc_rom = {OP_MUL,T_CAL,R_Z2,R_Y1,R_T0};   // T0 = Z2*Y1 (precompute)
        6'd21: uc_rom = {OP_SUB,T_CAL,R_Y2,R_T1,R_Y2};   // Y2 = Y2 - T1
        // ---- point add ----
        6'd22: uc_rom = {OP_MUL,T_CAL,R_Z0,R_Z0,R_T2};   // T2 = Z0^2
        6'd23: uc_rom = {OP_MUL,T_CAL,R_Z0,R_Y1,R_T0};   // T0 = Z0*Y1
        6'd24: uc_rom = {OP_MUL,T_CAL,R_T2,R_T0,R_T1};   // T1 = T2*T0 (=Y1*Z0^3)
        6'd25: uc_rom = {OP_MUL,T_CAL,R_X1,R_T2,R_Z2};   // Z2 = X1*T2 (=X1*Z0^2)
        6'd26: uc_rom = {OP_SUB,T_CAL,R_Z2,R_X0,R_T0};   // T0 = Z2 - X0 (H)
        6'd27: uc_rom = {OP_SUB,T_CAL,R_T1,R_Y0,R_T1};   // T1 = T1 - Y0 (R)
        6'd28: uc_rom = {OP_MUL,T_CAL,R_T0,R_Z0,R_Z2};   // Z2 = T0*Z0 (H*Z0)
        6'd29: uc_rom = {OP_MUL,T_CAL,R_T0,R_T0,R_T2};   // T2 = T0^2  (H^2)
        6'd30: uc_rom = {OP_MUL,T_CAL,R_T0,R_T2,R_Y2};   // Y2 = T0*T2 (H^3)
        6'd31: uc_rom = {OP_MUL,T_CAL,R_T2,R_X0,R_T2};   // T2 = T2*X0 (H^2*X0)
        6'd32: uc_rom = {OP_MUL,T_CAL,R_T1,R_T1,R_X2};   // X2 = T1^2  (R^2)
        6'd33: uc_rom = {OP_SUB,T_CAL,R_X2,R_Y2,R_X2};   // X2 = X2 - Y2
        6'd34: uc_rom = {OP_ADD,T_CAL,R_T2,R_T2,R_T0};   // T0 = 2*T2
        6'd35: uc_rom = {OP_SUB,T_CAL,R_X2,R_T0,R_X2};   // X2 = X2 - T0
        6'd36: uc_rom = {OP_SUB,T_CAL,R_T2,R_X2,R_T2};   // T2 = T2 - X2
        6'd37: uc_rom = {OP_MUL,T_CAL,R_T1,R_T2,R_T1};   // T1 = T1*T2
        6'd38: uc_rom = {OP_MUL,T_CAL,R_Y0,R_Y2,R_Y2};   // Y2 = Y0*Y2
        6'd39: uc_rom = {OP_MUL,T_CAL,R_Z2,R_Z2,R_T2};   // T2 = Z2^2 (precompute)
        6'd40: uc_rom = {OP_SUB,T_CAL,R_T1,R_Y2,R_Y2};   // Y2 = T1 - Y2
        // ---- affine conversion (cnst_x1 = z^{-1}) ----
        6'd41: uc_rom = {OP_MUL,T_CAL,R_X1,R_X1,R_T0};   // T0 = zi^2
        6'd42: uc_rom = {OP_MUL,T_CAL,R_X2,R_T0,R_X2};   // X2 = X2*zi^2
        6'd43: uc_rom = {OP_MUL,T_CAL,R_T0,R_X1,R_T0};   // T0 = zi^3
        6'd44: uc_rom = {OP_MUL,T_CAL,R_Y2,R_T0,R_Y2};   // Y2 = Y2*zi^3
        default: uc_rom = {OP_NUL,T_NUL,R_NUL,R_NUL,R_NUL};
    endcase
endfunction

// ---------------- submodule: microcoded datapath ---------------------------
reg  [15:0]  ins0;
reg          ins_vld;
reg  [255:0] data_path;
wire [255:0] var_x2, var_y2, var_z2;
wire         cal_done;

point_cal_top U_pcal(
    .clk(clk), .rst_n(rst_n),
    .ins_0_i(ins0),
    .ins_1_i(16'hFFFF),
    .ins_2_i(16'hFFFF),
    .ins_vld_i(ins_vld),
    .data_path_i(data_path),
    .var_x2_o(var_x2), .var_y2_o(var_y2), .var_z2_o(var_z2),
    .intr_cal_done_o(cal_done)
);

// ---------------- submodule: modular inversion ------------------------------
reg          inv_start;
reg  [255:0] inv_a, inv_m;
wire         inv_busy, inv_done, inv_err;
wire [255:0] inv_r;

generate
if (JAC_ONLY) begin : g_no_inv
    assign inv_busy = 1'b0;
    assign inv_done = 1'b0;
    assign inv_err  = 1'b0;
    assign inv_r    = 256'd0;
end else begin : g_inv
    sm2_mod_inv U_inv(
        .clk(clk), .rst_n(rst_n),
        .start(inv_start), .a_i(inv_a), .m_i(inv_m),
        .busy(inv_busy), .done(inv_done), .err(inv_err), .r_o(inv_r)
    );
end
endgenerate

// ---------------- sequencer FSM ---------------------------------------------
// Lists run: S_UC_ISSUE/S_UC_WAIT drive uc_rom indices [uc_idx..uc_end].
// After a list completes, dispatch is selected by post_sel:
//   POST_FIN_PD : issue FIN, then check current k bit (PA if set, else advance)
//   POST_FIN_PA : issue FIN, then advance to next k bit
//   POST_AFF    : go to affine conversion (no FIN needed)
localparam [1:0] POST_FIN_PD = 2'd0;
localparam [1:0] POST_FIN_PA = 2'd1;
localparam [1:0] POST_AFF    = 2'd2;
localparam [1:0] POST_DONE   = 2'd3;

localparam S_IDLE      = 5'd0;
localparam S_LD_ISSUE  = 5'd1;
localparam S_LD_WAIT   = 5'd2;
localparam S_SCAN      = 5'd3;
localparam S_K1        = 5'd4;   // k == 1 special case: result = base point
localparam S_UC_ISSUE  = 5'd5;
localparam S_UC_WAIT   = 5'd6;
localparam S_GAP       = 5'd7;
localparam S_FIN_ISSUE = 5'd8;
localparam S_FIN_WAIT  = 5'd9;
localparam S_POST      = 5'd10;
localparam S_NEXT      = 5'd11;
localparam S_AFF_ZCHK  = 5'd12;
localparam S_AFF_INV   = 5'd13;
localparam S_AFF_LDW   = 5'd14;
localparam S_DONE_ERR  = 5'd15;
localparam S_CAPTURE   = 5'd16;

reg [4:0]    state;
reg [8:0]    bit_cnt;        // remaining k bits to process
reg [255:0]  k_shft;         // left-shifting scalar (MSB = current bit)
reg          first_pd;       // first point-double needs the full round list
reg [5:0]    uc_idx;
reg [5:0]    uc_end;
reg [1:0]    post_sel;
reg [2:0]    ld_cnt;
reg [3:0]    wait_cnt;
reg [1:0]    op_reg;
reg [255:0]  base_x, base_y;
reg [255:0]  add_x, add_y;
reg          run_pd;

// data / reg-id selection for cnst loads: order x0,y0,z0,x1,y1,z1
wire [255:0] ld_data =
    (ld_cnt == 3'd0) ? base_x :
    (ld_cnt == 3'd1) ? base_y :
    (ld_cnt == 3'd2) ? 256'd1 :
    (ld_cnt == 3'd3) ? add_x  :
    (ld_cnt == 3'd4) ? add_y  :
                       256'd1 ;
wire [3:0] ld_reg =
    (ld_cnt == 3'd0) ? R_X0 :
    (ld_cnt == 3'd1) ? R_Y0 :
    (ld_cnt == 3'd2) ? R_Z0 :
    (ld_cnt == 3'd3) ? R_X1 :
    (ld_cnt == 3'd4) ? R_Y1 :
                       R_Z1 ;

always @(posedge clk or negedge rst_n) begin
    if (~rst_n) begin
        state <= S_IDLE;
        busy_o <= 0; done_o <= 0; inf_o <= 0; err_o <= 0;
        rx_o <= 0; ry_o <= 0; rz_o <= 0;
        ins0 <= {OP_NUL,T_NUL,R_NUL,R_NUL,R_NUL};
        ins_vld <= 0; data_path <= 0;
        inv_start <= 0; inv_a <= 0; inv_m <= 0;
        bit_cnt <= 0; k_shft <= 0; first_pd <= 0;
        uc_idx <= 0; uc_end <= 0; post_sel <= POST_FIN_PD;
        ld_cnt <= 0; wait_cnt <= 0;
        op_reg <= 0; base_x <= 0; base_y <= 0; add_x <= 0; add_y <= 0;
        run_pd <= 0;
    end else begin
        done_o <= 1'b0;
        case (state)
            // --------------------------------------------------------------
            S_IDLE: begin
                err_o <= 1'b0;
                inf_o <= 1'b0;
                if (start) begin
                    busy_o <= 1'b1;
                    op_reg <= op_i;
                    base_x <= (op_i == OP_PMUL_G) ? GX : ax_i;
                    base_y <= (op_i == OP_PMUL_G) ? GY : ay_i;
                    add_x  <= (op_i == OP_PADD)   ? bx_i :
                              (op_i == OP_PMUL_G) ? GX  : ax_i;
                    add_y  <= (op_i == OP_PADD)   ? by_i :
                              (op_i == OP_PMUL_G) ? GY  : ay_i;
                    k_shft   <= k_i;
                    bit_cnt  <= 9'd256;
                    first_pd <= 1'b1;
                    ld_cnt   <= 0;
                    run_pd   <= (op_i != OP_PADD);
                    state    <= S_LD_ISSUE;
                end
            end

            // ---- load cnst registers via UPDT_REG ---------------------------
            S_LD_ISSUE: begin
                ins0      <= {OP_NUL, T_UPD, R_NUL, R_NUL, ld_reg};
                data_path <= ld_data;
                ins_vld   <= 1'b1;
                wait_cnt  <= 4'd4;
                state     <= S_LD_WAIT;
            end
            S_LD_WAIT: begin
                ins_vld <= 1'b0;
                if (cal_done) begin
                    if (ld_cnt == 3'd5) begin
                        if (run_pd) begin
                            state <= S_SCAN;
                        end else begin
                            uc_idx   <= 6'd22;   // PA_FULL for one-shot PADD
                            uc_end   <= 6'd40;
                            post_sel <= POST_AFF;
                            state    <= S_UC_ISSUE;
                        end
                    end else begin
                        ld_cnt <= ld_cnt + 1'b1;
                        state  <= S_LD_ISSUE;
                    end
                end
            end

            // ---- scan k for its leading 1 -----------------------------------
            S_SCAN: begin
                if (k_shft == 0) begin
                    inf_o  <= 1'b1;
                    rx_o   <= 0; ry_o <= 0; rz_o <= 0;
                    busy_o <= 1'b0; done_o <= 1'b1;
                    state  <= S_IDLE;
                end else if (k_shft[255]) begin
                    // skip the leading 1 (accumulator already holds the base)
                    k_shft  <= {k_shft[254:0], 1'b0};
                    bit_cnt <= bit_cnt - 1'b1;
                    state   <= (bit_cnt == 9'd1) ? S_K1 : S_NEXT;
                end else begin
                    k_shft  <= {k_shft[254:0], 1'b0};
                    bit_cnt <= bit_cnt - 1'b1;
                end
            end

            S_K1: begin
                // k == 1: result is the affine base point
                rx_o <= base_x; ry_o <= base_y; rz_o <= 256'd1;
                busy_o <= 1'b0; done_o <= 1'b1;
                state <= S_IDLE;
            end

            // ---- per-bit dispatch --------------------------------------------
            S_NEXT: begin
                if (bit_cnt == 0) begin
                    state <= S_AFF_ZCHK;
                end else begin
                    uc_idx   <= first_pd ? 6'd0 : 6'd1;
                    uc_end   <= 6'd21;
                    post_sel <= POST_FIN_PD;
                    first_pd <= 1'b0;
                    state    <= S_UC_ISSUE;
                end
            end

            // ---- microcode list execution ------------------------------------
            S_UC_ISSUE: begin
                ins0    <= uc_rom(uc_idx);
                ins_vld <= 1'b1;
                state   <= S_UC_WAIT;
            end
            S_UC_WAIT: begin
                ins_vld <= 1'b0;
                if (cal_done) begin
                    if (uc_idx == uc_end) begin
                        if (post_sel == POST_AFF) begin
                            state <= S_AFF_ZCHK;
                        end else if (post_sel == POST_DONE) begin
                            // var regs commit on this same edge; settle 1 cycle
                            state <= S_CAPTURE;
                        end else begin
                            wait_cnt <= 4'd4;
                            state    <= S_FIN_ISSUE;
                        end
                    end else begin
                        uc_idx <= uc_idx + 1'b1;
                        state  <= S_GAP;
                    end
                end
            end
            S_GAP: state <= S_UC_ISSUE;

            // ---- FIN: var -> cnst for the next iteration ----------------------
            S_FIN_ISSUE: begin
                ins0     <= {OP_NUL, T_FIN, R_NUL, R_NUL, R_NUL};
                ins_vld  <= 1'b1;
                state    <= S_FIN_WAIT;
            end
            S_FIN_WAIT: begin
                ins_vld <= 1'b0;
                if (cal_done) state <= S_POST;
            end

            // ---- after-PD / after-PA dispatch ---------------------------------
            S_POST: begin
                if (post_sel == POST_FIN_PD) begin
                    // PD for the current bit just finished; bit = k_shft[255]
                    if (k_shft[255]) begin
                        uc_idx   <= 6'd23;   // PA_FAST (uses PD precomputes)
                        uc_end   <= 6'd40;
                        post_sel <= POST_FIN_PA;
                        state    <= S_UC_ISSUE;
                    end else begin
                        k_shft  <= {k_shft[254:0], 1'b0};
                        bit_cnt <= bit_cnt - 1'b1;
                        state   <= S_NEXT;
                    end
                end else begin
                    // POST_FIN_PA: bit fully processed, advance
                    k_shft  <= {k_shft[254:0], 1'b0};
                    bit_cnt <= bit_cnt - 1'b1;
                    state   <= S_NEXT;
                end
            end

            // ---- affine conversion -------------------------------------------
            S_AFF_ZCHK: begin
                if (var_z2 == 0) begin
                    inf_o <= 1'b1; rx_o <= 0; ry_o <= 0; rz_o <= 0;
                    busy_o <= 1'b0; done_o <= 1'b1;
                    state <= S_IDLE;
                end else if (JAC_ONLY) begin
                    // Jacobian output: host performs z^{-1} and affine scaling
                    rx_o <= var_x2; ry_o <= var_y2; rz_o <= var_z2;
                    busy_o <= 1'b0; done_o <= 1'b1;
                    state <= S_IDLE;
                end else begin
                    inv_a     <= var_z2;
                    inv_m     <= P256;
                    inv_start <= 1'b1;
                    state     <= S_AFF_INV;
                end
            end
            S_AFF_INV: begin
                inv_start <= 1'b0;
                if (inv_done) begin
                    if (inv_err) begin
                        state <= S_DONE_ERR;
                    end else begin
                        data_path <= inv_r;
                        ins0      <= {OP_NUL, T_UPD, R_NUL, R_NUL, R_X1};
                        ins_vld   <= 1'b1;
                        wait_cnt  <= 4'd4;
                        state     <= S_AFF_LDW;
                    end
                end
            end
            S_AFF_LDW: begin
                ins_vld <= 1'b0;
                if (cal_done) begin
                    uc_idx   <= 6'd41;
                    uc_end   <= 6'd44;
                    post_sel <= POST_DONE;
                    state    <= S_UC_ISSUE;
                end
            end

            S_CAPTURE: begin
                rx_o <= var_x2;
                ry_o <= var_y2;
                rz_o <= 256'd1;
                busy_o <= 1'b0; done_o <= 1'b1;
                state <= S_IDLE;
            end

            S_DONE_ERR: begin
                err_o  <= 1'b1;
                busy_o <= 1'b0; done_o <= 1'b1;
                state  <= S_IDLE;
            end

            default: state <= S_IDLE;
        endcase
    end
end

endmodule
