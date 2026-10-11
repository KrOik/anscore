`timescale 1ns / 1ps
// tb_ips_rle_codec : production-line testbench for the run-length codec core.
//
// Runs the encode direction over generated packets whose run lengths cross the
// MAX_RUN packing boundary (including one deliberately long run), then the decode
// direction over a token table that carries literal tokens, repeat tokens, a
// repeat longer than MAX_RUN, a malformed literal token and a dangling control
// byte.  Direction flips are inserted while tokens are in flight so the protocol
// error path is exercised.  Exactly one enabled posedge drives the core per beat
// (clk_en is low on the intervening edge), which also proves the trap T2 gating,
// and a few beats hold clk_en low for the whole period to show the codec stalls
// instead of consuming bytes.  Bytes are re-presented until in_ready accepts them.
// Only DUT outputs are folded; models/ips_rle_codec.py derives the expected stream
// from the written contract (trap T1) and all verdicts use === (trap T6).
module tb_ips_rle_codec;

`include "ips_tb_common.vh"

localparam integer NPACK    = 6;
localparam integer NRUNS    = 5;
localparam integer NPENC2   = 3;
localparam integer MIN_BEATS = 200;
localparam [31:0]  SEED     = 32'h13579BDF;
localparam integer ORDY_SLOT = 3;

reg                 rst_n;
reg                 clk_en;
reg                 dir;
reg                 in_valid;
reg                 in_last;
reg  [7:0]          in_byte;
reg                 out_ready;

wire                in_ready;
wire                busy;
wire                out_tok_infl;
wire                out_valid;
wire [7:0]          out_byte;
wire [7:0]          run_len;
wire [5:0]          tok_cnt;
wire [4:0]          lit_cnt;
wire [4:0]          run_ovf;
wire [4:0]          tok_ovf;
wire [7:0]          exp_cnt;
wire [3:0]          err_proto;
wire [2:0]          err_sticky;
wire [4:0]          cnt_sat;

ips_rle_codec dut (
    .clk          (ips_clk),
    .clk_en       (clk_en),
    .rst_n        (rst_n),
    .dir          (dir),
    .in_valid     (in_valid),
    .in_last      (in_last),
    .in_byte      (in_byte),
    .out_ready    (out_ready),
    .in_ready     (in_ready),
    .busy         (busy),
    .out_tok_infl (out_tok_infl),
    .out_valid    (out_valid),
    .out_byte     (out_byte),
    .run_len      (run_len),
    .tok_cnt      (tok_cnt),
    .lit_cnt      (lit_cnt),
    .run_ovf      (run_ovf),
    .tok_ovf      (tok_ovf),
    .exp_cnt      (exp_cnt),
    .err_proto    (err_proto),
    .err_sticky   (err_sticky),
    .cnt_sat      (cnt_sat)
);

