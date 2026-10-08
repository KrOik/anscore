// ============================================================================
// st_prbs31 -- selftest cell for prbs31 (wave2 idx33, TAG "PRBS").
//
// Loopback scenario (golden model: tools/golden_sys.py):
//   seed = 31'h2AA55AA5; 300 bits are generated and fed back into the
//   checker.  Bits 0..30 are shifted in with chk_sync=1 (window load);
//   bits 31..299 are checked (269 bits).  Forced errors at bit indices
//   {40,100,101,250} (each corrupts the received bit AND later
//   predictions while it slides through the window -> err_cnt is the
//   golden-modelled total, not just 4).
// Folded bytes: 32 stream bytes (bits 0..255 packed earliest-bit-at-LSB:
// emitted byte[j] = stream bit 8k+j), then
//   err_cnt[7:0], err_cnt[15:8], bit_cnt[7:0], bit_cnt[15:8],
//   {7'b0,synced}.  37 bytes total.
// ============================================================================
`timescale 1ns/1ps
module st_prbs31 (
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

localparam [31:0] EXP = 32'hDBA2F926;   // tools/golden_sys.py: PRBS DIGEST
localparam NBIT = 300;

localparam S_IDLE = 4'd0;
localparam S_SEED = 4'd1;
localparam S_RUN  = 4'd2;
localparam S_E0   = 4'd3;
localparam S_E1   = 4'd4;
localparam S_E2   = 4'd5;
localparam S_E3   = 4'd6;
localparam S_E4   = 4'd7;
localparam S_FIN  = 4'd8;
localparam S_GAP  = 4'd9;   // seed settle beat (no gen/chk activity)

reg [3:0]  st;
reg [15:0] i;
reg [7:0]  acc;
reg        run_flag;

// ---- DUT -------------------------------------------------------------
wire       gen_bit;
wire [15:0] err_cnt, bit_cnt;
wire       synced;
reg        seed_we_r;
reg [30:0] seed_r;

wire in_run  = (st == S_RUN);
wire inj     = (i == 16'd40) || (i == 16'd100) ||
               (i == 16'd101) || (i == 16'd250);
wire chk_bit = gen_bit ^ inj;

prbs31 dut (
    .clk(clk), .clk_en(clk_en || !rst_n), .rst_n(rst_n),
    .seed_we(seed_we_r), .seed(seed_r),
    .gen_en(in_run), .gen_bit(gen_bit),
    .chk_en(in_run), .chk_sync(in_run && (i < 16'd31)), .chk_bit(chk_bit),
    .err_cnt(err_cnt), .bit_cnt(bit_cnt), .synced(synced)
);

`ifndef SYNTHESIS
integer fd;
initial fd = $fopen("sim/dump_prbs31.txt", "w");
task emit;
    input [7:0] b;
    begin
        digest <= fnv(digest, b);
        $fwrite(fd, "%02x\n", b);
    end
endtask
`else
task emit;
    input [7:0] b;
    begin digest <= fnv(digest, b); end
endtask
`endif

wire ce = clk_en || !rst_n;

always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        st <= S_IDLE; i <= 0; acc <= 0; run_flag <= 0;
        seed_we_r <= 0; seed_r <= 31'h2AA55AA5;
        done <= 0; pass <= 0; digest <= 32'h811C9DC5; cycles <= 0;
    end else if (ce) begin
        seed_we_r <= 0;
        if (run_flag && !done) cycles <= cycles + 16'd1;

        case (st)
            S_IDLE: if (start) begin
                st <= S_SEED; i <= 0; acc <= 0;
                digest <= 32'h811C9DC5; done <= 0; pass <= 0;
                cycles <= 0; run_flag <= 1;
            end
            S_SEED: begin
                seed_we_r <= 1; seed_r <= 31'h2AA55AA5;
                st <= S_GAP;
            end
            S_GAP: st <= S_RUN;   // seed_we beat must not consume stream bit
            S_RUN: begin
                // pack generated bit into acc (MSB-first); fold every 8 bits
                if (i < 16'd256) begin
                    acc <= {gen_bit, acc[7:1]};
                    if (i[2:0] == 3'd7) begin
                        emit({gen_bit, acc[7:1]});
                        acc <= 8'd0;
                    end
                end
                if (i == NBIT - 1) st <= S_E0;
                else i <= i + 16'd1;
            end
            S_E0: begin emit(err_cnt[7:0]);       st <= S_E1; end
            S_E1: begin emit(err_cnt[15:8]);      st <= S_E2; end
            S_E2: begin emit(bit_cnt[7:0]);       st <= S_E3; end
            S_E3: begin emit(bit_cnt[15:8]);      st <= S_E4; end
            S_E4: begin emit({7'b0, synced});     st <= S_FIN; end
            S_FIN: begin
                pass <= (digest === EXP) && synced && (bit_cnt == 16'd269);
                done <= 1;
                run_flag <= 0;
                st <= S_IDLE;
            end
            default: st <= S_IDLE;
        endcase
    end
end

endmodule
