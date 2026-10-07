// ============================================================================
// gowin_bsram_sim -- behavioral simulation model of the Gowin DPX9B BSRAM
// primitive, sufficient for the imgwin_20k testbenches (iverilog).
//
// Supports the exact configuration used by line_buf_ram:
//   BIT_WIDTH_0 = BIT_WIDTH_1 = 18, RESET_MODE = "ASYNC" (resets tied off),
//   physical address = {word_idx[9:0], 2'b00, byte_enable[1:0]},
//   bypass-mode DO (combinational array read), no cascade (BLK_SEL = 000).
// Memory holds 1024 x 18-bit words (16Kbit + parity BSRAM block).
// INIT_RAM_* parameters are accepted for compatibility; array starts as X
// like an uninitialised reg array (X-propagation probes stay meaningful).
// ============================================================================
`timescale 1ns/1ps
module DPX9B (
    input  wire        CLKA,
    input  wire        CEA,
    input  wire        CLKB,
    input  wire        CEB,
    input  wire        OCEA,
    input  wire        OCEB,
    input  wire        RESETA,
    input  wire        RESETB,
    input  wire        WREA,
    input  wire        WREB,
    input  wire [13:0] ADA,
    input  wire [13:0] ADB,
    input  wire [17:0] DIA,
    input  wire [17:0] DIB,
    input  wire [2:0]  BLKSELA,
    input  wire [2:0]  BLKSELB,
    output wire [17:0] DOA,
    output wire [17:0] DOB
);
parameter READ_MODE0  = 1'b0;
parameter READ_MODE1  = 1'b0;
parameter WRITE_MODE0 = 2'b00;
parameter WRITE_MODE1 = 2'b00;
parameter BIT_WIDTH_0 = 18;
parameter BIT_WIDTH_1 = 18;
parameter BLK_SEL_0   = 3'b000;
parameter BLK_SEL_1   = 3'b000;
parameter RESET_MODE  = "SYNC";
parameter INIT_RAM_00 = 288'h0; parameter INIT_RAM_01 = 288'h0;
parameter INIT_RAM_02 = 288'h0; parameter INIT_RAM_03 = 288'h0;
parameter INIT_RAM_04 = 288'h0; parameter INIT_RAM_05 = 288'h0;
parameter INIT_RAM_06 = 288'h0; parameter INIT_RAM_07 = 288'h0;
parameter INIT_RAM_08 = 288'h0; parameter INIT_RAM_09 = 288'h0;
parameter INIT_RAM_0A = 288'h0; parameter INIT_RAM_0B = 288'h0;
parameter INIT_RAM_0C = 288'h0; parameter INIT_RAM_0D = 288'h0;
parameter INIT_RAM_0E = 288'h0; parameter INIT_RAM_0F = 288'h0;
parameter INIT_RAM_10 = 288'h0; parameter INIT_RAM_11 = 288'h0;
parameter INIT_RAM_12 = 288'h0; parameter INIT_RAM_13 = 288'h0;
parameter INIT_RAM_14 = 288'h0; parameter INIT_RAM_15 = 288'h0;
parameter INIT_RAM_16 = 288'h0; parameter INIT_RAM_17 = 288'h0;
parameter INIT_RAM_18 = 288'h0; parameter INIT_RAM_19 = 288'h0;
parameter INIT_RAM_1A = 288'h0; parameter INIT_RAM_1B = 288'h0;
parameter INIT_RAM_1C = 288'h0; parameter INIT_RAM_1D = 288'h0;
parameter INIT_RAM_1E = 288'h0; parameter INIT_RAM_1F = 288'h0;
parameter INIT_RAM_20 = 288'h0; parameter INIT_RAM_21 = 288'h0;
parameter INIT_RAM_22 = 288'h0; parameter INIT_RAM_23 = 288'h0;
parameter INIT_RAM_24 = 288'h0; parameter INIT_RAM_25 = 288'h0;
parameter INIT_RAM_26 = 288'h0; parameter INIT_RAM_27 = 288'h0;
parameter INIT_RAM_28 = 288'h0; parameter INIT_RAM_29 = 288'h0;
parameter INIT_RAM_2A = 288'h0; parameter INIT_RAM_2B = 288'h0;
parameter INIT_RAM_2C = 288'h0; parameter INIT_RAM_2D = 288'h0;
parameter INIT_RAM_2E = 288'h0; parameter INIT_RAM_2F = 288'h0;
parameter INIT_RAM_30 = 288'h0; parameter INIT_RAM_31 = 288'h0;
parameter INIT_RAM_32 = 288'h0; parameter INIT_RAM_33 = 288'h0;
parameter INIT_RAM_34 = 288'h0; parameter INIT_RAM_35 = 288'h0;
parameter INIT_RAM_36 = 288'h0; parameter INIT_RAM_37 = 288'h0;
parameter INIT_RAM_38 = 288'h0; parameter INIT_RAM_39 = 288'h0;
parameter INIT_RAM_3A = 288'h0; parameter INIT_RAM_3B = 288'h0;
parameter INIT_RAM_3C = 288'h0; parameter INIT_RAM_3D = 288'h0;
parameter INIT_RAM_3E = 288'h0; parameter INIT_RAM_3F = 288'h0;

    // 18-bit words, word index in address bits [13:4] (1024-word array).
    reg [17:0] mem [0:1023];
    wire [9:0] wa = ADA[13:4];
    wire [9:0] ra = ADB[13:4];
    wire [1:0] bea = ADA[1:0];
    wire [1:0] beb = ADB[1:0];

    // Port A: synchronous write with per-9-bit-lane byte enables.
    always @(posedge CLKA) begin
        if (CEA && WREA) begin
            if (bea[0]) mem[wa][8:0]  <= DIA[8:0];
            if (bea[1]) mem[wa][17:9] <= DIA[17:9];
        end
    end

    // Port B: synchronous write (unused by line_buf_ram, modelled anyway).
    always @(posedge CLKB) begin
        if (CEB && WREB) begin
            if (beb[0]) mem[ra][8:0]  <= DIB[8:0];
            if (beb[1]) mem[ra][17:9] <= DIB[17:9];
        end
    end

    // MEASURED SILICON BEHAVIOUR (Tang Primer 20K, GW2A-18C): DO is
    // REGISTERED by CLK whenever CE is high, even with READ_MODE=0 and
    // OCE=0.  A registered-DO model reproduces the exact digests captured
    // from the physical board, while a combinational model does not.
    reg [17:0] doa_r, dob_r;
    always @(posedge CLKA) if (CEA) doa_r <= mem[wa];
    always @(posedge CLKB) if (CEB) dob_r <= mem[ra];
    assign DOA = doa_r;
    assign DOB = dob_r;
endmodule