// one count per enabled clock edge, so the verdict line reports real activity
always @(posedge ips_clk) begin
    if (clk_en === 1'b1) begin
        ips_cycle = ips_cycle + 32'd1;
    end
end

function [7:0] tok_ctrl_at;
    input integer t;
    begin
        case (t)
            0:        tok_ctrl_at = 8'h00;
            1:        tok_ctrl_at = 8'h80;
            2:        tok_ctrl_at = 8'h81;
            3:        tok_ctrl_at = 8'h82;
            4:        tok_ctrl_at = 8'h87;
            5:        tok_ctrl_at = 8'h93;
            6:        tok_ctrl_at = 8'h98;
            7:        tok_ctrl_at = 8'h9E;
            8:        tok_ctrl_at = 8'h05;
            9:        tok_ctrl_at = 8'h81;
            default:  tok_ctrl_at = 8'h93;
        endcase
    end
endfunction

function [7:0] tok_data_at;
    input integer t;
    begin
        tok_data_at = 8'h90 ^ t[7:0];
    end
endfunction

integer pk;
integer r;
integer q;
integer g;
integer t;
integer rlen;
integer bi;
integer beats;
reg     bad;
reg     acc;
reg [7:0] bval;
reg [31:0] state;
reg [3:0] stick_prev;
reg [4:0] sat_prev;

task fold_beat;
    begin
        ips_fnv_word({28'd0, out_valid, out_tok_infl, busy, in_ready});
        ips_fnv_word({24'd0, out_byte});
        ips_fnv_word({24'd0, run_len});
        ips_fnv_word({27'd0, lit_cnt});
        ips_fnv_word({26'd0, tok_cnt});
        ips_fnv_word({27'd0, run_ovf});
        ips_fnv_word({27'd0, tok_ovf});
        ips_fnv_word({24'd0, exp_cnt});
        ips_fnv_word({28'd0, err_proto});
        ips_fnv_word({29'd0, err_sticky});
        ips_fnv_word({27'd0, cnt_sat});

        if ((^{out_valid, out_tok_infl, busy, in_ready}) === 1'bx) bad = 1'b1;
        if ((^out_byte) === 1'bx || (^run_len) === 1'bx) bad = 1'b1;
        if ((^{tok_cnt, lit_cnt, run_ovf, tok_ovf}) === 1'bx) bad = 1'b1;
        if ((^exp_cnt) === 1'bx || (^err_proto) === 1'bx) bad = 1'b1;
        if ((^err_sticky) === 1'bx || (^cnt_sat) === 1'bx) bad = 1'b1;

        // sticky words must never clear
        if ((sat_prev & ~cnt_sat) !== 5'h0) bad = 1'b1;
        if ((stick_prev & ~err_sticky) !== 4'h0) bad = 1'b1;
        sat_prev   = cnt_sat;
        stick_prev = err_sticky;

        // literal tokens are a subset of all tokens
        if ({1'b0, lit_cnt} > tok_cnt) bad = 1'b1;

        bi    = bi + 1;
        beats = beats + 1;
    end
endtask

task beat;
    input        v;
    input        l;
    input [7:0]  d;
    input        ce;
    begin
        @(negedge ips_clk);
        clk_en    = ce;
        in_valid  = v;
        in_last   = l;
        in_byte   = d;
        out_ready = ((bi % ORDY_SLOT) == 2) ? 1'b0 : 1'b1;
        // settle the combinational accept flags: sampling in_ready in the same
        // delta cycle as the out_ready change is a zero-delay race.
        #1;
        acc = (ce === 1'b1) && (v === 1'b1) && (in_ready === 1'b1);
        @(negedge ips_clk);
        clk_en   = 1'b0;
        in_valid = 1'b0;
        in_last  = 1'b0;
        in_byte  = 8'h00;
        fold_beat();
    end
endtask

task send_byte;
    input        l;
    input [7:0]  d;
    begin
        acc = 1'b0;
        while (acc !== 1'b1) begin
            beat(1'b1, l, d, 1'b1);
        end
    end
endtask

initial begin
    ips_fnv_reset();
    rst_n     = 1'b0;
    clk_en    = 1'b0;
    dir       = 1'b0;
    in_valid  = 1'b0;
    in_last   = 1'b0;
    in_byte   = 8'h00;
    out_ready = 1'b1;
    state     = SEED;
    bad       = 1'b0;
    acc       = 1'b0;
    bi        = 0;
    beats     = 0;
    sat_prev   = 5'h00;
    stick_prev = 4'h0;

    repeat (4) @(posedge ips_clk);
    rst_n = 1'b1;
    repeat (2) @(posedge ips_clk);

    // ---------------- encode phase ----------------
    for (pk = 0; pk < NPACK; pk = pk + 1) begin
        for (r = 0; r < NRUNS; r = r + 1) begin
            state = state * 32'd1664525 + 32'd1013904223;
            rlen  = 1 + state[4:0];
            if (pk == 3 && r == 2) begin
                rlen = 45;
            end
            bval = ((r & 1) == 0) ? (8'h30 ^ r[5:0]) : (8'hC0 ^ r[5:0]);
            for (q = 0; q < rlen; q = q + 1) begin
                send_byte(((q == rlen - 1) && (r == NRUNS - 1)) ? 1'b1 : 1'b0, bval);
            end
        end
        for (g = 0; g < 3; g = g + 1) begin
            beat(1'b0, 1'b0, 8'h00, 1'b1);
        end
    end

    // ---------------- flip to decode while a token is still queued ----------------
    state = state * 32'd1664525 + 32'd1013904223;
    rlen  = 1 + state[4:0];
    bval  = 8'h5A;
    for (q = 0; q < rlen; q = q + 1) begin
        send_byte((q == rlen - 1) ? 1'b1 : 1'b0, bval);
    end
    dir = 1'b1;
    beat(1'b0, 1'b0, 8'h00, 1'b1);

    // ---------------- decode phase ----------------
    for (t = 0; t < 8; t = t + 1) begin
        send_byte(1'b0, tok_ctrl_at(t));
        send_byte(1'b0, tok_data_at(t));
        for (g = 0; g < 2; g = g + 1) begin
            beat(1'b0, 1'b0, 8'h00, 1'b1);
        end
    end

    // malformed literal token (non-zero run field) plus one disabled-clock beat
    send_byte(1'b0, tok_ctrl_at(8));
    beat(1'b0, 1'b0, 8'h00, 1'b0);
    send_byte(1'b0, tok_data_at(8));

    // abandon a long repeat expansion by flipping the direction mid-token
    send_byte(1'b0, tok_ctrl_at(7));
    send_byte(1'b0, tok_data_at(7));
    dir = 1'b0;
    beat(1'b0, 1'b0, 8'h00, 1'b1);

    // ---------------- back to encode ----------------
    for (pk = 0; pk < NPENC2; pk = pk + 1) begin
        for (r = 0; r < NRUNS; r = r + 1) begin
            state = state * 32'd1664525 + 32'd1013904223;
            rlen  = 1 + state[4:0];
            if (pk == 1 && r == 0) begin
                rlen = 60;
            end
            bval = ((r & 1) == 0) ? (8'h12 ^ r[5:0]) : (8'hE1 ^ r[5:0]);
            for (q = 0; q < rlen; q = q + 1) begin
                send_byte(((q == rlen - 1) && (r == NRUNS - 1)) ? 1'b1 : 1'b0, bval);
            end
        end
        for (g = 0; g < 2; g = g + 1) begin
            beat(1'b0, 1'b0, 8'h00, 1'b1);
        end
    end

    // ---------------- decode the tail, ending on a dangling control byte --------
    dir = 1'b1;
    beat(1'b0, 1'b0, 8'h00, 1'b1);
    for (t = 9; t < 12; t = t + 1) begin
        send_byte(1'b0, tok_ctrl_at(t));
        send_byte(1'b0, tok_data_at(t));
    end
    send_byte(1'b1, tok_ctrl_at(4));
    for (g = 0; g < 4; g = g + 1) begin
        beat(1'b0, 1'b0, 8'h00, 1'b1);
    end

    repeat (4) @(negedge ips_clk);

    ips_fnv_word({26'd0, tok_cnt});
    ips_fnv_word({27'd0, lit_cnt});
    ips_fnv_word({27'd0, run_ovf});
    ips_fnv_word({27'd0, tok_ovf});
    ips_fnv_word({24'd0, exp_cnt});
    ips_fnv_word({28'd0, err_proto});
    ips_fnv_word({29'd0, err_sticky});
    ips_fnv_word({27'd0, cnt_sat});

    if (beats < MIN_BEATS) bad = 1'b1;
    // every designed violation path must have latched its cause: a run that did
    // not fit the encoder field, a token asking for more than MAX_RUN, and a
    // protocol violation seen while decoding.
    if (err_sticky[0] !== 1'b1 || err_sticky[1] !== 1'b1 || err_sticky[2] !== 1'b1) begin
        bad = 1'b1;
    end
    if (tok_cnt === 6'h00) bad = 1'b1;
    if (exp_cnt === 8'h00) bad = 1'b1;

    ips_verdict(!bad, "ips_rle_codec");
end

endmodule
