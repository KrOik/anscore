// Same-frame GRAY8 Otsu thresholding. Capture -> histogram -> exact solver -> replay.
// Binary output is (pixel > threshold) XOR start_invert. All memories synchronous.
module img_hist_otsu_frame #(
    parameter integer FRAME_WIDTH=32,FRAME_HEIGHT=24,COUNT_WIDTH=16,TAG_WIDTH=16
)(
    input wire clk,rst_n,clk_en,
    input wire start_valid,
    output wire start_ready,
    input wire [TAG_WIDTH-1:0] start_tag,
    input wire start_invert,
    input wire s_valid,
    output wire s_ready,
    input wire [7:0] s_gray,
    input wire s_sof,s_eol,
    output wire m_valid,
    input wire m_ready,
    output reg [7:0] m_gray,
    output wire m_sof,m_eol,m_last,
    output wire [TAG_WIDTH-1:0] m_tag,
    output reg done_valid,
    input wire done_ready,
    output reg done_error,
    output reg [7:0] done_error_code,done_threshold,
    output reg [COUNT_WIDTH-1:0] done_count,
    output reg [TAG_WIDTH-1:0] done_tag,
    output wire busy
);
localparam DIMS_OK=FRAME_WIDTH>0 && FRAME_WIDTH<=512 && FRAME_HEIGHT>0 && FRAME_HEIGHT<=512;
localparam DEPTH=DIMS_OK?FRAME_WIDTH*FRAME_HEIGHT:1;
localparam AW=DEPTH>1?$clog2(DEPTH):1;
localparam PARAM_OK=DIMS_OK && COUNT_WIDTH>=1 && COUNT_WIDTH<=24 &&
                    (64'd1*DEPTH)<=((64'd1<<COUNT_WIDTH)-1);
localparam IDLE=0,START_HIST=1,CAPTURE=2,WAIT_HIST=3,START_SOLVE=4,
           READ_HIST=5,WAIT_BIN=6,WAIT_SOLVE=7,REPLAY_READ=8,MAP=9,OUTPUT_HOLD=10,RESPONSE=11;
reg [3:0] state;
reg [AW-1:0] write_index,read_index;
reg [31:0] output_x;
reg [7:0] bin_index;
reg [TAG_WIDTH-1:0] frame_tag;
reg invert,abort_solver;
reg [7:0] frame[0:DEPTH-1];
reg [7:0] frame_q;
wire hist_start_ready,hist_s_ready,hist_done_valid,hist_done_error;
wire [7:0] hist_error_code;
wire [COUNT_WIDTH-1:0] hist_done_count;
wire [TAG_WIDTH-1:0] hist_done_tag;
wire hist_req_ready,hist_rsp_valid,hist_rsp_error;
wire [COUNT_WIDTH-1:0] hist_rsp_count;
wire solver_ready,solver_s_ready,solver_rsp_valid;
wire [7:0] solver_threshold;
wire [1:0] solver_error;
wire input_fire=s_valid && s_ready;
wire binary_value=(frame_q>done_threshold)^invert;
assign start_ready=rst_n && state==IDLE;
assign s_ready=rst_n && state==CAPTURE && hist_s_ready;
assign m_valid=rst_n && state==OUTPUT_HOLD;
assign m_sof=m_valid && read_index==0;
assign m_eol=m_valid && output_x==FRAME_WIDTH-1;
assign m_last=m_valid && read_index==DEPTH-1;
assign m_tag=frame_tag;
assign busy=state!=IDLE;
always @(posedge clk) if(clk_en) begin
    if(input_fire) frame[write_index]<=s_gray;
    if(state==REPLAY_READ) frame_q<=frame[read_index];
end
img_hist_accumulator #(.FRAME_WIDTH(FRAME_WIDTH),.FRAME_HEIGHT(FRAME_HEIGHT),
    .COUNT_WIDTH(COUNT_WIDTH),.TAG_WIDTH(TAG_WIDTH)) histogram(
    .clk(clk),.rst_n(rst_n),.clk_en(clk_en),
    .start_valid(state==START_HIST),.start_ready(hist_start_ready),.start_tag(frame_tag),
    .s_valid(s_valid && state==CAPTURE),.s_ready(hist_s_ready),.s_gray(s_gray),.s_sof(s_sof),.s_eol(s_eol),
    .done_valid(hist_done_valid),.done_ready(state==WAIT_HIST),.done_error(hist_done_error),
    .done_error_code(hist_error_code),.done_count(hist_done_count),.done_tag(hist_done_tag),
    .rd_req_valid(state==READ_HIST),.rd_req_ready(hist_req_ready),.rd_req_bin(bin_index),
    .rd_rsp_valid(hist_rsp_valid),.rd_rsp_ready(state==WAIT_BIN && solver_s_ready),
    .rd_rsp_bin(),.rd_rsp_count(hist_rsp_count),.rd_rsp_tag(),.rd_rsp_error(hist_rsp_error),.busy());
