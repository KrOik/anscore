// SPDX-License-Identifier: Apache-2.0
`timescale 1ns/1ps
`default_nettype none
module grayscale_size_zone #(
    parameter integer WIDTH=16,HEIGHT=16,PIXEL_W=8,GRAY_W=2,CONNECTIVITY=8,TAG_W=8,
    localparam integer N=WIDTH*HEIGHT,
    localparam integer COUNT_W=($clog2(N+1)<1)?1:$clog2(N+1)
)(
    input wire clk,rst,
    input wire s_valid,output wire s_ready,
    input wire [PIXEL_W-1:0] s_pixel,
    input wire s_sof,s_eol,
    input wire [TAG_W-1:0] s_tag,
    output wire m_valid,input wire m_ready,
    output wire [GRAY_W-1:0] m_gray,
    output wire [COUNT_W-1:0] m_size,m_count,m_zones,
    output wire m_first,m_last,
    output wire [TAG_W-1:0] m_tag,
    output wire [1:0] m_errors
);
    localparam integer IW=($clog2(N)<1)?1:$clog2(N),
        XW=($clog2(WIDTH)<1)?1:$clog2(WIDTH),CW=COUNT_W,
        HW=GRAY_W+IW,HDEPTH=1<<HW,QW=IW+XW;
    localparam [3:0] CLEAR=0,CAPTURE=1,SCAN_READ=2,SCAN_EVAL=3,
        Q_READ=4,Q_EVAL=5,NEIGHBOR=6,N_READ=7,N_EVAL=8,
        H_READ=9,H_WRITE=10,OUT_READ=11,OUT_HOLD=12;
    reg [3:0] state;
    reg [HW-1:0] clear_index;
    reg [IW-1:0] capture_index,scan_index,current_index,neighbor_index;
    reg [XW-1:0] capture_x,scan_x,current_x,neighbor_x;
    reg [3:0] neighbor;
    reg [CW-1:0] head,tail,zone_size,zones;
    reg [GRAY_W-1:0] zone_gray,out_gray;
    reg [CW-1:0] out_size;
    reg [TAG_W-1:0] tag_q;
    reg [1:0] errors;
    reg [GRAY_W:0] pixels[0:N-1],pixel_q;
    reg [QW-1:0] queue_mem[0:N-1],queue_q;
    reg [CW-1:0] hist_mem[0:HDEPTH-1],hist_q;
    reg neighbor_inside;
    reg [IW-1:0] candidate_index;
    reg [XW-1:0] candidate_x;
    wire [HW-1:0] zone_address={zone_gray,IW'(zone_size-1'b1)};
    wire [HW-1:0] output_address={out_gray,IW'(out_size-1'b1)};
    wire new_neighbor=!pixel_q[GRAY_W] && pixel_q[GRAY_W-1:0]==zone_gray;
    assign s_ready=!rst && state==CAPTURE;
    assign m_valid=!rst && state==OUT_HOLD;
    assign m_gray=out_gray;
    assign m_size=out_size;
    assign m_count=(errors!=0)?{CW{1'b0}}:hist_q;
    assign m_zones=(errors!=0)?{CW{1'b0}}:zones;
    assign m_first=out_gray==0 && out_size==1;
    assign m_last=(&out_gray) && out_size==N;
    assign m_tag=tag_q;
    assign m_errors=errors;

    // Axial neighbors first, then diagonals; bounds precede all RAM reads.
    // current_index carries y implicitly, so no runtime quotient/product exists.
    always @* begin
        neighbor_inside=0;candidate_index=current_index;candidate_x=current_x;
        case(neighbor)
            0:begin neighbor_inside=current_x!=0;candidate_index=current_index-1'b1;candidate_x=current_x-1'b1;end
            1:begin neighbor_inside=current_x!=WIDTH-1;candidate_index=current_index+1'b1;candidate_x=current_x+1'b1;end
            2:begin neighbor_inside=current_index>=WIDTH;candidate_index=current_index-WIDTH;end
            3:begin neighbor_inside=current_index<N-WIDTH;candidate_index=current_index+WIDTH;end
            4:begin neighbor_inside=current_x!=0 && current_index>=WIDTH;candidate_index=current_index-WIDTH-1;candidate_x=current_x-1'b1;end
            5:begin neighbor_inside=current_x!=WIDTH-1 && current_index>=WIDTH;candidate_index=current_index-WIDTH+1;candidate_x=current_x+1'b1;end
            6:begin neighbor_inside=current_x!=0 && current_index<N-WIDTH;candidate_index=current_index+WIDTH-1;candidate_x=current_x-1'b1;end
            7:begin neighbor_inside=current_x!=WIDTH-1 && current_index<N-WIDTH;candidate_index=current_index+WIDTH+1;candidate_x=current_x+1'b1;end
            default:begin end
        endcase
    end

    // Each memory has a synchronous read and one write; reads/writes occur in
    // disjoint phases. Capture initializes every visited bit before traversal.
    always @(posedge clk)if(!rst)begin
        if(state==CAPTURE && s_valid && s_ready)
            pixels[capture_index]<={1'b0,s_pixel[PIXEL_W-1 -:GRAY_W]};
        if(state==SCAN_READ)pixel_q<=pixels[scan_index];
        if(state==N_READ)pixel_q<=pixels[neighbor_index];
        if(state==SCAN_EVAL && !pixel_q[GRAY_W])begin
            pixels[scan_index]<={1'b1,pixel_q[GRAY_W-1:0]};
            queue_mem[0]<={scan_index,scan_x};
        end
        if(state==N_EVAL && new_neighbor)begin
            // Mark and enqueue on the same edge, before another neighbor read.
            pixels[neighbor_index]<={1'b1,zone_gray};
            queue_mem[IW'(tail)]<={neighbor_index,neighbor_x};
        end
        if(state==Q_READ && head<tail)queue_q<=queue_mem[IW'(head)];
        if(state==CLEAR)hist_mem[clear_index]<=0;
        if(state==H_READ)hist_q<=hist_mem[zone_address];
        if(state==H_WRITE)hist_mem[zone_address]<=hist_q+1'b1;
        if(state==OUT_READ)hist_q<=hist_mem[output_address];
    end

    task automatic advance_scan;
        begin
            if(scan_index==N-1)begin out_gray<=0;out_size<=1;state<=OUT_READ;end
            else begin
                scan_index<=scan_index+1'b1;
                scan_x<=(scan_x==WIDTH-1)?{XW{1'b0}}:scan_x+1'b1;
                state<=SCAN_READ;
            end
        end
    endtask
    task automatic advance_neighbor;
        begin
            if(neighbor==CONNECTIVITY-1)state<=Q_READ;
            else begin neighbor<=neighbor+1'b1;state<=NEIGHBOR;end
        end
    endtask
    always @(posedge clk)begin
        if(rst)begin
            state<=CLEAR;clear_index<=0;capture_index<=0;capture_x<=0;
            scan_index<=0;scan_x<=0;current_index<=0;current_x<=0;
            neighbor_index<=0;neighbor_x<=0;neighbor<=0;head<=0;tail<=0;
            zone_size<=0;zones<=0;zone_gray<=0;out_gray<=0;out_size<=1;tag_q<=0;errors<=0;
        end else case(state)
            CLEAR:if(clear_index==HDEPTH-1)begin
                state<=CAPTURE;capture_index<=0;capture_x<=0;zones<=0;errors<=0;
            end else clear_index<=clear_index+1'b1;
            CAPTURE:if(s_valid && s_ready)begin
                if(capture_index==0)tag_q<=s_tag;
                if(s_sof!=(capture_index==0))errors[0]<=1;
                if(s_eol!=(capture_x==WIDTH-1))errors[1]<=1;
                if(capture_index==N-1)begin
                    scan_index<=0;scan_x<=0;out_gray<=0;out_size<=1;
                    if(errors!=0 || s_sof!=(capture_index==0) || s_eol!=(capture_x==WIDTH-1))state<=OUT_READ;
                    else state<=SCAN_READ;
                end else begin
                    capture_index<=capture_index+1'b1;
                    capture_x<=(capture_x==WIDTH-1)?{XW{1'b0}}:capture_x+1'b1;
                end
            end
            SCAN_READ:state<=SCAN_EVAL;
            SCAN_EVAL:if(pixel_q[GRAY_W])advance_scan();else begin
                zone_gray<=pixel_q[GRAY_W-1:0];zone_size<=1;head<=0;tail<=1;state<=Q_READ;
            end
            Q_READ:if(head==tail)state<=H_READ;else state<=Q_EVAL;
            Q_EVAL:begin
                current_index<=queue_q[QW-1:XW];current_x<=queue_q[XW-1:0];
                head<=head+1'b1;neighbor<=0;state<=NEIGHBOR;
            end
            NEIGHBOR:if(neighbor_inside)begin
                neighbor_index<=candidate_index;neighbor_x<=candidate_x;state<=N_READ;
            end else advance_neighbor();
            N_READ:state<=N_EVAL;
            N_EVAL:begin
                if(new_neighbor)begin tail<=tail+1'b1;zone_size<=zone_size+1'b1;end
                advance_neighbor();
            end
            H_READ:state<=H_WRITE;
            H_WRITE:begin zones<=zones+1'b1;advance_scan();end
            OUT_READ:state<=OUT_HOLD;
            OUT_HOLD:if(m_ready)begin
                if(m_last)begin clear_index<=0;state<=CLEAR;end
                else begin
                    if(out_size==N)begin out_size<=1;out_gray<=out_gray+1'b1;end
                    else out_size<=out_size+1'b1;
                    state<=OUT_READ;
                end
            end
            default:state<=CLEAR;
        endcase
    end
    generate if(WIDTH<1 || WIDTH>32 || HEIGHT<1 || HEIGHT>32 || PIXEL_W<1 || PIXEL_W>16 ||
        GRAY_W<1 || GRAY_W>3 || GRAY_W>PIXEL_W || (CONNECTIVITY!=4 && CONNECTIVITY!=8) ||
        TAG_W<1 || TAG_W>32)begin:invalid_parameters
        grayscale_size_zone_invalid_parameters invalid_configuration();
    end endgenerate
endmodule
`default_nettype wire
