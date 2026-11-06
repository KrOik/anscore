// SPDX-License-Identifier: Apache-2.0
// Original coordinate-fragment RMW store. All streams are ordinary ready/valid.
module fragment_rgb_depth_store #(
    parameter integer WIDTH=64,HEIGHT=64,TAG_W=8
)(
    input wire clk,rst,
    input wire begin_valid,output wire begin_ready,
    input wire [23:0] begin_rgb,input wire [15:0] begin_depth,
    input wire [TAG_W-1:0] begin_tag,
    input wire s_valid,output wire s_ready,
    input wire [15:0] s_x,s_y,s_depth,input wire [23:0] s_rgb,
    input wire [7:0] s_alpha,input wire [1:0] s_depth_func,
    input wire s_depth_write,input wire [2:0] s_color_write,
    input wire end_valid,output wire end_ready,
    output wire m_valid,input wire m_ready,
    output wire [23:0] m_rgb,output wire [15:0] m_depth,
    output wire [7:0] m_x,m_y,output wire m_sof,m_eol,m_last,
    output wire [TAG_W-1:0] m_tag,
    output wire done_valid,input wire done_ready,
    output wire [TAG_W-1:0] done_tag,
    output reg [31:0] done_seen,done_passed,done_oob,
    output reg done_count_overflow
);
    localparam integer N=WIDTH*HEIGHT,AW=(N>1)?$clog2(N):1;
    localparam [3:0] IDLE=0,CLEAR=1,DRAW=2,FREAD=3,FTEST=4,FWRITE=5,SREAD=6,SEND=7,DONE=8;
    reg [3:0] state;
    reg [39:0] frame_ram [0:N-1];
    reg [39:0] clear_word,old_word,new_word,scan_word;
    reg [AW-1:0] address,clear_address,scan_address;
    reg [7:0] scan_x,scan_y;
    reg [TAG_W-1:0] tag;
    reg [23:0] rgb;
    reg [15:0] depth;
    reg [7:0] alpha;
    reg [1:0] depth_func;
    reg depth_write;
    reg [2:0] color_write;
    wire depth_pass=(depth_func==0)||((depth_func==1)&&(depth<old_word[39:24]))||
                    ((depth_func==2)&&(depth<=old_word[39:24]));
    // Exact nearest straight-alpha blend. Valid t<=65152; this range admits
    // floor(t/255) = (t+1+(t>>8))>>8, avoiding a general divider.
    function automatic [7:0] blend;
        input [7:0] src,dst,a;
        reg signed [8:0] delta;
        reg signed [17:0] product,numerator;
        reg [15:0] t;
        reg [16:0] folded;
        begin
            delta=$signed({1'b0,src})-$signed({1'b0,dst});
            product=delta*$signed({1'b0,a});
            numerator=$signed({2'b0,dst,8'b0})-$signed({10'b0,dst})+product+18'sd127;
            t=numerator[15:0];folded={1'b0,t}+{9'b0,t[15:8]}+17'd1;
            blend=folded[15:8];
        end
    endfunction
    assign begin_ready=!rst&&state==IDLE;
    assign end_ready=!rst&&state==DRAW;
    assign s_ready=!rst&&state==DRAW&&!end_valid;
    assign m_valid=state==SEND;
    assign m_rgb=scan_word[23:0];assign m_depth=scan_word[39:24];
    assign m_x=scan_x;assign m_y=scan_y;
    assign m_sof=scan_address==0;assign m_eol=scan_x==WIDTH-1;assign m_last=scan_address==N-1;
    assign m_tag=tag;assign done_tag=tag;assign done_valid=state==DONE;
    always @(posedge clk) begin
        if(rst) begin
            state<=IDLE;clear_word<=0;old_word<=0;new_word<=0;scan_word<=0;
            address<=0;clear_address<=0;scan_address<=0;scan_x<=0;scan_y<=0;tag<=0;
            rgb<=0;depth<=0;alpha<=0;depth_func<=0;depth_write<=0;color_write<=0;
            done_seen<=0;done_passed<=0;done_oob<=0;done_count_overflow<=0;
        end else case(state)
            IDLE:if(begin_valid) begin
                clear_word<={begin_depth,begin_rgb};tag<=begin_tag;clear_address<=0;
                done_seen<=0;done_passed<=0;done_oob<=0;done_count_overflow<=0;state<=CLEAR;
            end
            CLEAR:begin
                frame_ram[clear_address]<=clear_word;
                if(clear_address==N-1) state<=DRAW;
                else clear_address<=clear_address+1'b1;
            end
            DRAW:if(end_valid) begin scan_address<=0;scan_x<=0;scan_y<=0;state<=SREAD;end
                 else if(s_valid) begin
                     if(&done_seen) done_count_overflow<=1;else done_seen<=done_seen+1'b1;
                     if(s_x>=WIDTH||s_y>=HEIGHT) begin
                         if(&done_oob) done_count_overflow<=1;else done_oob<=done_oob+1'b1;
                     end else begin
                         address<=AW'(s_y*WIDTH+s_x);rgb<=s_rgb;depth<=s_depth;
                         alpha<=s_alpha;depth_func<=s_depth_func;depth_write<=s_depth_write;
                         color_write<=s_color_write;state<=FREAD;
                     end
                 end
            FREAD:begin old_word<=frame_ram[address];state<=FTEST;end
            FTEST:if(depth_pass) begin
                if(&done_passed) done_count_overflow<=1;else done_passed<=done_passed+1'b1;
                new_word[39:24]<=depth_write?depth:old_word[39:24];
                new_word[23:16]<=color_write[2]?blend(rgb[23:16],old_word[23:16],alpha):old_word[23:16];
                new_word[15:8]<=color_write[1]?blend(rgb[15:8],old_word[15:8],alpha):old_word[15:8];
                new_word[7:0]<=color_write[0]?blend(rgb[7:0],old_word[7:0],alpha):old_word[7:0];
                state<=FWRITE;
            end else state<=DRAW;
            FWRITE:begin frame_ram[address]<=new_word;state<=DRAW;end
            SREAD:begin scan_word<=frame_ram[scan_address];state<=SEND;end
            SEND:if(m_ready) begin
                if(scan_address==N-1) state<=DONE;
                else begin
                    scan_address<=scan_address+1'b1;
                    if(scan_x==WIDTH-1) begin scan_x<=0;scan_y<=scan_y+1'b1;end
                    else scan_x<=scan_x+1'b1;
                    state<=SREAD;
                end
            end
            DONE:if(done_ready) state<=IDLE;
            default:state<=IDLE;
        endcase
    end
    generate if(WIDTH<1||WIDTH>128||HEIGHT<1||HEIGHT>128||TAG_W<1||TAG_W>32) begin: invalid
        fragment_rgb_depth_store_invalid_parameters invalid_parameters();
    end endgenerate
endmodule
