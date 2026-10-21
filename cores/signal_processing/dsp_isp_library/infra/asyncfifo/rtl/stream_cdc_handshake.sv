`timescale 1ns/1ps
// Single-item request/acknowledge CDC channel (toggle / 2-phase handshake).
//
//   s_clk / s_rst_n : write (slave)  domain, s_tdata/s_tvalid/s_tready
//   m_clk / m_rst_n : read  (master) domain, m_tdata/m_tvalid/m_tready
//
// One WIDTH-bit payload in flight at a time. The source registers the beat
// into sbuf and flips req_t; the request level crosses through a 2-FF
// synchronizer, the destination captures sbuf and acknowledges by copying the
// request level into ack_t, which crosses back through a 2-FF synchronizer.
// s_tready is low while a transfer is outstanding, so sbuf is guaranteed
// stable for the whole m-side capture window (multi-cycle path).
//
// Throughput is roughly one beat per full handshake round trip
// (~2 m_clk request sync + capture + ~2 s_clk acknowledge sync), independent
// of the clock ratio. Use async_stream_fifo when sustained throughput matters.
//
// Reset contract matches async_stream_fifo: each domain toggles its rst_tog
// once per local reset assertion; the peer detects the level change through a
// 2-FF synchronizer and clamps its own state to idle (req==ack) for
// CLAMP_LEN clocks. Either side may reset alone; both domains converge to
// the idle state. The in-flight beat inside the detect window is dropped.
module stream_cdc_handshake #(
    parameter WIDTH = 16
)(
    input  wire             s_clk,
    input  wire             s_rst_n,
    input  wire [WIDTH-1:0] s_tdata,
    input  wire             s_tvalid,
    output wire             s_tready,
    input  wire             m_clk,
    input  wire             m_rst_n,
    output reg  [WIDTH-1:0] m_tdata,
    output reg              m_tvalid,
    input  wire             m_tready
);
    localparam CLAMP_LEN = 4;

    reg req_t = 1'b0;                // s_clk request toggle
    reg [WIDTH-1:0] sbuf;            // held payload (MCP source, see SPEC.md)
    (* async_reg="true" *) reg ack_w1, ack_w2;   // ack_t synced into s_clk
    (* async_reg="true" *) reg m_tog_w1, m_tog_w2;
    reg m_tog_seen = 1'b0;
    reg [2:0] clamp_s = 3'd0;
    reg s_rst_d   = 1'b0;
    reg s_rst_tog = 1'b0;

    reg ack_t = 1'b0;                // m_clk acknowledge toggle
    reg req_seen = 1'b0;             // m_clk: last consumed request level
    (* async_reg="true" *) reg req_m1, req_m2;   // req_t synced into m_clk
    (* async_reg="true" *) reg s_tog_r1, s_tog_r2;
    reg s_tog_seen = 1'b0;
    reg [2:0] clamp_m = 3'd0;
    reg m_rst_d   = 1'b0;
    reg m_rst_tog = 1'b0;

    // --------------------------------------------------------- write domain
    wire wr_clamp = (m_tog_w2 != m_tog_seen) | (clamp_s != 0);
    wire s_idle   = (req_t == ack_w2);
    assign s_tready = s_rst_n & ~wr_clamp & s_idle;
    wire push = s_tvalid & s_tready;

    always @(posedge s_clk) begin
        if (!s_rst_n) begin
            if (s_rst_d) s_rst_tog <= ~s_rst_tog;
            s_rst_d <= 1'b0;
            req_t <= 1'b0;
            ack_w1 <= 0; ack_w2 <= 0;
            m_tog_w1 <= 0; m_tog_w2 <= 0;
            m_tog_seen <= 1'b0; clamp_s <= 3'd0;
        end else begin
            s_rst_d <= 1'b1;
            m_tog_w1 <= m_rst_tog; m_tog_w2 <= m_tog_w1;
            ack_w1 <= ack_t; ack_w2 <= ack_w1;
            if (m_tog_w2 != m_tog_seen) begin
                m_tog_seen <= m_tog_w2;
                clamp_s    <= CLAMP_LEN[2:0];
            end else if (clamp_s != 0) begin
                clamp_s <= clamp_s - 3'd1;
            end
            if (wr_clamp) req_t <= 1'b0;
            else if (push) begin
                sbuf  <= s_tdata;
                req_t <= ~req_t;
            end
        end
    end

    // ---------------------------------------------------------- read domain
    wire rd_clamp = (s_tog_r2 != s_tog_seen) | (clamp_m != 0);
    wire got_req  = (req_m2 != req_seen);

    always @(posedge m_clk) begin
        if (!m_rst_n) begin
            if (m_rst_d) m_rst_tog <= ~m_rst_tog;
            m_rst_d <= 1'b0;
            req_m1 <= 0; req_m2 <= 0;
            req_seen <= 1'b0; ack_t <= 1'b0;
            s_tog_r1 <= 0; s_tog_r2 <= 0;
            s_tog_seen <= 1'b0; clamp_m <= 3'd0;
            m_tvalid <= 1'b0;
        end else begin
            m_rst_d <= 1'b1;
            s_tog_r1 <= s_rst_tog; s_tog_r2 <= s_tog_r1;
            req_m1 <= req_t; req_m2 <= req_m1;
            if (s_tog_r2 != s_tog_seen) begin
                s_tog_seen <= s_tog_r2;
                clamp_m    <= CLAMP_LEN[2:0];
            end else if (clamp_m != 0) begin
                clamp_m <= clamp_m - 3'd1;
            end
            if (rd_clamp) begin
                // Peer reset: drop the held beat and align the acknowledge
                // with the remote request level (0 after its reset).
                req_seen <= req_m2;
                ack_t    <= req_m2;
                m_tvalid <= 1'b0;
            end else if (!m_tvalid && got_req) begin
                m_tdata  <= sbuf;          // sbuf stable: MCP, see SPEC.md
                m_tvalid <= 1'b1;
                req_seen <= req_m2;
                ack_t    <= req_m2;
            end else if (m_tvalid && m_tready) begin
                m_tvalid <= 1'b0;
            end
        end
    end

    initial begin
        if (WIDTH < 1) $fatal(1, "invalid parameter: WIDTH>=1");
    end
endmodule
