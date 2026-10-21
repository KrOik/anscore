// Four-register elastic RGB blend with exact nibble partial products.
// Stage0 captures config, stage1 nibble products, stage2 exact17-bit products;
// stage3 rounds/adds and emits. No arithmetic approximation or DSP dependency.
module img_mf_rgb_blend_partial_pipe #(parameter TAG_WIDTH=16,FRAME_WIDTH=16)(
    input wire clk,rst_n,clk_en,
    input wire s_valid,output wire s_ready,input wire [23:0] s_base,s_aux,
    input wire [8:0] s_weight,input wire s_use_blend,
    input wire s_sof,s_eol,input wire [TAG_WIDTH-1:0] s_tag,
    input wire [FRAME_WIDTH-1:0] s_frameid,input wire [7:0] s_error,
    output reg m_valid,input wire m_ready,output reg [23:0] m_data,
    output reg m_sof,m_eol,output reg [TAG_WIDTH-1:0] m_tag,
    output reg [FRAME_WIDTH-1:0] m_frameid,output reg [7:0] m_error
);
    reg v0,v1,v2;
    reg [23:0] base0,aux0,base1,base2;
    reg [8:0] weight0,complement0;
    reg use0,use1,use2,sof0,eol0,sof1,eol1,sof2,eol2;
    reg [TAG_WIDTH-1:0] tag0,tag1,tag2;
    reg [FRAME_WIDTH-1:0] frame0,frame1,frame2;
    reg [7:0] error0,error1,error2;
    reg [16:0] ar,ag,ab,br,bg,bb;
    wire room3=!m_valid||m_ready;
    wire room2=!v2||room3;
    wire room1=!v1||room2;
    wire room0=!v0||room1;
    reg [12:0] arlo,arhi,aglo,aghi,ablo,abhi,brlo,brhi,bglo,bghi,bblo,bbhi;
    wire [17:0] red_sum={1'b0,ar}+{1'b0,br}+18'd128;
    wire [17:0] green_sum={1'b0,ag}+{1'b0,bg}+18'd128;
    wire [17:0] blue_sum={1'b0,ab}+{1'b0,bb}+18'd128;
    assign s_ready=rst_n&&clk_en&&room0;
    always @(posedge clk or negedge rst_n)begin
        if(!rst_n)begin
            v0<=0;v1<=0;v2<=0;base0<=0;aux0<=0;base1<=0;base2<=0;weight0<=0;complement0<=0;
            use0<=0;use1<=0;use2<=0;sof2<=0;eol2<=0;tag2<=0;frame2<=0;error2<=0;sof0<=0;eol0<=0;sof1<=0;eol1<=0;
            tag0<=0;tag1<=0;frame0<=0;frame1<=0;error0<=0;error1<=0;
            ar<=0;ag<=0;ab<=0;br<=0;bg<=0;bb<=0;arlo<=0;arhi<=0;aglo<=0;aghi<=0;ablo<=0;abhi<=0;brlo<=0;brhi<=0;bglo<=0;bghi<=0;bblo<=0;bbhi<=0;
            m_valid<=0;m_data<=0;m_sof<=0;m_eol<=0;m_tag<=0;m_frameid<=0;m_error<=0;
        end else if(clk_en)begin
            if(room3)begin
                m_valid<=v2;
                if(v2)begin
                    m_data<=(error2!=0)?24'd0:(!use2?base2:{red_sum[15:8],green_sum[15:8],blue_sum[15:8]});
                    m_sof<=sof2;m_eol<=eol2;m_tag<=tag2;m_frameid<=frame2;m_error<=error2;
                end
            end
            if(room2)begin
                v2<=v1;
                if(v1)begin
                    ar<={4'd0,arlo}+{arhi,4'd0};ag<={4'd0,aglo}+{aghi,4'd0};ab<={4'd0,ablo}+{abhi,4'd0};
                    br<={4'd0,brlo}+{brhi,4'd0};bg<={4'd0,bglo}+{bghi,4'd0};bb<={4'd0,bblo}+{bbhi,4'd0};
                    base2<=base1;use2<=use1;sof2<=sof1;eol2<=eol1;tag2<=tag1;frame2<=frame1;error2<=error1;
                end
            end
            if(room1)begin
                v1<=v0;
                if(v0)begin
                    arlo<=base0[19:16]*complement0;arhi<=base0[23:20]*complement0;aglo<=base0[11:8]*complement0;aghi<=base0[15:12]*complement0;ablo<=base0[3:0]*complement0;abhi<=base0[7:4]*complement0;
                    brlo<=aux0[19:16]*weight0;brhi<=aux0[23:20]*weight0;bglo<=aux0[11:8]*weight0;bghi<=aux0[15:12]*weight0;bblo<=aux0[3:0]*weight0;bbhi<=aux0[7:4]*weight0;
                    base1<=base0;use1<=use0;sof1<=sof0;eol1<=eol0;tag1<=tag0;frame1<=frame0;error1<=error0;
                end
            end
            if(room0)begin
                v0<=s_valid;
                if(s_valid)begin
                    base0<=s_base;aux0<=s_aux;weight0<=s_weight;complement0<=9'd256-s_weight;use0<=s_use_blend;
                    sof0<=s_sof;eol0<=s_eol;tag0<=s_tag;frame0<=s_frameid;error0<=s_error;
                end
            end
        end
    end
endmodule
