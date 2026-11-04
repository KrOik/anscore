// SPDX-License-Identifier: Apache-2.0
`timescale 1ns/1ps
module label_region_adjacency #(
    parameter integer WIDTH=64,HEIGHT=64,LABEL_W=4,MAX_LABEL=15,TAG_W=8,
    localparam integer PIXELS=WIDTH*HEIGHT,
    localparam integer AREA_W=$clog2(PIXELS+1),
    localparam integer SIDE_W=$clog2(2*PIXELS+1),
    localparam integer NODE_W=$clog2(MAX_LABEL+1),
    localparam integer EDGE_W=(MAX_LABEL<2)?1:$clog2(MAX_LABEL*(MAX_LABEL-1)/2+1)
)(
    input wire clk,rst,s_valid,output wire s_ready,
    input wire [LABEL_W-1:0] s_label,
    input wire s_sof,s_eol,input wire [TAG_W-1:0] s_tag,
    output wire m_valid,input wire m_ready,
    output reg [LABEL_W-1:0] m_a,m_b,
    output reg [SIDE_W-1:0] m_contact_sides,
    output wire done_valid,input wire done_ready,
    output reg [1:0] done_errors,
    output reg [NODE_W-1:0] done_nodes,
    output reg [AREA_W-1:0] done_foreground,
    output reg [EDGE_W-1:0] done_edges,
    output reg [SIDE_W-1:0] done_contact_sides,
    output reg [TAG_W-1:0] done_tag
);
    localparam integer TABLE=MAX_LABEL*MAX_LABEL;
    localparam integer TABLE_AW=(TABLE<2)?1:$clog2(TABLE);
    localparam integer XW=(WIDTH<2)?1:$clog2(WIDTH);
    localparam integer YW=(HEIGHT<2)?1:$clog2(HEIGHT);
    localparam [3:0] CLEAR=0,CAPTURE=1,LEFT_TEST=2,LEFT_READ=3,LEFT_WRITE=4,
        UP_TEST=5,UP_READ=6,UP_WRITE=7,FINISH=8,FINALIZE=9,
        SCAN_READ=10,SCAN_LOAD=11,EDGE=12,DONE=13;
    reg [3:0] state;
    reg [LABEL_W-1:0] row_memory[0:WIDTH-1];
    reg [SIDE_W-1:0] contacts[0:TABLE-1];
    reg [LABEL_W-1:0] upper_q,pixel_q,left_q,scan_a,scan_b;
    reg [SIDE_W-1:0] contact_q;
    reg [TABLE_AW-1:0] clear_address,edge_address,scan_address;
    reg [XW-1:0] x;
    reg [YW-1:0] y;
    reg [MAX_LABEL:0] seen;
    wire label_ok=s_label<=MAX_LABEL;
    wire markers_ok=s_sof==(x==0 && y==0) && s_eol==(x==WIDTH-1);
    wire [LABEL_W-1:0] neighbor=(state==LEFT_TEST)?left_q:upper_q;
    wire [LABEL_W-1:0] small_label=(pixel_q<neighbor)?pixel_q:neighbor;
    wire [LABEL_W-1:0] large_label=(pixel_q<neighbor)?neighbor:pixel_q;

    // Static stride uses only shifts/adds. This is a dense upper-triangle
    // address inside a square allocation; lower/diagonal entries stay zero.
    function automatic [TABLE_AW-1:0] pair_slot;
        input [LABEL_W-1:0] a,b;
        integer k;
        reg [TABLE_AW-1:0] offset;
        begin
            offset=0;
            for(k=0;k<6;k=k+1)
                if((MAX_LABEL>>k)&1) offset=offset+(TABLE_AW'(a-1'b1)<<k);
            pair_slot=offset+TABLE_AW'(b-1'b1);
        end
    endfunction
    assign s_ready=!rst && state==CAPTURE;
    assign m_valid=!rst && state==EDGE;
    assign done_valid=!rst && state==DONE;

    // All memory ports are synchronous. Read/modify/write operations and
    // row read/write use distinct states; no collision mode is assumed.
    always @(posedge clk) if(!rst) begin
        if(state==CLEAR) contacts[clear_address]<=0;
        if(state==LEFT_READ || state==UP_READ) contact_q<=contacts[edge_address];
        if(state==LEFT_WRITE || state==UP_WRITE) contacts[edge_address]<=contact_q+1'b1;
        if(state==SCAN_READ) contact_q<=contacts[scan_address];
        if(state==CAPTURE && s_valid) upper_q<=row_memory[x];
        if(state==FINISH) row_memory[x]<=pixel_q;
    end
    task automatic advance_scan;
        begin
            if(scan_address==TABLE-1) state<=DONE;
            else begin
                scan_address<=scan_address+1'b1;
                if(scan_b==MAX_LABEL) begin scan_b<=1;scan_a<=scan_a+1'b1;end
                else scan_b<=scan_b+1'b1;
                state<=SCAN_READ;
            end
        end
    endtask
    always @(posedge clk) begin
        if(rst) begin
            state<=CLEAR;clear_address<=0;edge_address<=0;scan_address<=0;
            x<=0;y<=0;pixel_q<=0;left_q<=0;seen<=0;scan_a<=1;scan_b<=1;
            m_a<=0;m_b<=0;m_contact_sides<=0;
            done_errors<=0;done_nodes<=0;done_foreground<=0;done_edges<=0;
            done_contact_sides<=0;done_tag<=0;
        end else case(state)
            CLEAR: begin
                if(clear_address==TABLE-1) state<=CAPTURE;
                else clear_address<=clear_address+1'b1;
            end
            CAPTURE: if(s_valid) begin
                if(x==0 && y==0) done_tag<=s_tag;
                if(!markers_ok) done_errors[0]<=1;
                if(!label_ok) done_errors[1]<=1;
                pixel_q<=label_ok?s_label:{LABEL_W{1'b0}};
                if(label_ok && s_label!=0) begin
                    done_foreground<=done_foreground+1'b1;
                    if(!seen[s_label]) begin seen[s_label]<=1;done_nodes<=done_nodes+1'b1;end
                end
                state<=LEFT_TEST;
            end
            LEFT_TEST: begin
                if(done_errors==0 && x!=0 && pixel_q!=0 && left_q!=0 && pixel_q!=left_q) begin
                    edge_address<=pair_slot(small_label,large_label);state<=LEFT_READ;
                end else state<=UP_TEST;
            end
            LEFT_READ: state<=LEFT_WRITE;
            LEFT_WRITE: begin done_contact_sides<=done_contact_sides+1'b1;state<=UP_TEST;end
            UP_TEST: begin
                // The first row ignores stale RAM before each cell is overwritten.
                if(done_errors==0 && y!=0 && pixel_q!=0 && upper_q!=0 && pixel_q!=upper_q) begin
                    edge_address<=pair_slot(small_label,large_label);state<=UP_READ;
                end else state<=FINISH;
            end
            UP_READ: state<=UP_WRITE;
            UP_WRITE: begin done_contact_sides<=done_contact_sides+1'b1;state<=FINISH;end
            FINISH: begin
                if(x==WIDTH-1) begin
                    x<=0;left_q<=0;
                    if(y==HEIGHT-1) state<=FINALIZE;
                    else begin y<=y+1'b1;state<=CAPTURE;end
                end else begin x<=x+1'b1;left_q<=pixel_q;state<=CAPTURE;end
            end
            FINALIZE: begin
                if(done_errors!=0) begin
                    done_nodes<=0;done_foreground<=0;done_edges<=0;done_contact_sides<=0;
                    state<=DONE;
                end else begin scan_address<=0;scan_a<=1;scan_b<=1;state<=SCAN_READ;end
            end
            SCAN_READ: state<=SCAN_LOAD;
            SCAN_LOAD: begin
                if(contact_q!=0) begin
                    m_a<=scan_a;m_b<=scan_b;m_contact_sides<=contact_q;state<=EDGE;
                end else advance_scan();
            end
            EDGE: if(m_ready) begin done_edges<=done_edges+1'b1;advance_scan();end
            DONE: if(done_ready) begin
                state<=CLEAR;clear_address<=0;x<=0;y<=0;left_q<=0;seen<=0;
                done_errors<=0;done_nodes<=0;done_foreground<=0;done_edges<=0;done_contact_sides<=0;
            end
            default: state<=CLEAR;
        endcase
    end
    generate if(WIDTH<1 || WIDTH>1024 || HEIGHT<1 || HEIGHT>1024 ||
                LABEL_W<1 || LABEL_W>8 || MAX_LABEL<1 || MAX_LABEL>63 ||
                MAX_LABEL>((1<<LABEL_W)-1) || TAG_W<1 || TAG_W>32) begin : invalid_parameters
        label_region_adjacency_invalid_parameters__see_README invalid_configuration();
    end endgenerate
endmodule
