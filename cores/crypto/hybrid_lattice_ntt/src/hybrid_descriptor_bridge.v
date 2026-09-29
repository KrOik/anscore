// Descriptor bridge between the zero-switch sequencer and the systolic state array.
//
// The sequencer's contract is initiation interval 1: it raises error and
// ERR_INVALID_BUBBLE on any cycle it holds a descriptor while the consumer is not
// ready.  The systolic array cannot honour that -- it is busy for ~3000 cycles per
// op and only accepts a start in its idle state.  Neither contract is wrong; they
// just need something in between that (a) absorbs the whole burst into a FIFO and
// (b) presents start to the array in the first cycle the array can take it.
//
// Because the grant is combinational on array_start_ready, and the array becomes
// ready in the same edge that raises done, the next op is accepted on that very
// next edge: handoff 1, zero dead cycles.  A registered grant would cost one.
//
// Accounting, all of it observable on the ports:
//   * max_handoff / dead_cycle_count -- edges between one op's last edge and the
//     next op's accept edge, minus the one edge the array physically needs to
//     leave S_DIGEST_RUN.  A zero-switch stream must report max_handoff 1 and no
//     dead cycles at all.
//   * underrun_cycles -- the array sat idle with nothing in the FIFO while the
//     burst was still running, i.e. the producer did not keep up.
//   * pushed / launched / complete must agree when the burst ends.
module hybrid_descriptor_bridge #(
    parameter integer DEPTH = 32
) (
    input  wire        clk,
    input  wire        rst_n,
    input  wire        start,
    input  wire [15:0] descriptor_count,

    input  wire        desc_valid,
    input  wire [2:0]  desc_op,
    output wire        desc_ready,

    input  wire        array_start_ready,
    input  wire        array_done,
    input  wire        array_error,
    output wire        array_start,
    output wire [2:0]  array_op,
    output reg  [2:0]  running_op,

    output wire        ready,
    output reg         busy,
    output reg         done,
    output reg         error,
    output reg  [15:0] terminal_error_cause,
    output reg  [15:0] pushed_count,
    output reg  [15:0] launched_count,
    output reg  [15:0] complete_count,
    output reg  [15:0] dead_cycle_count,
    output reg  [15:0] max_handoff,
    output reg  [15:0] underrun_cycles,
    output reg  [7:0]  fifo_level
);

localparam [15:0] ERR_ZERO_COUNT  = 16'h0001;
localparam [15:0] ERR_OVER_PUSH   = 16'h0002;
localparam [15:0] ERR_UNSUPPORTED = 16'h0004;
localparam [15:0] ERR_ARRAY       = 16'h0008;
localparam [15:0] ERR_HANDOFF     = 16'h0010;

// DEPTH is a power of two.  The pointer width is spelled out instead of $clog2 so
// the same source reads the same way in iverilog and in the yosys Verilog frontend.
localparam integer PTR_BITS =
    (DEPTH == 2)   ? 1 :
    (DEPTH == 4)   ? 2 :
    (DEPTH == 8)   ? 3 :
    (DEPTH == 16)  ? 4 :
    (DEPTH == 32)  ? 5 :
    (DEPTH == 64)  ? 6 :
    (DEPTH == 128) ? 7 : 8;

localparam integer COUNT_BITS = PTR_BITS + 1;
localparam [COUNT_BITS-1:0] DEPTH_VEC = DEPTH;

reg [2:0] fifo [0:DEPTH-1];
reg [PTR_BITS-1:0] wr_ptr;
reg [PTR_BITS-1:0] rd_ptr;
reg [COUNT_BITS-1:0] count;
reg armed;
reg stop;
reg [15:0] target_count;
reg [31:0] cycle_number;
reg done_prev;
reg have_handoff_base;
reg [31:0] handoff_base;

