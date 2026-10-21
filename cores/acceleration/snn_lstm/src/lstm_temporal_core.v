`timescale 1ns / 1ps
// -----------------------------------------------------------------------------
// Quantized LSTM temporal core (weight-stationary, single DSP MAC) for 25K
// -----------------------------------------------------------------------------
// Semantics, mirrored exactly by model/golden_lstm.py:
//   all activations and weights are Q1.7 signed (real = q/128);
//   for each timestep t, for each gate g in (i, candidate, f, o) and each
//   hidden row: z = (sum_k x_k*wih + sum_k h_k*whh) >>> 7 + b; y = act(z);
//   then the recurrence: c = f*c + i*candidate, h = o*tanh(c).
//   Sigmoid and tanh are piecewise-linear, shift/add only (no LUT memory),
//   which is what makes the core cheap and its timing path short.
// There is no intra-timestep recurrence in the gate phase (gates always read
// h[t-1]), so the MAC loop needs no bypass network.
// -----------------------------------------------------------------------------
module lstm_temporal_core #(
    parameter N_IN    = 4,
    parameter N_HID   = 8,
    parameter N_GATE  = 4,
    parameter FRAC    = 7,
    parameter AW      = 8,
    parameter ZW      = 13,      // signed Q1.7 pre-activation width
    parameter MW      = 22,      // MAC accumulator width
    parameter N_T     = 8,
    parameter T_BITS  = 4,
    parameter X_DEPTH = 64
) (
    input  wire clk,
    input  wire rst_n,

    input  wire                          start,
    input  wire [N_GATE*N_HID*N_IN*8-1:0]  wih_rom,   // ((g*N_HID+row)*N_IN + k)
    input  wire [N_GATE*N_HID*N_HID*8-1:0] whh_rom,   // ((g*N_HID+row)*N_HID + k)
    input  wire [N_GATE*N_HID*16-1:0]      b_rom,     // 16-bit signed lanes (g*N_HID+row)

    // input sequence load port: N_T*N_IN bytes, timestep-major
    input  wire                     ld_en,
    input  wire [7:0]               ld_addr,
    input  wire signed [7:0]        ld_data,
    input  wire [8:0]               ld_count,

    // hidden state observability, one byte per hidden unit per timestep
    output reg                      h_valid,
    output reg  [T_BITS-1:0]        h_step,
    output reg  [7:0]               h_idx,
    output reg  signed [7:0]        h_val,
    output reg  signed [7:0]        h_cval,

    output reg                      done,
    output reg                      error,
    output reg  [7:0]               err_code,
    output reg                      busy,

    output reg  [31:0]              digest,
    output reg  [15:0]              stat_macs,
    output reg  [15:0]              stat_sat,
    output reg  [15:0]              stat_act_ops,
    output reg  [T_BITS-1:0]        stat_steps,
    output reg  [23:0]              stat_cycles
);

    localparam KTOT  = N_IN + N_HID;
    localparam KMAX  = KTOT - 1;
    localparam ROWB  = N_GATE * N_HID;      // total gate rows per timestep
    localparam XLEN  = N_T * N_IN;
    localparam HMAX  = N_HID - 1;

    localparam signed [ZW-1:0] ZP_MAX = (1 << (ZW-1)) - 1;
    localparam signed [ZW-1:0] ZP_MIN = -(1 << (ZW-1));
    localparam signed [MW-1:0] ZW_MAX = (1 << (ZW-1)) - 1;
    localparam signed [MW-1:0] ZW_MIN = -(1 << (ZW-1));

    // Pipeline schedule. One MAC costs three cycles (operand mux, multiply,
    // accumulate) and one hidden unit costs six (product, cell sum, tanh,
    // output product, two hash mixes), so no cycle chains a multiply into an
    // add, an add into a saturation compare, or a compare cone into the FNV
    // mix. The arithmetic result per step is bit-exact with the single-cycle
    // form; only the cycle count changes.
    localparam S_IDLE = 4'd0, S_GATE = 4'd1, S_ACT1 = 4'd2, S_ACT2 = 4'd3,
             S_CELL1 = 4'd4, S_CELL2 = 4'd5, S_CELL3 = 4'd6, S_CELL4 = 4'd7,
             S_FIN1 = 4'd8, S_FIN2 = 4'd9, S_ERR = 4'd10, S_CLEAR = 4'd11;

    reg [3:0]             st;
    reg [T_BITS-1:0]      t;
    reg [2:0]             g;
    reg [3:0]             row;
    reg [3:0]             k;
    reg signed [MW-1:0]   acc;
    reg [2:0]             crow;
    reg [1:0]             ph;          // MAC sub-phase
    reg [1:0]             cph;         // cell-recurrence sub-phase
    reg signed [7:0]      a_r, w_r;    // registered MAC operands
    reg signed [15:0]     prod_r;      // registered product
    reg signed [ZW-1:0]   z_r;         // registered pre-activation
    reg signed [15:0]     pf_r, pi_r;  // registered cell products
    reg signed [15:0]     phh_r;       // registered o*tanh(c) product
    reg signed [7:0]      c_r, h_r;    // cell stage results
    reg [2:0]             crow_r;
    reg signed [7:0]      go_r, tc_r;
    reg [31:0]            hash2;
    reg                   sat_row;       // this hidden unit already saturated

    // ------------------------------------------------------------- state mem
    // xbuf is a flat register file: GW5A offers no distributed-RAM BELs and the
    // MAC operand mux reads it combinationally, so an array form would map to
    // RAM16SDP4 and fail placement.
    reg [X_DEPTH*8-1:0]  xbuf;
    wire [8:0]           x_base = (t * N_IN + k) * 8;
    wire signed [7:0]    x_word = xbuf[x_base +: 8];
    reg signed [7:0] hbuf [0:N_HID-1];
    reg signed [7:0] cbuf [0:N_HID-1];
    reg signed [7:0] gi   [0:N_HID-1];
    reg signed [7:0] gc   [0:N_HID-1];
    reg signed [7:0] gf   [0:N_HID-1];
    reg signed [7:0] go   [0:N_HID-1];

    // --------------------------------------------------------- MAC datapath
    // Every multiply in the core (the MAC term, the two cell products, and
    // o*tanh(c)) is time-shared through one GW5A MULT12X12 hard block. It is
    // signed 12x12 -> 24, so Q1.7 operands only need sign extension and the
    // product always fits the low 16 bits.
    wire [23:0] dsp_dout;
    wire signed [7:0] dsp_ia =
        (st == S_GATE)               ? a_r :
        (st == S_CELL1 && cph == 2'd0) ? gf[crow] :
        (st == S_CELL1 && cph == 2'd1) ? gi[crow] :
        (st == S_CELL2 && cph == 2'd1) ? go_r  : 8'sd0;
    wire signed [7:0] dsp_ib =
        (st == S_GATE)               ? w_r :
        (st == S_CELL1 && cph == 2'd0) ? cbuf[crow] :
        (st == S_CELL1 && cph == 2'd1) ? gc[crow] :
        (st == S_CELL2 && cph == 2'd1) ? tc_r  : 8'sd0;

    MULT12X12 #(.AREG_CLK("BYPASS"), .BREG_CLK("BYPASS"),
                .PREG_CLK("BYPASS"), .OREG_CLK("BYPASS"))
        u_dsp (.DOUT(dsp_dout),
               .A({{4{dsp_ia[7]}}, dsp_ia}),
               .B({{4{dsp_ib[7]}}, dsp_ib}),
               .CLK(2'b00), .CE(2'b00), .RESET(2'b00));
    wire signed [15:0] dsp_p = dsp_dout[15:0];

    wire                 use_x = (k < N_IN);
    wire signed [7:0]    a_op  = use_x ? x_word : hbuf[k - N_IN];
    wire signed [7:0]    w_op  = use_x
        ? wih_rom[((g*N_HID + row)*N_IN + k) * 8 +: 8]
        : whh_rom[((g*N_HID + row)*N_HID + (k - N_IN)) * 8 +: 8];
    // The accumulate stage only adds the registered DSP product, so each cycle
    // holds one arithmetic cone.
    wire signed [MW-1:0] acc_n = acc + prod_r;
    wire                 acc_ovf = (acc_n > ((1 << (MW-1)) - 1)) || (acc_n < -(1 << (MW-1)));

    wire signed [MW-1:0] acc_sh = acc >>> FRAC;      // Q1.7 pre-activation, wide
    wire                 acc_sat = (acc_sh > ZW_MAX) || (acc_sh < ZW_MIN);
    wire signed [ZW-1:0] z_raw = acc_sat ? (acc_sh[MW-1] ? ZP_MIN : ZP_MAX)
                                         : acc_sh[ZW-1:0];
    wire signed [15:0]   bias  = b_rom[(g*N_HID + row) * 16 +: 16];
    wire signed [ZW-1:0] zsb   = z_raw + bias[ZW-1:0];
    wire                 zb_sat = (bias[15] != bias[14]) ||
                                 ((zsb[ZW-1] != z_raw[ZW-1]) && (zsb[ZW-1] != bias[ZW-1]));
    wire signed [ZW-1:0] z_eff = zb_sat ? (bias[15] ? ZP_MIN : ZP_MAX) : zsb;
    wire                 z_sat = acc_sat || zb_sat;

    // --------------------------------------------------- piecewise tanh/sig
    function signed [7:0] tanh_pl;
        input signed [ZW-1:0] z;
        reg [ZW-1:0] u, y, tt;
        begin
            u = z[ZW-1] ? (~z + 1'b1) : z;
            if (u < 13'd128)       y = u;
            else if (u <= 13'd384) begin
                tt = u - 13'd128;
                y  = 13'd97 + (((tt << 5) - (tt << 1)) >> 8);
            end else               y = 13'd127;
            tanh_pl = z[ZW-1] ? (-y[7:0]) : y[7:0];
        end
    endfunction

    function signed [7:0] sigmoid_pl;
        input signed [ZW-1:0] z;
        reg signed [7:0] th;
        reg signed [15:0] s;
        begin
            th = tanh_pl(z >>> 1);
            s  = 16'sd64 + (th >>> 1);
            if (s < 0)   s = 16'sd0;
            if (s > 127) s = 16'sd127;
            sigmoid_pl = s[7:0];
        end
    endfunction

    // candidate gate (g==1) uses tanh, i/f/o use sigmoid
    wire signed [7:0]    y_act     = (g == 1) ? tanh_pl(z_r) : sigmoid_pl(z_r);

    // ------------------------------------------------------- cell recurrence
    wire signed [15:0] ps   = (pf_r >>> FRAC) + (pi_r >>> FRAC);
    wire                 s_sat = (ps > 16'sd127) || (ps < -16'sd128);
    wire signed [7:0]  c_new = s_sat ? ((ps > 0) ? 8'sd127 : -8'sd128) : ps[7:0];

    wire signed [7:0]  tc     = tanh_pl({{5{c_r[7]}}, c_r});
    wire signed [15:0] phh_s  = phh_r >>> FRAC;
    wire                 h_sat = (phh_s > 16'sd127) || (phh_s < -16'sd128);
    wire signed [7:0]  h_new  = h_sat ? ((phh_s > 0) ? 8'sd127 : -8'sd128) : phh_s[7:0];

    // ------------------------------------------------------------------- hash
    function [31:0] fnv_mix;
        input [31:0] h;
        input [7:0]  b;
        reg [31:0] x;
        begin
            x = h ^ {24'd0, b};
            fnv_mix = x + (x << 1) + (x << 4) + (x << 7) + (x << 8) + (x << 24);
        end
    endfunction

    reg [31:0] hash;

    always @(posedge clk) begin
        if (ld_en) xbuf[ld_addr[5:0]*8 +: 8] <= ld_data;
    end

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            st <= S_IDLE; t <= {T_BITS{1'b0}}; g <= 3'd0; row <= 4'd0;
            k <= 4'd0; acc <= {MW{1'b0}}; crow <= 3'd0; hash <= 32'd2166136261;
            ph <= 2'd0; cph <= 2'd0; a_r <= 8'sd0; w_r <= 8'sd0;
            prod_r <= 16'sd0; z_r <= {ZW{1'b0}}; pf_r <= 16'sd0; pi_r <= 16'sd0;
            phh_r <= 16'sd0;
            c_r <= 8'sd0; h_r <= 8'sd0; crow_r <= 3'd0; go_r <= 8'sd0;
            tc_r <= 8'sd0; hash2 <= 32'd0; sat_row <= 1'b0;
            done <= 1'b0; error <= 1'b0; err_code <= 8'd0; busy <= 1'b0;
            digest <= 32'd0;
            stat_macs <= 16'd0; stat_sat <= 16'd0; stat_act_ops <= 16'd0;
            stat_steps <= {T_BITS{1'b0}}; stat_cycles <= 24'd0;
            h_valid <= 1'b0; h_step <= {T_BITS{1'b0}}; h_idx <= 8'd0;
            h_val <= 8'sd0; h_cval <= 8'sd0;
        end else begin
            stat_cycles <= stat_cycles + 24'd1;
            h_valid     <= 1'b0;

            case (st)
                S_IDLE: begin
                    done <= 1'b0;
                    if (start) begin
                        if (ld_count != XLEN) begin
                            error    <= 1'b1;
                            err_code <= 8'h22;       // input sequence length wrong
                            st       <= S_ERR;
                        end else begin
                            busy     <= 1'b1;
                            done     <= 1'b0;
                            error    <= 1'b0;
                            err_code <= 8'd0;
                            t        <= {T_BITS{1'b0}};
                            g        <= 3'd0;
                            row      <= 4'd0;
                            k        <= 4'd0;
                            acc      <= {MW{1'b0}};
                            hash     <= 32'd2166136261;
                            crow     <= 3'd0;
                            stat_macs    <= 16'd0;
                            stat_sat     <= 16'd0;
                            stat_act_ops <= 16'd0;
                            stat_steps   <= {T_BITS{1'b0}};
                            ph       <= 2'd0;
                            cph      <= 2'd0;
                            st       <= S_CLEAR;
                        end
                    end
                end

                // ---- zero the recurrent state (hardware-real clear pass)
                S_CLEAR: begin
                    hbuf[crow] <= 8'sd0;
                    cbuf[crow] <= 8'sd0;
                    if (crow == N_HID - 1) begin
                        st <= S_GATE;
                    end else begin
                        crow <= crow + 1'b1;
                    end
                end

                // ---- z = sum(x*wih) + sum(h*whh), one MAC per cycle
                S_GATE: begin
                    case (ph)
                        2'd0: begin
                            a_r <= a_op;
                            w_r <= w_op;
                            ph  <= 2'd1;
                        end
                        2'd1: begin
                            prod_r <= dsp_p;
                            ph     <= 2'd2;
                        end
                        default: begin
                            if (acc_ovf) begin
                                error    <= 1'b1;
                                err_code <= 8'h21;
                                st       <= S_ERR;
                            end else begin
                                acc       <= acc_n;
                                stat_macs <= stat_macs + 16'd1;
                                ph        <= 2'd0;
                                if (k == KMAX) begin
                                    k  <= 4'd0;
                                    st <= S_ACT1;
                                end else begin
                                    k <= k + 1'b1;
                                end
                            end
                        end
                    endcase
                end

                // ---- pre-activation: acc -> shifted, saturated, bias-added
                S_ACT1: begin
                    z_r <= z_eff;
                    if (z_sat) stat_sat <= stat_sat + 16'd1;
                    st <= S_ACT2;
                end

                // ---- activation of the registered pre-activation
                S_ACT2: begin
                    case (g)
                        3'd0: gi[row]  <= y_act;
                        3'd1: gc[row]  <= y_act;
                        3'd2: gf[row]  <= y_act;
                        default: go[row] <= y_act;
                    endcase
                    stat_act_ops <= stat_act_ops + 16'd1;
                    acc <= {MW{1'b0}};
                    k   <= 4'd0;
                    if (row == N_HID - 1) begin
                        row <= 4'd0;
                        if (g == N_GATE - 1) begin
                            crow <= 3'd0;
                            cph  <= 2'd0;
                            st   <= S_CELL1;
                        end else begin
                            g  <= g + 1'b1;
                            st <= S_GATE;
                        end
                    end else begin
                        row <= row + 1'b1;
                        st  <= S_GATE;
                    end
                end

                // ---- c = f*c + i*candidate: two DSP products, then the sum
                S_CELL1: begin
                    case (cph)
                        2'd0: begin
                            pf_r    <= dsp_p;
                            sat_row <= 1'b0;
                            cph     <= 2'd1;
                        end
                        2'd1: begin
                            pi_r <= dsp_p;
                            cph  <= 2'd2;
                        end
                        default: begin
                            cbuf[crow] <= c_new;
                            c_r    <= c_new;
                            crow_r <= crow;
                            go_r   <= go[crow];
                            if (s_sat) sat_row <= 1'b1;
                            cph  <= 2'd0;
                            st   <= S_CELL2;
                        end
                    endcase
                end

                // ---- h = o*tanh(c): tanh, DSP product, then saturation
                S_CELL2: begin
                    case (cph)
                        2'd0: begin
                            tc_r <= tc;
                            cph  <= 2'd1;
                        end
                        2'd1: begin
                            phh_r <= dsp_p;
                            cph   <= 2'd2;
                        end
                        default: begin
                            hbuf[crow_r] <= h_new;
                            h_r    <= h_new;
                            if (sat_row || h_sat) stat_sat <= stat_sat + 16'd1;
                            cph  <= 2'd0;
                            st   <= S_CELL3;
                        end
                    endcase
                end

                // ---- digest mix: hidden byte first, then cell byte
                S_CELL3: begin
                    hash <= fnv_mix(hash, h_r);
                    st   <= S_CELL4;
                end

                S_CELL4: begin
                    hash       <= fnv_mix(hash, c_r);
                    h_valid    <= 1'b1;
                    h_step     <= t;
                    h_idx      <= {4'd0, crow_r};
                    h_val      <= h_r;
                    h_cval     <= c_r;
                    if (crow == N_HID - 1) begin
                        if (t == N_T - 1) begin
                            st <= S_FIN1;
                        end else begin
                            t          <= t + 1'b1;
                            stat_steps <= t + 1'b1;
                            g          <= 3'd0;
                            row        <= 4'd0;
                            k          <= 4'd0;
                            acc        <= {MW{1'b0}};
                            ph         <= 2'd0;
                            crow       <= 3'd0;
                            st         <= S_GATE;
                        end
                    end else begin
                        crow <= crow + 1'b1;
                        cph  <= 2'd0;
                        st   <= S_CELL1;
                    end
                end

                S_FIN1: begin
                    hash2 <= fnv_mix(hash, stat_macs[7:0]);
                    st    <= S_FIN2;
                end

                S_FIN2: begin
                    busy   <= 1'b0;
                    done   <= 1'b1;
                    digest <= fnv_mix(hash2, {{(8-T_BITS){1'b0}}, t});
                    stat_steps <= t;
                    st        <= S_FIN2;
                    if (start) begin
                        done <= 1'b0;
                        st   <= S_IDLE;
                    end
                end

                S_ERR: begin
                    busy <= 1'b0;
                    done <= 1'b1;
                    st   <= S_ERR;
                    if (start) begin
                        done <= 1'b0;
                        st   <= S_IDLE;
                    end
                end

                default: st <= S_IDLE;
            endcase
        end
    end

endmodule
