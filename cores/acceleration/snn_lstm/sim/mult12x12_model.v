// Simulation model of the GW5A MULT12X12 hard multiply.
// OSS CAD Suite ships only an empty declaration (share/yosys/gowin/cells_xtra_gw5a.v),
// exactly like the BSRAM cells, so a testbench that elaborates a real instance
// needs this model on its file list.  The hardware is SIGNED 12x12 -> 24-bit.
`timescale 1ns / 1ps
module MULT12X12 #(
    parameter AREG_CLK   = "BYPASS",
    parameter BREG_CLK   = "BYPASS",
    parameter PREG_CLK   = "BYPASS",
    parameter OREG_CLK   = "BYPASS",
    parameter MULT_RESET_MODE = "SYNC"
) (
    output [23:0] DOUT,
    input  [11:0] A,
    input  [11:0] B,
    input  [1:0]  CLK,
    input  [1:0]  CE,
    input  [1:0]  RESET
);
    localparam A_REG = (AREG_CLK != "BYPASS");
    localparam B_REG = (BREG_CLK != "BYPASS");
    localparam P_REG = (PREG_CLK != "BYPASS");
    localparam O_REG = (OREG_CLK != "BYPASS");

    reg signed [11:0] aq, bq;
    reg signed [23:0] pq, oq;
    wire signed [23:0] an = A_REG ? aq : $signed(A);
    wire signed [23:0] bn = B_REG ? bq : $signed(B);
    wire signed [23:0] pcomb = an * bn;

    assign DOUT = O_REG ? oq : (P_REG ? pq : pcomb);

    always @(posedge CLK[0]) begin
        if (RESET[0]) begin
            aq <= 12'sd0;
            bq <= 12'sd0;
        end else begin
            if (A_REG) aq <= $signed(A);
            if (B_REG) bq <= $signed(B);
        end
    end

    always @(posedge CLK[0]) begin
        if (RESET[0]) begin
            pq <= 24'sd0;
            oq <= 24'sd0;
        end else begin
            if (P_REG) pq <= pcomb;
            if (O_REG) oq <= P_REG ? pq : pcomb;
        end
    end
endmodule
