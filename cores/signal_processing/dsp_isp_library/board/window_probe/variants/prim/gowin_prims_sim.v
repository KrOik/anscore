// Behavioral iverilog models of the Gowin BSRAM primitives used by the
// explicit-primitive diagnostic variant. NOT for synthesis (yosys supplies the
// real cells); run.py compiles this file only into simulation.
//
// Semantics mirror the measured-silicon model in
// cores/image_processing/window/sim/gowin_bsram_sim.v: DO is a clocked read register
// that updates only while CE is high and otherwise holds. BIT_WIDTH=9 uses
// physical address {word_index[10:0],3'b000} (AD[13:3]); BIT_WIDTH=18 uses
// {word_index[9:0],2'b00,byte_enable[1:0]} (AD[13:4]/AD[1:0]) as decoded from
// yosys gowin/brams_map.v and the retained mapped netlists.
`timescale 1ns/1ps

module SPX9 (DO, DI, BLKSEL, AD, WRE, CLK, CE, OCE, RESET);
parameter READ_MODE  = 1'b0;
parameter WRITE_MODE = 2'b00; // 0: no read on write, 1: transparent(new), 2: read-before-write(old)
parameter BIT_WIDTH  = 36;
parameter BLK_SEL    = 3'b000;
parameter RESET_MODE = "SYNC";
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
output [35:0] DO;
input  [35:0] DI;
input  [2:0]  BLKSEL;
input  [13:0] AD;
input  WRE, CLK, CE, OCE, RESET;
    reg [8:0] mem [0:2047];
    wire [10:0] wa = AD[13:3];
    reg [35:0] dor;
    always @(posedge CLK) begin
        if (CE) begin
            if (WRE) begin
                if (WRITE_MODE==2'b01)      dor <= {27'b0,DI[8:0]}; // transparent
                else if (WRITE_MODE==2'b10) dor <= {27'b0,mem[wa]}; // read-before-write
                // WRITE_MODE==0: no read on write -> DO holds
            end else begin
                dor <= {27'b0,mem[wa]};
            end
            if (WRE) mem[wa] <= DI[8:0];
        end
    end
    assign DO = dor;
endmodule

module DPX9B (
    input  wire        CLKA, CEA, CLKB, CEB, OCEA, OCEB,
    input  wire        RESETA, RESETB, WREA, WREB,
    input  wire [13:0] ADA, ADB,
    input  wire [17:0] DIA, DIB,
    input  wire [2:0]  BLKSELA, BLKSELB,
    output wire [17:0] DOA, DOB
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
    reg [8:0] mem [0:2047];
    wire [10:0] wa = ADA[13:3];
    wire [10:0] ra = ADB[13:3];
    reg [17:0] doa_r, dob_r;
    // Port A: write (+transparent read modelling only what WRITE_MODE0=1 needs).
    always @(posedge CLKA) begin
        if (CEA) begin
            if (WREA) begin
                if (WRITE_MODE0==2'b01)      doa_r <= {9'b0,DIA[8:0]};
                else if (WRITE_MODE0==2'b10) doa_r <= {9'b0,mem[wa]};
            end else doa_r <= {9'b0,mem[wa]};
            if (WREA) mem[wa] <= DIA[8:0];
        end
    end
    // Port B: read (+optional write).
    always @(posedge CLKB) begin
        if (CEB) begin
            if (WREB) begin
                if (WRITE_MODE1==2'b01)      dob_r <= {9'b0,DIB[8:0]};
                else if (WRITE_MODE1==2'b10) dob_r <= {9'b0,mem[ra]};
            end else dob_r <= {9'b0,mem[ra]};
            if (WREB) mem[ra] <= DIB[8:0];
        end
    end
    assign DOA = doa_r;
    assign DOB = dob_r;
endmodule
