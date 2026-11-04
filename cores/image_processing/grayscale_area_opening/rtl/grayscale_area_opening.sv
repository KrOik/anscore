// SPDX-License-Identifier: Apache-2.0
`timescale 1ns/1ps
module grayscale_area_opening #(
    parameter integer WIDTH=32,HEIGHT=32,PIXEL_W=8,TAG_W=8,
    localparam integer N=WIDTH*HEIGHT,
    localparam integer COUNT_W=(N<2)?1:$clog2(N+1)
)(
    input wire clk,rst,s_valid,
    output wire s_ready,
    input wire [PIXEL_W-1:0] s_pixel,
    input wire s_sof,s_eol,
    input wire [COUNT_W-1:0] s_area,
    input wire [TAG_W-1:0] s_tag,
    output wire m_valid,
    input wire m_ready,
    output wire [PIXEL_W-1:0] m_pixel,
    output wire m_sof,m_eol,m_last,
    output wire [TAG_W-1:0] m_tag,
    output wire [2:0] m_errors
);
    localparam integer DEPTH=(N<1 || N>4096)?1:N;
    localparam integer IW=(DEPTH<2)?1:$clog2(DEPTH);
    localparam integer XW=(WIDTH<2)?1:$clog2(WIDTH);
    localparam integer LEVELS=1<<PIXEL_W;
    localparam [3:0] COLLECT=0,FRAME_END=1,CHOOSE=2,CLEAR=3,
        SCAN_READ=4,SCAN_CHECK=5,SCAN_ADV=6,Q_READ=7,Q_SET=8,
        NEIGH_READ=9,NEIGH_CHECK=10,Q_ADV=11,WRITE_READ=12,
        WRITE_PIXEL=13,OUT_READ=14,OUT_HOLD=15;
    reg [3:0] state;
    reg [IW-1:0] capture_index,scan_index,clear_index,out_index,current;
    reg [XW-1:0] capture_x,scan_x,out_x,current_x;
    reg [COUNT_W-1:0] area_q,head,tail,write_index;
    reg [TAG_W-1:0] tag_q;
    reg [2:0] errors;
    reg [1:0] neighbor;
    reg [PIXEL_W:0] level;
    reg [PIXEL_W-1:0] maximum;
    reg [LEVELS-1:0] occupied;
    reg [PIXEL_W-1:0] source_mem[0:DEPTH-1],output_mem[0:DEPTH-1];
    reg visited_mem[0:DEPTH-1];
    reg [IW+XW-1:0] queue_mem[0:DEPTH-1];
    reg [PIXEL_W-1:0] source_q,output_q;
    reg visited_q;
    reg [IW+XW-1:0] queue_q;
    wire [IW-1:0] queued_address=queue_q[IW-1:0];
    wire [XW-1:0] queued_x=queue_q[IW+XW-1:IW];
    reg neighbor_valid;
    reg [IW-1:0] neighbor_address;
    reg [XW-1:0] neighbor_x;
    wire [2:0] marker_errors={1'b0,s_eol!=(capture_x==WIDTH-1),s_sof!=(capture_index==0)};
    wire bad_area=(s_area==0 || s_area>N);
    assign s_ready=!rst && state==COLLECT;
    assign m_valid=!rst && state==OUT_HOLD;
    assign m_pixel=output_q;
    assign m_sof=out_index==0;
    assign m_eol=out_x==WIDTH-1;
    assign m_last=out_index==N-1;
    assign m_tag=tag_q;
    assign m_errors=errors;
    always @* begin
        neighbor_valid=0;neighbor_address=current;neighbor_x=current_x;
        case(neighbor)
            0:begin neighbor_valid=current_x!=0;neighbor_address=current-1'b1;neighbor_x=current_x-1'b1;end
            1:begin neighbor_valid=current_x!=WIDTH-1;neighbor_address=current+1'b1;neighbor_x=current_x+1'b1;end
            2:begin neighbor_valid=current>=WIDTH;neighbor_address=current-IW'(WIDTH);end
            3:begin neighbor_valid=current<N-WIDTH;neighbor_address=current+IW'(WIDTH);end
        endcase
    end
    // Every memory read is synchronous. Schedule phases exclude all same-bank
    // read/write collisions; a queue/visited entry is committed before use.
    always @(posedge clk) if(!rst) begin
        if(state==COLLECT && s_valid) begin
            source_mem[capture_index]<=s_pixel;
            output_mem[capture_index]<=0;
        end
        if(state==CLEAR) visited_mem[clear_index]<=0;
        if(state==SCAN_READ) begin
            source_q<=source_mem[scan_index];visited_q<=visited_mem[scan_index];
        end
        if(state==SCAN_CHECK && !visited_q && source_q>=level) begin
            visited_mem[scan_index]<=1;
            queue_mem[0]<={scan_x,scan_index};
        end
        if(state==NEIGH_READ && neighbor_valid) begin
            source_q<=source_mem[neighbor_address];visited_q<=visited_mem[neighbor_address];
        end
        if(state==NEIGH_CHECK && !visited_q && source_q>=level) begin
            visited_mem[neighbor_address]<=1;
            queue_mem[IW'(tail)]<={neighbor_x,neighbor_address};
        end
        if(state==Q_READ) queue_q<=queue_mem[IW'(head)];
        if(state==WRITE_READ) queue_q<=queue_mem[IW'(write_index)];
        if(state==WRITE_PIXEL) output_mem[queued_address]<=level[PIXEL_W-1:0];
        if(state==OUT_READ) output_q<=output_mem[out_index];
    end
    always @(posedge clk) begin
        if(rst) begin
            state<=COLLECT;capture_index<=0;capture_x<=0;scan_index<=0;scan_x<=0;
            clear_index<=0;out_index<=0;out_x<=0;current<=0;current_x<=0;
            area_q<=0;head<=0;tail<=0;write_index<=0;tag_q<=0;errors<=0;
            neighbor<=0;level<=1;maximum<=0;occupied<=0;
        end else case(state)
            COLLECT:if(s_valid && s_ready)begin
                if(capture_index==0)begin
                    area_q<=s_area;tag_q<=s_tag;errors<=marker_errors|{bad_area,2'b00};
                    occupied<=( {{(LEVELS-1){1'b0}},1'b1} << s_pixel );maximum<=s_pixel;
                end else begin
                    errors<=errors|marker_errors;occupied[s_pixel]<=1'b1;
                    if(s_pixel>maximum)maximum<=s_pixel;
                end
                if(capture_index==N-1)begin state<=FRAME_END;out_index<=0;out_x<=0;end
                else begin
                    capture_index<=capture_index+1'b1;
                    capture_x<=(capture_x==WIDTH-1)?0:capture_x+1'b1;
                end
            end
            FRAME_END:begin level<=1;state<=(errors!=0)?OUT_READ:CHOOSE;end
            CHOOSE:begin
                if(level>{1'b0,maximum})state<=OUT_READ;
                else if(occupied[level[PIXEL_W-1:0]])begin clear_index<=0;state<=CLEAR;end
                else level<=level+1'b1;
            end
            CLEAR:if(clear_index==N-1)begin scan_index<=0;scan_x<=0;state<=SCAN_READ;end
                else clear_index<=clear_index+1'b1;
            SCAN_READ:state<=SCAN_CHECK;
            SCAN_CHECK:if(!visited_q && source_q>=level)begin head<=0;tail<=1;state<=Q_READ;end
                else state<=SCAN_ADV;
            SCAN_ADV:if(scan_index==N-1)begin level<=level+1'b1;state<=CHOOSE;end
                else begin
                    scan_index<=scan_index+1'b1;scan_x<=(scan_x==WIDTH-1)?0:scan_x+1'b1;state<=SCAN_READ;
                end
            Q_READ:state<=Q_SET;
            Q_SET:begin current<=queued_address;current_x<=queued_x;neighbor<=0;state<=NEIGH_READ;end
            NEIGH_READ:if(neighbor_valid)state<=NEIGH_CHECK;
                else if(neighbor==3)state<=Q_ADV;else neighbor<=neighbor+1'b1;
            NEIGH_CHECK:begin
                if(!visited_q && source_q>=level)tail<=tail+1'b1;
                if(neighbor==3)state<=Q_ADV;
                else begin neighbor<=neighbor+1'b1;state<=NEIGH_READ;end
            end
            Q_ADV:if(head+1'b1<tail)begin head<=head+1'b1;state<=Q_READ;end
                else if(tail>=area_q)begin write_index<=0;state<=WRITE_READ;end
                else state<=SCAN_ADV;
            WRITE_READ:state<=WRITE_PIXEL;
            WRITE_PIXEL:if(write_index+1'b1==tail)state<=SCAN_ADV;
                else begin write_index<=write_index+1'b1;state<=WRITE_READ;end
            OUT_READ:state<=OUT_HOLD;
            OUT_HOLD:if(m_ready)begin
                if(out_index==N-1)begin state<=COLLECT;capture_index<=0;capture_x<=0;end
                else begin out_index<=out_index+1'b1;out_x<=(out_x==WIDTH-1)?0:out_x+1'b1;state<=OUT_READ;end
            end
            default:state<=COLLECT;
        endcase
    end
    generate if(WIDTH<1 || WIDTH>64 || HEIGHT<1 || HEIGHT>64 || PIXEL_W<1 || PIXEL_W>8 ||
                TAG_W<1 || TAG_W>32)begin:invalid_parameters
        grayscale_area_opening_invalid_parameters invalid_configuration();
    end endgenerate
endmodule
