// SPDX-License-Identifier: Apache-2.0
// Original ANSCORE max-norm adaptive rational HDR compressor. No upstream RTL.
module frame_adaptive_rgb_tonemap #(
    parameter integer WIDTH=32, HEIGHT=24, TAG_W=8
)(
    input wire clk, input wire rst_n, input wire ce,
    input wire start_valid, output wire start_ready,
    input wire [11:0] start_key_q8, input wire [TAG_W-1:0] start_tag,
    input wire abort,
    input wire s_valid, output wire s_ready, input wire [47:0] s_rgb,
    input wire s_sof, input wire s_eol, input wire s_last,
    output wire m_valid, input wire m_ready, output reg [23:0] m_rgb,
    output wire [7:0] m_x, output wire [7:0] m_y,
    output wire m_sof, output wire m_eol, output wire m_last,
    output wire [TAG_W-1:0] m_tag, output wire [23:0] m_exposure,
    output wire done_valid, input wire done_ready,
    output reg [1:0] done_error, output wire [TAG_W-1:0] done_tag,
    output wire [14:0] done_count, output wire [31:0] done_sum_max,
    output wire [23:0] done_exposure
);
    localparam integer N=WIDTH*HEIGHT;
    localparam integer AW=(N>1)?$clog2(N):1;
    localparam [3:0] IDLE=0,CAPTURE=1,EXP_PREP=2,DIVIDE=3,
        EXP_STORE=4,READ_PIXEL=5,PIX_PREP=6,CHAN_PREP=7,
        CHAN_STORE=8,EMIT=9,DONE=10;
    reg [3:0] state;
    reg [47:0] frame_ram [0:N-1];
    reg [AW-1:0] wr_addr,rd_addr;
    reg [7:0] cap_x,cap_y,out_x,out_y;
    reg [14:0] emitted;
    reg [TAG_W-1:0] tag;
    reg [11:0] key;
    reg [31:0] sum_max;
    reg [23:0] exposure;
    reg [47:0] pixel;
    reg [24:0] pixel_denom;
    reg [1:0] channel;
    reg [39:0] dividend,divisor,quotient;
    reg [40:0] remainder;
    reg [5:0] div_bit;
    reg div_is_exposure;
    wire [15:0] s_rgmax=(s_rgb[47:32]>s_rgb[31:16])?s_rgb[47:32]:s_rgb[31:16];
    wire [15:0] s_max=(s_rgmax>s_rgb[15:0])?s_rgmax:s_rgb[15:0];
    wire [15:0] p_rgmax=(pixel[47:32]>pixel[31:16])?pixel[47:32]:pixel[31:16];
    wire [15:0] p_max=(p_rgmax>pixel[15:0])?p_rgmax:pixel[15:0];
    wire [15:0] component=(channel==0)?pixel[47:32]:(channel==1)?pixel[31:16]:pixel[15:0];
    // 255*C uses shifts/subtraction; N is an elaboration-time constant.
    wire [23:0] channel_numerator=({component,8'b0}-{8'b0,component});
    wire [39:0] exposure_denominator=N*{28'b0,key};
    wire [40:0] trial={remainder[39:0],dividend[39]};
    wire subtract_ok=trial>={1'b0,divisor};
    wire [40:0] next_remainder=subtract_ok?trial-{1'b0,divisor}:trial;
    assign start_ready=rst_n && ce && state==IDLE;
    assign s_ready=rst_n && ce && state==CAPTURE && !abort;
    assign m_valid=state==EMIT;
    assign m_x=out_x; assign m_y=out_y;
    assign m_sof=(rd_addr==0); assign m_eol=(out_x==WIDTH-1);
    assign m_last=(rd_addr==N-1); assign m_tag=tag; assign m_exposure=exposure;
    assign done_valid=state==DONE; assign done_tag=tag;
    assign done_count=emitted; assign done_sum_max=sum_max;
    assign done_exposure=exposure;
    // Reset only control/public state. Every emitted RAM location is freshly captured.
    always @(posedge clk) begin
        if (!rst_n) begin
            state<=IDLE; wr_addr<=0;rd_addr<=0;cap_x<=0;cap_y<=0;out_x<=0;out_y<=0;
            emitted<=0;tag<=0;key<=256;sum_max<=0;exposure<=0;done_error<=0;m_rgb<=0;
            pixel<=0;pixel_denom<=1;channel<=0;dividend<=0;divisor<=1;quotient<=0;
            remainder<=0;div_bit<=0;div_is_exposure<=0;
        end else if (ce) begin
            // Abort masks input acceptance. An already pending output may still
            // transfer on this edge; its count is retained in the failed DONE.
            if (abort && state!=IDLE && state!=DONE) begin
                if(state==EMIT && m_ready) emitted<=emitted+1'b1;
                done_error<=3;state<=DONE;
            end else case (state)
                IDLE: if(start_valid) begin
                    tag<=start_tag;key<=start_key_q8;sum_max<=0;exposure<=0;emitted<=0;
                    wr_addr<=0;rd_addr<=0;cap_x<=0;cap_y<=0;out_x<=0;out_y<=0;done_error<=0;
                    if(start_key_q8==0) begin done_error<=1;state<=DONE;end
                    else state<=CAPTURE;
                end
                CAPTURE: if(s_valid) begin
                    if(s_sof!=(wr_addr==0) || s_eol!=(cap_x==WIDTH-1) || s_last!=(wr_addr==N-1)) begin
                        done_error<=2;state<=DONE;
                    end else begin
                        frame_ram[wr_addr]<=s_rgb;sum_max<=sum_max+{16'b0,s_max};
                        if(wr_addr==N-1) state<=EXP_PREP;
                        else begin
                            wr_addr<=wr_addr+1'b1;
                            if(cap_x==WIDTH-1) begin cap_x<=0;cap_y<=cap_y+1'b1;end
                            else cap_x<=cap_x+1'b1;
                        end
                    end
                end
                EXP_PREP: begin
                    dividend<=({8'b0,sum_max}<<8)+(exposure_denominator>>1);
                    divisor<=exposure_denominator;quotient<=0;remainder<=0;div_bit<=39;
                    div_is_exposure<=1;state<=DIVIDE;
                end
                DIVIDE: begin
                    remainder<=next_remainder;dividend<={dividend[38:0],1'b0};
                    quotient<={quotient[38:0],subtract_ok};
                    if(div_bit==0) state<=div_is_exposure?EXP_STORE:CHAN_STORE;
                    else div_bit<=div_bit-1'b1;
                end
                EXP_STORE: begin
                    exposure<=(quotient==0)?24'd1:quotient[23:0];state<=READ_PIXEL;
                end
                READ_PIXEL: begin pixel<=frame_ram[rd_addr];state<=PIX_PREP;end
                PIX_PREP: begin
                    pixel_denom<={1'b0,exposure}+{9'b0,p_max};channel<=0;state<=CHAN_PREP;
                end
                CHAN_PREP: begin
                    dividend<={16'b0,channel_numerator}+({15'b0,pixel_denom}>>1);
                    divisor<={15'b0,pixel_denom};quotient<=0;remainder<=0;div_bit<=39;
                    div_is_exposure<=0;state<=DIVIDE;
                end
                CHAN_STORE: begin
                    case(channel)
                        0:m_rgb[23:16]<=quotient[7:0];
                        1:m_rgb[15:8]<=quotient[7:0];
                        default:m_rgb[7:0]<=quotient[7:0];
                    endcase
                    if(channel==2) state<=EMIT;
                    else begin channel<=channel+1'b1;state<=CHAN_PREP;end
                end
                EMIT: if(m_ready) begin
                    emitted<=emitted+1'b1;
                    if(rd_addr==N-1) state<=DONE;
                    else begin
                        rd_addr<=rd_addr+1'b1;
                        if(out_x==WIDTH-1) begin out_x<=0;out_y<=out_y+1'b1;end
                        else out_x<=out_x+1'b1;
                        state<=READ_PIXEL;
                    end
                end
                DONE: if(done_ready) state<=IDLE;
                default: begin done_error<=3;state<=DONE;end
            endcase
        end
    end
    // Elaboration contract; invalid static parameters are not a supported build.
    initial begin
        if(WIDTH<1 || WIDTH>128 || HEIGHT<1 || HEIGHT>128 || TAG_W<1 || TAG_W>32)
            $error("frame_adaptive_rgb_tonemap illegal parameters");
    end
endmodule
