// BRAM wrappers for the PicoRV32 evaluation SoC.
//
// Same proven GW2A pattern as src/e203/e203_soc_ram.v: the address feeds the
// RAM input directly and the data-out register provides the single cycle of
// read latency.  On GW2A this maps onto SPX9 BSRAM (verified bit-exact init
// on the E203 bring-up).
`timescale 1ns/1ps

// 16 KiB read-only instruction memory (firmware image lives in BRAM INIT).
module pico_imem_rom #(
    parameter integer WORDS = 4096,
    parameter AW = 12,
    parameter INIT_FILE = "fw/picorv32_init.hex"
) (
    input  wire          clk,
    input  wire          en,
    input  wire [AW-1:0] addr,
    output wire [31:0]   dout
);
    reg [31:0] mem [0:WORDS-1];
    reg [31:0] dout_r;

    initial begin
        $readmemh(INIT_FILE, mem);
    end

    always @(posedge clk) begin
        if (en) dout_r <= mem[addr];
    end

    assign dout = dout_r;
endmodule

// 8 KiB data memory with byte write strobes.
module pico_dmem_ram #(
    parameter integer WORDS = 2048,
    parameter AW = 11
) (
    input  wire          clk,
    input  wire          en,
    input  wire [3:0]    wem,     // 0 => read
    input  wire [AW-1:0] addr,
    input  wire [31:0]   din,
    output wire [31:0]   dout
);
    reg [31:0] mem [0:WORDS-1];
    reg [31:0] dout_r;

    always @(posedge clk) begin
        if (en) begin
            if (wem[0]) mem[addr][7:0]   <= din[7:0];
            if (wem[1]) mem[addr][15:8]  <= din[15:8];
            if (wem[2]) mem[addr][23:16] <= din[23:16];
            if (wem[3]) mem[addr][31:24] <= din[31:24];
            if (wem == 4'b0000) dout_r <= mem[addr];
        end
    end

    assign dout = dout_r;
endmodule
