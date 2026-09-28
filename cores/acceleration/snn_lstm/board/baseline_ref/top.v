`timescale 1ns / 1ps
// Tang Primer 25K Dock (GW5A-LV25MG121NES) top for the SNN sparse-conv + LSTM
// accelerator. Runs both cores from deterministic on-chip stimulus, reports the
// digests over the dock UART (FPGA C3 -> debugger channel B -> /dev/ttyUSB1),
// then repeats, so board output is directly comparable with the simulation
// capture and with model/golden_all.py.
module top #(
    // Overridable so a testbench can exercise several report rounds quickly;
    // the board build uses the default ~1.5 s cadence at 50 MHz.
    parameter RELOAD_CYCLES = 27'd75_000_000,
    // DIAG=1 runs the LSTM twice per round and prints both digests plus both
    // input fingerprints on an extra "DIAG" line.  Diagnostic only: the
    // acceptance lines and their counters are unchanged by it.
    parameter DIAG          = 0
) (
    input  wire       clk,      // E2, 50 MHz dock oscillator
    input  wire       rst_key,  // H11 dock key: restart the sequence
    input  wire       uart_rx,  // B3, reserved
    output wire [1:0] led,      // E8, L6
    output wire       uart_tx   // C3
);
    localparam IMG_W = 8, IMG_H = 8, CIN = 2, COUT = 4, KERN = 3, PAD = 1;
    localparam ACC_W = 16, LEAK = 3, VTH = 96, N_STEPS = 8, STEP_BITS = 4;
    localparam N_IN = 4, N_HID = 8, N_GATE = 4, FRAC = 7, ZW = 13, MW = 22,
               N_T = 8, T_BITS = 4;
    localparam FIELDS = 16;

    reg [7:0] por = 8'd0;
    always @(posedge clk) if (!por[7]) por <= por + 8'd1;
    wire rst_n = por[7];

    wire [CIN*KERN*KERN*COUT*8-1:0] wrom;
    snn_param_rom u_snn_rom (.wrom(wrom));

    wire [N_GATE*N_HID*N_IN*8-1:0]  wih_rom;
    wire [N_GATE*N_HID*N_HID*8-1:0] whh_rom;
    wire [N_GATE*N_HID*16-1:0]      b_rom;
    lstm_param_rom u_lstm_rom (.wih_rom(wih_rom), .whh_rom(whh_rom), .b_rom(b_rom));

    // ------------------------------------------------------- start strobes
    localparam T_NONE = 3'd0, T_LDSNN = 3'd1, T_SNN = 3'd2,
             T_LDLSTM = 3'd3, T_LSTM = 3'd4, T_RPT = 3'd5;

    reg start_ld_snn, start_ld_lstm, start_snn, start_lstm, start_rpt;
    reg [2:0] tgt;
    reg [2:0] scnt;
    reg       firing;

    // ------------------------------------------------------------ SNN layer
    wire       ld_en_snn, ld_done_snn;
    wire [7:0] ld_addr_snn;
    wire [STEP_BITS+15:0] ld_data_snn;
    wire [8:0] ld_count_snn;

    snn_event_loader #(
        .IMG_W(IMG_W), .IMG_H(IMG_H), .CIN(CIN), .N_STEPS(N_STEPS),
        .STEP_BITS(STEP_BITS), .EV_MASK(7), .IDX_MASK(CIN*IMG_W*IMG_H-1),
        .SEED(16'hACE1)
    ) u_snn_gen (.clk(clk), .rst_n(rst_n), .start(start_ld_snn),
                 .ld_en(ld_en_snn), .ld_addr(ld_addr_snn), .ld_data(ld_data_snn),
                 .ld_count(ld_count_snn), .load_done(ld_done_snn), .busy());

    wire s_valid;
    wire [7:0] s_evt_idx;
    wire [STEP_BITS-1:0] s_evt_step;
    wire [31:0] s_digest;
    wire [15:0] s_events, s_taps, s_taps_skip, s_spikes, s_scan, s_ovf, s_dense;
    wire [23:0] s_cycles;
    wire [STEP_BITS-1:0] s_step;
    wire s_done, s_error, s_busy;
    wire [7:0] s_err_code;

    snn_sparse_conv_core #(
        .IMG_W(IMG_W), .IMG_H(IMG_H), .CIN(CIN), .COUT(COUT), .KERN(KERN),
        .PAD(PAD), .ACC_W(ACC_W), .LEAK(LEAK), .VTH(VTH), .N_STEPS(N_STEPS),
        .STEP_BITS(STEP_BITS), .EVT_DEPTH(64), .OFIFO_DEPTH(64)
    ) u_snn (.clk(clk), .rst_n(rst_n), .start(start_snn), .wrom(wrom),
             .ld_en(ld_en_snn), .ld_addr(ld_addr_snn), .ld_data(ld_data_snn),
             .ld_count(ld_count_snn),
             .oevt_valid(s_valid), .oevt_ready(1'b1),
             .oevt_idx(s_evt_idx), .oevt_step(s_evt_step),
             .done(s_done), .error(s_error), .err_code(s_err_code), .busy(s_busy),
             .digest(s_digest), .stat_events(s_events), .stat_taps(s_taps),
             .stat_taps_skip(s_taps_skip), .stat_spikes(s_spikes),
             .stat_scan_cells(s_scan), .stat_ofifo_ovf(s_ovf),
             .stat_cycles(s_cycles), .stat_step(s_step), .stat_dense_macs(s_dense));

    // ----------------------------------------------------------- LSTM core
    wire       ld_en_lstm, ld_done_lstm;
    wire [7:0] ld_addr_lstm;
    wire signed [7:0] ld_data_lstm;
    wire [8:0] ld_count_lstm;

    lstm_input_loader #(.N_IN(N_IN), .N_T(N_T), .T_BITS(T_BITS), .SEED(16'h5A5A))
    u_lstm_gen (.clk(clk), .rst_n(rst_n), .start(start_ld_lstm), .ld_en(ld_en_lstm),
                .ld_addr(ld_addr_lstm), .ld_data(ld_data_lstm),
                .ld_count(ld_count_lstm), .load_done(ld_done_lstm), .busy());

    wire l_h_valid;
    wire [T_BITS-1:0] l_h_step;
    wire [7:0] l_h_idx;
    wire signed [7:0] l_h_val, l_c_val;
    wire [31:0] l_digest;
    wire [15:0] l_macs, l_sat, l_act;
    wire [T_BITS-1:0] l_steps;
    wire [23:0] l_cycles;
    wire l_done, l_error, l_busy;
    wire [7:0] l_err_code;

    lstm_temporal_core #(.N_IN(N_IN), .N_HID(N_HID), .N_GATE(N_GATE), .FRAC(FRAC),
                         .ZW(ZW), .MW(MW), .N_T(N_T), .T_BITS(T_BITS), .X_DEPTH(64))
    u_lstm (.clk(clk), .rst_n(rst_n), .start(start_lstm),
            .wih_rom(wih_rom), .whh_rom(whh_rom), .b_rom(b_rom),
            .ld_en(ld_en_lstm), .ld_addr(ld_addr_lstm), .ld_data(ld_data_lstm),
            .ld_count(ld_count_lstm),
            .h_valid(l_h_valid), .h_step(l_h_step), .h_idx(l_h_idx),
            .h_val(l_h_val), .h_cval(l_c_val),
            .done(l_done), .error(l_error), .err_code(l_err_code), .busy(l_busy),
            .digest(l_digest), .stat_macs(l_macs), .stat_sat(l_sat),
            .stat_act_ops(l_act), .stat_steps(l_steps), .stat_cycles(l_cycles));

    // ------------------------------------------------------------- report
    reg [31:0] r_snn_digest, r_lstm_digest;
    reg [15:0] r_events, r_taps, r_taps_skip, r_spikes, r_macs, r_act, r_sat;
    reg        r_err;
    // same-round double-run captures (used when DIAG=1)
    reg [31:0] r_dA, r_dB;
    wire [31:0] r_combined = ((r_snn_digest ^ 32'h9E37_79B9) + r_lstm_digest);

    wire [FIELDS*32-1:0] fields;
    assign fields[0*32  +: 32] = r_snn_digest;
    assign fields[1*32  +: 32] = {16'd0, r_events};
    assign fields[2*32  +: 32] = {16'd0, r_taps};
    assign fields[3*32  +: 32] = {16'd0, r_taps_skip};
    assign fields[4*32  +: 32] = {16'd0, r_spikes};
    assign fields[7*32  +: 32] = r_lstm_digest;
    assign fields[8*32  +: 32] = {16'd0, r_macs};
    assign fields[9*32  +: 32] = {16'd0, r_act};
    assign fields[10*32 +: 32] = {24'd0, r_sat};
    assign fields[12*32 +: 32] = r_combined;
    assign fields[13*32 +: 32] = r_dA;
    assign fields[14*32 +: 32] = r_dB;

    wire rpt_done;
    board_report #(.FIELDS(FIELDS), .CLK_HZ(50000000), .BAUD(115200),
                   .DIAG(DIAG)) u_rpt (
        .clk(clk), .rst_n(rst_n), .start(start_rpt), .fields(fields),
        .done(rpt_done), .tx(uart_tx)
    );

    // ------------------------------------------------------------- sequencer
    localparam Q_LD_SNN = 3'd1, Q_RUN_SNN = 3'd2, Q_LD_LSTM = 3'd3,
             Q_RUN_LSTM = 3'd4, Q_RPT = 3'd5, Q_WAIT = 3'd6,
             Q_RUN_L2   = 3'd7;

    reg [2:0]  seq;
    reg [26:0] wait_cnt;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            seq <= Q_LD_SNN; wait_cnt <= 27'd0;
            tgt <= T_LDSNN; scnt <= 3'd0; firing <= 1'b1;
            start_ld_snn <= 1'b0; start_ld_lstm <= 1'b0;
            start_snn <= 1'b0; start_lstm <= 1'b0; start_rpt <= 1'b0;
            r_snn_digest <= 32'd0; r_lstm_digest <= 32'd0;
            r_events <= 16'd0; r_taps <= 16'd0; r_taps_skip <= 16'd0;
            r_spikes <= 16'd0; r_macs <= 16'd0; r_act <= 16'd0; r_sat <= 16'd0;
            r_dA <= 32'd0; r_dB <= 32'd0;
            r_err <= 1'b0;
        end else begin
            start_ld_snn <= 1'b0;
            start_ld_lstm<= 1'b0;
            start_snn    <= 1'b0;
            start_lstm   <= 1'b0;
            start_rpt    <= 1'b0;

            // 4-cycle start strobe: the cores need two accepting cycles
            // (FIN -> IDLE -> CLEAR), the loaders need one.
            if (firing) begin
                scnt <= scnt + 3'd1;
                if (scnt == 3'd3) firing <= 1'b0;
                case (tgt)
                    T_LDSNN:  start_ld_snn <= 1'b1;
                    T_SNN:    start_snn    <= 1'b1;
                    T_LDLSTM: start_ld_lstm<= 1'b1;
                    T_LSTM:   start_lstm   <= 1'b1;
                    T_RPT:    start_rpt    <= 1'b1;
                    default: ;
                endcase
            end

            if (rst_key) begin
                seq        <= Q_LD_SNN;
                wait_cnt   <= 27'd0;
                firing     <= 1'b0;
                tgt        <= T_LDSNN;
                scnt       <= 3'd0;
            end else begin
                case (seq)
                    Q_LD_SNN: if (!firing && ld_done_snn) begin
                        seq <= Q_RUN_SNN; tgt <= T_SNN; scnt <= 3'd0; firing <= 1'b1;
                    end
                    Q_RUN_SNN: if (!firing && s_done) begin
                        r_snn_digest <= s_digest;
                        r_events     <= s_events;
                        r_taps       <= s_taps;
                        r_taps_skip  <= s_taps_skip;
                        r_spikes     <= s_spikes;
                        r_err        <= s_error;
                        seq <= Q_LD_LSTM; tgt <= T_LDLSTM; scnt <= 3'd0; firing <= 1'b1;
                    end
                    Q_LD_LSTM: if (!firing && ld_done_lstm) begin
                        seq <= Q_RUN_LSTM; tgt <= T_LSTM; scnt <= 3'd0; firing <= 1'b1;
                    end
                    Q_RUN_LSTM: if (!firing && l_done) begin
                        r_lstm_digest <= l_digest;
                        r_macs        <= l_macs;
                        r_act         <= l_act;
                        r_sat         <= l_sat;
                        r_err         <= r_err | l_error;
                        if (DIAG != 0) begin
                            r_dA <= l_digest;
                            seq <= Q_RUN_L2; tgt <= T_LSTM; scnt <= 3'd0;
                            firing <= 1'b1;
                        end else begin
                            seq <= Q_RPT; tgt <= T_RPT; scnt <= 3'd0;
                            firing <= 1'b1;
                        end
                    end
                    // same input, same core, second pass: any difference between
                    // A and B is silicon non-determinism, not a state carryover.
                    Q_RUN_L2: if (!firing && l_done) begin
                        r_dB <= l_digest;
                        r_lstm_digest <= l_digest;
                        r_macs        <= l_macs;
                        r_act         <= l_act;
                        r_sat         <= l_sat;
                        seq <= Q_RPT; tgt <= T_RPT; scnt <= 3'd0; firing <= 1'b1;
                    end
                    Q_RPT: if (!firing && rpt_done) begin
                        seq <= Q_WAIT; wait_cnt <= 27'd0;
                    end
                    Q_WAIT: begin
                        if (wait_cnt == RELOAD_CYCLES - 1) begin
                            seq      <= Q_LD_SNN;
                            wait_cnt <= 27'd0;
                        end else begin
                            wait_cnt <= wait_cnt + 27'd1;
                        end
                    end
                    default: seq <= Q_LD_SNN;
                endcase
            end
        end
    end

    assign led = {r_err, wait_cnt[22]};

endmodule
