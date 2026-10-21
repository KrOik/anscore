// One clock domain. Configuration changes only between accepted frames.
// Frame end must be the final accepted pixel, not EOL. No pixel buffering.
module frame_atomic_config #(parameter WORDS=4, DATA_W=24)(
 input wire clk,rst_n,
 input wire write_valid,output wire write_ready,
 input wire [$clog2(WORDS)-1:0] write_index,
 input wire [31:0] write_data,input wire [3:0] write_strb,
 input wire commit_valid,output wire commit_ready,
 output wire [WORDS*32-1:0] active,output wire [31:0] version,
 output wire pending,
 input wire s_valid,output wire s_ready,input wire [DATA_W-1:0] s_data,
 input wire s_sof,s_last,
 output wire m_valid,input wire m_ready,output wire [DATA_W-1:0] m_data,
 output wire m_sof,m_last,output reg in_frame,output reg framing_error
);
reg head_locked;
wire safe = !in_frame && !head_locked;
wire hold_boundary = safe && (pending || commit_valid);
assign m_valid = rst_n && s_valid && !hold_boundary;
assign s_ready = rst_n && m_ready && !hold_boundary;
assign m_data=s_data;
assign m_sof=s_sof;
assign m_last=s_last;
sys_atomic_config #(.WORDS(WORDS)) config_bank(
 .clk(clk),.rst_n(rst_n),.write_valid(write_valid),.write_ready(write_ready),
 .write_index(write_index),.write_data(write_data),.write_strb(write_strb),
 .commit_valid(commit_valid),.commit_ready(commit_ready),.apply_safe(safe),
 .active(active),.version(version),.pending(pending));
always @(posedge clk or negedge rst_n) begin
 if(!rst_n) begin in_frame<=0;framing_error<=0;head_locked<=0;end
 else begin
  if(m_valid&&!m_ready) head_locked<=1;
  if(m_valid&&m_ready) begin
  head_locked<=0;
  if((!in_frame&&!s_sof)||(in_frame&&s_sof)) framing_error<=1;
  // A malformed frame is still owned until LAST, preventing mid-frame apply.
  in_frame<=!s_last;
  end
 end
end
endmodule
