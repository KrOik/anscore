// ============================================================================
// dma_sg -- wave2 idx30 "DMA": simple descriptor-based DMA engine.
//
// Descriptor {src_addr, dst_addr, len, dir} is loaded through a small
// register write port; the engine then streams len words between two
// w2_dpram regions (RAM A <-> RAM B).  dir=0: A->B, dir=1: B->A.
// One word per clk_en beat once running (1-beat read latency pipelined
// against the write of the previous word).
//
// Register port (clk_en synchronous, accepted only while busy==0):
//   reg_addr=0: src_addr <= reg_data[AW-1:0]
//   reg_addr=1: dst_addr <= reg_data[AW-1:0]
//   reg_addr=2: len      <= reg_data[15:0]      (words, 1..DEPTH)
//   reg_addr=3: ctrl     <= {.., dir=bit1, go=bit0}  (go=1 launches)
//
// RAM ports are exposed; the integrator muxes them against other masters
// while busy==0.  done is a level flag (held until the next go); irq is a
// single clk_en pulse at completion.
//
// All registers clk_en gated (T2).  len==0 completes with done/irq and no
// transfers.
// ============================================================================
module dma_sg #(
    parameter W  = 8,
    parameter AW = 8
)(
    input  wire           clk,
    input  wire           clk_en,
    input  wire           rst_n,

    input  wire           reg_we,
    input  wire [1:0]     reg_addr,
    input  wire [15:0]    reg_data,

    // RAM A (word write port / word read port)
    output wire           a_we,
    output wire [AW-1:0]  a_waddr,
    output wire [W-1:0]   a_wdata,
    output wire           a_re,
    output wire [AW-1:0]  a_raddr,
    input  wire [W-1:0]   a_q,

    // RAM B
    output wire           b_we,
    output wire [AW-1:0]  b_waddr,
    output wire [W-1:0]   b_wdata,
    output wire           b_re,
    output wire [AW-1:0]  b_raddr,
    input  wire [W-1:0]   b_q,

    output reg            busy,
    output reg            done,
    output reg            irq
);

localparam S_IDLE = 2'd0;
localparam S_RUN  = 2'd1;
localparam S_FIN  = 2'd2;

reg [1:0]    state;
reg [AW-1:0] src, dst;
reg [15:0]   len;
reg          dir;
reg [15:0]   issue;   // next read index
reg [15:0]   wrcnt;   // writes completed
reg          pend;    // a read issued last beat -> q valid this beat

wire go       = reg_we && (reg_addr == 2'd3) && reg_data[0] && (state == S_IDLE);
wire rd_issue = (state == S_RUN) && (issue < len);
wire [AW-1:0] rd_addr_c = src + issue[AW-1:0];
wire [AW-1:0] wr_addr_c = dst + wrcnt[AW-1:0];
wire [W-1:0]   q_sel     = dir ? b_q : a_q;

// dir=0: read A -> write B ; dir=1: read B -> write A
assign a_re    = rd_issue & ~dir;
assign b_re    = rd_issue &  dir;
assign a_raddr = rd_addr_c;
assign b_raddr = rd_addr_c;
assign a_we    = pend &  dir;
assign b_we    = pend & ~dir;
assign a_waddr = wr_addr_c;
assign b_waddr = wr_addr_c;
assign a_wdata = q_sel;
assign b_wdata = q_sel;

always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        state <= S_IDLE;
        src <= {AW{1'b0}}; dst <= {AW{1'b0}}; len <= 16'd0; dir <= 1'b0;
        issue <= 16'd0; wrcnt <= 16'd0; pend <= 1'b0;
        busy <= 1'b0; done <= 1'b0; irq <= 1'b0;
    end else if (clk_en) begin
        irq <= 1'b0;
        if (reg_we && !busy) begin
            case (reg_addr)
                2'd0: src <= reg_data[AW-1:0];
                2'd1: dst <= reg_data[AW-1:0];
                2'd2: len <= reg_data;
                2'd3: dir <= reg_data[1];
                default: ;
            endcase
        end
        case (state)
            S_IDLE: begin
                if (go) begin
                    done  <= 1'b0;
                    busy  <= 1'b1;
                    issue <= 16'd0;
                    wrcnt <= 16'd0;
                    pend  <= 1'b0;
                    state <= (len == 16'd0) ? S_FIN : S_RUN;
                end
            end
            S_RUN: begin
                pend <= rd_issue;
                if (rd_issue) issue <= issue + 16'd1;
                if (pend)     wrcnt <= wrcnt + 16'd1;
                if (pend && (wrcnt == len - 16'd1)) state <= S_FIN;
            end
            S_FIN: begin
                done  <= 1'b1;
                irq   <= 1'b1;
                busy  <= 1'b0;
                state <= S_IDLE;
            end
            default: state <= S_IDLE;
        endcase
    end
end

endmodule
