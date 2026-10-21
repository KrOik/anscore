// ============================================================================
// w2_fnv.vh -- shared FNV-1a 32-bit digest function for wave2 st_ cells.
// Usage (inside a module):  `include "w2_fnv.vh"
// iverilog/yosys compile with -I src (or the file's directory).
//
//   dg <= fnv(dg, byte);        // init dg = 32'h811C9DC5
//
// 0x01000193 multiplication expanded to shift-add (trap T4: constant multiplies
// each burn one DSP on this flow -- never write x*32'h01000193).
// ============================================================================
function [31:0] fnv;
    input [31:0] h;
    input [7:0]  b;
    reg   [31:0] x;
    begin
        x   = h ^ {24'd0, b};
        fnv = x + (x << 1) + (x << 4) + (x << 7) + (x << 8) + (x << 24);
    end
endfunction
