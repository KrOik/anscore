// Fixed-frame OSD/difference/background/fusion application. Shared CE protocol.
// Capture both sources before processing; bank 1 is Q8.8 when used as background.
module img_mf_frame_application #(
    parameter WIDTH=32, HEIGHT=24, TAG_WIDTH=16, FRAME_WIDTH=16,
    parameter CAPTURE_TIMEOUT=65536
)(
    input wire clk,rst_n,clk_en,
    input wire cmd_valid,output wire cmd_ready,input wire [3:0] cmd_opcode,
    input wire [FRAME_WIDTH-1:0] cmd_frameid,
    input wire [8:0] cfg_weight,input wire cfg_key_enable,input wire [23:0] cfg_key,
    input wire [7:0] cfg_threshold,input wire [3:0] cfg_bg_shift,input wire cfg_bg_freeze,
    output reg rsp_valid,input wire rsp_ready,output wire rsp_done,
    output reg [3:0] rsp_opcode,output reg [FRAME_WIDTH-1:0] rsp_frameid,
    output reg [7:0] rsp_error,output reg [7:0] error_code,
    input wire s_valid,output wire s_ready,input wire [23:0] s_data,
    input wire s_sof,s_eol,input wire [TAG_WIDTH-1:0] s_tag,input wire [FRAME_WIDTH-1:0] s_frameid,
    input wire aux_valid,output wire aux_ready,input wire [23:0] aux_data,
    input wire aux_sof,aux_eol,input wire [TAG_WIDTH-1:0] aux_tag,input wire [FRAME_WIDTH-1:0] aux_frameid,
    output wire m_valid,input wire m_ready,output wire [23:0] m_data,
    output wire m_foreground,m_sof,m_eol,output wire [TAG_WIDTH-1:0] m_tag,
    output wire [FRAME_WIDTH-1:0] m_frameid,output wire [7:0] m_error,
    output wire [1:0] frames_valid
);
    localparam PIXELS=WIDTH*HEIGHT;
    localparam IDLE=0,CONFIGURE=1,DISPATCH=2,WAIT_STORE=3,PROCESS=4;
    reg [2:0] state;
    reg [3:0] store_opcode;
    reg [1:0] mode;
    reg [FRAME_WIDTH-1:0] target_frame;
    reg [8:0] weight;
    reg key_enable,bg_freeze;
    reg [23:0] key;
    reg [7:0] threshold,operation_error;
    reg [3:0] bg_shift;
    reg [31:0] output_count,writeback_count;
    reg store_finished;
    wire store_cmd_ready,store_rsp_valid,store_rsp_done;
    wire [3:0] store_rsp_opcode;
    wire [FRAME_WIDTH-1:0] store_rsp_frameid;
    wire [7:0] store_rsp_error,store_error;
    wire replay_valid,replay_ready,replay_sof,replay_eol,replay_pair;
    wire [23:0] replay_data,replay_aux;
    wire [TAG_WIDTH-1:0] replay_tag;
    wire [FRAME_WIDTH-1:0] replay_frame;
    wire [7:0] replay_error;
    wire wb_valid,wb_ready,wb_enable,wr_ready;
    wire [15:0] wb_data;
    wire [TAG_WIDTH-1:0] wb_tag;
    wire [7:0] wb_error;
    wire [31:0] writeback_address=wb_tag;
    assign cmd_ready=rst_n && clk_en && state==IDLE && !rsp_valid;
    assign rsp_done=rsp_valid;
    wire proc_active=state==PROCESS;
    assign wb_ready=proc_active && wr_ready;
    img_mf_dual_frame_store #(.WIDTH(WIDTH),.HEIGHT(HEIGHT),.TAG_WIDTH(TAG_WIDTH),
        .FRAME_WIDTH(FRAME_WIDTH),.CAPTURE_TIMEOUT(CAPTURE_TIMEOUT)) store_i (
        .clk(clk),.rst_n(rst_n),.clk_en(clk_en),
        .cmd_valid(state==DISPATCH),.cmd_ready(store_cmd_ready),.cmd_opcode(store_opcode),.cmd_frameid(target_frame),
        .rsp_valid(store_rsp_valid),.rsp_ready(state==WAIT_STORE || proc_active),.rsp_done(store_rsp_done),
        .rsp_opcode(store_rsp_opcode),.rsp_frameid(store_rsp_frameid),.rsp_error(store_rsp_error),.error_code(store_error),
        .s_valid(s_valid),.s_ready(s_ready),.s_data(s_data),.s_sof(s_sof),.s_eol(s_eol),.s_tag(s_tag),.s_frameid(s_frameid),
        .aux_valid(aux_valid),.aux_ready(aux_ready),.aux_data(aux_data),.aux_sof(aux_sof),.aux_eol(aux_eol),.aux_tag(aux_tag),.aux_frameid(aux_frameid),
        .m_valid(replay_valid),.m_ready(replay_ready),.m_data(replay_data),.m_aux_data(replay_aux),.m_pair(replay_pair),
        .m_sof(replay_sof),.m_eol(replay_eol),.m_tag(replay_tag),.m_frameid(replay_frame),.m_error(replay_error),.frames_valid(frames_valid),
        .rd_valid(1'b0),.rd_ready(),.rd_addr0(32'd0),.rd_addr1(32'd0),.rd_rsp_valid(),.rd_rsp_ready(1'b1),.rd_data0(),.rd_data1(),.rd_error(),
        .wr_valid(proc_active && wb_valid && wb_enable && mode==2),.wr_ready(wr_ready),.wr_bank(1'b1),
        .wr_addr(writeback_address),.wr_data({8'd0,wb_data})
    );
    img_mf_processing_bank #(.TAG_WIDTH(TAG_WIDTH),.FRAME_WIDTH(FRAME_WIDTH)) processing_i (
        .clk(clk),.rst_n(rst_n),.clk_en(clk_en),.mode(mode),.cfg_pulse(state==CONFIGURE),
        .cfg_weight(weight),.cfg_key_enable(key_enable),.cfg_key(key),.cfg_threshold(threshold),.cfg_bg_shift(bg_shift),.cfg_bg_freeze(bg_freeze),
        .s_valid(replay_valid && proc_active),.s_ready(replay_ready),.s_data(replay_data),.aux_data(replay_aux),
        .s_sof(replay_sof),.s_eol(replay_eol),.s_tag(replay_tag),.s_frameid(replay_frame),
        .m_valid(m_valid),.m_ready(m_ready && proc_active),.m_data(m_data),.m_foreground(m_foreground),
        .m_sof(m_sof),.m_eol(m_eol),.m_tag(m_tag),.m_frameid(m_frameid),.m_error(m_error),
        .wb_valid(wb_valid),.wb_ready(wb_ready),.wb_data(wb_data),.wb_enable(wb_enable),.wb_tag(wb_tag),.wb_error(wb_error)
    );
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state<=IDLE; store_opcode<=0; mode<=0; target_frame<=0; weight<=128;
            key_enable<=0; key<=0; threshold<=16; bg_shift<=4; bg_freeze<=1;
            rsp_valid<=0; rsp_opcode<=0; rsp_frameid<=0; rsp_error<=0; error_code<=0;
            operation_error<=0; output_count<=0; writeback_count<=0; store_finished<=0;
        end else if (clk_en) begin
            if (rsp_valid && rsp_ready) rsp_valid<=0;
            if (proc_active && m_valid && m_ready) begin
                output_count<=output_count+1; operation_error<=operation_error|m_error;
                error_code<=error_code|m_error;
            end
            if (proc_active && wb_valid && wb_ready) begin
                writeback_count<=writeback_count+1;
                if (wb_error!=0) begin operation_error<=operation_error|wb_error; error_code<=error_code|wb_error; end
            end
            case (state)
                IDLE: if (cmd_valid && cmd_ready) begin
                    rsp_opcode<=cmd_opcode; rsp_frameid<=cmd_frameid; target_frame<=cmd_frameid;
                    rsp_error<=0; operation_error<=0; output_count<=0; writeback_count<=0; store_finished<=0;
                    weight<=cfg_weight; key_enable<=cfg_key_enable; key<=cfg_key;
                    threshold<=cfg_threshold; bg_shift<=cfg_bg_shift; bg_freeze<=cfg_bg_freeze;
                    if (cmd_opcode<=2 || cmd_opcode==7 || cmd_opcode==8) begin
                        store_opcode<=(cmd_opcode==7)?4'd6:((cmd_opcode==8)?4'd7:cmd_opcode); state<=DISPATCH;
                    end else if (cmd_opcode>=3 && cmd_opcode<=6) begin
                        mode<=cmd_opcode-3; store_opcode<=3;
                        if (((cmd_opcode==3 || cmd_opcode==6) && cfg_weight>256) ||
                            (cmd_opcode==5 && cfg_bg_shift>8)) begin
                            rsp_valid<=1; rsp_error<=8'h08; error_code<=error_code|8'h08;
                        end else if (frames_valid!=3) begin
                            rsp_valid<=1; rsp_error<=8'h04; error_code<=error_code|8'h04;
                        end else state<=CONFIGURE;
                    end else begin rsp_valid<=1; rsp_error<=8'h80; error_code<=error_code|8'h80; end
                end
                CONFIGURE: state<=DISPATCH;
                DISPATCH: if (store_cmd_ready) state<=(rsp_opcode>=3 && rsp_opcode<=6)?PROCESS:WAIT_STORE;
                WAIT_STORE: if (store_rsp_valid) begin
                    rsp_valid<=1; rsp_error<=store_rsp_error; error_code<=error_code|store_rsp_error; state<=IDLE;
                end
                PROCESS: begin
                    if (store_rsp_valid) begin
                        store_finished<=1;
                        if (store_rsp_error!=0) begin
                            rsp_valid<=1; rsp_error<=store_rsp_error; error_code<=error_code|store_rsp_error; state<=IDLE;
                        end
                    end
                    // Completion is fenced behind both the image and background sinks.
                    if (store_finished && output_count==PIXELS && (mode!=2 || writeback_count==PIXELS)) begin
                        rsp_valid<=1; rsp_error<=operation_error; error_code<=error_code|operation_error; state<=IDLE;
                    end
                end
                default: begin state<=IDLE; rsp_valid<=1; rsp_error<=8'h40; error_code<=error_code|8'h40; end
            endcase
        end
    end
endmodule