wire [2:0] head_op = fifo[rd_ptr];
wire fifo_empty = (count == {COUNT_BITS{1'b0}});
wire fifo_full  = (count == DEPTH_VEC);
wire arm_now    = !armed && start;
wire can_take   = armed && !fifo_full && !stop;
wire push       = desc_valid && can_take;
// The array takes a start in any cycle it is idle; grant combinationally so the
// accept lands on the first edge that can possibly honour it.  array_error is a
// level that rises with done and survives until the next accept, so gating the
// grant on it stops a failed op from being followed by another one, and costs
// nothing while the array is healthy.
wire accept     = armed && !fifo_empty && !stop && array_start_ready && !array_error;
wire done_rise  = array_done && !done_prev;
wire [15:0] pushed_next    = pushed_count + (push ? 16'd1 : 16'd0);
wire [15:0] launched_next  = launched_count + (accept ? 16'd1 : 16'd0);
wire [15:0] complete_next  = complete_count + (done_rise ? 16'd1 : 16'd0);
wire push_bad     = push && (desc_op > 3'd3 || pushed_next > target_count);
wire array_bad    = done_rise && array_error;
wire burst_done   = done_rise && (complete_next >= target_count);
wire burst_end    = push_bad || array_bad || burst_done;
// Edges from the previous op's last edge to this accept; 1 means the accept landed
// on the next edge, so nothing was wasted.  The zero-switch case is precisely the
// one where done_rise and accept fall in the same edge, so the base written by
// this edge has to be the base this edge measures against -- reading the
// registered value would report the whole previous op instead of the handoff.
wire [31:0] handoff_base_now = done_rise ? (cycle_number - 32'd1) : handoff_base;
wire handoff_known = have_handoff_base || done_rise;
wire [31:0] handoff = cycle_number - handoff_base_now;
wire handoff_bad  = handoff_known && (handoff > 32'd1);
wire [COUNT_BITS-1:0] count_next =
    count + (push ? 1'b1 : 1'b0) - (accept ? 1'b1 : 1'b0);

assign ready       = !armed;
assign desc_ready  = can_take;
assign array_start = accept;
assign array_op    = head_op;

always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        wr_ptr               <= {PTR_BITS{1'b0}};
        rd_ptr               <= {PTR_BITS{1'b0}};
        count                <= {COUNT_BITS{1'b0}};
        fifo_level           <= 8'd0;
        armed                <= 1'b0;
        stop                 <= 1'b0;
        target_count         <= 16'd0;
        cycle_number         <= 32'd0;
        done_prev            <= 1'b0;
        have_handoff_base    <= 1'b0;
        handoff_base         <= 32'd0;
        running_op           <= 3'd0;
        busy                 <= 1'b0;
        done                 <= 1'b0;
        error                <= 1'b0;
        terminal_error_cause <= 16'd0;
        pushed_count         <= 16'd0;
        launched_count       <= 16'd0;
        complete_count       <= 16'd0;
        dead_cycle_count     <= 16'd0;
        max_handoff          <= 16'd0;
        underrun_cycles      <= 16'd0;
    end else begin
        cycle_number <= cycle_number + 32'd1;
        done_prev    <= array_done;
        count        <= count_next;
        fifo_level   <= count_next;
        done         <= 1'b0;
        busy         <= armed && !burst_end;

        if (arm_now) begin
            wr_ptr               <= {PTR_BITS{1'b0}};
            rd_ptr               <= {PTR_BITS{1'b0}};
            count                <= {COUNT_BITS{1'b0}};
            fifo_level           <= 8'd0;
            target_count         <= descriptor_count;
            pushed_count         <= 16'd0;
            launched_count       <= 16'd0;
            complete_count       <= 16'd0;
            dead_cycle_count     <= 16'd0;
            max_handoff          <= 16'd0;
            underrun_cycles      <= 16'd0;
            terminal_error_cause <= 16'd0;
            error                <= 1'b0;
            stop                 <= 1'b0;
            have_handoff_base    <= 1'b0;
            running_op           <= 3'd0;
            armed                <= (descriptor_count != 16'd0);
            busy                 <= (descriptor_count != 16'd0);
            if (descriptor_count == 16'd0) begin
                done                 <= 1'b1;
                error                <= 1'b1;
                terminal_error_cause <= ERR_ZERO_COUNT;
            end
        end else begin
            if (push) begin
                fifo[wr_ptr] <= desc_op;
                wr_ptr       <= wr_ptr + 1'b1;
                pushed_count <= pushed_next;
            end

            if (accept) begin
                rd_ptr         <= rd_ptr + 1'b1;
                launched_count <= launched_next;
                running_op     <= head_op;
                if (handoff_known) begin
                    if (handoff > {16'd0, max_handoff}) begin
                        max_handoff <= handoff[15:0];
                    end
                    if (handoff_bad) begin
                        dead_cycle_count     <= dead_cycle_count +
                            handoff[15:0] - 16'd1;
                        error                <= 1'b1;
                        terminal_error_cause <= terminal_error_cause | ERR_HANDOFF;
                    end
                end
            end

            if (done_rise) begin
                complete_count    <= complete_next;
                handoff_base      <= cycle_number - 32'd1;
                have_handoff_base <= 1'b1;
            end

            // A descriptor arriving in this edge cannot rescue it: the accept is
            // built from the FIFO content the edge started with, so an idle array
            // with an empty FIFO is a stall whether or not one is on the way in.
            if (armed && array_start_ready && fifo_empty &&
                (pushed_count != 16'd0) && !burst_end) begin
                underrun_cycles <= underrun_cycles + 16'd1;
            end

            if (push_bad) begin
                error                <= 1'b1;
                stop                 <= 1'b1;
                armed                <= 1'b0;
                done                 <= 1'b1;
                terminal_error_cause <= terminal_error_cause |
                    (desc_op > 3'd3 ? ERR_UNSUPPORTED : ERR_OVER_PUSH);
            end else if (array_bad) begin
                error                <= 1'b1;
                stop                 <= 1'b1;
                armed                <= 1'b0;
                done                 <= 1'b1;
                terminal_error_cause <= terminal_error_cause | ERR_ARRAY;
            end else if (burst_done) begin
                armed <= 1'b0;
                done  <= 1'b1;
            end
        end
    end
end

endmodule
