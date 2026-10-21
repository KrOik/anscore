// ============================================================================
// golden_ref -- tapeout-debug item A9: "must-be-correct" reference unit.
//
// Deliberately trivial datapath (16-bit counter + 3-op ALU + 16-bit shift
// chain) that runs CYCLES iterations after reset release and folds to a
// fixed 32-bit digest.  The whole point is that this unit is so simple that
// a wrong digest almost certainly means library/floorplan/silicon trouble,
// not an RTL bug -- the D2 discriminator from the checklist.
//
// Sequence per accepted clock-enable beat:
//   cnt <= cnt + 1
//   acc <= alu(acc, cnt)   where alu op = cnt[1:0]:
//            0: acc + cnt
//            1: acc ^ cnt
//            2: {acc[14:0], acc[15]} + cnt[7:0]
//            3: acc - cnt
//   shf <= {shf[14:0], acc[0] ^ cnt[15] ^ acc[8]}
//   digest = {acc, shf} when done.
//
// fi_xor (A8): XORed into the ALU result every beat -- models a stuck or
// corrupted data bit.  The external shadow checker in top_tapedbg recomputes
// the clean sequence and raises a mismatch trigger on first divergence.
// ============================================================================
module golden_ref #(
    parameter [15:0] CYCLES = 16'd4096
)(
    input  wire        clk,
    input  wire        clk_en,
    input  wire        rst_n,
    input  wire [15:0] fi_xor,
    output reg         busy,
    output reg         done,
    output reg [15:0]  cnt,
    output reg [15:0]  acc,
    output reg [15:0]  shf,
    output wire [31:0] digest
);

function [15:0] alu;
    input [15:0] a;
    input [15:0] c;
    begin
        case (c[1:0])
            2'd0: alu = a + c;
            2'd1: alu = a ^ c;
            2'd2: alu = {a[14:0], a[15]} + {8'd0, c[7:0]};
            default: alu = a - c;
        endcase
    end
endfunction

always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        cnt  <= 16'd0;
        acc  <= 16'h0001;
        shf  <= 16'h0000;
        busy <= 1'b1;
        done <= 1'b0;
    end else if (clk_en) begin
        if (busy) begin
            acc <= alu(acc, cnt) ^ fi_xor;
            shf <= {shf[14:0], acc[0] ^ cnt[15] ^ acc[8]};
            if (cnt == CYCLES - 16'd1) begin
                busy <= 1'b0;
                done <= 1'b1;
            end else begin
                cnt <= cnt + 16'd1;
            end
        end
    end
end

assign digest = {acc, shf};

endmodule
