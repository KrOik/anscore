// SPDX-License-Identifier: Apache-2.0
// Original bounded, whole-file-validated QOI decoder. See README for acceptance.
`timescale 1ns/1ps
module qoi_decoder #(
    parameter MAX_WIDTH=8,MAX_HEIGHT=8,MAX_BYTES=342,TAG_W=8,
    localparam P=MAX_WIDTH*MAX_HEIGHT,
    localparam FAW=(MAX_BYTES<2)?1:$clog2(MAX_BYTES),FCW=$clog2(MAX_BYTES+1),
    localparam PIW=(P<2)?1:$clog2(P),PCW=$clog2(P+1),
    localparam XW=(MAX_WIDTH<2)?1:$clog2(MAX_WIDTH),
    localparam YW=(MAX_HEIGHT<2)?1:$clog2(MAX_HEIGHT),
    localparam WCW=$clog2(MAX_WIDTH+1),HCW=$clog2(MAX_HEIGHT+1)
)(
    input wire clk,rst,input wire s_valid,output wire s_ready,
    input wire [7:0] s_byte,input wire s_last,input wire [TAG_W-1:0] s_tag,
    output wire m_valid,input wire m_ready,output reg [31:0] m_rgba,
    output reg [XW-1:0] m_x,output reg [YW-1:0] m_y,
    output wire m_sof,m_eol,m_last,
    output reg [31:0] m_width,m_height,output reg [7:0] m_channels,
    output reg m_colorspace,output reg [2:0] m_status,
    output wire [FCW-1:0] m_bytes,output reg [TAG_W-1:0] m_tag
);
    generate if(MAX_WIDTH<1 || MAX_WIDTH>16 || MAX_HEIGHT<1 || MAX_HEIGHT>16 ||
                MAX_BYTES<27 || MAX_BYTES>1302 || TAG_W<1 || TAG_W>32)begin:bad
        qoi_decoder_invalid_parameter__see_README invalid();
    end endgenerate
    localparam CAPTURE=0,CHECK=1,FREAD=2,FSAVE=3,HEADER=4,HEADER_DONE=5,
        CHUNK=6,RGB=7,RGBA=8,LUMA=9,IREAD=10,ILATCH=11,COMMIT=12,
        TAIL=13,VERIFY=14,OREAD=15,OLATCH=16,HOLD=17;
    reg [4:0] state,return_state;
    reg started,overflow,last_was_index;
    reg [FCW-1:0] file_count,file_pointer;
    reg [7:0] file_memory[0:MAX_BYTES-1];
    reg [31:0] pixel_memory[0:P-1],index_memory[0:63];
    reg [7:0] file_q,byte_value;
    reg [31:0] pixel_q,index_q,previous_pixel;
    reg [63:0] index_valid;
    reg [5:0] index_address,last_index,luma_green,run_remaining;
    reg [3:0] header_position;
    reg [1:0] literal_position;
    reg [2:0] tail_position;
    reg [PCW-1:0] decoded_count,total_pixels;
    reg [PIW-1:0] output_index;
    wire [10:0] hr={5'b0,previous_pixel[29:24]},hg={5'b0,previous_pixel[21:16]},
        hb={5'b0,previous_pixel[13:8]},ha={5'b0,previous_pixel[5:0]};
    wire [10:0] color_hash=(hr<<1)+hr+(hg<<2)+hg+(hb<<2)+(hb<<1)+hb+(ha<<3)+(ha<<1)+ha;
    // The only data multiply is at most 5x5 bits after full 32-bit bounds checks.
    wire [PCW-1:0] geometry_pixels=m_width[WCW-1:0]*m_height[HCW-1:0];
    assign s_ready=!rst && state==CAPTURE;
    assign m_valid=!rst && state==HOLD;
    assign m_bytes=file_count;
    assign m_sof=m_valid && (m_status!=0 || output_index==0);
    assign m_eol=m_valid && (m_status!=0 || m_x==m_width-1'b1);
    assign m_last=m_valid && (m_status!=0 || output_index==total_pixels-1'b1);
    // All memories have clocked reads and no reset. Validity/owned prefix gates use.
    always @(posedge clk)if(!rst)begin
        if(state==CAPTURE && s_valid && file_count<MAX_BYTES)file_memory[file_count[FAW-1:0]]<=s_byte;
        if(state==FREAD && file_pointer<file_count)file_q<=file_memory[file_pointer[FAW-1:0]];
        if(state==IREAD)index_q<=index_memory[index_address];
        if(state==COMMIT)begin
            pixel_memory[decoded_count[PIW-1:0]]<=previous_pixel;
            index_memory[color_hash[5:0]]<=previous_pixel;
        end
        if(state==OREAD)pixel_q<=pixel_memory[output_index];
    end
    task fetch;
        input [4:0] destination;
        begin return_state<=destination;state<=FREAD;end
    endtask
    task fail;
        input [2:0] reason;
        begin
            m_status<=reason;m_rgba<=0;m_x<=0;m_y<=0;m_width<=0;m_height<=0;
            m_channels<=0;m_colorspace<=0;total_pixels<=0;decoded_count<=0;output_index<=0;
            state<=HOLD;
        end
    endtask
    always @(posedge clk)begin
        if(rst)begin
            state<=CAPTURE;return_state<=0;started<=0;overflow<=0;file_count<=0;file_pointer<=0;
            byte_value<=0;previous_pixel<=0;index_valid<=0;index_address<=0;last_index<=0;last_was_index<=0;
            luma_green<=0;run_remaining<=0;header_position<=0;literal_position<=0;tail_position<=0;
            decoded_count<=0;total_pixels<=0;output_index<=0;
            m_rgba<=0;m_x<=0;m_y<=0;m_width<=0;m_height<=0;m_channels<=0;m_colorspace<=0;m_status<=0;m_tag<=0;
        end else case(state)
            CAPTURE:if(s_valid)begin
                if(!started)begin
                    started<=1;m_tag<=s_tag;m_status<=0;m_rgba<=0;m_x<=0;m_y<=0;
                    m_width<=0;m_height<=0;m_channels<=0;m_colorspace<=0;
                    file_pointer<=0;header_position<=0;decoded_count<=0;total_pixels<=0;output_index<=0;
                    previous_pixel<=32'h000000ff;index_valid<=0;last_was_index<=0;last_index<=0;run_remaining<=0;
                end
                if(file_count<MAX_BYTES)file_count<=file_count+1'b1;else overflow<=1;
                if(s_last)state<=CHECK;
            end
            CHECK:begin
                if(overflow)fail(1);
                else if(file_count<22)fail(3);
                else fetch(HEADER);
            end
            FREAD:begin
                if(file_pointer>=file_count ||
                   ((return_state>=CHUNK && return_state<=LUMA) && file_pointer>=file_count-4'd8))fail(3);
                else state<=FSAVE;
            end
            FSAVE:begin byte_value<=file_q;file_pointer<=file_pointer+1'b1;state<=return_state;end
            HEADER:begin
                if((header_position==0 && byte_value!=8'h71) || (header_position==1 && byte_value!=8'h6f) ||
                   (header_position==2 && byte_value!=8'h69) || (header_position==3 && byte_value!=8'h66) ||
                   (header_position==13 && byte_value>1))fail(2);
                else begin
                    if(header_position>=4 && header_position<=7)m_width<={m_width[23:0],byte_value};
                    if(header_position>=8 && header_position<=11)m_height<={m_height[23:0],byte_value};
                    if(header_position==12)m_channels<=byte_value;
                    if(header_position==13)begin m_colorspace<=byte_value[0];state<=HEADER_DONE;end
                    else begin header_position<=header_position+1'b1;fetch(HEADER);end
                end
            end
            HEADER_DONE:begin
                if(m_width==0 || m_height==0 || m_width>MAX_WIDTH || m_height>MAX_HEIGHT || (m_channels!=3 && m_channels!=4))fail(2);
                else begin total_pixels<=geometry_pixels;fetch(CHUNK);end
            end
            CHUNK:begin
                if(byte_value==8'hfe || byte_value==8'hff)begin
                    last_was_index<=0;literal_position<=0;fetch(byte_value==8'hfe ? RGB : RGBA);
                end else case(byte_value[7:6])
                    0:begin
                        if(last_was_index && last_index==byte_value[5:0])fail(6);
                        else begin index_address<=byte_value[5:0];last_index<=byte_value[5:0];last_was_index<=1;state<=IREAD;end
                    end
                    1:begin
                        last_was_index<=0;
                        previous_pixel[31:24]<=previous_pixel[31:24]+{6'b0,byte_value[5:4]}-8'd2;
                        previous_pixel[23:16]<=previous_pixel[23:16]+{6'b0,byte_value[3:2]}-8'd2;
                        previous_pixel[15:8]<=previous_pixel[15:8]+{6'b0,byte_value[1:0]}-8'd2;
                        state<=COMMIT;
                    end
                    2:begin last_was_index<=0;luma_green<=byte_value[5:0];fetch(LUMA);end
                    3:begin
                        last_was_index<=0;
                        if(byte_value[5:0]>=total_pixels-decoded_count)fail(4);
                        else begin run_remaining<=byte_value[5:0];state<=COMMIT;end
                    end
                endcase
            end
            RGB,RGBA:begin
                case(literal_position)
                    0:previous_pixel[31:24]<=byte_value;
                    1:previous_pixel[23:16]<=byte_value;
                    2:previous_pixel[15:8]<=byte_value;
                    3:previous_pixel[7:0]<=byte_value;
                endcase
                if((state==RGB && literal_position==2) || literal_position==3)state<=COMMIT;
                else begin literal_position<=literal_position+1'b1;fetch(state);end
            end
            LUMA:begin
                previous_pixel[31:24]<=previous_pixel[31:24]+{2'b0,luma_green}+{4'b0,byte_value[7:4]}-8'd40;
                previous_pixel[23:16]<=previous_pixel[23:16]+{2'b0,luma_green}-8'd32;
                previous_pixel[15:8]<=previous_pixel[15:8]+{2'b0,luma_green}+{4'b0,byte_value[3:0]}-8'd40;
                state<=COMMIT;
            end
            IREAD:state<=ILATCH;
            ILATCH:begin previous_pixel<=index_valid[index_address]?index_q:32'b0;state<=COMMIT;end
            COMMIT:begin
                index_valid[color_hash[5:0]]<=1;decoded_count<=decoded_count+1'b1;
                if(decoded_count+1'b1==total_pixels)begin
                    if(run_remaining!=0)fail(4);
                    else if({1'b0,file_pointer}+4'd8!={1'b0,file_count})fail(5);
                    else begin tail_position<=0;fetch(TAIL);end
                end else if(run_remaining!=0)run_remaining<=run_remaining-1'b1;
                else fetch(CHUNK);
            end
            TAIL:begin
                if(byte_value!=((tail_position==7)?8'd1:8'd0))fail(5);
                else if(tail_position==7)state<=VERIFY;
                else begin tail_position<=tail_position+1'b1;fetch(TAIL);end
            end
            VERIFY:begin
                if(file_pointer!=file_count)fail(5);
                else begin output_index<=0;m_x<=0;m_y<=0;state<=OREAD;end
            end
            OREAD:state<=OLATCH;
            OLATCH:begin m_rgba<=pixel_q;state<=HOLD;end
            HOLD:if(m_ready)begin
                if(m_status!=0 || {1'b0,output_index}+1'b1==total_pixels)begin
                    state<=CAPTURE;started<=0;overflow<=0;file_count<=0;
                end else begin
                    output_index<=output_index+1'b1;
                    if({1'b0,m_x}+1'b1==m_width)begin m_x<=0;m_y<=m_y+1'b1;end else m_x<=m_x+1'b1;
                    state<=OREAD;
                end
            end
            default:begin state<=CAPTURE;started<=0;overflow<=0;file_count<=0;end
        endcase
    end
endmodule
