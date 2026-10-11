`timescale 1ns / 1ps
// ips_ram_dp_1w2r : one writer, two independent readers, no port collision.
//
// The array is duplicated into two banks.  Each bank carries the write port plus
// one read port, i.e. two physical simple-dual-port memories give the three
// logical ports this core advertises, so a read on either side can never be
// blocked by the other reader and neither reader ever loses an access.  Both
// banks see every write, so they always hold the same image; the duplication is
// what buys the extra port, not extra capacity.
//
// The write port lives in a dedicated plain `always @(posedge clk)` block with no
// reset term and clk_en gated inside it (docs/IP_CORE_SOP.md trap T5).  The read
// ports are pure asynchronous ports on their own bank, which is what keeps this
// shape inside the LUT-class budget: this OSS synth_gowin flow never infers a
// Gowin BSRAM, so a clocked read port would become a DEPTH x WIDTH flip-flop
// array with a DEPTH:1 mux tree per bit, twice over, while an asynchronous port
// maps onto distributed LUTRAM.
//
// A write and a read of the same cell in the same beat is the case a single-port
// RAM cannot resolve.  Here it is resolved by construction: col0/col1 detect it
// and that read port takes wdata (write-through), so the reported result never
// depends on the scheduling order of the two always blocks.  col0 && col1 is the
// worst case - all three logical ports on one cell - and conflict_sticky latches
// that it happened.
//
// Each read port has its own OUT_REG-deep output register chain carrying the data,
// the address that produced it and a valid flag (OUT_REG = 0 taps the
// unregistered port, the shipped default 1 appends one synchronised stage), so the
// two streams stay independent, every reported datum is tied to the address that
// produced it, and a slot of the chain that carried no access reads back as zero.
// rst_n clears the pipelines and the counters but never the banks: an entry that
// was never written holds no defined value, so the caller must write before it
// reads (trap T6, which the series testbench asserts as an X check on both read
// ports).
//
// r0_top / r1_top replace their port address by the highest implemented address
// DEPTH-1, which is what makes the declared depth observable.  hit_count counts
// port-0 accesses whose datum is exactly MATCH_CONST, guard_count counts port-1
// accesses whose slice above bit GUARD_SHIFT equals the same slice of
// MATCH_CONST, read_count counts enabled read accesses on both ports,
// write_count the writes and collide_count the beats where a write collided with
// at least one read port.
module ips_ram_dp_1w2r #(
    parameter WIDTH = 32,
    parameter ADDR_BITS = 4,
    parameter DEPTH = 1 << ADDR_BITS,
    parameter OUT_REG = 1,
    parameter GUARD_SHIFT = 8,
    parameter MATCH_CONST = 32'hA5A5_5A5A
)(
    input  wire                  clk,
    input  wire                  clk_en,
    input  wire                  rst_n,

    input  wire                  wr_en,
    input  wire [ADDR_BITS-1:0]  waddr,
    input  wire [WIDTH-1:0]      wdata,

    input  wire                  r0_en,
    input  wire [ADDR_BITS-1:0]  r0_addr,
    input  wire                  r0_top,

    input  wire                  r1_en,
    input  wire [ADDR_BITS-1:0]  r1_addr,
    input  wire                  r1_top,

    output wire [WIDTH-1:0]      r0_data,
    output wire [ADDR_BITS-1:0]  r0_addr_q,
    output wire                  r0_valid,
    output wire [WIDTH-1:0]      r1_data,
    output wire [ADDR_BITS-1:0]  r1_addr_q,
    output wire                  r1_valid,
    output reg  [7:0]            hit_count,
    output reg  [7:0]            guard_count,
    output reg  [15:0]           read_count,
    output reg  [7:0]            write_count,
    output reg  [7:0]            collide_count,
    output reg                   conflict_sticky
);

localparam integer IDX_BITS = ADDR_BITS + 2;
localparam integer STAGES   = OUT_REG + 1;

reg [WIDTH-1:0]            bank0 [0:DEPTH-1];
reg [WIDTH-1:0]            bank1 [0:DEPTH-1];

reg [STAGES*WIDTH-1:0]     p0;
reg [STAGES*WIDTH-1:0]     p1;
reg [STAGES*IDX_BITS-1:0]  q0;
reg [STAGES*IDX_BITS-1:0]  q1;
reg [STAGES-1:0]           v0;
reg [STAGES-1:0]           v1;
reg [STAGES*WIDTH-1:0]     p0n;
reg [STAGES*WIDTH-1:0]     p1n;
reg [STAGES*IDX_BITS-1:0]  q0n;
reg [STAGES*IDX_BITS-1:0]  q1n;
reg [STAGES-1:0]           v0n;
reg [STAGES-1:0]           v1n;

wire [IDX_BITS-1:0]        top_addr = DEPTH - 1;
wire [IDX_BITS-1:0]        wa       = waddr;
wire [IDX_BITS-1:0]        a0_in    = r0_addr;
wire [IDX_BITS-1:0]        a1_in    = r1_addr;
wire [IDX_BITS-1:0]        a0       = r0_top ? top_addr : a0_in;
wire [IDX_BITS-1:0]        a1       = r1_top ? top_addr : a1_in;

wire [WIDTH-1:0]           bank0_q  = bank0[a0];
wire [WIDTH-1:0]           bank1_q  = bank1[a1];

wire                       col0     = (wr_en && r0_en && (wa == a0));
wire                       col1     = (wr_en && r1_en && (wa == a1));
wire [WIDTH-1:0]           d0       = col0 ? wdata : bank0_q;
wire [WIDTH-1:0]           d1       = col1 ? wdata : bank1_q;

wire                       hit0     = (d0 === MATCH_CONST);
wire                       guard1   = ((d1 >> GUARD_SHIFT) == (MATCH_CONST >> GUARD_SHIFT));
wire [1:0]                 rd_inc   = {1'b0, r0_en} + {1'b0, r1_en};
wire [15:0]                rd_add   = {14'h0000, rd_inc};

// Both banks take the same write: the duplication is what gives the second reader
// its own port.  Plain posedge-clk block with no reset term, clk_en gating the
// access inside it (docs/IP_CORE_SOP.md trap T5).
always @(posedge clk) begin
    if (clk_en) begin
        if (wr_en) begin
            bank0[wa[ADDR_BITS-1:0]] = wdata;
            bank1[wa[ADDR_BITS-1:0]] = wdata;
        end
    end
end

always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        p0              <= {STAGES*WIDTH{1'b0}};
        p1              <= {STAGES*WIDTH{1'b0}};
        q0              <= {STAGES*IDX_BITS{1'b0}};
        q1              <= {STAGES*IDX_BITS{1'b0}};
        v0              <= {STAGES{1'b0}};
        v1              <= {STAGES{1'b0}};
        hit_count       <= 8'h00;
        guard_count     <= 8'h00;
        read_count      <= 16'h0000;
        write_count     <= 8'h00;
        collide_count   <= 8'h00;
        conflict_sticky <= 1'b0;
    end else if (clk_en) begin
        p0n       = p0 << WIDTH;
        p1n       = p1 << WIDTH;
        q0n       = q0 << IDX_BITS;
        q1n       = q1 << IDX_BITS;
        v0n       = v0 << 1;
        v1n       = v1 << 1;
        v0n[0]    = r0_en;
        v1n[0]    = r1_en;
        read_count <= read_count + rd_add;
        if (r0_en) begin
            p0n[WIDTH-1:0]    = d0;
            q0n[IDX_BITS-1:0] = a0;
            if (hit0) begin
                hit_count <= hit_count + 8'h01;
            end
        end
        if (r1_en) begin
            p1n[WIDTH-1:0]    = d1;
            q1n[IDX_BITS-1:0] = a1;
            if (guard1) begin
                guard_count <= guard_count + 8'h01;
            end
        end
        if (wr_en) begin
            write_count <= write_count + 8'h01;
        end
        if (col0 || col1) begin
            collide_count <= collide_count + 8'h01;
        end
        if (col0 && col1) begin
            conflict_sticky <= 1'b1;
        end
        p0 <= p0n;
        p1 <= p1n;
        q0 <= q0n;
        q1 <= q1n;
        v0 <= v0n;
        v1 <= v1n;
    end
end

assign r0_data   = (OUT_REG == 0) ? d0 : p0[(OUT_REG*WIDTH) +: WIDTH];
assign r0_addr_q = (OUT_REG == 0) ? a0[ADDR_BITS-1:0]
                                 : q0[(OUT_REG*IDX_BITS) +: ADDR_BITS];
assign r0_valid  = (OUT_REG == 0) ? r0_en : v0[OUT_REG];
assign r1_data   = (OUT_REG == 0) ? d1 : p1[(OUT_REG*WIDTH) +: WIDTH];
assign r1_addr_q = (OUT_REG == 0) ? a1[ADDR_BITS-1:0]
                                 : q1[(OUT_REG*IDX_BITS) +: ADDR_BITS];
assign r1_valid  = (OUT_REG == 0) ? r1_en : v1[OUT_REG];

endmodule
