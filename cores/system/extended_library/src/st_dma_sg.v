// ============================================================================
// st_dma_sg -- selftest cell for dma_sg (wave2 idx30, TAG "DMA").
//
// Scenario (golden model: tools/golden_sys.py):
//   1. fill RAM_A[i] = (i + (i<<2) + 8'h3C) & 8'hFF  for i in 0..255
//      fill RAM_B[i] = 8'hC3                        for i in 0..255
//   2. descriptor 1: src=16 dst=100 len=64 dir=0 (A->B); wait done+irq
//   3. read back all of RAM_B (256 bytes) -> fold; fold status {irq,done}
//   4. descriptor 2: src=200 dst=0 len=16 dir=1 (B->A); wait done+irq
//   5. read back RAM_A[0..15] (16 bytes) -> fold; fold status {irq,done}
// Output stream = B[0..255], s1, A[0..15], s2  (274 bytes).
// ============================================================================
`timescale 1ns/1ps
module st_dma_sg (
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

localparam [31:0] EXP = 32'h92C91DF3;   // tools/golden_sys.py: DMA DIGEST
localparam AW = 8;

localparam S_IDLE  = 5'd0;
localparam S_FILLA = 5'd1;
localparam S_FILLB = 5'd2;
localparam S_D1    = 5'd3;
localparam S_W1    = 5'd4;
localparam S_RBI   = 5'd5;
localparam S_RBW   = 5'd6;
localparam S_RBC   = 5'd7;
localparam S_S1    = 5'd8;
localparam S_D2    = 5'd9;
localparam S_W2    = 5'd10;
localparam S_S2    = 5'd11;
localparam S_FIN   = 5'd12;

reg [4:0]    st;
reg [8:0]    i;          // 0..255
reg [2:0]    dw;         // descriptor write step
reg          rb_sel;     // 0: read RAM_B (256), 1: read RAM_A (16)
reg          irq1, irq2, saw_busy;
reg          sta_we, sta_re, stb_we, stb_re;
reg [AW-1:0] sta_waddr, sta_raddr, stb_waddr, stb_raddr;
reg [7:0]    sta_wdata, stb_wdata;
reg          dwe;
reg [1:0]    daddr;
reg [15:0]   ddata;
reg          run_flag;

// stimulus fill pattern for RAM_A: f(i) = i*5 + 0x3C (shift-add)
wire [7:0] fill_a = i[7:0] + (i[7:0] << 2) + 8'h3C;
wire [8:0] rb_len  = rb_sel ? 9'd16 : 9'd256;
wire [7:0] stat1_b = {6'b0, irq1, 1'b1};
wire [7:0] stat2_b = {6'b0, irq2, 1'b1};

// ---- DUT -------------------------------------------------------------
wire        dma_busy, dma_done, dma_irq;
wire        da_we, da_re, db_we, db_re;
wire [AW-1:0] da_waddr, da_raddr, db_waddr, db_raddr;
wire [7:0]  da_wdata, db_wdata;
wire [7:0]  a_q, b_q;

dma_sg #(.W(8), .AW(AW)) dut (
    .clk(clk), .clk_en(clk_en || !rst_n), .rst_n(rst_n),
    .reg_we(dwe), .reg_addr(daddr), .reg_data(ddata),
    .a_we(da_we), .a_waddr(da_waddr), .a_wdata(da_wdata),
    .a_re(da_re), .a_raddr(da_raddr), .a_q(a_q),
    .b_we(db_we), .b_waddr(db_waddr), .b_wdata(db_wdata),
    .b_re(db_re), .b_raddr(db_raddr), .b_q(b_q),
    .busy(dma_busy), .done(dma_done), .irq(dma_irq)
);

// port muxing: dma owns the RAMs while busy, st cell otherwise
wire        a_we    = dma_busy ? da_we    : sta_we;
wire [AW-1:0] a_waddr = dma_busy ? da_waddr : sta_waddr;
wire [7:0]  a_wdata = dma_busy ? da_wdata : sta_wdata;
wire        a_re    = dma_busy ? da_re    : sta_re;
wire [AW-1:0] a_raddr = dma_busy ? da_raddr : sta_raddr;
wire        b_we    = dma_busy ? db_we    : stb_we;
wire [AW-1:0] b_waddr = dma_busy ? db_waddr : stb_waddr;
wire [7:0]  b_wdata = dma_busy ? db_wdata : stb_wdata;
wire        b_re    = dma_busy ? db_re    : stb_re;
wire [AW-1:0] b_raddr = dma_busy ? db_raddr : stb_raddr;

w2_dpram #(.W(8), .DEPTH(256), .AW(AW)) ram_a (
    .clk(clk), .clk_en(clk_en || !rst_n),
    .we(a_we), .waddr(a_waddr), .wdata(a_wdata),
    .re(a_re), .raddr(a_raddr), .q(a_q));
w2_dpram #(.W(8), .DEPTH(256), .AW(AW)) ram_b (
    .clk(clk), .clk_en(clk_en || !rst_n),
    .we(b_we), .waddr(b_waddr), .wdata(b_wdata),
    .re(b_re), .raddr(b_raddr), .q(b_q));

// ---- stream dump (simulation only) ------------------------------------
`ifndef SYNTHESIS
integer fd;
initial fd = $fopen("sim/dump_dma_sg.txt", "w");
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
        st <= S_IDLE; i <= 9'd0; dw <= 3'd0; rb_sel <= 1'b0;
        irq1 <= 1'b0; irq2 <= 1'b0; saw_busy <= 1'b0;
        sta_we <= 0; sta_re <= 0; stb_we <= 0; stb_re <= 0;
        sta_waddr <= 0; sta_raddr <= 0; stb_waddr <= 0; stb_raddr <= 0;
        sta_wdata <= 0; stb_wdata <= 0;
        dwe <= 0; daddr <= 0; ddata <= 0;
        done <= 0; pass <= 0; digest <= 32'h811C9DC5; cycles <= 16'd0;
        run_flag <= 0;
    end else if (ce) begin
        // default-deasserted one-beat strobes
        sta_we <= 0; sta_re <= 0; stb_we <= 0; stb_re <= 0; dwe <= 0;
        if (run_flag && !done) cycles <= cycles + 16'd1;

        case (st)
            S_IDLE: begin
                if (start) begin
                    st <= S_FILLA; i <= 9'd0; digest <= 32'h811C9DC5;
                    done <= 0; pass <= 0; cycles <= 16'd0;
                    irq1 <= 0; irq2 <= 0; saw_busy <= 0; run_flag <= 1;
                end
            end
            S_FILLA: begin
                sta_we <= 1; sta_waddr <= i[AW-1:0]; sta_wdata <= fill_a;
                if (i == 9'd255) begin i <= 0; st <= S_FILLB; end
                else i <= i + 9'd1;
            end
            S_FILLB: begin
                stb_we <= 1; stb_waddr <= i[AW-1:0]; stb_wdata <= 8'hC3;
                if (i == 9'd255) begin i <= 0; dw <= 0; st <= S_D1; end
                else i <= i + 9'd1;
            end
            S_D1: begin
                dwe <= 1;
                case (dw)
                    3'd0: begin daddr <= 2'd0; ddata <= 16'd16;  end // src
                    3'd1: begin daddr <= 2'd1; ddata <= 16'd100; end // dst
                    3'd2: begin daddr <= 2'd2; ddata <= 16'd64;  end // len
                    default: begin daddr <= 2'd3; ddata <= 16'h0001; end // go,dir=0
                endcase
                if (dw == 3'd3) begin dw <= 0; saw_busy <= 0; st <= S_W1; end
                else dw <= dw + 3'd1;
            end
            S_W1: begin
                irq1 <= irq1 | dma_irq;
                if (dma_busy) saw_busy <= 1;
                if (saw_busy && dma_done) begin
                    i <= 0; rb_sel <= 0; st <= S_RBI;
                end
            end
            S_RBI: begin
                if (rb_sel) begin sta_re <= 1; sta_raddr <= i[AW-1:0]; end
                else        begin stb_re <= 1; stb_raddr <= i[AW-1:0]; end
                st <= S_RBW;
            end
            S_RBW: st <= S_RBC;
            S_RBC: begin
                emit(rb_sel ? a_q : b_q);
                if (i == rb_len - 9'd1) begin
                    i <= 0;
                    st <= rb_sel ? S_S2 : S_S1;
                end else begin
                    i <= i + 9'd1;
                    st <= S_RBI;
                end
            end
            S_S1: begin
                emit(stat1_b);
                dw <= 0; st <= S_D2;
            end
            S_D2: begin
                dwe <= 1;
                case (dw)
                    3'd0: begin daddr <= 2'd0; ddata <= 16'd200; end // src
                    3'd1: begin daddr <= 2'd1; ddata <= 16'd0;   end // dst
                    3'd2: begin daddr <= 2'd2; ddata <= 16'd16;  end // len
                    default: begin daddr <= 2'd3; ddata <= 16'h0003; end // go,dir=1
                endcase
                if (dw == 3'd3) begin dw <= 0; saw_busy <= 0; st <= S_W2; end
                else dw <= dw + 3'd1;
            end
            S_W2: begin
                irq2 <= irq2 | dma_irq;
                if (dma_busy) saw_busy <= 1;
                if (saw_busy && dma_done) begin
                    i <= 0; rb_sel <= 1; st <= S_RBI;
                end
            end
            S_S2: begin
                emit(stat2_b);
                st <= S_FIN;
            end
            S_FIN: begin
                // status bytes fold irq1/irq2, so a missed pulse is caught by
                // the digest; the explicit check makes pass robust anyway.
                pass <= (digest === EXP) && irq1 && irq2;
                done <= 1;
                run_flag <= 0;
                st <= S_IDLE;
            end
            default: st <= S_IDLE;
        endcase
    end
end

endmodule
