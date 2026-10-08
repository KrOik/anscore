// ============================================================================
// w2_dpram -- wave2 shared synchronous dual-port RAM, direct DPX9B wrapper.
//
// Silicon-proven wiring (see docs/IP_CORE_SOP.md trap T9 and
// cores/image_processing/window/src/line_buf_ram.v header): inferred block RAMs come
// back scrambled on this GW2A-18C batch, so ALL wave2 cores that need a RAM
// must go through this wrapper (or instantiate further w2_dpram banks).
//
//   port A = write (CEA=clk_en, WREA=we)
//   port B = read  (CEB=clk_en & re) -- DOB is REGISTERED by CLKB on silicon:
//            read data is valid one clk_en beat after re+raddr, and holds
//            while re is low.
//
//   W in 1..18, DEPTH <= 1024 (one 18x1024 BSRAM block).  For deeper storage
//   instantiate several w2_dpram and mux on high address bits.
//
// iverilog: compile with sim/gowin_bsram_sim.v (measured registered-DO model).
// ============================================================================
module w2_dpram #(
    parameter W     = 8,
    parameter DEPTH = 1024,
    parameter AW    = (DEPTH > 1) ? $clog2(DEPTH) : 1
)(
    input  wire           clk,
    input  wire           clk_en,
    input  wire           we,
    input  wire [AW-1:0]  waddr,
    input  wire [W-1:0]   wdata,
    input  wire           re,
    input  wire [AW-1:0]  raddr,
    output wire [W-1:0]   q
);
    wire [17:0] dob;
    // Physical addresses: word index in bits [13:4], byte-enables in [1:0].
    // be = 2'b11 -> both 9-bit lanes written; data lives in low W bits.
    wire [13:0] ada = { {(10-AW){1'b0}}, waddr, 2'b00, 2'b11 };
    wire [13:0] adb = { {(10-AW){1'b0}}, raddr, 4'b0000 };
    wire [17:0] dia = { {(18-W){1'b0}}, wdata };

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

    assign q = dob[W-1:0];
endmodule
