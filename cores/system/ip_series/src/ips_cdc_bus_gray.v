`timescale 1ns / 1ps
// ips_cdc_bus_gray : binary-to-Gray pointer crossing with atomicity checking.
//
// The source domain (src_tick stream) advances a binary pointer by src_step and
// registers its Gray code, so a single-bit change is the only thing the
// destination can ever see for one pointer step.  The destination domain
// (dst_tick stream) synchronises the Gray word through two flops and decodes it
// back to binary.  Whenever the word that lands in the second flop differs from
// the previous one in more than a single bit, the crossing was not atomic: the
// event latches err_sticky and increments err_count.  sync_count counts changed
// observations and hold_count the consecutive unchanged ones.  Every register is
// gated by clk_en and rst_n is the active-low asynchronous reset
// (docs/IP_CORE_SOP.md traps T2 and T13).
module ips_cdc_bus_gray #(
    parameter PTR_W = 4
)(
    input  wire             clk,
    input  wire             clk_en,
    input  wire             rst_n,

    input  wire             src_tick,
    input  wire             dst_tick,
    input  wire [PTR_W-1:0] src_step,

    output reg  [PTR_W-1:0] bin_ptr,
    output reg  [PTR_W-1:0] gray_q,
    output reg  [PTR_W-1:0] sync1,
    output reg  [PTR_W-1:0] sync2,
    output wire [PTR_W-1:0] bin_dec,
    output reg              err_sticky,
    output reg  [3:0]       err_count,
    output reg  [3:0]       sync_count,
    output reg  [3:0]       hold_count
);

wire [PTR_W-1:0] bin_next = bin_ptr + src_step;
wire [PTR_W-1:0] delta    = sync2 ^ sync1;
wire [PTR_W-1:0] dl       = delta & (delta - 1);
wire             multi_hit = (dl != 0);
wire             any_hit   = (delta != 0);

function [PTR_W-1:0] bin2gray;
    input [PTR_W-1:0] b;
    begin
        bin2gray = b ^ (b >> 1);
    end
endfunction

function [PTR_W-1:0] gray2bin;
    input  [PTR_W-1:0] g;
    integer k;
    begin
        gray2bin = g;
        for (k = PTR_W - 2; k >= 0; k = k - 1) begin
            gray2bin[k] = gray2bin[k + 1] ^ g[k];
        end
    end
endfunction

assign bin_dec = gray2bin(sync2);

always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        bin_ptr <= {PTR_W{1'b0}};
        gray_q  <= {PTR_W{1'b0}};
    end else if (clk_en && src_tick) begin
        bin_ptr <= bin_next;
        gray_q  <= bin2gray(bin_next);
    end
end

always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        sync1      <= {PTR_W{1'b0}};
        sync2      <= {PTR_W{1'b0}};
        err_sticky <= 1'b0;
        err_count  <= 4'h0;
        sync_count <= 4'h0;
        hold_count <= 4'h0;
    end else if (clk_en && dst_tick) begin
        sync1 <= gray_q;
        sync2 <= sync1;
        if (multi_hit) begin
            err_sticky <= 1;
            err_count  <= err_count + 1;
        end
        if (any_hit) begin
            sync_count <= sync_count + 1;
            hold_count <= 0;
        end else begin
            hold_count <= hold_count + 1;
        end
    end
end

endmodule
