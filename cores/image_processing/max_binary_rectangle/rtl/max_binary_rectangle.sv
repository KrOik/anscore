`timescale 1ns/1ps
// SPDX-License-Identifier: Apache-2.0
// Exact maximum-area all-foreground axis-aligned rectangle, O(WIDTH) storage.
module max_binary_rectangle #(
    parameter integer WIDTH=64,
    parameter integer HEIGHT=64,
    parameter integer TAG_W=8,
    localparam integer XW=(WIDTH>1)?$clog2(WIDTH):1,
    localparam integer YW=(HEIGHT>1)?$clog2(HEIGHT):1,
    localparam integer HCW=(HEIGHT>1)?$clog2(HEIGHT+1):1,
    localparam integer XCW=(WIDTH>1)?$clog2(WIDTH+1):1,
    localparam integer AW=(WIDTH*HEIGHT>1)?$clog2(WIDTH*HEIGHT+1):1,
    localparam integer STACK_W=HCW+XW
)(
    input wire clk,rst,
    input wire s_valid,output wire s_ready,
    input wire s_pixel,s_sof,s_eol,
    input wire [TAG_W-1:0] s_tag,
    output wire m_valid,input wire m_ready,
    output reg [AW-1:0] m_area,
    output reg [XW-1:0] m_xmin,m_xmax,
    output reg [YW-1:0] m_ymin,m_ymax,
    output wire m_empty,
    output reg m_error,
    output reg [TAG_W-1:0] m_tag
);
    localparam [2:0] INPUT_PIXEL=0,HEIGHT_UPDATE=1,PROCESS=2,
        RESTORE_TOP=3,ADVANCE=4,EMIT=5;
    reg [2:0] state;
    reg [XW-1:0] x;
    reg [YW-1:0] y;
    reg pixel;
    reg [HCW-1:0] heights[0:WIDTH-1];
    reg [HCW-1:0] height_q;
    reg [STACK_W-1:0] stack[0:WIDTH-1];
    reg [STACK_W-1:0] stack_q;
    reg [XCW-1:0] depth,scan_x;
    reg [HCW-1:0] current_height,top_height;
    reg [XW-1:0] current_start,top_start;
    wire [HCW-1:0] next_height=pixel ? ((y==0)?{{(HCW-1){1'b0}},1'b1}:height_q+1'b1) : {HCW{1'b0}};
    wire [XCW-1:0] candidate_width=scan_x-top_start;
    wire [HCW+XCW-1:0] candidate_area=top_height*candidate_width;
    wire [YW-1:0] candidate_ymin=y-top_height+1'b1;
    wire [XW-1:0] candidate_xmax=scan_x-1'b1;
    // Equal areas select lexicographically smallest (ymin,xmin,ymax,xmax).
    wire better=(candidate_area>m_area) ||
        ((candidate_area==m_area) &&
         ({candidate_ymin,top_start,y,candidate_xmax} <
          {m_ymin,m_xmin,m_ymax,m_xmax}));
    assign s_ready=!rst && state==INPUT_PIXEL;
    assign m_valid=!rst && state==EMIT;
    assign m_empty=(m_area==0);
`ifndef SYNTHESIS
    initial if(WIDTH<1 || WIDTH>1024 || HEIGHT<1 || HEIGHT>1024 ||
               TAG_W<1 || TAG_W>32)
        $fatal(1,"invalid max_binary_rectangle parameters");
`endif

    always @(posedge clk) begin
        if(rst) begin
            state<=INPUT_PIXEL; x<=0; y<=0; depth<=0; top_height<=0;
            m_area<=0; m_xmin<=0; m_xmax<=0; m_ymin<=0; m_ymax<=0;
            m_error<=0; m_tag<=0;
        end else case(state)
            INPUT_PIXEL: if(s_valid) begin
                height_q<=heights[x]; pixel<=s_pixel;
                if(x==0 && y==0) m_tag<=s_tag;
                if(s_sof!=(x==0 && y==0) || s_eol!=(x==WIDTH-1)) m_error<=1;
                state<=HEIGHT_UPDATE;
            end
            HEIGHT_UPDATE: begin
                // First row overwrites every consumed height; RAM need not reset.
                heights[x]<=next_height;
                current_height<=next_height; current_start<=x; scan_x<=x;
                state<=PROCESS;
            end
            PROCESS: begin
                if(depth!=0 && top_height>current_height) begin
                    if(better) begin
                        m_area<=candidate_area;
                        m_xmin<=top_start; m_xmax<=candidate_xmax;
                        m_ymin<=candidate_ymin; m_ymax<=y;
                    end
                    current_start<=top_start;
                    depth<=depth-1'b1;
                    if(depth>1) begin
                        stack_q<=stack[depth-2]; state<=RESTORE_TOP;
                    end else top_height<=0;
                end else begin
                    if(current_height!=0 && (depth==0 || top_height<current_height)) begin
                        if(depth!=0) stack[depth-1'b1]<={top_height,top_start};
                        top_height<=current_height; top_start<=current_start;
                        depth<=depth+1'b1;
                    end
                    state<=ADVANCE;
                end
            end
            RESTORE_TOP: begin
                {top_height,top_start}<=stack_q; state<=PROCESS;
            end
            ADVANCE: begin
                if(scan_x==WIDTH) begin
                    // The zero sentinel emptied the positive-height stack.
                    if(y==HEIGHT-1) state<=EMIT;
                    else begin x<=0; y<=y+1'b1; state<=INPUT_PIXEL; end
                end else if(x==WIDTH-1) begin
                    scan_x<=WIDTH; current_height<=0; current_start<=0;
                    state<=PROCESS;
                end else begin x<=x+1'b1; state<=INPUT_PIXEL; end
            end
            EMIT: if(m_ready) begin
                state<=INPUT_PIXEL; x<=0; y<=0; depth<=0; top_height<=0;
                m_area<=0; m_xmin<=0; m_xmax<=0; m_ymin<=0; m_ymax<=0;
                m_error<=0;
            end
        endcase
    end
endmodule
