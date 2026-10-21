// ============================================================================
// line_buf_ram -- synchronous line buffer for win3x3_gen.
//
// HW-FIX (board validation, Tang Primer 20K / GW2A-18C):
//   Inferred block RAMs (ram_style="block" -> Yosys memory_libmap) were mapped
//   to DPX9B with an address/byte-enable wiring that is functionally WRONG on
//   real silicon: the read side returned data for a permuted column address
//   (c^1), corrupting every line-buffer-backed core while the register-only
//   threshold path passed.  Three inferred variants were probed on hardware
//   (9-bit word, 18-bit word, both-lane write) -- all scrambled.
//
//   The fix is a DIRECT DPX9B instantiation replicating the exact netlist
//   pattern that apycula's techmap emits for the board-proven BSRAMs in
//   cnn_systolic_20k on the same device:
//     BIT_WIDTH_0/1 = 18, RESET_MODE = ASYNC, BLK_SEL_* = 000
//     ADA = {waddr[9:0], 2'b00, be[1:0]}  with be = const 2'b11
//     ADB = {raddr[9:0], 4'b0000}
//     port A = write (CEA=clk_en, WREA=we), port B = read (CEB=clk_en)
//   A hardware probe streaming 00..7f read-back verified this exact wiring
//   returns perfectly sequential data on the physical board.
//
//   DOB is used in bypass mode (READ_MODE1=0, OCEB=0 -> combinational array
//   read); the external q register restores the original one-clock
//   synchronous-read semantics of the inferred RAM.
//
//   For iverilog simulation provide the behavioral model in
//   sim/gowin_bsram_sim.v (also shipped in the ip/ packages).
//   DEPTH must be <= 1024 (10-bit physical word index).
// ============================================================================
module line_buf_ram #(
    parameter DEPTH = 16,                   // pixels per line (IMG_W)
    parameter AW    = (DEPTH > 1) ? $clog2(DEPTH) : 1
)(
    input  wire                          clk,
    input  wire                          clk_en,
    input  wire                          we,
    input  wire [AW-1:0]                 waddr,
    input  wire [8:0]                    wdata,
    input  wire                          re,
    input  wire [AW-1:0]                 raddr,
    output wire [8:0]                    q
);
    // Silicon behaviour (measured on the board): DOB is REGISTERED by CLKB
    // whenever CEB is high, even with READ_MODE1=0 / OCEB=0 -- a simulation
    // with a registered-DOB model reproduces the exact board digests of the
    // broken build (WIN=4771D2AC etc.).  So the primitive itself provides the
    // one-clock synchronous read; an extra external register would give a
    // two-tick read and misalign the window pipeline.
    //
    // CEB = clk_en & re makes the internal read register update under the
    // same condition as the original `if (clk_en) if (re) q <= mem[raddr]`,
    // preserving exact semantics (DOB holds its value while re is low).
    wire [17:0] dob;
    // Physical addresses: word index in bits [13:4], byte-enables in [1:0].
    // be = 2'b11 -> both 9-bit lanes written (pixel lives in the low lane).
    wire [13:0] ada = { {(10-AW){1'b0}}, waddr, 2'b00, 2'b11 };
    wire [13:0] adb = { {(10-AW){1'b0}}, raddr, 4'b0000 };
    wire [17:0] dia = { 9'b0, wdata };

    DPX9B #(
        .BIT_WIDTH_0(18),
        .BIT_WIDTH_1(18),
        .BLK_SEL_0(3'b000),
        .BLK_SEL_1(3'b000),
        .RESET_MODE("ASYNC")
    ) u_ram (
        .BLKSELA(3'b000), .BLKSELB(3'b000),
        .CLKA(clk), .CEA(clk_en), .WREA(we), .RESETA(1'b0),
        .ADA(ada), .DIA(dia), .DOA(),
        .CLKB(clk), .CEB(clk_en & re), .WREB(1'b0), .RESETB(1'b0),
        .ADB(adb), .DIB(18'b0), .DOB(dob),
        .OCEA(1'b0), .OCEB(1'b0)
    );

    assign q = dob[8:0];
endmodule
