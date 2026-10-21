// Multiple entropy blocks with restart alignment. Input codes already Huffman encoded.
module jpeg_entropy_scan_controller(
 input wire clk,rst,ce,
 input wire start_valid,output wire start_ready,input wire[31:0] cfg_total_blocks,cfg_restart_interval,input wire abort,
 input wire[15:0] s_code,s_amplitude,input wire[4:0] s_code_bits,s_amplitude_bits,
 input wire s_block_end,s_scan_last,s_valid,output wire s_ready,
 output wire[7:0] m_data,output wire m_valid,input wire m_ready,output wire m_marker,m_scan_last,
 output wire predictor_reset_valid,input wire predictor_reset_ready,
 output wire scan_done,input wire scan_done_ready,output reg[3:0] error_code,output wire busy,
 output reg[31:0] blocks_completed,restarts_emitted
);
 localparam IDLE=0,RESET_PRED=1,RUN=2,FLUSH=3,MARK_FF=4,MARK_ID=5,DONE=6,CLEAR=7;
 reg[2:0] state;
 reg[31:0] total,interval,since_restart;
 reg[2:0] restart_index;
 reg final_flush;
 wire p_ready,p_valid,p_last,p_error,p_done;wire[7:0] p_data;wire[6:0] p_pending;
 wire final_block=s_block_end&&blocks_completed==total-1;
 wire restart_block=s_block_end&&interval!=0&&since_restart==interval-1&&!final_block;
 wire bad=s_code_bits==0||s_code_bits>16||s_amplitude_bits>11||(s_code>>s_code_bits)!=0||(s_amplitude>>s_amplitude_bits)!=0||s_scan_last!=final_block;
 wire accepted=s_valid&&s_ready;
 wire cancel=abort&&ce;
 assign start_ready=ce&&!rst&&state==IDLE&&!cancel;
 assign s_ready=ce&&!rst&&state==RUN&&p_ready&&!cancel;
 assign predictor_reset_valid=!rst&&state==RESET_PRED&&!cancel;
 assign scan_done=!rst&&state==DONE;
 assign busy=state!=IDLE;
 assign m_marker=(state==MARK_FF||state==MARK_ID);
 assign m_valid=!rst&&!cancel&&((m_marker)||((state==RUN||state==FLUSH)&&p_valid));
 assign m_data=(state==MARK_FF)?8'hff:(state==MARK_ID)?(8'hd0|{5'd0,restart_index}):p_data;
 assign m_scan_last=m_valid&&!m_marker&&final_flush&&p_last;
 wire p_rst_n=!(rst||state==IDLE||state==CLEAR);
 jpeg_entropy_bitpacker packer(
 .clk(clk),.rst_n(p_rst_n),.ce(ce),.s_code(s_code),.s_amplitude(s_amplitude),.s_code_bits(s_code_bits),.s_amplitude_bits(s_amplitude_bits),
 .s_flush(final_block||restart_block),.s_valid(state==RUN&&s_valid&&!bad&&!cancel),.s_ready(p_ready),
 .m_data(p_data),.m_valid(p_valid),.m_last(p_last),.m_ready(m_ready&&(state==RUN||state==FLUSH)&&!cancel),
 .input_error(p_error),.flush_done(p_done),.pending_bits(p_pending));
 always @(posedge clk) begin
 if(rst) begin state<=IDLE;total<=0;interval<=0;since_restart<=0;restart_index<=0;final_flush<=0;error_code<=0;blocks_completed<=0;restarts_emitted<=0;end
 else if(ce) begin
 if(abort&&state!=IDLE&&state!=DONE&&state!=CLEAR) begin error_code<=4;state<=CLEAR;end
 else if(p_error&&state!=IDLE&&state!=DONE&&state!=CLEAR) begin error_code<=3;state<=CLEAR;end
 else case(state)
 IDLE: if(start_valid&&start_ready) begin
 error_code<=0;blocks_completed<=0;restarts_emitted<=0;since_restart<=0;restart_index<=0;final_flush<=0;
 if(cfg_total_blocks==0) begin error_code<=1;state<=CLEAR;end
 else begin total<=cfg_total_blocks;interval<=cfg_restart_interval;state<=RESET_PRED;end
 end
 RESET_PRED: if(predictor_reset_ready) state<=RUN;
 RUN: if(accepted) begin
 if(bad) begin error_code<=2;state<=CLEAR;end
 else if(s_block_end) begin
 blocks_completed<=blocks_completed+1'b1;since_restart<=since_restart+1'b1;
 if(final_block||restart_block) begin final_flush<=final_block;state<=FLUSH;end
 end
 end
 FLUSH: if(p_done) begin if(final_flush)state<=DONE;else state<=MARK_FF;end
 MARK_FF: if(m_ready) state<=MARK_ID;
 MARK_ID: if(m_ready) begin restart_index<=restart_index+1'b1;since_restart<=0;restarts_emitted<=restarts_emitted+1'b1;state<=RESET_PRED;end
 CLEAR: state<=DONE;
 DONE: if(scan_done_ready)state<=IDLE;
 default: state<=CLEAR;
 endcase
 end
 end
endmodule
