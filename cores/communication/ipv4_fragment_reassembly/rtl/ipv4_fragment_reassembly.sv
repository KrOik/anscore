// SPDX-License-Identifier: Apache-2.0
// Bounded decoded IPv4 payload reassembly. One context, no payload prefix.
module ipv4_fragment_reassembly #(
    parameter integer MAX_BYTES=512, TAG_W=8,
    parameter integer AW=(MAX_BYTES<2?1:$clog2(MAX_BYTES)),
    parameter integer CW=$clog2(MAX_BYTES+1)
)(
    input wire clk, rst,
    input wire c_valid, output wire c_ready,
    input wire [1:0] c_op,
    input wire [31:0] c_src, c_dst,
    input wire [15:0] c_id,
    input wire [7:0] c_protocol,
    input wire [12:0] c_offset8,
    input wire c_more,
    input wire [15:0] c_length,
    input wire [TAG_W-1:0] c_tag,
    input wire s_valid, output wire s_ready,
    input wire [7:0] s_data, input wire s_last,
    output wire d_valid, input wire d_ready,
    output reg [3:0] d_status,
    output reg d_complete, d_active,
    output reg [CW-1:0] d_filled, d_total,
    output reg [TAG_W-1:0] d_tag,
    output wire m_valid, input wire m_ready,
    output wire [7:0] m_data, output wire m_last,
    output wire [CW-1:0] m_length,
    output wire [31:0] m_src, m_dst,
    output wire [15:0] m_id,
    output wire [7:0] m_protocol,
    output wire [TAG_W-1:0] m_tag
);
    localparam integer BLOCKS=(MAX_BYTES+7)/8;
    localparam integer BW=(BLOCKS<2?1:$clog2(BLOCKS));
    localparam [3:0] IDLE=0, SCAN=1, INPUT_BYTES=2, RESP=3, READ_REQ=4, READ_OUT=5;
    reg [3:0] state;
    reg active, known_end;
    reg [BLOCKS-1:0] owned;
    reg [31:0] src, dst;
    reg [15:0] ident;
    reg [7:0] protocol;
    reg [CW-1:0] filled, total, high_water;
    reg [CW-1:0] pending_start, pending_end, pending_length, input_index;
    reg pending_more;
    reg [BW-1:0] scan_block, final_block;
    reg [AW-1:0] replay_index;
    wire [16:0] start_wide={1'b0,c_offset8,3'b000};
    wire [16:0] end_wide=start_wide+{1'b0,c_length};
    wire shape_bad=c_length==0 || end_wide>MAX_BYTES || end_wide>65515 ||
                   (c_more && c_length[2:0]!=0);
    wire foreign_key=active && (src!=c_src || dst!=c_dst || ident!=c_id || protocol!=c_protocol);
    wire end_bad=active && ((known_end && (end_wide>total ||
                   (!c_more && end_wide!=total) || (c_more && end_wide>=total))) ||
                   (!c_more && end_wide<high_water));
    wire [CW-1:0] byte_address=pending_start+input_index;
    wire [CW-1:0] filled_next=filled+pending_length;
    wire ram_ready, ram_valid, ram_error;
    wire [7:0] ram_data;
    wire ram_req=!rst && ((state==INPUT_BYTES && s_valid) || state==READ_REQ);
    wire ram_write=state==INPUT_BYTES;
    wire [AW-1:0] ram_addr=ram_write?byte_address[AW-1:0]:replay_index;
    cip_sync_sp_ram #(.DATA_WIDTH(8),.ADDR_WIDTH(AW),.DEPTH(MAX_BYTES)) payload (
        .clk(clk),.rst_n(!rst),.clk_en(1'b1),
        .req_valid(ram_req),.req_ready(ram_ready),.req_write(ram_write),
        .req_addr(ram_addr),.req_wdata(s_data),.req_wstrb(1'b1),
        .rsp_valid(ram_valid),.rsp_ready(state==READ_OUT?m_ready:1'b1),
        .rsp_rdata(ram_data),.rsp_error(ram_error)
    );
    assign c_ready=!rst && state==IDLE;
    assign s_ready=!rst && state==INPUT_BYTES && ram_ready;
    assign d_valid=!rst && state==RESP;
    assign m_valid=!rst && state==READ_OUT && ram_valid;
    assign m_data=ram_data;
    assign m_last=m_valid && replay_index==total-1'b1;
    assign m_length=total;
    assign m_src=src; assign m_dst=dst; assign m_id=ident;
    assign m_protocol=protocol; assign m_tag=d_tag;

    // Only ownership and context are reset. Payload RAM is never swept.
    always @(posedge clk) begin
        if(rst) begin
            state<=IDLE; active<=0; known_end<=0; owned<=0;
            src<=0; dst<=0; ident<=0; protocol<=0;
            filled<=0; total<=0; high_water<=0;
            pending_start<=0; pending_end<=0; pending_length<=0; input_index<=0;
            pending_more<=0; scan_block<=0; final_block<=0; replay_index<=0;
            d_status<=0; d_complete<=0; d_active<=0; d_filled<=0; d_total<=0; d_tag<=0;
        end else case(state)
            IDLE: if(c_valid) begin
                d_tag<=c_tag; d_status<=0; d_complete<=0;
                d_active<=active; d_filled<=filled; d_total<=known_end?total:0;
                state<=RESP;
                if(c_op==3) d_status<=1;
                else if(c_op==1) begin
                    active<=0; known_end<=0; owned<=0; filled<=0; total<=0; high_water<=0;
                    d_active<=0; d_filled<=0; d_total<=0;
                end else if(c_op==2) begin end
                else if(shape_bad) d_status<=2;
                else if(foreign_key) d_status<=3;
                else if(end_bad) d_status<=5;
                else begin
                    // Scan before taking ownership or consuming any payload.
                    pending_start<=start_wide[CW-1:0]; pending_end<=end_wide[CW-1:0];
                    pending_length<=c_length[CW-1:0]; pending_more<=c_more;
                    scan_block<=c_offset8[BW-1:0]; final_block<=(end_wide-1'b1)>>3;
                    if(!active) begin
                        src<=c_src; dst<=c_dst; ident<=c_id; protocol<=c_protocol;
                    end
                    state<=SCAN;
                end
            end
            SCAN: begin
                if(owned[scan_block]) begin d_status<=4; state<=RESP; end
                else if(scan_block==final_block) begin
                    active<=1;
                    if(!pending_more) begin known_end<=1; total<=pending_end; end
                    input_index<=0; state<=INPUT_BYTES;
                end else scan_block<=scan_block+1'b1;
            end
            INPUT_BYTES: if(s_valid && s_ready) begin
                owned[byte_address>>3]<=1;
                if(s_last!=(input_index==pending_length-1'b1)) begin
                    // No rollback RAM writes are needed: the whole context dies.
                    active<=0; known_end<=0; owned<=0; filled<=0; total<=0; high_water<=0;
                    d_status<=6; d_active<=0; d_filled<=0; d_total<=0; d_complete<=0; state<=RESP;
                end else if(s_last) begin
                    filled<=filled_next;
                    if(pending_end>high_water) high_water<=pending_end;
                    d_status<=0; d_active<=1; d_filled<=filled_next;
                    d_total<=known_end?total:0;
                    d_complete<=known_end && filled_next==total;
                    state<=RESP;
                end else input_index<=input_index+1'b1;
            end
            RESP: if(d_ready) begin
                if(d_complete) begin replay_index<=0; state<=READ_REQ; end
                else state<=IDLE;
            end
            READ_REQ: if(ram_ready) state<=READ_OUT;
            READ_OUT: if(m_valid && m_ready) begin
                if(m_last) begin
                    active<=0; known_end<=0; owned<=0; filled<=0; total<=0; high_water<=0; state<=IDLE;
                end else begin replay_index<=replay_index+1'b1; state<=READ_REQ; end
            end
            default: state<=IDLE;
        endcase
    end
    generate if(MAX_BYTES<1 || MAX_BYTES>4096 || TAG_W<1 || TAG_W>32 ||
                AW!=(MAX_BYTES<2?1:$clog2(MAX_BYTES)) || CW!=$clog2(MAX_BYTES+1)) begin: invalid
        ipv4_fragment_reassembly_invalid_parameters__see_README reject();
    end endgenerate
endmodule
