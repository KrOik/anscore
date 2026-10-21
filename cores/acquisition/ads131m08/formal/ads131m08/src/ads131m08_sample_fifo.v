// Synchronous sample FIFO for the ADS131M08 IP.
//
// Plain synchronous single-clock FIFO: one write port, one registered read
// port, no asynchronous reset on the storage array, so block RAM inference
// works.  Overflow is explicit and sticky -- a full FIFO never silently
// overwrites the oldest sample, it drops the new one and raises ``overflow``
// and ``drop_count`` so the host can see that data were lost.
`timescale 1ns/1ps

module ads131m08_sample_fifo #(
    parameter integer WIDTH = 272,
    parameter integer DEPTH = 512          // power of two
) (
    input  wire             clk,
    input  wire             rst_n,

    input  wire             wr_en,
    input  wire [WIDTH-1:0] wr_data,
    input  wire             rd_en,
    output reg  [WIDTH-1:0] rd_data,

    output wire             full,
    output wire             empty,
    output wire [15:0]      level,
    output reg  [31:0]      drop_count,
    output reg              overflow,      // sticky until cleared
    input  wire             clear          // pulse: flush and clear the sticky flags
);
    localparam integer AW = $clog2(DEPTH);

    // Prefer synchronous block RAM when the selected FPGA flow supports it.
    // The RTL remains vendor-neutral; unsupported flows may legally map this
    // storage to registers or distributed RAM, which the inference report
    // must expose rather than silently treating as BRAM evidence.
    (* ram_style = "block", syn_ramstyle = "block_ram" *)
    reg [WIDTH-1:0] mem [0:DEPTH-1];
    reg [AW:0]      wptr;
    reg [AW:0]      rptr;

    wire [AW:0] used = wptr - rptr;

    assign full  = (used == DEPTH[AW:0]);
    assign empty = (wptr == rptr);
    // used is only AW+1 bits; slicing [15:0] would read past the MSB and
    // produce X in the upper bits.
    assign level = used;

    wire do_wr = wr_en && !full;
    wire do_rd = rd_en && !empty;

    always @(posedge clk) begin
        if (do_wr) mem[wptr[AW-1:0]] <= wr_data;
        if (do_rd) rd_data          <= mem[rptr[AW-1:0]];
    end

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            wptr       <= {(AW+1){1'b0}};
            rptr       <= {(AW+1){1'b0}};
            overflow   <= 1'b0;
            drop_count <= 32'd0;
        end else if (clear) begin
            wptr       <= {(AW+1){1'b0}};
            rptr       <= {(AW+1){1'b0}};
            overflow   <= 1'b0;
            drop_count <= 32'd0;
        end else begin
            if (do_wr) wptr <= wptr + {{AW{1'b0}}, 1'b1};
            if (do_rd) rptr <= rptr + {{AW{1'b0}}, 1'b1};
            if (wr_en && full) begin
                // Dropped rather than overwritten: the host must be able to tell.
                overflow   <= 1'b1;
                drop_count <= drop_count + 32'd1;
            end
        end
    end

endmodule
