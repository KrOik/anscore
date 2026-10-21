// AWB statistics collector with RGB bypass.
// The next accepted SOF publishes the preceding frame; stats_flush publishes
// the final frame while s_valid is low. img_isp_awb_auto connects this to the
// hardware gray-world solver and frame-committed gain stage.
`timescale 1ns/1ps
module img_isp_awb_stats #(
    parameter integer SUM_WIDTH = 48
) (
    input wire clk, input wire rst_n, input wire clk_en,
    input wire [23:0] s_data, input wire s_valid, output wire s_ready,
    input wire s_sof, input wire s_eol,
    output reg [23:0] m_data, output reg m_valid, input wire m_ready,
    output reg m_sof, output reg m_eol,
    input wire stats_flush, output wire stats_flush_ready,
    output reg stats_valid, input wire stats_ready,
    output reg [SUM_WIDTH-1:0] stats_sum_r, stats_sum_g, stats_sum_b,
    output reg [31:0] stats_pixel_count,
    output reg [31:0] stats_line_count,
    output reg [31:0] stats_frame_id,
    output reg stats_overflow,
    output reg protocol_error
);
    reg frame_open, overflow;
    reg [SUM_WIDTH-1:0] sum_r, sum_g, sum_b;
    reg [31:0] pixel_count, line_count, frame_id;
    // Exact parallel byte carries: preserve saturation and frame wrap.
    function [31:0] increment_count;
        input [31:0] value;
        begin
            increment_count[7:0]=value[7:0]+8'd1;
            increment_count[15:8]=value[15:8]+(&value[7:0]);
            increment_count[23:16]=value[23:16]+(&value[15:0]);
            increment_count[31:24]=value[31:24]+(&value[23:0]);
        end
    endfunction
    wire [31:0] pixel_increment=increment_count(pixel_count);
    wire [31:0] line_increment=increment_count(line_count);
    wire [31:0] frame_increment=increment_count(frame_id);
    wire pixel_saturated=&pixel_count;
    wire line_saturated=&line_count;
    wire stats_slot_free = !stats_valid || stats_ready;
    wire boundary_blocked = s_valid && s_sof && frame_open && !stats_slot_free;
    // Exact modulo-2^(SUM_WIDTH+1) additions; retain nibble prefix
    // boundaries so no-ALU mapping cannot serialize a full-width carry.
    wire [SUM_WIDTH:0] next_r, next_g, next_b;
    wire [SUM_WIDTH:0] pixel_r = s_data[23:16];
    wire [SUM_WIDTH:0] pixel_g = s_data[15:8];
    wire [SUM_WIDTH:0] pixel_b = s_data[7:0];
    img_awb_add_prefix #(.WIDTH(SUM_WIDTH+1)) add_r(
        .a({1'b0,sum_r}), .b(pixel_r), .result(next_r));
    img_awb_add_prefix #(.WIDTH(SUM_WIDTH+1)) add_g(
        .a({1'b0,sum_g}), .b(pixel_g), .result(next_g));
    img_awb_add_prefix #(.WIDTH(SUM_WIDTH+1)) add_b(
        .a({1'b0,sum_b}), .b(pixel_b), .result(next_b));
    assign s_ready = clk_en && (!m_valid || m_ready) && !boundary_blocked;
    assign stats_flush_ready = clk_en && frame_open && !s_valid && stats_slot_free;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            m_data <= 0; m_valid <= 0; m_sof <= 0; m_eol <= 0;
            stats_valid <= 0; stats_sum_r <= 0; stats_sum_g <= 0; stats_sum_b <= 0;
            stats_pixel_count <= 0; stats_line_count <= 0; stats_frame_id <= 0;
            stats_overflow <= 0; protocol_error <= 0;
            frame_open <= 0; overflow <= 0;
            sum_r <= 0; sum_g <= 0; sum_b <= 0;
            pixel_count <= 0; line_count <= 0; frame_id <= 0;
        end else if (clk_en) begin
            if (m_valid && m_ready) m_valid <= 0;
            if (stats_valid && stats_ready) stats_valid <= 0;
            if (stats_flush && stats_flush_ready) begin
                stats_valid <= 1;
                stats_sum_r <= sum_r; stats_sum_g <= sum_g; stats_sum_b <= sum_b;
                stats_pixel_count <= pixel_count; stats_line_count <= line_count;
                stats_frame_id <= frame_id; stats_overflow <= overflow;
                frame_id <= frame_increment;
                frame_open <= 0;
            end
            if (s_valid && s_ready) begin
                m_data <= s_data; m_valid <= 1; m_sof <= s_sof; m_eol <= s_eol;
                if (s_sof) begin
                    if (frame_open) begin
                        stats_valid <= 1;
                        stats_sum_r <= sum_r; stats_sum_g <= sum_g; stats_sum_b <= sum_b;
                        stats_pixel_count <= pixel_count; stats_line_count <= line_count;
                        stats_frame_id <= frame_id; stats_overflow <= overflow;
                        frame_id <= frame_increment;
                    end
                    frame_open <= 1;
                    sum_r <= s_data[23:16]; sum_g <= s_data[15:8]; sum_b <= s_data[7:0];
                    pixel_count <= 1; line_count <= s_eol ? 1 : 0; overflow <= 0;
                end else if (frame_open) begin
                    sum_r <= next_r[SUM_WIDTH] ? {SUM_WIDTH{1'b1}} : next_r[SUM_WIDTH-1:0];
                    sum_g <= next_g[SUM_WIDTH] ? {SUM_WIDTH{1'b1}} : next_g[SUM_WIDTH-1:0];
                    sum_b <= next_b[SUM_WIDTH] ? {SUM_WIDTH{1'b1}} : next_b[SUM_WIDTH-1:0];
                    if (!pixel_saturated) pixel_count <= pixel_increment;
                    if (s_eol && !line_saturated) line_count <= line_increment;
                    if (next_r[SUM_WIDTH] || next_g[SUM_WIDTH] || next_b[SUM_WIDTH] ||
                        pixel_saturated || (s_eol && line_saturated))
                        overflow <= 1;
                end else protocol_error <= 1;
            end
        end
    end
endmodule

// Exact modulo-2^WIDTH addition. Retained nibble prefix boundaries keep
// no-ALU synthesis from rebuilding one long carry chain. No added latency.
module img_awb_add_prefix #(parameter integer WIDTH=49)(
    input wire [WIDTH-1:0] a,b,
    output wire [WIDTH-1:0] result
);
    localparam integer GROUPS=(WIDTH+3)/4;
    localparam integer PAD_WIDTH=GROUPS*4;
    localparam integer LEVELS=(GROUPS<=1)?0:$clog2(GROUPS);
    wire [PAD_WIDTH-1:0] a_pad=a,b_pad=b;
    wire [PAD_WIDTH-1:0] padded_result;
    (* keep=1 *) wire [GROUPS-1:0] group_p[0:LEVELS];
    (* keep=1 *) wire [GROUPS-1:0] group_g[0:LEVELS];
    wire [GROUPS:0] carry;
    assign carry[0]=1'b0;
    assign result=padded_result[WIDTH-1:0];
    genvar nibble,level;
    generate for(nibble=0;nibble<GROUPS;nibble=nibble+1) begin: leaf
        wire [3:0] av=a_pad[4*nibble+:4],bv=b_pad[4*nibble+:4];
        wire [4:0] local_sum={1'b0,av}+{1'b0,bv};
        assign group_p[0][nibble]=&(av^bv);
        assign group_g[0][nibble]=local_sum[4];
        assign carry[nibble+1]=group_g[LEVELS][nibble];
        assign padded_result[4*nibble+:4]=av+bv+carry[nibble];
    end
    for(level=0;level<LEVELS;level=level+1) begin: prefix_level
        for(nibble=0;nibble<GROUPS;nibble=nibble+1) begin: prefix_node
            if(nibble >= (1<<level)) begin: combine
                assign group_g[level+1][nibble]=group_g[level][nibble] |
                    (group_p[level][nibble] & group_g[level][nibble-(1<<level)]);
                assign group_p[level+1][nibble]=group_p[level][nibble] &
                    group_p[level][nibble-(1<<level)];
            end else begin: pass
                assign group_g[level+1][nibble]=group_g[level][nibble];
                assign group_p[level+1][nibble]=group_p[level][nibble];
            end
        end
    end endgenerate
endmodule
