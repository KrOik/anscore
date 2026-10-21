`timescale 1ns/1ps
// Asynchronous dual-clock Stream FIFO (CDC bridge), Gray-pointer scheme.
//
//   s_clk / s_rst_n : write (slave)  domain, s_tdata/s_tvalid/s_tready
//   m_clk / m_rst_n : read  (master) domain, m_tdata/m_tvalid/m_tready
//
// - DEPTH is a power of two >= 2. RAM holds DEPTH beats; one additional beat
//   lives in the registered output slot, so total buffering is DEPTH+1.
// - Binary pointers are AW+1 bits (wrap bit separates full from empty); only
//   the Gray-coded pointers cross domains through 2-FF synchronizers, so a
//   synchronizer can only ever capture the old or the new pointer value.
// - Both resets are synchronous active-low. The memory array is never reset.
// - Asymmetric reset recovery: each domain toggles s_rst_tog/m_rst_tog once
//   per local reset assertion (edge-detected). The peer samples the toggle
//   through a 2-FF synchronizer and, on detecting a level change, clamps its
//   own pointers/output-valid to the empty state for CLAMP_LEN clocks.
//   A toggle is a persistent level change, so arbitrarily short reset pulses
//   are always detected (events separated by less than ~4 clocks of the peer
//   domain may merge, which is still safe: every detection re-zeroes the
//   pointers). After any reset combination both domains converge to
//   (wptr,rptr)=(0,0)=empty. In-flight beats inside the detect window may be
//   delivered (read side, in order) or dropped (write side); all remaining
//   queued beats are discarded. Recovery requires the peer clock to be
//   toggling while the reset event is sampled.
// - II=1 on both sides whenever not full/empty; s_tready never depends on
//   m_tready and m_tvalid never depends on m_tready.
module async_stream_fifo #(
    parameter WIDTH = 16,
    parameter DEPTH = 16            // power of two, >= 2
)(
    input  wire                   s_clk,
    input  wire                   s_rst_n,
    input  wire [WIDTH-1:0]       s_tdata,
    input  wire                   s_tvalid,
    output wire                   s_tready,
    input  wire                   m_clk,
    input  wire                   m_rst_n,
    output reg  [WIDTH-1:0]       m_tdata,
    output reg                    m_tvalid,
    input  wire                   m_tready,
    // Observability only: writer's conservative RAM occupancy and reader's
    // visible beat count (RAM-not-yet-fetched + output slot). Both lag reality
    // by the synchronizer delay; do not use them for flow control. One extra
    // bit beyond AW+1 keeps reset-transient (apparently negative) differences
    // unwrapped in the modelable range.
    output wire [$clog2(DEPTH)+1:0] s_level,
    output wire [$clog2(DEPTH)+1:0] m_level
);
    localparam AW = $clog2(DEPTH);
    localparam [AW:0] DEPTHW = DEPTH[AW:0];
    localparam CLAMP_LEN = 4;       // peer-reset purge pulse, local clocks

    (* ram_style="block" *) reg [WIDTH-1:0] mem [0:DEPTH-1];

    // write domain state
    reg  [AW:0] wptr_bin, wptr_gray;
    (* async_reg="true" *) reg  [AW:0] rptr_w1, rptr_w2;
    (* async_reg="true" *) reg         m_tog_w1, m_tog_w2;
    reg         m_tog_seen = 1'b0;
    reg  [2:0]  clamp_s    = 3'd0;
    reg         s_rst_d    = 1'b0;
    reg         s_rst_tog  = 1'b0;   // reset-event toggle, crosses to m_clk
    // read domain state
    reg  [AW:0] rptr_bin, rptr_gray;
    (* async_reg="true" *) reg  [AW:0] wptr_r1, wptr_r2;
    (* async_reg="true" *) reg         s_tog_r1, s_tog_r2;
    reg         s_tog_seen = 1'b0;
    reg  [2:0]  clamp_m    = 3'd0;
    reg         m_rst_d    = 1'b0;
    reg         m_rst_tog  = 1'b0;   // reset-event toggle, crosses to s_clk

    function automatic [AW:0] g2b(input [AW:0] g);
        integer i;
        begin
            g2b[AW] = g[AW];
            for (i = AW-1; i >= 0; i = i-1) g2b[i] = g2b[i+1] ^ g[i];
        end
    endfunction

    // --------------------------------------------------------- write domain
    wire [AW:0] rbin_sync  = g2b(rptr_w2);
    // Peer reset detection: clamp for the detect edge + CLAMP_LEN clocks.
    wire       wr_clamp   = (m_tog_w2 != m_tog_seen) | (clamp_s != 0);
    // Occupancy seen by the writer is in [0,DEPTH] (synced rptr lags the true
    // rptr), so equality with DEPTH is an unambiguous full condition.
    wire       full       = ((wptr_bin - rbin_sync) == DEPTHW);
    assign     s_tready   = s_rst_n & ~wr_clamp & ~full;
    wire       push       = s_tvalid & s_tready;
    wire [AW:0] wbin_next  = wptr_bin + {{AW{1'b0}}, push};
    wire [AW:0] wgray_next = (wbin_next >> 1) ^ wbin_next;

    assign s_level = wptr_bin - rbin_sync;

    always @(posedge s_clk) begin
        if (!s_rst_n) begin
            if (s_rst_d) s_rst_tog <= ~s_rst_tog;  // once per assertion
            s_rst_d  <= 1'b0;
            wptr_bin <= 0; wptr_gray <= 0;
            rptr_w1  <= 0; rptr_w2   <= 0;
            m_tog_w1 <= 0; m_tog_w2  <= 0;
            m_tog_seen <= 1'b0; clamp_s <= 3'd0;
        end else begin
            s_rst_d  <= 1'b1;
            m_tog_w1 <= m_rst_tog; m_tog_w2 <= m_tog_w1;
            rptr_w1  <= rptr_gray; rptr_w2 <= rptr_w1;
            if (m_tog_w2 != m_tog_seen) begin
                m_tog_seen <= m_tog_w2;
                clamp_s    <= CLAMP_LEN[2:0];
            end else if (clamp_s != 0) begin
                clamp_s <= clamp_s - 3'd1;
            end
            if (wr_clamp) begin
                wptr_bin <= 0; wptr_gray <= 0;
            end else begin
                wptr_bin  <= wbin_next;
                wptr_gray <= wgray_next;
            end
        end
    end

    // Pure posedge write port, no reset (BRAM/distributed-RAM friendly).
    always @(posedge s_clk) begin
        if (push) mem[wptr_bin % DEPTH] <= s_tdata;
    end

    // ---------------------------------------------------------- read domain
    wire [AW:0] wbin_sync  = g2b(wptr_r2);
    wire       rd_clamp   = (s_tog_r2 != s_tog_seen) | (clamp_m != 0);
    // The synced wptr is a monotone delayed copy; wbin_sync-rptr_bin stays in
    // [0,DEPTH], so equality is the exact empty condition.
    wire       empty      = (wbin_sync == rptr_bin);
    wire       slot_free  = ~m_tvalid | m_tready;
    // Synchronous RAM read into the held output slot (no FWFT, no async read).
    wire       fetch      = ~rd_clamp & ~empty & slot_free;
    wire [AW:0] rbin_next  = rptr_bin + {{AW{1'b0}}, fetch};
    wire [AW:0] rgray_next = (rbin_next >> 1) ^ rbin_next;

    assign m_level = (wbin_sync - rptr_bin) + {{AW{1'b0}}, m_tvalid};

    always @(posedge m_clk) begin
        if (!m_rst_n) begin
            if (m_rst_d) m_rst_tog <= ~m_rst_tog;  // once per assertion
            m_rst_d  <= 1'b0;
            rptr_bin <= 0; rptr_gray <= 0;
            wptr_r1  <= 0; wptr_r2   <= 0;
            s_tog_r1 <= 0; s_tog_r2  <= 0;
            s_tog_seen <= 1'b0; clamp_m <= 3'd0;
            m_tvalid <= 1'b0;
        end else begin
            m_rst_d  <= 1'b1;
            s_tog_r1 <= s_rst_tog; s_tog_r2 <= s_tog_r1;
            wptr_r1  <= wptr_gray; wptr_r2 <= wptr_r1;
            if (s_tog_r2 != s_tog_seen) begin
                s_tog_seen <= s_tog_r2;
                clamp_m    <= CLAMP_LEN[2:0];
            end else if (clamp_m != 0) begin
                clamp_m <= clamp_m - 3'd1;
            end
            if (rd_clamp) begin
                rptr_bin <= 0; rptr_gray <= 0;
                m_tvalid <= 1'b0;
            end else begin
                if (fetch) begin
                    rptr_bin  <= rbin_next;
                    rptr_gray <= rgray_next;
                    m_tdata   <= mem[rptr_bin % DEPTH];
                    m_tvalid  <= 1'b1;
                end else if (m_tready) begin
                    m_tvalid <= 1'b0;
                end
            end
        end
    end

    initial begin
        if (WIDTH < 1 || DEPTH < 2 || (DEPTH & (DEPTH-1)) != 0)
            $fatal(1, "invalid parameter: WIDTH>=1, DEPTH power of two >=2");
    end
endmodule
