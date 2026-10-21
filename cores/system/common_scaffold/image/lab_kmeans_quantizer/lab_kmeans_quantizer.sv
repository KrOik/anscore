// Complete RGB -> encoded D65 Lab -> K-means -> RGB frame quantization.
// A single Lab converter is reused for both full-frame passes.
module lab_kmeans_quantizer #(
 parameter WIDTH=16,HEIGHT=16,
 parameter DECODE_FILE="decode.mem",NONLINEAR_FILE="nonlinear.mem"
)(
 input wire clk,rst_n,ce,
 input wire start_valid,output wire start_ready,input wire abort,
 input wire[2:0] cfg_k,input wire[7:0] cfg_max_iterations,cfg_tolerance,
 input wire[31:0] cfg_seed,
 input wire[23:0] s_rgb,input wire s_valid,s_sof,s_eol,output wire s_ready,
 output wire[23:0] m_rgb,output wire[1:0] m_label,
 output wire m_valid,m_sof,m_eol,m_last,input wire m_ready,
 output wire[95:0] initial_centers_lab,final_centers_lab,
 output wire[43:0] cluster_counts,output wire[31:0] inertia,
 output wire[7:0] iterations,output wire converged,
 output wire done_valid,input wire done_ready,output wire done_error,
 output reg[7:0] error_code,output wire busy
);
 localparam IDLE=0,FORWARD=1,ACK_FORWARD=2,START_INVERSE=3,
            INVERSE=4,COMPLETE=5,FAILED=6;
 localparam N=WIDTH*HEIGHT;
 reg[2:0] state;
 reg[1:0] label_hold;
 reg[15:0] output_index;
 wire child_reset=!rst_n||state==FAILED;
 wire lab_start_ready,lab_s_ready,lab_m_valid,lab_m_sof,lab_m_eol;
 wire[23:0] lab_m_data;
 wire lab_done,lab_error;wire[3:0] lab_code;
 wire k_start_ready,k_s_ready,k_m_valid,k_m_sof,k_m_eol,k_m_last;
 wire[23:0] k_m_data;wire[1:0] k_label;
 wire k_done,k_error;wire[3:0] k_code;
 wire initial_start=start_valid&&start_ready;
 wire finish_pair=state==INVERSE&&lab_done&&k_done&&!lab_error&&!k_error&&!abort;
 assign start_ready=rst_n&&ce&&state==IDLE&&lab_start_ready&&k_start_ready&&!abort;
 rgb_cielab_stream #(.WIDTH(WIDTH),.HEIGHT(HEIGHT),
  .DECODE_FILE(DECODE_FILE),.NONLINEAR_FILE(NONLINEAR_FILE)) color(
  .clk(clk),.rst(child_reset),.ce(ce),
  .start_valid(initial_start||state==START_INVERSE),.start_ready(lab_start_ready),
  .cfg_inverse(state==START_INVERSE||state==INVERSE),
  .s_data(state==INVERSE?k_m_data:s_rgb),
  .s_valid((state==FORWARD&&s_valid)||(state==INVERSE&&k_m_valid)),
  .s_sof(state==INVERSE?k_m_sof:s_sof),.s_eol(state==INVERSE?k_m_eol:s_eol),
  .s_ready(lab_s_ready),.m_data(lab_m_data),.m_valid(lab_m_valid),
  .m_sof(lab_m_sof),.m_eol(lab_m_eol),
  .m_ready((state==FORWARD&&k_s_ready)||(state==INVERSE&&m_ready)),
  .done_valid(lab_done),.done_ready(state==ACK_FORWARD||finish_pair),
  .done_error(lab_error),.error_code(lab_code),.busy());
 kmeans_rgb_frame #(.WIDTH(WIDTH),.HEIGHT(HEIGHT)) cluster(
  .clk(clk),.rst_n(!child_reset),.ce(ce),
  .start_valid(initial_start),.start_ready(k_start_ready),
  .cfg_k(cfg_k),.cfg_max_iterations(cfg_max_iterations),
  .cfg_tolerance(cfg_tolerance),.cfg_seed(cfg_seed),
  .s_rgb(lab_m_data),.s_valid(state==FORWARD&&lab_m_valid),
  .s_sof(lab_m_sof),.s_eol(lab_m_eol),.s_ready(k_s_ready),
  .m_rgb(k_m_data),.m_label(k_label),.m_valid(k_m_valid),
  .m_ready(state==INVERSE&&lab_s_ready),
  .m_sof(k_m_sof),.m_eol(k_m_eol),.m_last(k_m_last),
  .initial_centers(initial_centers_lab),.final_centers(final_centers_lab),
  .cluster_counts(cluster_counts),.inertia(inertia),
  .iterations(iterations),.converged(converged),
  .done_valid(k_done),.done_ready(finish_pair),
  .done_error(k_error),.error_code(k_code),.busy());
 assign s_ready=rst_n&&state==FORWARD&&lab_s_ready;
 assign m_valid=rst_n&&state==INVERSE&&lab_m_valid;
 assign m_rgb=lab_m_data;assign m_label=label_hold;
 assign m_sof=m_valid&&lab_m_sof;assign m_eol=m_valid&&lab_m_eol;
 assign m_last=m_valid&&output_index==N-1;
 assign done_valid=rst_n&&(state==COMPLETE||state==FAILED);
 assign done_error=state==FAILED;
 assign busy=state!=IDLE;
 initial if(WIDTH<1||HEIGHT<1||WIDTH>1024||HEIGHT>1024||N>1024)
  $fatal(1,"invalid Lab quantizer geometry");
 always @(posedge clk)begin
  if(!rst_n)begin state<=IDLE;label_hold<=0;output_index<=0;error_code<=0;end
  else if(ce)begin
   if(state>=FORWARD&&state<=INVERSE&&
      (abort||(lab_done&&lab_error)||(k_done&&k_error)))begin
    error_code<=abort?8'h93:((lab_done&&lab_error)?{4'h1,lab_code}:{4'h2,k_code});
    state<=FAILED;
   end else case(state)
    IDLE:if(initial_start)begin state<=FORWARD;output_index<=0;label_hold<=0;error_code<=0;end
    FORWARD:if(lab_done)state<=ACK_FORWARD;
    ACK_FORWARD:state<=START_INVERSE;
    START_INVERSE:if(lab_start_ready)state<=INVERSE;
    INVERSE:begin
     if(k_m_valid&&lab_s_ready)label_hold<=k_label;
     if(m_valid&&m_ready)output_index<=output_index+1'b1;
     if(finish_pair)state<=COMPLETE;
    end
    COMPLETE:if(done_ready)state<=IDLE;
    FAILED:if(done_ready)state<=IDLE;
    default:begin error_code<=8'h94;state<=FAILED;end
   endcase
  end
 end
endmodule
