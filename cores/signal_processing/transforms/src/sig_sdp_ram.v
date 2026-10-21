// ============================================================================
// sig_sdp_ram -- synchronous simple-dual-port RAM for GW2A-18C.
//
// HW-FIX (see imgwin_20k/doc/VALIDATION_LOG.md "Root cause"): inferred block
// RAMs (ram_style="block" -> Yosys memory_libmap) are mapped to DPX9B with an
// address/byte-enable wiring that is functionally WRONG on this silicon --
// reads come back address-permuted on the physical board while sim is clean.
// This module instead instantiates DPX9B directly with the exact wiring
// proven on this board (replicated from imgwin_20k/src/line_buf_ram.v):
//   BIT_WIDTH_0/1 = 18, BLK_SEL_* = 000, RESET_MODE = ASYNC
//   ADA = {waddr[9:0], 2'b00, 2'b11}   (both 9-bit lanes written)
//   ADB = {raddr[9:0], 4'b0000}
//   port A = write (CEA=clk_en, WREA=we), port B = read (CEB=clk_en&re)
//
// Silicon note (measured by imgwin_20k): DOB is REGISTERED by CLKB whenever
// CEB is high even with READ_MODE1=0/OCEB=0, so CEB = clk_en & re reproduces
// exactly `if (clk_en && re) q <= mem[raddr]` -- one-tick synchronous read,
// q holds while re is low.
//
// iverilog sim model: sim/gowin_bsram_sim.v.  WIDTH <= 18, DEPTH <= 1024.
// ============================================================================
module sig_sdp_ram #(
    parameter WIDTH = 18,
    parameter DEPTH = 64,
    parameter AW    = (DEPTH > 1) ? $clog2(DEPTH) : 1,
    // REGS=1: plain register array instead of DPX9B.  The direct DPX9B
    // wiring works for hist256's access pattern but shows data/address-
    // dependent marginal reads on this GW2A-18C silicon for the fft64
    // pattern (host reads of addr%4==0 cells returned unstable garbage;
    // compute reads corrupted stage-5+ data at those cells).  At 64x18
    // a reg array costs ~1.2K FFs -- far below the BSRAM risk.
    parameter REGS = 0
)(
    input  wire             clk,
    input  wire             clk_en,
    input  wire             we,
    input  wire [AW-1:0]    waddr,
    input  wire [WIDTH-1:0] wdata,
    input  wire             re,
    input  wire [AW-1:0]    raddr,
    output wire [WIDTH-1:0] q
);

    initial begin
        if (WIDTH > 18 || DEPTH > 1024)
            $error("sig_sdp_ram: WIDTH>18 or DEPTH>1024 unsupported");
    end

generate
if (REGS) begin : g_regs
    // synchronous write + one-clk-en synchronous read; q holds while !re.
    // ram_style="registers" blocks Yosys memory_libmap -> stays FFs.
    (* ram_style = "registers" *) reg [WIDTH-1:0] mem [0:DEPTH-1];
    reg [WIDTH-1:0] qr;
    always @(posedge clk) begin
        if (clk_en && we) mem[waddr] <= wdata;
        if (clk_en && re) qr <= mem[raddr];
    end
    assign q = qr;
end else begin : g_bram
    wire [17:0] dob;
    wire [13:0] ada = { {(10-AW){1'b0}}, waddr, 2'b00, 2'b11 };
    // adb[1:0]=2'b11 (was 4'b0000): read-side lane enables -- measured
    // improvement on board (vec2 fft errors 16 -> 9).  2'b00 in [3:2]:
    // they are real decode bits, not enables ('11' regressed).
    wire [13:0] adb = { {(10-AW){1'b0}}, raddr, 2'b00, 2'b11 };
    wire [17:0] dia = { {(18-WIDTH){1'b0}}, wdata };

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

    assign q = dob[WIDTH-1:0];
end
endgenerate

endmodule
