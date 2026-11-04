`timescale 1ns/1ps
module qoi_encoder #(
    parameter integer WIDTH=8, HEIGHT=8, CHANNELS=4, TAG_W=8,
    localparam integer BYTE_W=($clog2((CHANNELS+1)*WIDTH*HEIGHT+23)<1)?1:$clog2((CHANNELS+1)*WIDTH*HEIGHT+23)
)(
    input wire clk, input wire rst,
    input wire s_valid, output wire s_ready,
    input wire [8*CHANNELS-1:0] s_pixel,
    input wire s_sof, input wire s_eol, input wire s_error,
    input wire [TAG_W-1:0] s_tag, input wire s_colorspace,
    output wire m_valid, input wire m_ready,
    output wire [7:0] m_byte, output wire m_sof, output wire m_last,
    output wire [BYTE_W-1:0] m_index, output wire [TAG_W-1:0] m_tag,
    output wire d_valid, input wire d_ready,
    output wire [BYTE_W-1:0] d_bytes, output wire [2:0] d_errors,
    output wire [TAG_W-1:0] d_tag, output wire d_colorspace
);
    localparam integer N=WIDTH*HEIGHT, P=8*CHANNELS;
    localparam integer A=(N<2)?1:$clog2(N), X=(WIDTH<2)?1:$clog2(WIDTH);
    localparam [31:0] HEADER_WIDTH=WIDTH, HEADER_HEIGHT=HEIGHT;
    localparam [3:0] CAPTURE=0,CHECK=1,CLEAR=2,HEADER=3,PIXEL_READ=4,
        CLASSIFY=5,IREAD=6,ICHECK=7,CHOOSE=8,NEXT=9,FOOTER=10,SEND=11,DONE=12;
    generate if(WIDTH<1 || WIDTH>64 || HEIGHT<1 || HEIGHT>64 ||
                (CHANNELS!=3 && CHANNELS!=4) || TAG_W<1 || TAG_W>32) begin: invalid
        qoi_encoder_invalid_configuration bad_parameters();
    end endgenerate

    reg [P-1:0] frame_memory [0:N-1];
    reg [31:0] history_memory [0:63];
    reg [P-1:0] frame_q;
    reg [31:0] history_q;
    reg [3:0] state,return_state;
    reg [A-1:0] address;
    reg [X-1:0] x;
    reg [3:0] cursor;
    reg [5:0] clear_cursor,run;
    reg [31:0] previous;
    reg [39:0] packet;
    reg [2:0] remaining;
    reg [BYTE_W-1:0] byte_count;
    reg [TAG_W-1:0] tag;
    reg [2:0] errors;
    reg colorspace;
    wire [31:0] current_pixel;
    generate if(CHANNELS==3) begin: rgb
        assign current_pixel={frame_q,8'hff};
    end else begin: rgba
        assign current_pixel=frame_q;
    end endgenerate
    wire [10:0] hr={5'b0,current_pixel[29:24]},hg={5'b0,current_pixel[21:16]},
        hb={5'b0,current_pixel[13:8]},ha={5'b0,current_pixel[5:0]};
    // Full weighted sum <=6630. Removing channel multiples of64 leaves the
    // same residue; this reduced sum <=1638, and fits the explicit11 bits.
    wire [10:0] hash_sum=(hr<<1)+hr+(hg<<2)+hg+(hb<<2)+(hb<<1)+hb+(ha<<3)+(ha<<1)+ha;
    wire [5:0] color_hash=hash_sum[5:0];
    wire signed [7:0] dr=current_pixel[31:24]-previous[31:24];
    wire signed [7:0] dg=current_pixel[23:16]-previous[23:16];
    wire signed [7:0] db=current_pixel[15:8]-previous[15:8];
    wire signed [7:0] dr_dg=dr-dg,db_dg=db-dg;
    wire diff_ok=(dr>=-8'sd2 && dr<=8'sd1 && dg>=-8'sd2 && dg<=8'sd1 && db>=-8'sd2 && db<=8'sd1);
    wire luma_ok=(dg>=-8'sd32 && dg<=8'sd31 && dr_dg>=-8'sd8 && dr_dg<=8'sd7 && db_dg>=-8'sd8 && db_dg<=8'sd7);
    wire [1:0] enc_dr=dr+8'sd2,enc_dg=dg+8'sd2,enc_db=db+8'sd2;
    wire [5:0] enc_green=dg+8'sd32;
    wire [3:0] enc_rg=dr_dg+8'sd8,enc_bg=db_dg+8'sd8;
    wire [2:0] accepted_errors={s_error,(s_eol!=(x==WIDTH-1)),(s_sof!=(address==0))};

    assign s_ready=!rst && state==CAPTURE;
    assign m_valid=!rst && state==SEND;
    assign m_byte=packet[39:32];
    assign m_index=byte_count;
    assign m_tag=tag;
    assign m_sof=m_valid && byte_count==0;
    assign m_last=m_valid && return_state==FOOTER && cursor==8 && remaining==1;
    assign d_valid=!rst && state==DONE;
    assign d_bytes=byte_count;
    assign d_errors=errors;
    assign d_tag=tag;
    assign d_colorspace=colorspace;

    function automatic [7:0] header_byte(input [3:0] position);
        case(position)
            0:header_byte=8'h71;1:header_byte=8'h6f;2:header_byte=8'h69;3:header_byte=8'h66;
            4:header_byte=HEADER_WIDTH[31:24];5:header_byte=HEADER_WIDTH[23:16];
            6:header_byte=HEADER_WIDTH[15:8];7:header_byte=HEADER_WIDTH[7:0];
            8:header_byte=HEADER_HEIGHT[31:24];9:header_byte=HEADER_HEIGHT[23:16];
            10:header_byte=HEADER_HEIGHT[15:8];11:header_byte=HEADER_HEIGHT[7:0];
            12:header_byte=(CHANNELS==3)?8'd3:8'd4;
            13:header_byte={7'b0,colorspace};default:header_byte=0;
        endcase
    endfunction

    // Two single-port clocked RAMs. Their arrays and read-q registers have no
    // reset. Complete capture and serial history clear establish ownership.
    always @(posedge clk) begin
        if(!rst) begin
            if(state==CAPTURE && s_valid)frame_memory[address]<=s_pixel;
            else if(state==PIXEL_READ)frame_q<=frame_memory[address];
            if(state==CLEAR)history_memory[clear_cursor]<=0;
            else if(state==CHOOSE)history_memory[color_hash]<=current_pixel;
            else if(state==IREAD)history_q<=history_memory[color_hash];
        end
    end
    always @(posedge clk) begin
        if(rst)begin
            state<=CAPTURE;return_state<=CAPTURE;address<=0;x<=0;cursor<=0;clear_cursor<=0;
            run<=0;previous<=32'h000000ff;packet<=0;remaining<=0;byte_count<=0;
            tag<=0;errors<=0;colorspace<=0;
        end else case(state)
            CAPTURE:if(s_valid)begin
                if(address==0)begin tag<=s_tag;colorspace<=s_colorspace;errors<=accepted_errors;byte_count<=0;end
                else errors<=errors|accepted_errors;
                if(x==WIDTH-1)x<=0;else x<=x+1'b1;
                if(address==N-1)state<=CHECK;else address<=address+1'b1;
            end
            CHECK:begin
                if(errors!=0)begin byte_count<=0;state<=DONE;end
                else begin address<=0;x<=0;previous<=32'h000000ff;run<=0;cursor<=0;clear_cursor<=0;state<=CLEAR;end
            end
            CLEAR:if(clear_cursor==63)begin cursor<=0;state<=HEADER;end
                else clear_cursor<=clear_cursor+1'b1;
            HEADER:if(cursor==14)state<=PIXEL_READ;
                else begin packet<={header_byte(cursor),32'b0};remaining<=1;cursor<=cursor+1'b1;return_state<=HEADER;state<=SEND;end
            PIXEL_READ:state<=CLASSIFY;
            CLASSIFY:begin
                if(current_pixel==previous)begin
                    if(run==61 || address==N-1)begin
                        packet<={(8'hc0|{2'b0,run}),32'b0};remaining<=1;run<=0;return_state<=NEXT;state<=SEND;
                    end else begin run<=run+1'b1;state<=NEXT;end
                end else if(run!=0)begin
                    packet<={(8'hc0|({2'b0,run}-8'd1)),32'b0};remaining<=1;run<=0;return_state<=IREAD;state<=SEND;
                end else state<=IREAD;
            end
            IREAD:state<=ICHECK;
            ICHECK:if(history_q==current_pixel)begin
                packet<={2'b0,color_hash,32'b0};remaining<=1;previous<=current_pixel;return_state<=NEXT;state<=SEND;
            end else state<=CHOOSE;
            CHOOSE:begin
                previous<=current_pixel;return_state<=NEXT;state<=SEND;
                if(current_pixel[7:0]!=previous[7:0])begin packet<={8'hff,current_pixel};remaining<=5;end
                else if(diff_ok)begin packet<={2'b01,enc_dr,enc_dg,enc_db,32'b0};remaining<=1;end
                else if(luma_ok)begin packet<={2'b10,enc_green,enc_rg,enc_bg,24'b0};remaining<=2;end
                else begin packet<={8'hfe,current_pixel[31:8],8'b0};remaining<=4;end
            end
            NEXT:if(address==N-1)begin cursor<=0;state<=FOOTER;end
                else begin address<=address+1'b1;state<=PIXEL_READ;end
            FOOTER:if(cursor==8)state<=DONE;
                else begin packet<={(cursor==7?8'd1:8'd0),32'b0};remaining<=1;cursor<=cursor+1'b1;return_state<=FOOTER;state<=SEND;end
            SEND:if(m_ready)begin
                byte_count<=byte_count+1'b1;
                if(remaining==1)begin remaining<=0;state<=return_state;end
                else begin packet<=packet<<8;remaining<=remaining-1'b1;end
            end
            DONE:if(d_ready)begin state<=CAPTURE;address<=0;x<=0;errors<=0;byte_count<=0;end
            default:begin state<=CAPTURE;address<=0;x<=0;errors<=0;byte_count<=0;remaining<=0;end
        endcase
    end
endmodule
