// Complete bounded integer-translation SAD registration and synchronous-RAM warp.
// Fixed canvas extends MAX_SHIFT pixels around the main frame. Optional supplied
// inverse homography maps main-frame coordinates into auxiliary coordinates.
module img_mf_auto_stitch #(
    parameter WIDTH=32,HEIGHT=24,MAX_SHIFT=2,TAG_WIDTH=16,FRAME_WIDTH=16,
    parameter CAPTURE_TIMEOUT=65536,MIN_CONFIDENCE=1
)(
    input wire clk,rst_n,clk_en,
    input wire cmd_valid,output wire cmd_ready,input wire [3:0] cmd_opcode,
    input wire [FRAME_WIDTH-1:0] cmd_frameid,
    input wire [8:0] cfg_aux_weight,input wire [23:0] cfg_background,
    input wire signed [31:0] cfg_h00,cfg_h01,cfg_h02,cfg_h10,cfg_h11,cfg_h12,cfg_h20,cfg_h21,cfg_h22,
    output reg rsp_valid,input wire rsp_ready,output wire rsp_done,
    output reg [3:0] rsp_opcode,output reg [FRAME_WIDTH-1:0] rsp_frameid,
    output reg [7:0] rsp_error,output reg [7:0] error_code,
    input wire s_valid,output wire s_ready,input wire [23:0] s_data,
    input wire s_sof,s_eol,input wire [TAG_WIDTH-1:0] s_tag,input wire [FRAME_WIDTH-1:0] s_frameid,
    input wire aux_valid,output wire aux_ready,input wire [23:0] aux_data,
    input wire aux_sof,aux_eol,input wire [TAG_WIDTH-1:0] aux_tag,input wire [FRAME_WIDTH-1:0] aux_frameid,
    output reg m_valid,input wire m_ready,output reg [23:0] m_data,
    output reg m_sof,m_eol,output reg [TAG_WIDTH-1:0] m_tag,
    output reg [FRAME_WIDTH-1:0] m_frameid,output reg [7:0] m_error,
    output wire [1:0] frames_valid,output reg signed [15:0] registration_dx,registration_dy,
    output reg [47:0] registration_cost,registration_confidence,
    output wire [31:0] canvas_width,canvas_height
);
    localparam CW=WIDTH+2*MAX_SHIFT,CH=HEIGHT+2*MAX_SHIFT;
    // The project parameter guard limits each legal canvas to 65536 pixels.
    // A homography coordinate is bounded by max(WIDTH,HEIGHT)+shift. For
    // B<=2^k-1, each signed linear form is bounded by 2^31*(2*B+1), which fits
    // HOMOGRAPHY_W=32+(k+1) signed bits.
    localparam integer HOMOGRAPHY_COORD_BOUND =
        ((WIDTH>HEIGHT)?WIDTH:HEIGHT) + ((MAX_SHIFT>0)?MAX_SHIFT:0);
    localparam integer HOMOGRAPHY_COORD_MAG_BITS =
        (HOMOGRAPHY_COORD_BOUND>0)?$clog2(HOMOGRAPHY_COORD_BOUND+1):1;
    localparam integer HOMOGRAPHY_COORD_W = HOMOGRAPHY_COORD_MAG_BITS+1;
    localparam integer HOMOGRAPHY_W = 32+HOMOGRAPHY_COORD_W;
    localparam integer DIV_COUNT_W = $clog2(HOMOGRAPHY_W);
    localparam IDLE=0,CAP_CMD=1,CAP_WAIT=2,REG_START=3,REG_WAIT=4,
        MAP=5,REQUEST=6,WAIT_DATA=7,SEND=8,DIV_X_INIT=9,DIV_Y_INIT=10,
        DIV_ITER=11,DIV_FINISH=12,MAP_FINISH=13,BLEND_FINISH=14;
    reg [3:0] state,store_opcode;
    reg [FRAME_WIDTH-1:0] target_frame;
    reg [8:0] weight;
    reg [23:0] background;
    reg use_homography;
    reg signed [31:0] h00,h01,h02,h10,h11,h12,h20,h21,h22;
    reg [31:0] out_x,out_y,out_index,address0,address1;
    reg present0,present1;
    reg [7:0] operation_error;
    reg blend_pending;
    reg [16:0] blend_ar,blend_ag,blend_ab,blend_br,blend_bg,blend_bb;
    wire [17:0] blend_r={1'b0,blend_ar}+{1'b0,blend_br}+18'd128;
    wire [17:0] blend_g={1'b0,blend_ag}+{1'b0,blend_bg}+18'd128;
    wire [17:0] blend_b={1'b0,blend_ab}+{1'b0,blend_bb}+18'd128;
    reg signed [HOMOGRAPHY_W-1:0] homography_numerator_x,homography_numerator_y;
    reg signed [HOMOGRAPHY_W-1:0] homography_denominator;
    reg signed [HOMOGRAPHY_W-1:0] homography_x_result,homography_y_result;
    // One staged signed-floor divider is shared by x and y. It shifts MSBs
    // and separates low/high borrow propagation; no dynamic bit selection.
    reg div_for_y;
    wire divider_ready,divider_valid;
    wire signed [HOMOGRAPHY_W-1:0] divider_result;
    wire [7:0] divider_error;
    img_mf_signed_floor_divider #(.W(HOMOGRAPHY_W)) divider_i(
        .clk(clk),.rst_n(rst_n),.clk_en(clk_en),
        .start_valid(state==DIV_X_INIT||state==DIV_Y_INIT),.start_ready(divider_ready),
        .numerator(state==DIV_Y_INIT?homography_numerator_y:homography_numerator_x),
        .denominator(homography_denominator),.result_valid(divider_valid),
        .result_ready(state==DIV_ITER),.result(divider_result),.error(divider_error));
    wire store_cmd_ready,store_rsp_valid;
    wire [7:0] store_rsp_error,store_error;
    wire store_rd_ready,store_rd_rsp_valid,store_rd_rsp_ready;
    wire [23:0] rd_data0,rd_data1;
    wire [7:0] rd_error;
    wire sad_start_ready,sad_result_valid,sad_rd_valid,sad_rd_rsp_ready;
    wire [31:0] sad_addr0,sad_addr1,sad_samples;
    wire signed [15:0] sad_dx,sad_dy;
    wire [47:0] sad_cost,sad_second,sad_confidence;
    wire [7:0] sad_error;
    wire registering=state==REG_START || state==REG_WAIT;
    wire params_ok=WIDTH>0 && HEIGHT>0 && MAX_SHIFT>=0 && MAX_SHIFT<=15 &&
        WIDTH>2*MAX_SHIFT && HEIGHT>2*MAX_SHIFT && CW*CH<=65536 && TAG_WIDTH>=16 && TAG_WIDTH<=32;
    assign cmd_ready=rst_n && clk_en && state==IDLE && !rsp_valid && !m_valid;
    assign rsp_done=rsp_valid;
    assign canvas_width=CW;
    assign canvas_height=CH;
    assign store_rd_rsp_ready=registering?sad_rd_rsp_ready:(state==WAIT_DATA);
    img_mf_dual_frame_store_bram_read #(.WIDTH(WIDTH),.HEIGHT(HEIGHT),.TAG_WIDTH(TAG_WIDTH),
        .FRAME_WIDTH(FRAME_WIDTH),.CAPTURE_TIMEOUT(CAPTURE_TIMEOUT)) store_i (
        .clk(clk),.rst_n(rst_n),.clk_en(clk_en),.cmd_valid(state==CAP_CMD),.cmd_ready(store_cmd_ready),
        .cmd_opcode(store_opcode),.cmd_frameid(target_frame),.rsp_valid(store_rsp_valid),.rsp_ready(state==CAP_WAIT),
        .rsp_done(),.rsp_opcode(),.rsp_frameid(),.rsp_error(store_rsp_error),.error_code(store_error),
        .s_valid(s_valid),.s_ready(s_ready),.s_data(s_data),.s_sof(s_sof),.s_eol(s_eol),.s_tag(s_tag),.s_frameid(s_frameid),
        .aux_valid(aux_valid),.aux_ready(aux_ready),.aux_data(aux_data),.aux_sof(aux_sof),.aux_eol(aux_eol),.aux_tag(aux_tag),.aux_frameid(aux_frameid),
        .m_valid(),.m_ready(1'b1),.m_data(),.m_aux_data(),.m_pair(),.m_sof(),.m_eol(),.m_tag(),.m_frameid(),.m_error(),.frames_valid(frames_valid),
        .rd_valid(registering?sad_rd_valid:(state==REQUEST)),.rd_ready(store_rd_ready),
        .rd_addr0(registering?sad_addr0:address0),.rd_addr1(registering?sad_addr1:address1),
        .rd_rsp_valid(store_rd_rsp_valid),.rd_rsp_ready(store_rd_rsp_ready),.rd_data0(rd_data0),.rd_data1(rd_data1),.rd_error(rd_error),
        .wr_valid(1'b0),.wr_ready(),.wr_bank(1'b0),.wr_addr(32'd0),.wr_data(24'd0)
    );
    img_mf_translation_sad #(.WIDTH(WIDTH),.HEIGHT(HEIGHT),.MAX_SHIFT(MAX_SHIFT),
        .MIN_CONFIDENCE(MIN_CONFIDENCE)) registration_i (
        .clk(clk),.rst_n(rst_n),.clk_en(clk_en),.start_valid(state==REG_START),.start_ready(sad_start_ready),
        .result_valid(sad_result_valid),.result_ready(state==REG_WAIT),.best_dx(sad_dx),.best_dy(sad_dy),
        .best_cost(sad_cost),.second_cost(sad_second),.confidence(sad_confidence),.sample_count(sad_samples),.result_error(sad_error),
        .rd_valid(sad_rd_valid),.rd_ready(store_rd_ready),.rd_addr0(sad_addr0),.rd_addr1(sad_addr1),
        .rd_rsp_valid(store_rd_rsp_valid && registering),.rd_rsp_ready(sad_rd_rsp_ready),.rd_data0(rd_data0),.rd_data1(rd_data1),.rd_error(rd_error)
    );
    function [7:0] mix;
        input [7:0] a,b; input [8:0] w;
        reg [17:0] total;
        begin total=a*(9'd256-w)+b*w+18'd128; mix=total[15:8]; end
    endfunction
    // Canvas bounds keep every coordinate and linear homography term in range.
    wire signed [63:0] main_x=$signed({1'b0,out_x})-MAX_SHIFT;
    wire signed [63:0] main_y=$signed({1'b0,out_y})-MAX_SHIFT;
    wire signed [HOMOGRAPHY_COORD_W-1:0] main_x_homography=main_x;
    wire signed [HOMOGRAPHY_COORD_W-1:0] main_y_homography=main_y;
    wire signed [HOMOGRAPHY_W-1:0] denominator=
        $signed(h20)*main_x_homography+$signed(h21)*main_y_homography+$signed(h22);
    wire signed [HOMOGRAPHY_W-1:0] numerator_x=
        $signed(h00)*main_x_homography+$signed(h01)*main_y_homography+$signed(h02);
    wire signed [HOMOGRAPHY_W-1:0] numerator_y=
        $signed(h10)*main_x_homography+$signed(h11)*main_y_homography+$signed(h12);
    wire signed [63:0] translated_x=main_x+$signed(registration_dx);
    wire signed [63:0] translated_y=main_y+$signed(registration_dy);
    wire main_present=main_x>=0 && main_x<WIDTH && main_y>=0 && main_y<HEIGHT;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state<=IDLE; store_opcode<=0; target_frame<=0; weight<=128; background<=0; use_homography<=0;
            h00<=1;h01<=0;h02<=0;h10<=0;h11<=1;h12<=0;h20<=0;h21<=0;h22<=1;
            out_x<=0;out_y<=0;out_index<=0;address0<=0;address1<=0;present0<=0;present1<=0;
            homography_numerator_x<=0;homography_numerator_y<=0;homography_denominator<=0;
            homography_x_result<=0;homography_y_result<=0;
            div_for_y<=0;
            rsp_valid<=0;rsp_opcode<=0;rsp_frameid<=0;rsp_error<=0;error_code<=0;operation_error<=0;
            blend_pending<=0;
            blend_ar<=0;blend_ag<=0;blend_ab<=0;blend_br<=0;blend_bg<=0;blend_bb<=0;
            m_valid<=0;m_data<=0;m_sof<=0;m_eol<=0;m_tag<=0;m_frameid<=0;m_error<=0;
            registration_dx<=0;registration_dy<=0;registration_cost<=0;registration_confidence<=0;
        end else if (clk_en) begin
            if (rsp_valid && rsp_ready) rsp_valid<=0;
            case (state)
                IDLE: if (cmd_valid && cmd_ready) begin
                    target_frame<=cmd_frameid;rsp_frameid<=cmd_frameid;rsp_opcode<=cmd_opcode;rsp_error<=0;operation_error<=0;
                    weight<=cfg_aux_weight;background<=cfg_background;
                    h00<=cfg_h00;h01<=cfg_h01;h02<=cfg_h02;h10<=cfg_h10;h11<=cfg_h11;h12<=cfg_h12;h20<=cfg_h20;h21<=cfg_h21;h22<=cfg_h22;
                    out_x<=0;out_y<=0;out_index<=0;
                    if (!params_ok) begin rsp_valid<=1;rsp_error<=8'h40;error_code<=error_code|8'h40; end
                    else if (cmd_opcode<=2 || cmd_opcode==5) begin
                        store_opcode<=cmd_opcode==5?4'd6:cmd_opcode;state<=CAP_CMD;
                    end else if (cmd_opcode==3 || cmd_opcode==4) begin
                        use_homography<=cmd_opcode==4;
                        if (frames_valid!=3) begin rsp_valid<=1;rsp_error<=8'h04;error_code<=error_code|8'h04; end
                        else if (cfg_aux_weight>256) begin rsp_valid<=1;rsp_error<=8'h08;error_code<=error_code|8'h08; end
                        else if (cmd_opcode==4 && cfg_h20==0 && cfg_h21==0 && cfg_h22==0) begin
                            rsp_valid<=1;rsp_error<=8'h08;error_code<=error_code|8'h08;
                        end else state<=cmd_opcode==3?REG_START:MAP;
                    end else begin rsp_valid<=1;rsp_error<=8'h80;error_code<=error_code|8'h80; end
                end
                CAP_CMD: if (store_cmd_ready) state<=CAP_WAIT;
                CAP_WAIT: if (store_rsp_valid) begin
                    rsp_valid<=1;rsp_error<=store_rsp_error;error_code<=error_code|store_rsp_error;state<=IDLE;
                end
                REG_START: if (sad_start_ready) state<=REG_WAIT;
                REG_WAIT: if (sad_result_valid) begin
                    registration_dx<=sad_dx;registration_dy<=sad_dy;registration_cost<=sad_cost;registration_confidence<=sad_confidence;
                    if (sad_error!=0) begin rsp_valid<=1;rsp_error<=sad_error;error_code<=error_code|sad_error;state<=IDLE; end
                    else state<=MAP;
                end
                MAP: begin
                    present0<=main_present;
                    address0<=main_present?main_y*WIDTH+main_x:0;
                    if (use_homography) begin
                        homography_numerator_x<=numerator_x;
                        homography_numerator_y<=numerator_y;
                        homography_denominator<=denominator;
                        if (denominator==0) begin
                            // Preserve zero-denominator handling as an invalid auxiliary sample.
                            present1<=0;address1<=0;state<=REQUEST;
                        end else state<=DIV_X_INIT;
                    end else begin
                        present1<=translated_x>=0 && translated_x<WIDTH &&
                            translated_y>=0 && translated_y<HEIGHT;
                        address1<=(translated_x>=0 && translated_x<WIDTH &&
                            translated_y>=0 && translated_y<HEIGHT)?
                            translated_y*WIDTH+translated_x:0;
                        state<=REQUEST;
                    end
                end
                DIV_X_INIT:if(divider_ready)begin div_for_y<=0;state<=DIV_ITER;end
                DIV_Y_INIT:if(divider_ready)begin div_for_y<=1;state<=DIV_ITER;end
                DIV_ITER:if(divider_valid)begin
                    if(divider_error!=0)begin
                        // Zero denominators are handled before launch. Retain
                        // explicit containment for an unexpected helper fault.
                        operation_error<=operation_error|8'h08;
                        present1<=0;address1<=0;state<=REQUEST;
                    end else if(div_for_y)begin homography_y_result<=divider_result;state<=MAP_FINISH;end
                    else begin homography_x_result<=divider_result;state<=DIV_Y_INIT;end
                end
                MAP_FINISH: begin
                    present1<=homography_x_result>=0 && homography_x_result<WIDTH &&
                        homography_y_result>=0 && homography_y_result<HEIGHT;
                    address1<=(homography_x_result>=0 && homography_x_result<WIDTH &&
                        homography_y_result>=0 && homography_y_result<HEIGHT)?
                        homography_y_result*WIDTH+homography_x_result:0;
                    state<=REQUEST;
                end
                REQUEST: if (store_rd_ready) state<=WAIT_DATA;
                WAIT_DATA: if (store_rd_rsp_valid) begin
                    m_sof<=out_index==0;m_eol<=out_x==CW-1;m_tag<=out_index;
                    m_frameid<=target_frame;m_error<=rd_error;operation_error<=operation_error|rd_error;
                    if (rd_error!=0) m_data<=0;
                    else if (present0 && present1) begin
                        blend_ar<=rd_data0[23:16]*(9'd256-weight);
                        blend_ag<=rd_data0[15:8]*(9'd256-weight);
                        blend_ab<=rd_data0[7:0]*(9'd256-weight);
                        blend_br<=rd_data1[23:16]*weight;
                        blend_bg<=rd_data1[15:8]*weight;
                        blend_bb<=rd_data1[7:0]*weight;
                    end
                    else if (present0) m_data<=rd_data0;
                    else if (present1) m_data<=rd_data1;
                    else m_data<=background;
                    blend_pending<=rd_error==0 && present0 && present1;
                    state<=BLEND_FINISH;
                end
                BLEND_FINISH: begin
                    if(blend_pending)m_data<={blend_r[15:8],blend_g[15:8],blend_b[15:8]};
                    m_valid<=1;state<=SEND;
                end
                SEND: if (m_valid && m_ready) begin
                    m_valid<=0;
                    if (out_index==CW*CH-1) begin
                        rsp_valid<=1;rsp_error<=operation_error;error_code<=error_code|operation_error;state<=IDLE;
                    end else begin
                        out_index<=out_index+1;
                        if (out_x==CW-1) begin out_x<=0;out_y<=out_y+1; end else out_x<=out_x+1;
                        state<=MAP;
                    end
                end
                default: begin state<=IDLE;rsp_valid<=1;rsp_error<=8'h40;error_code<=error_code|8'h40; end
            endcase
        end
    end
endmodule
