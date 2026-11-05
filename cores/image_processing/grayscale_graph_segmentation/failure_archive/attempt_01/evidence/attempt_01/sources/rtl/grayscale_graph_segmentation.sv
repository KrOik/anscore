// SPDX-License-Identifier: Apache-2.0
`timescale 1ns/1ps
// Exact four-neighbor FH segmentation. All RAM accesses are synchronous;
// count-sort scatter is stable in (pixel index, right-before-down) order.
module grayscale_graph_segmentation #(
    parameter integer WIDTH=16,
    parameter integer HEIGHT=16,
    parameter integer TAG_W=8,
    localparam integer N=WIDTH*HEIGHT,
    localparam integer INDEX_W=(N<2)?1:$clog2(N),
    localparam integer COUNT_W=(N<2)?1:$clog2(N+1),
    localparam integer X_W=(WIDTH<2)?1:$clog2(WIDTH),
    localparam integer Y_W=(HEIGHT<2)?1:$clog2(HEIGHT)
)(
    input wire clk,rst,
    input wire s_valid,
    output wire s_ready,
    input wire [7:0] s_pixel,
    input wire s_sof,s_eol,s_last,
    input wire [15:0] s_k,
    input wire [COUNT_W-1:0] s_min_size,
    input wire [TAG_W-1:0] s_tag,
    output wire m_valid,
    input wire m_ready,
    output wire m_keep,
    output wire [INDEX_W-1:0] m_index,
    output wire [INDEX_W-1:0] m_label,
    output wire [COUNT_W-1:0] m_area,m_regions,
    output wire m_sof,m_eol,m_last,
    output wire [3:0] m_errors,
    output wire [TAG_W-1:0] m_tag
);
    generate if(WIDTH<1 || WIDTH>64 || HEIGHT<1 || HEIGHT>64 || TAG_W<1 || TAG_W>32) begin : g_invalid
        grayscale_graph_segmentation_invalid_parameters__see_README invalid_configuration();
    end endgenerate
    localparam integer E=HEIGHT*(WIDTH-1)+WIDTH*(HEIGHT-1);
    localparam integer EDGE_CAP=(E<1)?1:E;
    localparam integer EDGE_AW=(E<2)?1:$clog2(E);
    localparam integer EDGE_CW=(E<2)?1:$clog2(E+1);
    localparam integer EDGE_W=INDEX_W+9;
    localparam integer META_W=COUNT_W+8+INDEX_W;
    localparam integer PRODUCT_W=(COUNT_W+8<16)?16:COUNT_W+8;
    localparam [COUNT_W-1:0] FULL_SIZE=COUNT_W'(N);
    localparam [5:0] CAPTURE=0,CLEAR_REQ=1,CLEAR_WAIT=2,META_INIT=3,HIST_INIT=4,
        GEN_SELECT=5,SRC_READ=6,SRC_CAPTURE=7,NB_READ=8,NB_CAPTURE=9,
        GEN_COUNT_READ=10,GEN_COMMIT=11,GEN_NEXT=12,PREFIX_READ=13,PREFIX_COMMIT=14,
        EDGE_READ=15,EDGE_CAPTURE=16,FIND_A_REQ=17,FIND_A_WAIT=18,
        FIND_B_REQ=19,FIND_B_WAIT=20,META_A_READ=21,META_A_CAPTURE=22,
        META_B_READ=23,META_B_CAPTURE=24,CHECK_A=25,CHECK_B=26,CHECK_DECIDE=27,
        UNION_REQ=28,UNION_WAIT=29,META_WRITE=30,EDGE_NEXT=31,
        OUT_FIND_REQ=32,OUT_FIND_WAIT=33,OUT_META_READ=34,OUT_META_CAPTURE=35,
        OUT_HOLD=36,ERROR_HOLD=37;
    reg [5:0] state;
    reg [INDEX_W-1:0] capture_index,init_index,scan_index,out_index;
    reg [X_W-1:0] capture_x,scan_x,out_x;
    reg [Y_W-1:0] scan_y;
    reg direction,scatter_pass,postprocess;
    reg [7:0] hist_index,source_pixel,weight;
    reg [EDGE_CW-1:0] prefix_sum,edge_cursor;
    reg [EDGE_W-1:0] edge_work;
    reg [INDEX_W-1:0] root_a,root_b,write_root;
    reg [META_W-1:0] meta_a,meta_b;
    reg [PRODUCT_W-1:0] product;
    reg [15:0] frame_k;
    reg [COUNT_W-1:0] frame_min,region_count,area_hold;
    reg [INDEX_W-1:0] label_hold;
    reg [3:0] errors;
    reg [TAG_W-1:0] frame_tag;

    reg [7:0] pixels[0:N-1];
    reg [EDGE_W-1:0] edges[0:EDGE_CAP-1];
    reg [EDGE_CW-1:0] histogram[0:255];
    reg [META_W-1:0] metadata[0:N-1];
    reg [7:0] pixel_q;
    reg [EDGE_W-1:0] edge_q;
    reg [EDGE_CW-1:0] hist_q;
    reg [META_W-1:0] meta_q;

    wire input_fire=s_valid && s_ready;
    wire [3:0] input_errors={
        ((capture_index==0) && (s_min_size==0 || s_min_size>FULL_SIZE)),
        (s_last!=(capture_index==N-1)),
        (s_eol!=(capture_x==WIDTH-1)),
        (s_sof!=(capture_index==0))};
    wire edge_in_bounds=direction?(scan_y<HEIGHT-1):(scan_x<WIDTH-1);
    wire [INDEX_W:0] neighbor_wide={1'b0,scan_index}+
        (direction?(INDEX_W+1)'(WIDTH):(INDEX_W+1)'(1));
    wire [INDEX_W-1:0] neighbor_index=neighbor_wide[INDEX_W-1:0];
    wire [INDEX_W-1:0] edge_source=edge_work[INDEX_W-1:0];
    wire edge_direction=edge_work[INDEX_W];
    wire [7:0] edge_weight=edge_work[EDGE_W-1 -: 8];
    wire [INDEX_W:0] edge_target_wide={1'b0,edge_source}+
        (edge_direction?(INDEX_W+1)'(WIDTH):(INDEX_W+1)'(1));
    wire [INDEX_W-1:0] edge_target=edge_target_wide[INDEX_W-1:0];
    wire [COUNT_W-1:0] size_a=meta_a[META_W-1 -: COUNT_W];
    wire [COUNT_W-1:0] size_b=meta_b[META_W-1 -: COUNT_W];
    wire [7:0] internal_a=meta_a[INDEX_W +: 8];
    wire [7:0] internal_b=meta_b[INDEX_W +: 8];
    wire [INDEX_W-1:0] label_a=meta_a[INDEX_W-1:0];
    wire [INDEX_W-1:0] label_b=meta_b[INDEX_W-1:0];
    wire [7:0] gap_a=(edge_weight>internal_a)?edge_weight-internal_a:8'b0;
    wire [7:0] gap_b=(edge_weight>internal_b)?edge_weight-internal_b:8'b0;
    wire [7:0] mul_gap=(state==CHECK_B)?gap_b:gap_a;
    wire [COUNT_W-1:0] mul_size=(state==CHECK_B)?size_b:size_a;
    // One shared unsigned multiply; all PRODUCT_W bits are retained.
    wire [PRODUCT_W-1:0] mul_product=mul_gap*mul_size;
    wire [PRODUCT_W-1:0] widened_k=PRODUCT_W'(frame_k);
    wire [COUNT_W:0] merged_size={1'b0,size_a}+{1'b0,size_b};
    wire [7:0] max_internal=(internal_a>internal_b)?internal_a:internal_b;
    wire [7:0] merged_internal=(edge_weight>max_internal)?edge_weight:max_internal;
    wire [INDEX_W-1:0] merged_label=(label_a<label_b)?label_a:label_b;

    wire dsu_s_ready,dsu_m_valid,dsu_m_same,dsu_m_merged,dsu_m_error;
    wire [1:0] dsu_m_op;
    wire [INDEX_W-1:0] dsu_m_root;
    wire [COUNT_W-1:0] dsu_m_groups;
    wire dsu_m_tag;
    wire dsu_s_valid=!rst && (state==CLEAR_REQ || state==FIND_A_REQ ||
        state==FIND_B_REQ || state==UNION_REQ || state==OUT_FIND_REQ);
    wire [1:0] dsu_s_op=(state==CLEAR_REQ)?2'd3:(state==UNION_REQ)?2'd1:2'd0;
    wire [INDEX_W-1:0] dsu_s_a=(state==FIND_A_REQ)?edge_source:
        (state==FIND_B_REQ)?edge_target:(state==UNION_REQ)?root_a:out_index;
    wire [INDEX_W-1:0] dsu_s_b=(state==UNION_REQ)?root_b:{INDEX_W{1'b0}};
    wire dsu_m_ready=!rst && (state==CLEAR_WAIT || state==FIND_A_WAIT ||
        state==FIND_B_WAIT || state==UNION_WAIT || state==OUT_FIND_WAIT);
    disjoint_set_union #(.NUM_NODES(N),.TAG_W(1)) u_dsu (
        .clk(clk),.rst(rst),.s_valid(dsu_s_valid),.s_ready(dsu_s_ready),
        .s_op(dsu_s_op),.s_a(dsu_s_a),.s_b(dsu_s_b),.s_tag(1'b0),
        .m_valid(dsu_m_valid),.m_ready(dsu_m_ready),.m_op(dsu_m_op),
        .m_root(dsu_m_root),.m_same(dsu_m_same),.m_merged(dsu_m_merged),
        .m_error(dsu_m_error),.m_groups(dsu_m_groups),.m_tag(dsu_m_tag));

    assign s_ready=!rst && state==CAPTURE;
    assign m_valid=!rst && (state==OUT_HOLD || state==ERROR_HOLD);
    assign m_keep=state==OUT_HOLD;
    assign m_index=(state==ERROR_HOLD)?{INDEX_W{1'b0}}:out_index;
    assign m_label=(state==ERROR_HOLD)?{INDEX_W{1'b0}}:label_hold;
    assign m_area=(state==ERROR_HOLD)?{COUNT_W{1'b0}}:area_hold;
    assign m_regions=(state==ERROR_HOLD)?{COUNT_W{1'b0}}:region_count;
    assign m_sof=(state==ERROR_HOLD) || out_index==0;
    assign m_eol=(state!=ERROR_HOLD) && out_x==WIDTH-1;
    assign m_last=(state==ERROR_HOLD) || out_index==N-1;
    assign m_errors=errors;
    assign m_tag=frame_tag;

    // Each bank has exclusive read/write states; payloads and read-q do not
    // reset. Complete capture/initialization dominates every subsequent read.
    always @(posedge clk) begin
        if(!rst) begin
            if(input_fire) pixels[capture_index]<=s_pixel;
            if(state==SRC_READ) pixel_q<=pixels[scan_index];
            if(state==NB_READ) pixel_q<=pixels[neighbor_index];
            if(state==GEN_COMMIT && scatter_pass)
                edges[hist_q[EDGE_AW-1:0]]<={weight,direction,scan_index};
            if(state==EDGE_READ) edge_q<=edges[edge_cursor[EDGE_AW-1:0]];
            if(state==HIST_INIT) histogram[hist_index]<=0;
            if(state==GEN_COUNT_READ) hist_q<=histogram[weight];
            if(state==GEN_COMMIT) histogram[weight]<=hist_q+1'b1;
            if(state==PREFIX_READ) hist_q<=histogram[hist_index];
            if(state==PREFIX_COMMIT) histogram[hist_index]<=prefix_sum;
            if(state==META_INIT)
                metadata[init_index]<={COUNT_W'(1),8'b0,init_index};
            if(state==META_A_READ) meta_q<=metadata[root_a];
            if(state==META_B_READ) meta_q<=metadata[root_b];
            if(state==META_WRITE)
                metadata[write_root]<={merged_size[COUNT_W-1:0],merged_internal,merged_label};
            if(state==OUT_META_READ) meta_q<=metadata[write_root];
        end
    end
    always @(posedge clk) begin
        if(rst) begin
            state<=CAPTURE;capture_index<=0;capture_x<=0;init_index<=0;
            scan_index<=0;scan_x<=0;scan_y<=0;direction<=0;
            scatter_pass<=0;postprocess<=0;hist_index<=0;source_pixel<=0;weight<=0;
            prefix_sum<=0;edge_cursor<=0;edge_work<=0;root_a<=0;root_b<=0;write_root<=0;
            meta_a<=0;meta_b<=0;product<=0;frame_k<=0;frame_min<=0;
            region_count<=0;out_index<=0;out_x<=0;area_hold<=0;label_hold<=0;
            errors<=0;frame_tag<=0;
        end else case(state)
            CAPTURE: if(input_fire) begin
                if(capture_index==0) begin
                    frame_k<=s_k;frame_min<=s_min_size;frame_tag<=s_tag;errors<=input_errors;
                end else errors<=errors|input_errors;
                if(capture_index==N-1) begin
                    if((errors|input_errors)!=0) state<=ERROR_HOLD;
                    else state<=CLEAR_REQ;
                end else begin
                    capture_index<=capture_index+1'b1;
                    capture_x<=(capture_x==WIDTH-1)?{X_W{1'b0}}:capture_x+1'b1;
                end
            end
            CLEAR_REQ: if(dsu_s_ready) state<=CLEAR_WAIT;
            CLEAR_WAIT: if(dsu_m_valid) begin init_index<=0;state<=META_INIT;end
            META_INIT: begin
                if(init_index==N-1) begin
                    if(E==0) begin region_count<=FULL_SIZE;out_index<=0;out_x<=0;state<=OUT_FIND_REQ;end
                    else begin hist_index<=0;state<=HIST_INIT;end
                end else init_index<=init_index+1'b1;
            end
            HIST_INIT: begin
                if(hist_index==255) begin
                    scan_index<=0;scan_x<=0;scan_y<=0;direction<=0;scatter_pass<=0;state<=GEN_SELECT;
                end else hist_index<=hist_index+1'b1;
            end
            GEN_SELECT: state<=edge_in_bounds?SRC_READ:GEN_NEXT;
            SRC_READ: state<=SRC_CAPTURE;
            SRC_CAPTURE: begin source_pixel<=pixel_q;state<=NB_READ;end
            NB_READ: state<=NB_CAPTURE;
            NB_CAPTURE: begin
                weight<=(source_pixel>pixel_q)?source_pixel-pixel_q:pixel_q-source_pixel;
                state<=GEN_COUNT_READ;
            end
            GEN_COUNT_READ: state<=GEN_COMMIT;
            GEN_COMMIT: state<=GEN_NEXT;
            GEN_NEXT: begin
                if(!direction) begin direction<=1;state<=GEN_SELECT;end
                else if(scan_index==N-1) begin
                    if(!scatter_pass) begin hist_index<=0;prefix_sum<=0;state<=PREFIX_READ;end
                    else begin edge_cursor<=0;postprocess<=0;state<=EDGE_READ;end
                end else begin
                    scan_index<=scan_index+1'b1;direction<=0;
                    if(scan_x==WIDTH-1) begin scan_x<=0;scan_y<=scan_y+1'b1;end
                    else scan_x<=scan_x+1'b1;
                    state<=GEN_SELECT;
                end
            end
            PREFIX_READ: state<=PREFIX_COMMIT;
            PREFIX_COMMIT: begin
                prefix_sum<=prefix_sum+hist_q;
                if(hist_index==255) begin
                    scatter_pass<=1;scan_index<=0;scan_x<=0;scan_y<=0;direction<=0;state<=GEN_SELECT;
                end else begin hist_index<=hist_index+1'b1;state<=PREFIX_READ;end
            end
            EDGE_READ: state<=EDGE_CAPTURE;
            EDGE_CAPTURE: begin edge_work<=edge_q;state<=FIND_A_REQ;end
            FIND_A_REQ: if(dsu_s_ready) state<=FIND_A_WAIT;
            FIND_A_WAIT: if(dsu_m_valid) begin root_a<=dsu_m_root;state<=FIND_B_REQ;end
            FIND_B_REQ: if(dsu_s_ready) state<=FIND_B_WAIT;
            FIND_B_WAIT: if(dsu_m_valid) begin
                root_b<=dsu_m_root;state<=(root_a==dsu_m_root)?EDGE_NEXT:META_A_READ;
            end
            META_A_READ: state<=META_A_CAPTURE;
            META_A_CAPTURE: begin meta_a<=meta_q;state<=META_B_READ;end
            META_B_READ: state<=META_B_CAPTURE;
            META_B_CAPTURE: begin meta_b<=meta_q;state<=CHECK_A;end
            CHECK_A: begin
                if(postprocess) state<=(size_a<frame_min || size_b<frame_min)?UNION_REQ:EDGE_NEXT;
                else begin product<=mul_product;state<=CHECK_B;end
            end
            CHECK_B: begin
                if(product<=widened_k) begin product<=mul_product;state<=CHECK_DECIDE;end
                else state<=EDGE_NEXT;
            end
            CHECK_DECIDE: state<=(product<=widened_k)?UNION_REQ:EDGE_NEXT;
            UNION_REQ: if(dsu_s_ready) state<=UNION_WAIT;
            UNION_WAIT: if(dsu_m_valid) begin
                // The existing backend chooses by rank, then lower root ID.
                // Use its actual returned winner; no predicted root is used.
                write_root<=dsu_m_root;state<=META_WRITE;
            end
            META_WRITE: state<=EDGE_NEXT;
            EDGE_NEXT: begin
                if(edge_cursor==E-1) begin
                    if(!postprocess && frame_min>1) begin
                        postprocess<=1;edge_cursor<=0;state<=EDGE_READ;
                    end else begin
                        region_count<=dsu_m_groups;out_index<=0;out_x<=0;state<=OUT_FIND_REQ;
                    end
                end else begin edge_cursor<=edge_cursor+1'b1;state<=EDGE_READ;end
            end
            OUT_FIND_REQ: if(dsu_s_ready) state<=OUT_FIND_WAIT;
            OUT_FIND_WAIT: if(dsu_m_valid) begin write_root<=dsu_m_root;state<=OUT_META_READ;end
            OUT_META_READ: state<=OUT_META_CAPTURE;
            OUT_META_CAPTURE: begin
                label_hold<=meta_q[INDEX_W-1:0];area_hold<=meta_q[META_W-1 -: COUNT_W];state<=OUT_HOLD;
            end
            OUT_HOLD: if(m_ready) begin
                if(out_index==N-1) begin state<=CAPTURE;capture_index<=0;capture_x<=0;errors<=0;end
                else begin
                    out_index<=out_index+1'b1;
                    out_x<=(out_x==WIDTH-1)?{X_W{1'b0}}:out_x+1'b1;
                    state<=OUT_FIND_REQ;
                end
            end
            ERROR_HOLD: if(m_ready) begin state<=CAPTURE;capture_index<=0;capture_x<=0;errors<=0;end
            default: state<=CAPTURE;
        endcase
    end
endmodule
