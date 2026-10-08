// ============================================================================
// st_mem_bist -- selftest cell for mem_bist (wave2 idx34, TAG "MBST").
//
// Scenario (golden model: tools/golden_sys.py):
//   run 1: clean march over the internal 256x8 w2_dpram; expect fail=0.
//          then host-read 8 locations {0,1,2,3,0x55,0xAA,0xFE,0xFF}
//          (final contents are ~wk(a) = ~(8'h01<<a[2:0])).
//   run 2: same march with fi_en=1, fi_addr=0x37 -> phase-0 write at 0x37
//          is corrupted, so phase 1 must fail at 0x37 (exp 0x55 got 0xAA).
// Folded per run: {phase, {6'b0,fail,done}, fail_addr, fail_exp, fail_got,
// {4'b0,fail_phase}} = 6 bytes; run1 also folds the 8 host-read bytes.
// Stream = 6 + 8 + 6 = 20 bytes.
// ============================================================================
`timescale 1ns/1ps
module st_mem_bist (
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

localparam [31:0] EXP = 32'hC9D87DF5;   // tools/golden_sys.py: MBST DIGEST
localparam AW = 8;

localparam S_IDLE = 5'd0;
localparam S_K1   = 5'd1;
localparam S_W1   = 5'd2;
localparam S_ST1  = 5'd3;
localparam S_HRI  = 5'd4;
localparam S_HRW  = 5'd5;
localparam S_HRC  = 5'd6;
localparam S_K2   = 5'd7;
localparam S_W2   = 5'd8;
localparam S_ST2  = 5'd9;
localparam S_FIN  = 5'd10;

reg [4:0]    st;
reg [2:0]    j;        // status byte index / host-read index
reg          start_r;
reg          fi_r;
reg          hre_r;
reg [AW-1:0] haddr_r;
reg          chk1, chk2;
reg          run_flag;
reg          saw_busy;

// ---- DUT -------------------------------------------------------------
wire        mb_busy, mb_done, mb_fail;
wire [AW-1:0] mb_faddr;
wire [7:0]  mb_fexp, mb_fgot;
wire [3:0]  mb_fphase, mb_phase;
wire [7:0]  h_q;

// host-read address sequence: 0,1,2,3,0x55,0xAA,0xFE,0xFF
function [AW-1:0] hr_addr;
    input [2:0] k;
    begin
        case (k)
            3'd0: hr_addr = 8'h00;
            3'd1: hr_addr = 8'h01;
            3'd2: hr_addr = 8'h02;
            3'd3: hr_addr = 8'h03;
            3'd4: hr_addr = 8'h55;
            3'd5: hr_addr = 8'hAA;
            3'd6: hr_addr = 8'hFE;
            default: hr_addr = 8'hFF;
        endcase
    end
endfunction

mem_bist #(.DEPTH(256), .AW(AW)) dut (
    .clk(clk), .clk_en(clk_en || !rst_n), .rst_n(rst_n),
    .start(start_r),
    .busy(mb_busy), .done(mb_done), .fail(mb_fail),
    .fail_addr(mb_faddr), .fail_exp(mb_fexp), .fail_got(mb_fgot),
    .fail_phase(mb_fphase), .phase(mb_phase),
    .fi_en(fi_r), .fi_addr(8'h37),
    .h_we(1'b0), .h_waddr({AW{1'b0}}), .h_wdata(8'd0),
    .h_re(hre_r), .h_raddr(haddr_r), .h_q(h_q)
);

`ifndef SYNTHESIS
integer fd;
initial fd = $fopen("sim/dump_mem_bist.txt", "w");
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
        st <= S_IDLE; j <= 0; start_r <= 0; fi_r <= 0;
        hre_r <= 0; haddr_r <= 0;
        chk1 <= 0; chk2 <= 0; run_flag <= 0; saw_busy <= 0;
        done <= 0; pass <= 0; digest <= 32'h811C9DC5; cycles <= 0;
    end else if (ce) begin
        start_r <= 0; hre_r <= 0;
        if (run_flag && !done) cycles <= cycles + 16'd1;

        case (st)
            S_IDLE: if (start) begin
                st <= S_K1; j <= 0; fi_r <= 0;
                digest <= 32'h811C9DC5; done <= 0; pass <= 0;
                chk1 <= 0; chk2 <= 0; cycles <= 0; run_flag <= 1;
            end
            S_K1: begin
                start_r <= 1; saw_busy <= 0; st <= S_W1;
            end
            S_W1: begin
                if (mb_busy) saw_busy <= 1;
                if (saw_busy && mb_done) begin
                    j <= 0; st <= S_ST1;
                    chk1 <= !mb_fail;
                end
            end
            S_ST1: begin
                case (j)
                    3'd0: emit({4'b0, mb_phase});
                    3'd1: emit({6'b0, mb_fail, mb_done});
                    3'd2: emit(mb_faddr[7:0]);
                    3'd3: emit(mb_fexp);
                    3'd4: emit(mb_fgot);
                    default: emit({4'b0, mb_fphase});
                endcase
                if (j == 3'd5) begin j <= 0; st <= S_HRI; end
                else j <= j + 3'd1;
            end
            S_HRI: begin
                hre_r <= 1; haddr_r <= hr_addr(j);
                st <= S_HRW;
            end
            S_HRW: st <= S_HRC;
            S_HRC: begin
                emit(h_q);
                if (j == 3'd7) begin j <= 0; st <= S_K2; end
                else begin j <= j + 3'd1; st <= S_HRI; end
            end
            S_K2: begin
                fi_r <= 1; start_r <= 1; saw_busy <= 0; st <= S_W2;
            end
            S_W2: begin
                if (mb_busy) saw_busy <= 1;
                if (saw_busy && mb_done) begin
                    j <= 0; st <= S_ST2;
                    chk2 <= mb_fail && (mb_faddr === 8'h37) &&
                            (mb_fphase === 4'd1) && (mb_fexp === 8'h55);
                end
            end
            S_ST2: begin
                case (j)
                    3'd0: emit({4'b0, mb_phase});
                    3'd1: emit({6'b0, mb_fail, mb_done});
                    3'd2: emit(mb_faddr[7:0]);
                    3'd3: emit(mb_fexp);
                    3'd4: emit(mb_fgot);
                    default: emit({4'b0, mb_fphase});
                endcase
                if (j == 3'd5) st <= S_FIN;
                else j <= j + 3'd1;
            end
            S_FIN: begin
                pass <= (digest === EXP) && chk1 && chk2;
                done <= 1;
                run_flag <= 0;
                st <= S_IDLE;
            end
            default: st <= S_IDLE;
        endcase
    end
end

endmodule
