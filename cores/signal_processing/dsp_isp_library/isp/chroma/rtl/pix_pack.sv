`timescale 1ns/1ps
// ============================================================================
// ISP-15 pixel packing: sample <-> word width adaptation.
//
// pix_pack : groups NS consecutive BITS-bit stream samples into one
//            NS*SLT-bit word.  SLT = SLOT==0 ? BITS : SLOT (SLOT in {8,16}
//            gives per-sample byte/halfword padding, e.g. 10-bit in a 16-bit
//            slot).  First sample lands in the MSB slot.  An input tlast
//            flushes a partial group immediately; unfilled low slots are
//            zero.  Output tuser = the group's first sample tuser, output
//            tlast = the flushing sample's tlast (a full NS-sample group
//            carries tlast through unchanged).
//            proto_error: sticky, set when a sample arrives with tuser
//            inside an unfinished group (frame restart without EOL).
// pix_unpack: expands words back to NS sample beats in MSB->LSB slot order.
//            Output tuser on the first slot, tlast on the last slot.
//            A flushed (padded) word re-expands to NS beats with zero
//            samples before tlast - count-preserving per word, not per
//            original group.
//
// Rate: pack output rate = input rate / NS (one beat per NS accepts),
// sustained input II=1 while the single output register drains.
// Unpack output rate = input word rate * NS; input accepts one word per
// NS cycles sustained (accept overlaps the last slot emission).
// ============================================================================
module pix_pack #(
    parameter BITS = 8,
    parameter NS   = 4,
    parameter SLOT = 0
)(
    input  wire              clk,
    input  wire              rst_n,
    input  wire [BITS-1:0]   s_tdata,
    input  wire              s_tvalid,
    input  wire              s_tuser,
    input  wire              s_tlast,
    output wire              s_tready,
    output reg  [((NS*((SLOT == 0) ? BITS : SLOT)) > 0 ?
                  (NS*((SLOT == 0) ? BITS : SLOT)) : 1)-1:0] m_tdata,
    output reg               m_tvalid,
    output reg               m_tuser,
    output reg               m_tlast,
    input  wire              m_tready,
    output reg               proto_error
);
    localparam SLT = (SLOT == 0) ? BITS : SLOT;
    localparam NW  = (NS * SLT > 0) ? NS * SLT : 1;  // width guard; NS==0 dies in $fatal

    reg [BITS-1:0] samp [0:((NS > 0) ? NS : 1)-1];
    reg [3:0]      n;
    reg            usave;
    reg            in_frame;

    wire out_free = ~m_tvalid | m_tready;
    assign s_tready = rst_n & out_free;
    wire fire  = s_tvalid & s_tready;
    wire flush = fire & ((n == NS - 1) | s_tlast);

    // MSB-first word assembly of the pending group plus the firing sample
    function [NW-1:0] make_word;
        input dummy;
        integer k;
        reg [NW-1:0] w;
        begin
            w = {NW{1'b0}};
            for (k = 0; k < NS; k = k + 1)
                w[(NS-1-k)*SLT +: SLT] =
                    (k < n) ? samp[k] : (k == n ? s_tdata : {SLT{1'b0}});
            make_word = w;
        end
    endfunction

    always @(posedge clk) begin
        if (!rst_n) begin
            n           <= 4'd0;
            usave       <= 1'b0;
            in_frame    <= 1'b0;
            proto_error <= 1'b0;
            m_tdata     <= {NW{1'b0}};
            m_tvalid    <= 1'b0;
            m_tuser     <= 1'b0;
            m_tlast     <= 1'b0;
        end else begin
            if (m_tready) m_tvalid <= 1'b0;
            if (fire) begin
                samp[n] <= s_tdata;
                if (s_tuser && in_frame) proto_error <= 1'b1;
                if (n == 0) usave <= s_tuser;
                if (flush) begin
                    m_tdata  <= make_word(1'b0);
                    m_tuser  <= (n == 0) ? s_tuser : usave;
                    m_tlast  <= s_tlast;
                    m_tvalid <= 1'b1;
                    n        <= 4'd0;
                end else n <= n + 1'b1;
                if (s_tuser) in_frame <= 1'b1;
                if (s_tlast) in_frame <= 1'b0;
            end
        end
    end

    initial begin
        if ((BITS != 8 && BITS != 10) || NS < 1 || NS > 8
            || (SLOT != 0 && SLOT != 8 && SLOT != 16) || SLOT < BITS && SLOT != 0)
            $fatal(1, "unsupported pix_pack parameters");
    end
endmodule

// ----------------------------------------------------------------------------
module pix_unpack #(
    parameter BITS = 8,
    parameter NS   = 4,
    parameter SLOT = 0
)(
    input  wire              clk,
    input  wire              rst_n,
    input  wire [((NS*((SLOT == 0) ? BITS : SLOT)) > 0 ?
                  (NS*((SLOT == 0) ? BITS : SLOT)) : 1)-1:0] s_tdata,
    input  wire              s_tvalid,
    input  wire              s_tuser,
    input  wire              s_tlast,
    output wire              s_tready,
    output reg  [BITS-1:0]   m_tdata,
    output reg               m_tvalid,
    output reg               m_tuser,
    output reg               m_tlast,
    input  wire              m_tready
);
    localparam SLT = (SLOT == 0) ? BITS : SLOT;
    localparam NW  = (NS * SLT > 0) ? NS * SLT : 1;  // width guard; NS==0 dies in $fatal

    reg [NW-1:0] word;
    reg          wu, wl, active;
    reg [3:0]    idx;

    wire out_free  = ~m_tvalid | m_tready;
    wire last_emit = active & (idx == NS - 1);
    // accept the next word exactly when the current word's last slot emits
    assign s_tready = rst_n & (~active | (last_emit & out_free));
    wire take = s_tvalid & s_tready;

    wire [SLT-1:0] slice = word[(NS-1-idx)*SLT +: SLT];

    always @(posedge clk) begin
        if (!rst_n) begin
            word     <= {NW{1'b0}};
            wu       <= 1'b0;
            wl       <= 1'b0;
            active   <= 1'b0;
            idx      <= 4'd0;
            m_tdata  <= {BITS{1'b0}};
            m_tvalid <= 1'b0;
            m_tuser  <= 1'b0;
            m_tlast  <= 1'b0;
        end else begin
            if (m_tready) m_tvalid <= 1'b0;
            if (active && out_free) begin
                m_tdata  <= slice[BITS-1:0];
                m_tvalid <= 1'b1;
                m_tuser  <= (idx == 0) & wu;
                m_tlast  <= (idx == NS - 1) & wl;
                idx      <= (idx == NS - 1) ? 4'd0 : idx + 1'b1;
            end
            if (take) begin
                word   <= s_tdata;
                wu     <= s_tuser;
                wl     <= s_tlast;
                active <= 1'b1;
                idx    <= 4'd0;
            end else if (active && out_free && idx == NS - 1) begin
                active <= 1'b0;
            end
        end
    end

    initial begin
        if ((BITS != 8 && BITS != 10) || NS < 1 || NS > 8
            || (SLOT != 0 && SLOT != 8 && SLOT != 16) || SLOT < BITS && SLOT != 0)
            $fatal(1, "unsupported pix_unpack parameters");
    end
endmodule