img_hist_otsu_threshold #(.COUNT_W(COUNT_WIDTH)) solver(
    .clk(clk),.rst_n(rst_n && !abort_solver),.clk_en(clk_en),
    .cmd_valid(state==START_SOLVE),.cmd_ready(solver_ready),
    .s_count(hist_rsp_count),.s_valid(state==WAIT_BIN && hist_rsp_valid && !hist_rsp_error),
    .s_ready(solver_s_ready),.rsp_valid(solver_rsp_valid),.rsp_ready(state==WAIT_SOLVE),
    .rsp_threshold(solver_threshold),.rsp_error(solver_error));
always @(posedge clk or negedge rst_n) begin
    if(!rst_n) begin
        state<=IDLE;write_index<=0;read_index<=0;output_x<=0;bin_index<=0;frame_tag<=0;
        invert<=0;abort_solver<=0;m_gray<=0;done_valid<=0;done_error<=0;done_error_code<=0;
        done_threshold<=0;done_count<=0;done_tag<=0;
    end else if(clk_en) begin
        abort_solver<=0;
        case(state)
        IDLE:if(start_valid && start_ready) begin
            frame_tag<=start_tag;done_tag<=start_tag;invert<=start_invert;
            write_index<=0;read_index<=0;output_x<=0;bin_index<=0;
            done_count<=0;done_threshold<=0;done_error<=0;done_error_code<=0;
            if(!PARAM_OK) begin done_valid<=1;done_error<=1;done_error_code<=1;state<=RESPONSE;end
            else state<=START_HIST;
        end
        START_HIST:if(hist_start_ready) state<=CAPTURE;
        CAPTURE:if(input_fire) begin
            if(write_index==DEPTH-1) state<=WAIT_HIST;
            else write_index<=write_index+1'b1;
        end
        WAIT_HIST:if(hist_done_valid) begin
            done_count<=hist_done_count;
            if(hist_done_error || hist_done_tag!=frame_tag) begin
                done_valid<=1;done_error<=1;done_error_code<=hist_done_error?hist_error_code:8'h10;state<=RESPONSE;
            end else state<=START_SOLVE;
        end
        START_SOLVE:if(solver_ready) state<=READ_HIST;
        READ_HIST:if(hist_req_ready) state<=WAIT_BIN;
        WAIT_BIN:if(hist_rsp_valid && solver_s_ready) begin
            if(hist_rsp_error) begin
                abort_solver<=1;done_valid<=1;done_error<=1;done_error_code<=8'h10;state<=RESPONSE;
            end else if(bin_index==255) state<=WAIT_SOLVE;
            else begin bin_index<=bin_index+1'b1;state<=READ_HIST;end
        end
        WAIT_SOLVE:if(solver_rsp_valid) begin
            done_threshold<=solver_threshold;
            if(solver_error!=0) begin done_valid<=1;done_error<=1;done_error_code<=8'h08;state<=RESPONSE;end
            else state<=REPLAY_READ;
        end
        REPLAY_READ:state<=MAP;
        MAP:begin m_gray<=binary_value?8'hff:8'h00;state<=OUTPUT_HOLD;end
        OUTPUT_HOLD:if(m_ready) begin
            if(read_index==DEPTH-1) begin done_valid<=1;done_error<=0;done_error_code<=0;state<=RESPONSE;end
            else begin
                read_index<=read_index+1'b1;
                if(output_x==FRAME_WIDTH-1) output_x<=0;else output_x<=output_x+1;
                state<=REPLAY_READ;
            end
        end
        RESPONSE:if(done_ready) begin done_valid<=0;state<=IDLE;end
        default:state<=IDLE;
        endcase
    end
end
endmodule
