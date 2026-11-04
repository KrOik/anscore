// SPDX-License-Identifier: Apache-2.0
// Original bounded max-tree: counting sort, serial union/find and area accumulation.
`timescale 1ns/1ps
module grayscale_max_tree #(
    parameter WIDTH=8,HEIGHT=8,PIXEL_W=8,CONNECTIVITY=4,TAG_W=8,
    localparam N=WIDTH*HEIGHT,
    localparam IW=(N<2)?1:$clog2(N),CW=(N<2)?1:$clog2(N+1),
    localparam XW=(WIDTH<2)?1:$clog2(WIDTH)
)(
    input wire clk,rst,input wire s_valid,output wire s_ready,
    input wire [PIXEL_W-1:0] s_pixel,input wire s_sof,s_eol,
    input wire [TAG_W-1:0] s_tag,
    output wire m_valid,input wire m_ready,output wire [IW-1:0] m_index,
    output reg [IW-1:0] m_parent,output reg [PIXEL_W-1:0] m_level,
    output reg m_canonical,output reg [CW-1:0] m_area,
    output wire m_sof,m_eol,m_last,output wire [1:0] m_errors,
    output wire [TAG_W-1:0] m_tag
);
    generate if(WIDTH<1 || WIDTH>16 || HEIGHT<1 || HEIGHT>16 || PIXEL_W<1 || PIXEL_W>8 ||
                (CONNECTIVITY!=4 && CONNECTIVITY!=8) || TAG_W<1 || TAG_W>32)begin:bad
        grayscale_max_tree_invalid_parameter__see_README invalid();
    end endgenerate
    localparam DEPTH=(N<1 || N>256)?1:N,G=(PIXEL_W<1 || PIXEL_W>8)?2:(1<<PIXEL_W);
    localparam CAPTURE=0,CHECK=1,CLEAR=2,HIST_READ=3,HIST_BIN=4,HIST_WRITE=5,
        PREFIX_READ=6,PREFIX_WRITE=7,SORT_READ=8,SORT_BIN=9,SORT_WRITE=10,
        ORDER_READ=11,CUR_READ=12,ACTIVATE=13,COORD=14,NEIGHBOR=15,N_READ=16,N_EVAL=17,
        Z_READ=18,Z_EVAL=19,Z_GRAND=20,Z_HALVE=21,LINK=22,N_ADV=23,
        C_READ=24,C_PARENT=25,C_GRAND=26,C_LEVEL=27,C_EVAL=28,
        A_READ=29,A_PARENT=30,A_LOAD=31,A_WRITE=32,O_READ=33,O_LEVEL=34,O_LATCH=35,HOLD=36;
    reg [5:0] state;
    reg [IW-1:0] capture_index,scan_index,order_position,current,coord_remainder,
        neighbor_address,root_address,canonical_index,output_index;
    reg [XW-1:0] capture_x,current_x,output_x;
    reg [PIXEL_W-1:0] bin_index,parent_level,own_level;
    reg [3:0] neighbor_number;
    reg [CW-1:0] prefix_total,child_area,own_area;
    reg [1:0] errors;
    reg [TAG_W-1:0] tag;
    reg [PIXEL_W:0] image_memory[0:DEPTH-1],image_q;
    reg [IW-1:0] order_memory[0:DEPTH-1],z_memory[0:DEPTH-1],parent_memory[0:DEPTH-1];
    reg [CW-1:0] area_memory[0:DEPTH-1],hist_memory[0:G-1];
    reg [IW-1:0] order_q,z_q,zgrand_q,parent_q,grand_q;
    reg [CW-1:0] hist_q,area_q;
    reg neighbor_inside;
    reg [IW-1:0] neighbor_next;
    wire [1:0] marker_errors={s_eol!=(capture_x==WIDTH-1),s_sof!=(capture_index==0)};
    wire canonical_output=(output_index==parent_q || own_level!=image_q[PIXEL_W-1:0]);
    assign s_ready=!rst && state==CAPTURE;
    assign m_valid=!rst && state==HOLD;
    assign m_index=output_index;
    assign m_sof=m_valid && output_index==0;
    assign m_eol=m_valid && output_x==WIDTH-1;
    assign m_last=m_valid && output_index==N-1;
    assign m_errors=errors;
    assign m_tag=tag;
    always @* begin
        neighbor_inside=0;neighbor_next=current;
        case(neighbor_number)
            0:begin neighbor_inside=current_x!=0;neighbor_next=current-1'b1;end
            1:begin neighbor_inside=current_x!=WIDTH-1;neighbor_next=current+1'b1;end
            2:begin neighbor_inside=current>=WIDTH;neighbor_next=current-WIDTH;end
            3:begin neighbor_inside={1'b0,current}+WIDTH<N;neighbor_next=current+WIDTH;end
            4:begin neighbor_inside=current>=WIDTH && current_x!=0;neighbor_next=current-WIDTH-1'b1;end
            5:begin neighbor_inside=current>=WIDTH && current_x!=WIDTH-1;neighbor_next=current-WIDTH+1'b1;end
            6:begin neighbor_inside={1'b0,current}+WIDTH<N && current_x!=0;neighbor_next=current+WIDTH-1'b1;end
            7:begin neighbor_inside={1'b0,current}+WIDTH<N && current_x!=WIDTH-1;neighbor_next=current+WIDTH+1'b1;end
        endcase
    end
    // Each bank is single-port, clocked-read, unreset. Reads and writes are separate phases.
    always @(posedge clk)if(!rst)begin
        case(state)
            CAPTURE:if(s_valid)image_memory[capture_index]<={1'b0,s_pixel};
            CLEAR:hist_memory[bin_index]<=0;
            HIST_READ,SORT_READ:image_q<=image_memory[scan_index];
            HIST_BIN,SORT_BIN:hist_q<=hist_memory[image_q[PIXEL_W-1:0]];
            HIST_WRITE:hist_memory[image_q[PIXEL_W-1:0]]<=hist_q+1'b1;
            PREFIX_READ:hist_q<=hist_memory[bin_index];
            PREFIX_WRITE:hist_memory[bin_index]<=prefix_total+hist_q;
            SORT_WRITE:begin
                order_memory[hist_q-1'b1]<=scan_index;
                hist_memory[image_q[PIXEL_W-1:0]]<=hist_q-1'b1;
            end
            ORDER_READ,C_READ,A_READ:order_q<=order_memory[order_position];
            CUR_READ:image_q<=image_memory[order_q];
            ACTIVATE:begin
                image_memory[order_q]<={1'b1,image_q[PIXEL_W-1:0]};
                z_memory[order_q]<=order_q;parent_memory[order_q]<=order_q;area_memory[order_q]<=1;
            end
            N_READ:image_q<=image_memory[neighbor_address];
            Z_READ:z_q<=z_memory[root_address];
            Z_GRAND:zgrand_q<=z_memory[z_q];
            Z_HALVE:z_memory[root_address]<=zgrand_q;
            LINK:begin z_memory[root_address]<=current;parent_memory[root_address]<=current;end
            C_PARENT:parent_q<=parent_memory[order_q];
            C_GRAND:begin grand_q<=parent_memory[parent_q];image_q<=image_memory[parent_q];end
            C_LEVEL:image_q<=image_memory[grand_q];
            C_EVAL:if(parent_level==image_q[PIXEL_W-1:0])parent_memory[canonical_index]<=grand_q;
            A_PARENT:begin parent_q<=parent_memory[order_q];area_q<=area_memory[order_q];end
            A_LOAD:area_q<=area_memory[parent_q];
            A_WRITE:if(parent_q!=canonical_index)area_memory[parent_q]<=area_q+child_area;
            O_READ:begin
                parent_q<=parent_memory[output_index];image_q<=image_memory[output_index];area_q<=area_memory[output_index];
            end
            O_LEVEL:image_q<=image_memory[parent_q];
        endcase
    end
    always @(posedge clk)begin
        if(rst)begin
            state<=CAPTURE;capture_index<=0;capture_x<=0;scan_index<=0;bin_index<=0;
            order_position<=0;current<=0;current_x<=0;coord_remainder<=0;neighbor_number<=0;
            neighbor_address<=0;root_address<=0;canonical_index<=0;output_index<=0;output_x<=0;
            prefix_total<=0;parent_level<=0;own_level<=0;child_area<=0;own_area<=0;
            errors<=0;tag<=0;m_parent<=0;m_level<=0;m_canonical<=0;m_area<=0;
        end else case(state)
            CAPTURE:if(s_valid)begin
                if(capture_index==0)begin tag<=s_tag;errors<=marker_errors;end else errors<=errors|marker_errors;
                if(capture_index==N-1)state<=CHECK;
                else begin capture_index<=capture_index+1'b1;if(capture_x==WIDTH-1)capture_x<=0;else capture_x<=capture_x+1'b1;end
            end
            CHECK:begin
                if(errors!=0)begin
                    output_index<=0;output_x<=0;m_parent<=0;m_level<=0;m_canonical<=0;m_area<=0;state<=HOLD;
                end else begin bin_index<=0;state<=CLEAR;end
            end
            CLEAR:if(bin_index==G-1)begin scan_index<=0;state<=HIST_READ;end else bin_index<=bin_index+1'b1;
            HIST_READ:state<=HIST_BIN;
            HIST_BIN:state<=HIST_WRITE;
            HIST_WRITE:if(scan_index==N-1)begin bin_index<=0;prefix_total<=0;state<=PREFIX_READ;end
                else begin scan_index<=scan_index+1'b1;state<=HIST_READ;end
            PREFIX_READ:state<=PREFIX_WRITE;
            PREFIX_WRITE:begin
                prefix_total<=prefix_total+hist_q;
                if(bin_index==G-1)begin scan_index<=N-1;state<=SORT_READ;end
                else begin bin_index<=bin_index+1'b1;state<=PREFIX_READ;end
            end
            SORT_READ:state<=SORT_BIN;
            SORT_BIN:state<=SORT_WRITE;
            SORT_WRITE:if(scan_index==0)begin order_position<=N-1;state<=ORDER_READ;end
                else begin scan_index<=scan_index-1'b1;state<=SORT_READ;end
            ORDER_READ:state<=CUR_READ;
            CUR_READ:state<=ACTIVATE;
            ACTIVATE:begin current<=order_q;coord_remainder<=order_q;neighbor_number<=0;state<=COORD;end
            COORD:if(coord_remainder>=WIDTH)coord_remainder<=coord_remainder-WIDTH;
                else begin current_x<=coord_remainder;state<=NEIGHBOR;end
            NEIGHBOR:if(neighbor_inside)begin neighbor_address<=neighbor_next;state<=N_READ;end else state<=N_ADV;
            N_READ:state<=N_EVAL;
            N_EVAL:if(image_q[PIXEL_W])begin root_address<=neighbor_address;state<=Z_READ;end else state<=N_ADV;
            Z_READ:state<=Z_EVAL;
            Z_EVAL:if(z_q==root_address)begin if(root_address!=current)state<=LINK;else state<=N_ADV;end else state<=Z_GRAND;
            Z_GRAND:state<=Z_HALVE;
            Z_HALVE:begin
                root_address<=zgrand_q;
                if(zgrand_q==z_q)begin if(zgrand_q!=current)state<=LINK;else state<=N_ADV;end else state<=Z_READ;
            end
            LINK:state<=N_ADV;
            N_ADV:if(neighbor_number==CONNECTIVITY-1)begin
                if(order_position==0)begin order_position<=0;state<=C_READ;end
                else begin order_position<=order_position-1'b1;state<=ORDER_READ;end
            end else begin neighbor_number<=neighbor_number+1'b1;state<=NEIGHBOR;end
            C_READ:state<=C_PARENT;
            C_PARENT:begin canonical_index<=order_q;state<=C_GRAND;end
            C_GRAND:state<=C_LEVEL;
            C_LEVEL:begin parent_level<=image_q[PIXEL_W-1:0];state<=C_EVAL;end
            C_EVAL:if(order_position==N-1)begin order_position<=N-1;state<=A_READ;end
                else begin order_position<=order_position+1'b1;state<=C_READ;end
            A_READ:state<=A_PARENT;
            A_PARENT:begin canonical_index<=order_q;state<=A_LOAD;end
            A_LOAD:begin child_area<=area_q;state<=A_WRITE;end
            A_WRITE:if(order_position==0)begin output_index<=0;output_x<=0;state<=O_READ;end
                else begin order_position<=order_position-1'b1;state<=A_READ;end
            O_READ:state<=O_LEVEL;
            O_LEVEL:begin own_level<=image_q[PIXEL_W-1:0];own_area<=area_q;state<=O_LATCH;end
            O_LATCH:begin
                m_parent<=parent_q;m_level<=own_level;m_canonical<=canonical_output;
                m_area<=canonical_output ? own_area : {CW{1'b0}};state<=HOLD;
            end
            HOLD:if(m_ready)begin
                if(output_index==N-1)begin capture_index<=0;capture_x<=0;state<=CAPTURE;end
                else begin
                    output_index<=output_index+1'b1;
                    if(output_x==WIDTH-1)output_x<=0;else output_x<=output_x+1'b1;
                    if(errors==0)state<=O_READ;
                end
            end
            default:begin state<=CAPTURE;capture_index<=0;capture_x<=0;end
        endcase
    end
endmodule
