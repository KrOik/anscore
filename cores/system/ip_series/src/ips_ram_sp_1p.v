`timescale 1ns / 1ps
// ips_ram_sp_1p : single-port synchronous RAM wrapper with byte write enable.
//
// One port, one access per beat: ce selects the port, we picks the direction and
// be[] is the per-byte write enable of the WIDTH/8 byte lanes.  The array is
// written inside a dedicated plain `always @(posedge clk)` block that carries no
// reset term, and clk_en gates that access inside the block, which is the RAM
// inference contract of docs/IP_CORE_SOP.md trap T5.  The read side is a pure
// read port on the same array.  It is deliberately asynchronous: this OSS
// synth_gowin flow never infers a Gowin BSRAM (no SPX9/DPB cell is ever emitted),
// so a clocked read port would be mapped onto a DEPTH x WIDTH flip-flop array
// plus a 32:1 mux tree per bit and blow the 200 LUT-class budget on its own,
// while an asynchronous port maps onto distributed LUTRAM (RAM16SDP) and stays
// inside it.  The shipped geometry, WIDTH = 32 and DEPTH = 1 << ADDR_BITS = 32,
// is also a legal Gowin BSRAM shape, so a device built with a real block-RAM
// flow keeps the same port contract.
//
// With OUT_REG = 0 rdata is that combinational read latch; with OUT_REG = 1 (the
// shipped default) one synchronised stage is appended, so the read datum appears
// OUT_REG enabled beats after the access that produced it.  OUT_REG is a plain
// integer used as the length of that shift chain, not a boolean test of an
// unsized flag, so a device with a different value really is a different core.
// raddr_q travels through the same chain, which lets the caller tie every
// reported datum to the address that produced it.
//
// rst_n clears the pipeline, the reported address and the counters but never the
// array: no BSRAM mapping clears an array, so an entry that was never written
// holds no defined value and the caller must write before it reads (trap T6 is
// exactly that read-port X check, which the series testbench asserts).
//
// top_sel reads back the highest implemented address DEPTH-1 through the same
// port, which is what makes the declared depth observable.  addr_count counts
// read accesses, hit_count counts those whose datum equals MATCH_CONST exactly,
// guard_count counts those whose slice above bit SHIFT equals the corresponding
// slice of MATCH_CONST, and error_sticky latches the illegal beat that asserts we
// while the port is deselected (ce low), because a write needs the port.
module ips_ram_sp_1p #(
    parameter WIDTH = 32,
    parameter ADDR_BITS = 5,
    parameter DEPTH = 1 << ADDR_BITS,
    parameter OUT_REG = 1,
    parameter BYTES = WIDTH / 8,
    parameter MATCH_CONST = 32'hA5A5_5A5A
)(
    input  wire                   clk,
    input  wire                   clk_en,
    input  wire                   rst_n,

    input  wire                   ce,
    input  wire                   we,
    input  wire  [WIDTH/8-1:0]    be,
    input  wire  [ADDR_BITS-1:0]  waddr,
    input  wire  [ADDR_BITS-1:0]  raddr,
    input  wire                   top_sel,
    input  wire  [WIDTH-1:0]      wdata,

    output wire  [WIDTH-1:0]      rdata,
    output wire  [ADDR_BITS-1:0]  raddr_q,
    output reg   [7:0]            hit_count,
    output reg   [7:0]            guard_count,
    output reg   [15:0]           addr_count,
    output reg                    error_sticky
);

localparam integer IDX_BITS  = ADDR_BITS + 2;
localparam integer SHIFT     = 8;
localparam integer LANES     = 4;
localparam integer STAGES    = OUT_REG + 1;

reg [WIDTH-1:0]                   mem [0:DEPTH-1];
reg [STAGES*WIDTH-1:0]            rd_pipe;
reg [STAGES*ADDR_BITS-1:0]        ra_pipe;
reg [STAGES*WIDTH-1:0]            rd_next;
reg [STAGES*ADDR_BITS-1:0]        ra_next;

wire [IDX_BITS-1:0]               top_addr = DEPTH - 1;
wire [IDX_BITS-1:0]               r_in     = raddr;
wire [IDX_BITS-1:0]               r_addr   = top_sel ? top_addr : r_in;
wire [WIDTH-1:0]                  rd_raw   = mem[r_addr];
wire                              hit      = (rd_raw === MATCH_CONST);
wire                              guard    = ((rd_raw >> SHIFT) == (MATCH_CONST >> SHIFT));
wire                              load     = (ce && !we);

wire [WIDTH/8-1:0]                be_ok;
genvar                            gb;
generate
    for (gb = 0; gb < LANES; gb = gb + 1) begin : g_lane_en
        assign be_ok[gb] = (gb < BYTES) ? be[gb] : 1'b0;
    end
endgenerate

// Memory write port: plain posedge-clk block with no reset term, clk_en gated
// inside the block (docs/IP_CORE_SOP.md trap T5).
always @(posedge clk) begin
    if (clk_en) begin
        if (ce && we) begin
            if (be_ok[0]) mem[waddr][0*8 +: 8] = wdata[0*8 +: 8];
            if (be_ok[1]) mem[waddr][1*8 +: 8] = wdata[1*8 +: 8];
            if (be_ok[2]) mem[waddr][2*8 +: 8] = wdata[2*8 +: 8];
            if (be_ok[3]) mem[waddr][3*8 +: 8] = wdata[3*8 +: 8];
        end
    end
end

always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        rd_pipe      <= {STAGES*WIDTH{1'b0}};
        ra_pipe      <= {STAGES*ADDR_BITS{1'b0}};
        hit_count    <= 8'h00;
        guard_count  <= 8'h00;
        addr_count   <= 16'h0000;
        error_sticky <= 1'b0;
    end else if (clk_en) begin
        rd_next = rd_pipe << WIDTH;
        ra_next = ra_pipe << ADDR_BITS;
        if (load) begin
            rd_next[WIDTH-1:0]     = rd_raw;
            ra_next[ADDR_BITS-1:0] = r_addr[ADDR_BITS-1:0];
            addr_count <= addr_count + 16'h0001;
            if (hit) begin
                hit_count <= hit_count + 8'h01;
            end
            if (guard) begin
                guard_count <= guard_count + 8'h01;
            end
        end
        rd_pipe <= rd_next;
        ra_pipe <= ra_next;
        if (we && !ce) begin
            error_sticky <= 1'b1;
        end
    end
end

assign rdata   = (OUT_REG == 0) ? rd_raw : rd_pipe[(OUT_REG*WIDTH) +: WIDTH];
assign raddr_q = (OUT_REG == 0) ? r_addr[ADDR_BITS-1:0]
                                : ra_pipe[(OUT_REG*ADDR_BITS) +: ADDR_BITS];

endmodule
