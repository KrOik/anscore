// Isolated candidate: same motion/history arithmetic and stream contract as
// production, with bounded counters and registered blend products.
module img_filter_temporal_denoise #(parameter PIXEL_W=8,parameter MAX_WIDTH=64,
    parameter MAX_HEIGHT=64,parameter INTERNAL_HISTORY=1)(
    input wire clk,rst_n,clk_en,
    input wire cmd_valid,output wire cmd_ready,input wire [7:0] cmd_tag,
    input wire [15:0] cfg_width,cfg_height,
    input wire [8:0] cfg_current_weight_q8,
    input wire [PIXEL_W-1:0] cfg_motion_threshold,input wire cfg_history_valid,
    output wire rsp_valid,input wire rsp_ready,output wire [7:0] rsp_tag,rsp_error,
    input wire [PIXEL_W-1:0] s_data,s_history_data,
    input wire s_valid,s_sof,s_eol,output wire s_ready,
    input wire s_history_valid,s_history_sof,s_history_eol,output wire s_history_ready,
    output wire [PIXEL_W-1:0] m_data,
    output wire m_valid,m_sof,m_eol,input wire m_ready
);
    localparam XW=(MAX_WIDTH<2)?1:$clog2(MAX_WIDTH+1);
    localparam YW=(MAX_HEIGHT<2)?1:$clog2(MAX_HEIGHT+1);
    localparam AW=(MAX_WIDTH*MAX_HEIGHT<2)?1:$clog2(MAX_WIDTH*MAX_HEIGHT);
    localparam IDLE=0,LOAD=1,PRODUCTS=2,SUM=3,SEND=4;
    reg [2:0] state;
    reg [XW-1:0] width,history_width,x;
    reg [YW-1:0] height,history_height;
    reg [AW-1:0] count;
    reg [8:0] alpha;
    reg [PIXEL_W-1:0] threshold,current,external_previous,history_q,result;
    reg [PIXEL_W+8:0] current_product,previous_product;
    reg bypass_q;
    reg history_present,use_history,response_valid,output_valid,output_sof,output_eol;
    reg [7:0] tag,error_code;
    (* ram_style="block" *) reg [PIXEL_W-1:0] history[0:MAX_WIDTH*MAX_HEIGHT-1];
    wire [PIXEL_W-1:0] previous=(INTERNAL_HISTORY!=0)?history_q:external_previous;
    wire [PIXEL_W:0] difference=(current>=previous)?current-previous:previous-current;
    wire [PIXEL_W+9:0] weighted={1'b0,current_product}+{1'b0,previous_product}+128;
    wire [PIXEL_W-1:0] calculated=bypass_q?current:weighted[PIXEL_W+7:8];
    wire need_external=(INTERNAL_HISTORY==0&&use_history);
    // Product width is XW+YW including the full representable frame area.
    wire [XW+YW-1:0] frame_area=width*height;
    assign cmd_ready=rst_n&&clk_en&&state==IDLE&&!response_valid;
    assign s_ready=rst_n&&clk_en&&state==LOAD&&(!need_external||s_history_valid);
    assign s_history_ready=rst_n&&clk_en&&state==LOAD&&need_external&&s_valid;
    assign rsp_valid=response_valid;assign rsp_tag=tag;assign rsp_error=error_code;
    assign m_valid=output_valid;assign m_data=result;assign m_sof=output_sof;assign m_eol=output_eol;
    always @(posedge clk)if(rst_n&&clk_en&&INTERNAL_HISTORY!=0)begin
        if(state==LOAD&&s_valid&&s_ready)history_q<=history[count];
        if(state==SUM)history[count]<=calculated;
    end
    always @(posedge clk or negedge rst_n)begin
        if(!rst_n)begin
            state<=IDLE;width<=0;height<=0;history_width<=0;history_height<=0;
            alpha<=256;threshold<=0;current<=0;external_previous<=0;result<=0;
            current_product<=0;previous_product<=0;bypass_q<=1;
            history_present<=0;use_history<=0;response_valid<=0;output_valid<=0;
            output_sof<=0;output_eol<=0;tag<=0;error_code<=0;count<=0;x<=0;
        end else if(clk_en)begin
            if(response_valid&&rsp_ready)response_valid<=0;
            if(output_valid&&m_ready)output_valid<=0;
            case(state)
                IDLE:if(cmd_valid&&cmd_ready)begin
                    tag<=cmd_tag;error_code<=0;count<=0;x<=0;
                    if(cfg_width==0||cfg_height==0||cfg_width>MAX_WIDTH||cfg_height>MAX_HEIGHT||
                       cfg_current_weight_q8>256)begin response_valid<=1;error_code<=1;end
                    else begin
                        width<=cfg_width;height<=cfg_height;alpha<=cfg_current_weight_q8;
                        threshold<=cfg_motion_threshold;
                        use_history<=cfg_history_valid&&((INTERNAL_HISTORY==0)||
                            (history_present&&cfg_width==history_width&&cfg_height==history_height));
                        state<=LOAD;
                    end
                end
                LOAD:if(s_valid&&s_ready)begin
                    current<=s_data;external_previous<=s_history_data;
                    if(s_sof!=(count==0)||s_eol!=(x==width-1))error_code[1]<=1;
                    if(need_external&&(s_history_sof!=s_sof||s_history_eol!=s_eol))error_code[2]<=1;
                    state<=PRODUCTS;
                end
                PRODUCTS:begin
                    current_product<=current*alpha;
                    previous_product<=previous*(9'd256-alpha);
                    bypass_q<=!use_history||difference>threshold;state<=SUM;
                end
                SUM:begin
                    result<=calculated;output_valid<=1;output_sof<=count==0;
                    output_eol<=x==width-1;state<=SEND;
                end
                SEND:if(output_valid&&m_ready)begin
                    if(count==frame_area-1'b1)begin
                        history_present<=error_code==0;history_width<=width;history_height<=height;
                        response_valid<=1;state<=IDLE;
                    end else begin
                        count<=count+1'b1;
                        if(x==width-1'b1)x<=0;else x<=x+1'b1;
                        state<=LOAD;
                    end
                end
                default:begin state<=IDLE;error_code<=8'h80;response_valid<=1;history_present<=0;end
            endcase
        end
    end
endmodule
