// Frame-buffered DCP dehaze with automatic same-frame airlight and optional
// full grayscale guided filtering. Serial synchronous RAM access; no external
// windows, airlight solver or coefficient preparation required.
// Candidate-local exact serial N/R implementation. RGB normalization and
// signed restoration share the production byte divider; transmission uses the
// production byte multiplier. Each division takes 656 enabled edges after
// accept; multiplier takes 144. No frame state changes while CE=0.
module img_dh_dehaze_frame #(
    parameter integer MAX_WIDTH=32, MAX_HEIGHT=32, MAX_RADIUS=3,
    parameter integer TAG_WIDTH=16,
    parameter integer DEPTH=MAX_WIDTH*MAX_HEIGHT,
    parameter integer ADDR_W=(DEPTH<=1)?1:$clog2(DEPTH)
) (
    input wire clk,rst_n,clk_en,
    input wire cmd_valid,
    output wire cmd_ready,
    input wire [15:0] cmd_width,cmd_height,
    input wire [3:0] cmd_dark_radius,
    input wire cmd_auto_airlight,
    input wire [23:0] cmd_airlight_rgb,
    // Brightest RGB-sum pixel among the top dark-channel permille. 1=0.1%.
    input wire [9:0] cmd_airlight_permille,
    input wire [15:0] cmd_omega,cmd_t0,
    input wire cmd_guided_enable,
    input wire [3:0] cmd_guided_radius,
    input wire [31:0] cmd_guided_epsilon,
    input wire [TAG_WIDTH-1:0] cmd_tag,
    input wire [23:0] s_data,
    input wire s_valid,s_sof,s_eol,
    output wire s_ready,
    output reg [23:0] m_data,
    output reg m_valid,m_sof,m_eol,m_eof,
    input wire m_ready,
    output wire [TAG_WIDTH-1:0] m_tag,
    output reg rsp_valid,
    input wire rsp_ready,
    output reg [3:0] rsp_error,
    output wire [TAG_WIDTH-1:0] rsp_tag,
    output wire [23:0] rsp_airlight_rgb,
    output wire busy
);
    localparam integer PARAM_OK=MAX_WIDTH>=1 && MAX_WIDTH<=512 &&
        MAX_HEIGHT>=1 && MAX_HEIGHT<=512 && MAX_RADIUS>=0 && MAX_RADIUS<=7 &&
        DEPTH>=MAX_WIDTH*MAX_HEIGHT && ADDR_W>=1 && ADDR_W<=20 &&
        DEPTH<=(32'd1<<ADDR_W) && TAG_WIDTH>=1;
    localparam integer HIST_COUNT_W=(DEPTH<2)?1:$clog2(DEPTH+1);
    localparam integer MAX_TOP_COUNT=(DEPTH*1023+999)/1000;
    localparam integer TOP_COUNT_W=(MAX_TOP_COUNT<2)?1:$clog2(MAX_TOP_COUNT+1);
    localparam [5:0] IDLE=0,CAPTURE=1,H_CLEAR=2,D_CENTER_REQ=3,D_CENTER_CAP=4,
        D_INIT=5,D_REQ=6,D_ACC=7,D_STORE=8,H_READ=9,H_WRITE=10,
        THRESH_REQ=11,THRESH_ACC=12,A_REQ=13,A_CAP=14,A_FINAL=15,
        N_INIT=16,N_REQ=17,N_ACC=18,N_STORE=19,G_CMD=20,G_REQ=21,
        G_CAP=22,G_SEND=23,G_WAIT=24,R_REQ=25,R_CAP=26,R_EMIT=27,RESPONSE=28,
        N_DIV_PREP=29,N_DIV_START=30,N_DIV_WAIT=31,N_COMPARE=32,
        N_MUL_START=33,N_MUL_WAIT=34,R_DIV_PREP=35,R_DIV_START=36,
        R_DIV_WAIT=37,R_FINAL=38;
    reg [5:0] state;
    reg [15:0] width,height,px,py;
    reg [31:0] total,count,index;
    reg [3:0] dark_radius,guided_radius;
    reg signed [5:0] dx,dy;
    reg [15:0] omega,t0;
    reg [31:0] guided_epsilon;
    reg auto_airlight,guided_enable,frame_error;
    reg [TAG_WIDTH-1:0] tag;
    reg [23:0] airlight,airlight_candidate,center_rgb;
    reg [9:0] best_rgb_sum;
    reg [7:0] dark_min,hist_bin,airlight_threshold;
    reg [31:0] norm_min;
    reg [HIST_COUNT_W-1:0] hist_q,hist_acc;
    reg [TOP_COUNT_W-1:0] top_count;
    wire [HIST_COUNT_W:0] hist_sum={1'b0,hist_acc}+{1'b0,hist_q};
    reg [31:0] guided_write_index;
    (* ram_style="block",syn_ramstyle="block_ram" *) reg [23:0] rgb_mem[0:DEPTH-1];
    (* ram_style="block",syn_ramstyle="block_ram" *) reg [7:0] dark_mem[0:DEPTH-1];
    (* ram_style="block",syn_ramstyle="block_ram" *) reg [15:0] t_mem[0:DEPTH-1];
    (* ram_style="block",syn_ramstyle="block_ram" *) reg [HIST_COUNT_W-1:0] hist_mem[0:255];
    reg [23:0] rgb_q;
    reg [7:0] dark_q;
    reg [15:0] t_q;
    integer nx,ny;
    reg [31:0] neighbor_index;
    reg [1:0] channel_index;
    reg [31:0] normalized_pixel;
    reg [15:0] transmission_q;
    reg [23:0] restored_rgb;
    reg signed [63:0] math_numerator,math_denominator;
    wire signed [63:0] math_quotient;
    wire math_done,math_busy;
    wire math_start=(state==N_DIV_START || state==R_DIV_START);
    wire [7:0] math_c=(channel_index==0)?rgb_q[23:16]:
        ((channel_index==1)?rgb_q[15:8]:rgb_q[7:0]);
    wire [7:0] math_a=(channel_index==0)?airlight[23:16]:
        ((channel_index==1)?airlight[15:8]:airlight[7:0]);
    wire signed [8:0] math_delta=$signed({1'b0,math_c})-$signed({1'b0,math_a});
    wire [63:0] restored_sum;
    wire [7:0] restored_channel=restored_sum[63]?8'd0:
        ((|restored_sum[62:8])?8'd255:restored_sum[7:0]);
    wire mul_done;
    wire [63:0] mul_result,rounded_penalty;
    img_dh_iter_div_signed64 u_rgb_divider(
        .clk(clk),.rst_n(rst_n),.clk_en(clk_en),.start(math_start),
        .dividend(math_numerator),.divisor(math_denominator),
        .busy(math_busy),.done(math_done),.quotient(math_quotient));
    img_dh_iter_mul64x16_byte u_t_multiplier(
        .clk(clk),.rst_n(rst_n),.clk_en(clk_en),.start(state==N_MUL_START),
        .multiplicand({32'd0,norm_min}),.factor(omega),
        .busy(),.done(mul_done),.product(mul_result));
    img_dh_addsub64_prefix u_restore_add(math_quotient,{56'd0,math_a},1'b0,restored_sum);
    img_dh_addsub64_prefix u_penalty_round(mul_result,64'd16384,1'b0,rounded_penalty);
    always @* begin
        nx=$signed({1'b0,px})+$signed(dx);
        ny=$signed({1'b0,py})+$signed(dy);
        if(nx<0) nx=0;else if(nx>=width) nx=width-1;
        if(ny<0) ny=0;else if(ny>=height) ny=height-1;
        neighbor_index=ny*width+nx;
    end
    wire [31:0] rgb_read_index=(state==D_REQ || state==N_REQ)?neighbor_index:index;
    // H_READ and THRESH_REQ are the only histogram read states. Keep their
    // mutually exclusive addresses behind one mux so synthesis sees a single
    // synchronous read port that can map to the device block RAM.
    wire [7:0] hist_read_addr=(state==H_READ)?dark_min:hist_bin;
    wire hist_read_en=(state==H_READ || state==THRESH_REQ);
    wire input_fire=s_valid && s_ready;
    wire last_neighbor=(dx==$signed({1'b0,dark_radius})) &&
                       (dy==$signed({1'b0,dark_radius}));
    wire [9:0] rgb_sum={2'b0,rgb_q[23:16]}+{2'b0,rgb_q[15:8]}+{2'b0,rgb_q[7:0]};
    wire [7:0] pixel_min=(rgb_q[23:16]<rgb_q[15:8]) ?
        ((rgb_q[23:16]<rgb_q[7:0])?rgb_q[23:16]:rgb_q[7:0]) :
        ((rgb_q[15:8]<rgb_q[7:0])?rgb_q[15:8]:rgb_q[7:0]);
    assign cmd_ready=rst_n && clk_en && state==IDLE;
    assign s_ready=rst_n && clk_en && state==CAPTURE;
    assign m_tag=tag;
    assign rsp_tag=tag;
    assign rsp_airlight_rgb=airlight;
    assign busy=state!=IDLE;

    function [23:0] safe_airlight;
        input [23:0] a;
        begin safe_airlight={a[23:16]==0?8'd1:a[23:16],
            a[15:8]==0?8'd1:a[15:8],a[7:0]==0?8'd1:a[7:0]};end
    endfunction
    function [7:0] grayscale;
        input [23:0] rgb;
        reg [31:0] y;
        begin y=77*rgb[23:16]+150*rgb[15:8]+29*rgb[7:0]+128;
            grayscale=y>>8;end
    endfunction

    wire g_cmd_ready,g_s_ready,g_m_valid,g_rsp_valid;
    wire [15:0] g_m_q;
    wire [3:0] g_rsp_error;
    wire g_m_ready=state==G_WAIT;
    img_dh_guided_frame #(.MAX_WIDTH(MAX_WIDTH),.MAX_HEIGHT(MAX_HEIGHT),
        .MAX_RADIUS(MAX_RADIUS),.TAG_WIDTH(TAG_WIDTH)) u_guided (
        .clk(clk),.rst_n(rst_n),.clk_en(clk_en),
        .cmd_valid(state==G_CMD),.cmd_ready(g_cmd_ready),
        .cmd_width(width),.cmd_height(height),.cmd_radius(guided_radius),
        .cmd_epsilon(guided_epsilon),.cmd_tag(tag),
        .s_guide(grayscale(rgb_q)),.s_p(t_q),.s_valid(state==G_SEND),
        .s_sof(index==0),.s_eol(px==width-1),.s_ready(g_s_ready),
        .m_q(g_m_q),.m_valid(g_m_valid),.m_sof(),.m_eol(),.m_eof(),
        .m_ready(g_m_ready),.m_tag(),.rsp_valid(g_rsp_valid),
        .rsp_ready(state==G_WAIT),.rsp_error(g_rsp_error),.rsp_tag(),.busy()
    );
    // All frame, dark, transmission and histogram reads are synchronous.
    // No frame-array asynchronous read and no reset loop on frame memories.
    always @(posedge clk) begin
        if(rst_n && clk_en) begin
            if(input_fire) rgb_mem[count[ADDR_W-1:0]]<=s_data;
            if(state==D_CENTER_REQ || state==D_REQ || state==A_REQ ||
               state==N_REQ || state==G_REQ || state==R_REQ)
                rgb_q<=rgb_mem[rgb_read_index[ADDR_W-1:0]];
            if(state==A_REQ) dark_q<=dark_mem[index[ADDR_W-1:0]];
            if(state==D_STORE) dark_mem[index[ADDR_W-1:0]]<=dark_min;
            if(state==H_CLEAR) hist_mem[hist_bin]<=0;
            if(hist_read_en) hist_q<=hist_mem[hist_read_addr];
            if(state==H_WRITE) hist_mem[dark_min]<=hist_q+1'b1;
            if(state==N_STORE) t_mem[index[ADDR_W-1:0]]<=transmission_q;
            if(state==G_REQ || state==R_REQ) t_q<=t_mem[index[ADDR_W-1:0]];
            if(g_m_valid && g_m_ready) t_mem[guided_write_index[ADDR_W-1:0]]<=g_m_q;
        end
    end
    always @(posedge clk or negedge rst_n) begin
        if(!rst_n) begin
            state<=IDLE;width<=0;height<=0;px<=0;py<=0;total<=0;count<=0;index<=0;
            dark_radius<=0;guided_radius<=0;dx<=0;dy<=0;omega<=0;t0<=1;
            guided_epsilon<=1;auto_airlight<=0;guided_enable<=0;frame_error<=0;
            tag<=0;airlight<=24'hffffff;airlight_candidate<=0;center_rgb<=0;
            best_rgb_sum<=0;dark_min<=255;hist_bin<=0;airlight_threshold<=0;
            norm_min<=0;top_count<=1;hist_acc<=0;guided_write_index<=0;
            m_data<=0;m_valid<=0;m_sof<=0;m_eol<=0;m_eof<=0;
            rsp_valid<=0;rsp_error<=0;
            channel_index<=0;normalized_pixel<=0;transmission_q<=0;
            restored_rgb<=0;math_numerator<=0;math_denominator<=1;
        end else if(clk_en) begin
            if(g_m_valid && g_m_ready) guided_write_index<=guided_write_index+1'b1;
            case(state)
                IDLE: if(cmd_valid && cmd_ready) begin
                    tag<=cmd_tag;rsp_error<=0;
                    if(!PARAM_OK || cmd_width==0 || cmd_width>MAX_WIDTH ||
                       cmd_height==0 || cmd_height>MAX_HEIGHT ||
                       cmd_dark_radius>MAX_RADIUS || cmd_omega>32768 ||
                       cmd_t0==0 || cmd_t0>32768 ||
                       (cmd_auto_airlight && (cmd_airlight_permille==0 ||
                                              cmd_airlight_permille>1000)) ||
                       (cmd_guided_enable && (cmd_guided_radius>MAX_RADIUS ||
                          cmd_guided_epsilon==0 || cmd_guided_epsilon>65535))) begin
                        rsp_valid<=1;rsp_error<=1;state<=RESPONSE;
                    end else begin
                        width<=cmd_width;height<=cmd_height;
                        total<=32'd1*cmd_width*cmd_height;count<=0;index<=0;px<=0;py<=0;
                        dark_radius<=cmd_dark_radius;omega<=cmd_omega;t0<=cmd_t0;
                        guided_radius<=cmd_guided_radius;guided_epsilon<=cmd_guided_epsilon;
                        guided_enable<=cmd_guided_enable;auto_airlight<=cmd_auto_airlight;
                        airlight<=safe_airlight(cmd_airlight_rgb);
                        top_count<=(32'd1*cmd_width*cmd_height*cmd_airlight_permille+999)/1000;
                        frame_error<=0;state<=CAPTURE;
                    end
                end
                CAPTURE: if(input_fire) begin
                    if(s_sof !== (count==0) || s_eol !== (px==width-1)) frame_error<=1;
                    if(count==total-1) begin
                        px<=0;py<=0;index<=0;hist_bin<=0;
                        state<=auto_airlight?H_CLEAR:N_INIT;
                    end else begin
                        count<=count+1'b1;
                        if(px==width-1) begin px<=0;py<=py+1'b1;end
                        else px<=px+1'b1;
                    end
                end
                H_CLEAR: if(hist_bin==255) state<=D_CENTER_REQ;
                    else hist_bin<=hist_bin+1'b1;
                D_CENTER_REQ: state<=D_CENTER_CAP;
                D_CENTER_CAP: begin center_rgb<=rgb_q;state<=D_INIT;end
                D_INIT: begin
                    dark_min<=255;dx<=-$signed({1'b0,dark_radius});
                    dy<=-$signed({1'b0,dark_radius});state<=D_REQ;
                end
                D_REQ: state<=D_ACC;
                D_ACC: begin
                    if(pixel_min<dark_min) dark_min<=pixel_min;
                    if(last_neighbor) state<=D_STORE;
                    else begin
                        if(dx==$signed({1'b0,dark_radius})) begin
                            dx<=-$signed({1'b0,dark_radius});dy<=dy+1'b1;
                        end else dx<=dx+1'b1;
                        state<=D_REQ;
                    end
                end
                D_STORE: state<=H_READ;
                H_READ: state<=H_WRITE;
                H_WRITE: begin
                    if(index==total-1) begin hist_bin<=255;hist_acc<=0;state<=THRESH_REQ;end
                    else begin
                        index<=index+1'b1;
                        if(px==width-1) begin px<=0;py<=py+1'b1;end else px<=px+1'b1;
                        state<=D_CENTER_REQ;
                    end
                end
                THRESH_REQ: state<=THRESH_ACC;
                THRESH_ACC: begin
                    if(hist_sum>=top_count || hist_bin==0) begin
                        airlight_threshold<=hist_bin;best_rgb_sum<=0;airlight_candidate<=0;
                        index<=0;px<=0;py<=0;state<=A_REQ;
                    end else begin hist_acc<=hist_sum[HIST_COUNT_W-1:0];hist_bin<=hist_bin-1'b1;state<=THRESH_REQ;end
                end
                A_REQ: state<=A_CAP;
                A_CAP: begin
                    if(dark_q>=airlight_threshold && rgb_sum>=best_rgb_sum) begin
                        best_rgb_sum<=rgb_sum;airlight_candidate<=rgb_q;
                    end
                    if(index==total-1) state<=A_FINAL;
                    else begin index<=index+1'b1;state<=A_REQ;end
                end
                A_FINAL: begin
                    airlight<=safe_airlight(airlight_candidate);
                    index<=0;px<=0;py<=0;state<=N_INIT;
                end
                N_INIT: begin
                    norm_min<=32'hffffffff;dx<=-$signed({1'b0,dark_radius});
                    dy<=-$signed({1'b0,dark_radius});state<=N_REQ;
                end
                N_REQ: state<=N_ACC;
                N_ACC: begin
                    channel_index<=0;normalized_pixel<=32'hffffffff;
                    state<=N_DIV_PREP;
                end
                N_DIV_PREP: begin
                    // Disjoint fields: (c<<15)+(a>>1), no truncation/round change.
                    math_numerator<={41'd0,math_c,8'd0,math_a[7:1]};
                    math_denominator<={56'd0,math_a};state<=N_DIV_START;
                end
                N_DIV_START: state<=N_DIV_WAIT;
                N_DIV_WAIT: if(math_done) begin
                    if(math_quotient<normalized_pixel)normalized_pixel<=math_quotient[31:0];
                    if(channel_index==2)state<=N_COMPARE;
                    else begin channel_index<=channel_index+1'b1;state<=N_DIV_PREP;end
                end
                N_COMPARE: begin
                    if(normalized_pixel<norm_min)norm_min<=normalized_pixel;
                    if(last_neighbor)state<=N_MUL_START;
                    else begin
                        if(dx==$signed({1'b0,dark_radius})) begin
                            dx<=-$signed({1'b0,dark_radius});dy<=dy+1'b1;
                        end else dx<=dx+1'b1;
                        state<=N_REQ;
                    end
                end
                N_MUL_START: state<=N_MUL_WAIT;
                N_MUL_WAIT: if(mul_done) begin
                    transmission_q<=(|rounded_penalty[63:30])?16'd0:
                        16'd32768-{1'b0,rounded_penalty[29:15]};
                    state<=N_STORE;
                end
                N_STORE: begin
                    if(index==total-1) begin
                        index<=0;px<=0;py<=0;guided_write_index<=0;
                        state<=guided_enable?G_CMD:R_REQ;
                    end else begin
                        index<=index+1'b1;
                        if(px==width-1) begin px<=0;py<=py+1'b1;end else px<=px+1'b1;
                        state<=N_INIT;
                    end
                end
                G_CMD: if(g_cmd_ready) state<=G_REQ;
                G_REQ: state<=G_CAP;
                G_CAP: state<=G_SEND;
                G_SEND: if(g_s_ready) begin
                    if(index==total-1) state<=G_WAIT;
                    else begin
                        index<=index+1'b1;
                        if(px==width-1) begin px<=0;py<=py+1'b1;end else px<=px+1'b1;
                        state<=G_REQ;
                    end
                end
                G_WAIT: if(g_rsp_valid) begin
                    if(g_rsp_error!=0 || guided_write_index!=total) begin
                        rsp_error<=3;rsp_valid<=1;state<=RESPONSE;
                    end else begin index<=0;px<=0;py<=0;state<=R_REQ;end
                end
                R_REQ: state<=R_CAP;
                R_CAP: begin channel_index<=0;restored_rgb<=0;state<=R_DIV_PREP;end
                R_DIV_PREP: begin
                    math_numerator<={{40{math_delta[8]}},math_delta,15'd0};
                    math_denominator<={48'd0,((t_q<t0)?t0:t_q)};
                    state<=R_DIV_START;
                end
                R_DIV_START: state<=R_DIV_WAIT;
                R_DIV_WAIT: if(math_done) begin
                    case(channel_index)
                        0:restored_rgb[23:16]<=restored_channel;
                        1:restored_rgb[15:8]<=restored_channel;
                        2:restored_rgb[7:0]<=restored_channel;
                    endcase
                    if(channel_index==2)state<=R_FINAL;
                    else begin channel_index<=channel_index+1'b1;state<=R_DIV_PREP;end
                end
                R_FINAL: begin
                    m_data<=restored_rgb;
                    m_sof<=index==0;m_eol<=px==width-1;m_eof<=index==total-1;
                    m_valid<=1;state<=R_EMIT;
                end
                R_EMIT: if(m_valid && m_ready) begin
                    m_valid<=0;
                    if(index==total-1) begin
                        rsp_valid<=1;rsp_error<=frame_error?4'd2:4'd0;state<=RESPONSE;
                    end else begin
                        index<=index+1'b1;
                        if(px==width-1) begin px<=0;py<=py+1'b1;end else px<=px+1'b1;
                        state<=R_REQ;
                    end
                end
                RESPONSE: if(rsp_valid && rsp_ready) begin rsp_valid<=0;state<=IDLE;end
                default: begin m_valid<=0;rsp_error<=3;rsp_valid<=1;state<=RESPONSE;end
            endcase
        end
    end
endmodule
