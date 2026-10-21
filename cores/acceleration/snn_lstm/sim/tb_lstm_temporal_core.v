`timescale 1ns / 1ps
// Self-checking testbench for the quantized LSTM temporal core.
module tb_lstm_temporal_core;

    localparam N_IN = 4, N_HID = 8, N_GATE = 4, FRAC = 7, ZW = 13, MW = 22,
               N_T = 8, T_BITS = 4;

    `include "expected_lstm.vh"

    reg clk = 1'b0, rst_n = 1'b0;
    always #10 clk = ~clk;

    wire [N_GATE*N_HID*N_IN*8-1:0] wih_rom;
    wire [N_GATE*N_HID*N_HID*8-1:0] whh_rom;
    wire [N_GATE*N_HID*16-1:0]      b_rom;
    lstm_param_rom u_rom (.wih_rom(wih_rom), .whh_rom(whh_rom), .b_rom(b_rom));

    reg start_ld, start_core;
    wire ld_en, ld_done;
    wire [7:0]        ld_addr;
    wire signed [7:0] ld_data;
    wire [8:0]        ld_count;

    lstm_input_loader #(.N_IN(N_IN), .N_T(N_T), .T_BITS(T_BITS), .SEED(16'h5A5A))
    u_gen (.clk(clk), .rst_n(rst_n), .start(start_ld), .ld_en(ld_en),
           .ld_addr(ld_addr), .ld_data(ld_data), .ld_count(ld_count),
           .load_done(ld_done), .busy());

    wire h_valid;
    wire [T_BITS-1:0]   h_step;
    wire [7:0]          h_idx;
    wire signed [7:0]   h_val, h_cval;
    wire done, error, busy;
    wire [7:0] err_code;
    wire [31:0] digest;
    wire [15:0] stat_macs, stat_sat, stat_act_ops;
    wire [T_BITS-1:0] stat_steps;
    wire [23:0] stat_cycles;

    lstm_temporal_core #(.N_IN(N_IN), .N_HID(N_HID), .N_GATE(N_GATE), .FRAC(FRAC),
                         .ZW(ZW), .MW(MW), .N_T(N_T), .T_BITS(T_BITS), .X_DEPTH(64))
    u_core (.clk(clk), .rst_n(rst_n), .start(start_core),
            .wih_rom(wih_rom), .whh_rom(whh_rom), .b_rom(b_rom),
            .ld_en(ld_en), .ld_addr(ld_addr), .ld_data(ld_data), .ld_count(ld_count),
            .h_valid(h_valid), .h_step(h_step), .h_idx(h_idx), .h_val(h_val),
            .h_cval(h_cval), .done(done), .error(error), .err_code(err_code),
            .busy(busy), .digest(digest), .stat_macs(stat_macs), .stat_sat(stat_sat),
            .stat_act_ops(stat_act_ops), .stat_steps(stat_steps),
            .stat_cycles(stat_cycles));

    // record the last timestep's hidden/cell state straight from the stream
    reg signed [7:0] last_h [0:N_HID-1];
    reg signed [7:0] last_c [0:N_HID-1];
    integer obs = 0;
    always @(posedge clk) if (rst_n && h_valid) begin
        obs = obs + 1;
        last_h[h_idx[2:0]] <= h_val;
        last_c[h_idx[2:0]] <= h_cval;
    end

    integer fails = 0;
    integer ii;
    initial begin
        start_ld = 1'b0; start_core = 1'b0;
        repeat (4) @(posedge clk);
        rst_n = 1'b1;
        @(posedge clk); start_ld = 1'b1;
        @(posedge clk); start_ld = 1'b0;
        wait (ld_done);
        $display("LOADER xbytes=%0d", ld_count);
        @(posedge clk); start_core = 1'b1;
        @(posedge clk); start_core = 1'b0;

        fork : run_watch
            begin
                integer guard; guard = 0;
                while (!done && guard < 100000) begin @(posedge clk); guard = guard + 1; end
                if (!done) begin $display("FAIL core timeout"); fails = fails + 1; end
            end
        join

        if (error) begin $display("FAIL error code=%h", err_code); fails = fails + 1; end
        if (digest !== EXP_LSTM_DIGEST[31:0]) begin
            $display("FAIL digest got %h want %h", digest, EXP_LSTM_DIGEST[31:0]);
            fails = fails + 1;
        end
        if (stat_macs   !== EXP_LSTM_MACS[15:0])  begin $display("FAIL macs %0d want %0d", stat_macs, EXP_LSTM_MACS); fails = fails + 1; end
        if (stat_act_ops!== EXP_LSTM_ACT[15:0])   begin $display("FAIL act_ops %0d want %0d", stat_act_ops, EXP_LSTM_ACT); fails = fails + 1; end
        if (stat_sat    !== EXP_LSTM_SAT[15:0])   begin $display("FAIL sat %0d want %0d", stat_sat, EXP_LSTM_SAT); fails = fails + 1; end
        if (stat_steps  !== EXP_LSTM_STEPS[3:0])  begin $display("FAIL steps %0d want %0d", stat_steps, EXP_LSTM_STEPS); fails = fails + 1; end
        if (obs !== N_T * N_HID)                  begin $display("FAIL h stream observations %0d want %0d", obs, N_T*N_HID); fails = fails + 1; end

        $display("LSTM RESULT digest=%h macs=%0d act=%0d sat=%0d cycles=%0d",
                 digest, stat_macs, stat_act_ops, stat_sat, stat_cycles);
        for (ii = 0; ii < N_HID; ii = ii + 1)
            $display("LSTM FINAL h[%0d]=%0d c[%0d]=%0d", ii, last_h[ii], ii, last_c[ii]);
        if (fails == 0) $display("LSTM TB PASS D=%h M=%0d", digest, stat_macs);
        else            $display("LSTM TB FAIL n=%0d", fails);
        $finish;
    end

    initial begin
        #4000000;
        $display("LSTM TB FAIL global timeout");
        $finish;
    end
endmodule
