// Actual phase-only correlation followed by synchronous circular B-frame replay.
module phase_registration #(parameter SIDE=16,TWIDDLE_FILE="twiddle.mem")(
 input wire clk,rst_n,ce,start_valid,output wire start_ready,input wire cfg_remove_dc,abort,
 input wire[7:0]s_a,s_b,input wire s_valid,s_sof,s_eol,s_last,output wire s_ready,
 output reg[7:0]m_data,output reg m_valid,m_sof,m_eol,m_last,input wire m_ready,
 output reg signed[6:0]m_dx,m_dy,output reg signed[31:0]m_peak,output reg[15:0]m_valid_bins,
 output wire done_valid,input wire done_ready,output wire done_error,output reg[7:0]error_code,output wire busy
);
 localparam LG=$clog2(SIDE),AW=2*LG,N=SIDE*SIDE;
 localparam IDLE=0,RUN=1,ACK=2,ADDRESS=3,READ=4,VALUE=5,OUTPUT=6,COMPLETE=7,FAILED=8;
 reg[3:0]state;
 reg[AW-1:0]input_index,output_index,read_addr;
 reg[7:0]frame_b[0:N-1],ram_q;
 wire child_reset=!rst_n||state==FAILED;
 wire child_start_ready,child_s_ready,child_valid,child_done,child_error,child_invalid;
 wire signed[6:0]child_dx,child_dy;
 wire signed[31:0]child_peak;
 wire[15:0]child_bins;wire[7:0]child_code;
 wire bad_marker=s_sof!=(input_index==0)||s_eol!=(input_index[LG-1:0]==SIDE-1)||s_last!=(input_index==N-1);
 wire child_failed=(child_valid&&(child_invalid||child_error))||(child_done&&child_error);
 wire active=state>=RUN&&state<=OUTPUT;
 assign start_ready=rst_n&&ce&&state==IDLE&&child_start_ready&&!abort;
 assign s_ready=rst_n&&state==RUN&&child_s_ready&&!abort;
 wire begin_frame=start_valid&&start_ready;
 wire input_accept=s_valid&&s_ready;
 wire output_allowed=rst_n&&!abort&&!(state==RUN&&child_failed);
 wire[LG-1:0]source_x=output_index[LG-1:0]-m_dx;
 wire[LG-1:0]source_y=output_index[AW-1:LG]-m_dy;
 assign done_valid=rst_n&&(state==COMPLETE||state==FAILED);
 assign done_error=state==FAILED;
 assign busy=state!=IDLE;
 phase_correlation_frame #(.SIDE(SIDE),.TWIDDLE_FILE(TWIDDLE_FILE)) phase(
  .clk(clk),.rst(child_reset),.ce(ce),.start_valid(begin_frame),.start_ready(child_start_ready),.cfg_remove_dc(cfg_remove_dc),
  .s_a(s_a),.s_b(s_b),.s_valid(s_valid&&state==RUN&&!abort),.s_sof(s_sof),.s_eol(s_eol),.s_ready(child_s_ready),
  .m_valid(child_valid),.m_ready(state==RUN&&!abort),.m_dx(child_dx),.m_dy(child_dy),.m_peak(child_peak),
  .m_valid_bins(child_bins),.m_invalid(child_invalid),.done_valid(child_done),.done_ready(state==ACK),
  .done_error(child_error),.error_code(child_code),.busy());
 always @(posedge clk)if(ce)begin
  ram_q<=frame_b[read_addr];
  if(input_accept&&state==RUN&&!bad_marker)frame_b[input_index]<=s_b;
 end
 // Output validity is combinationally cancelled on abort, consistently with
 // the enabled acceptance condition in OUTPUT below.
 reg pending_valid;
 always @*m_valid=pending_valid&&output_allowed;
 initial if(SIDE!=8&&SIDE!=16&&SIDE!=32)$fatal(1,"invalid phase registration SIDE");
 always @(posedge clk)begin
  if(!rst_n)begin
   state<=IDLE;input_index<=0;output_index<=0;read_addr<=0;pending_valid<=0;
   m_data<=0;m_sof<=0;m_eol<=0;m_last<=0;m_dx<=0;m_dy<=0;m_peak<=0;m_valid_bins<=0;error_code<=0;
  end else if(ce)begin
   if(active&&abort)begin pending_valid<=0;error_code<=8'h93;state<=FAILED;end
   else if(state==RUN&&input_accept&&bad_marker)begin pending_valid<=0;error_code<=8'h81;state<=FAILED;end
   else if(state==RUN&&child_failed)begin
    pending_valid<=0;error_code<=child_invalid?8'h90:(8'h40|child_code);state<=FAILED;
   end else case(state)
    IDLE:if(begin_frame)begin input_index<=0;output_index<=0;error_code<=0;pending_valid<=0;state<=RUN;end
    RUN:begin
     if(input_accept)input_index<=input_index+1'b1;
     if(child_valid)begin
      m_dx<=child_dx;m_dy<=child_dy;m_peak<=child_peak;m_valid_bins<=child_bins;state<=ACK;
     end
    end
    ACK:if(child_done)begin output_index<=0;state<=ADDRESS;end
    ADDRESS:begin read_addr<={source_y,source_x};state<=READ;end
    READ:state<=VALUE;
    VALUE:begin
     m_data<=ram_q;m_sof<=output_index==0;m_eol<=output_index[LG-1:0]==SIDE-1;m_last<=output_index==N-1;
     pending_valid<=1;state<=OUTPUT;
    end
    OUTPUT:if(m_ready)begin pending_valid<=0;
     if(output_index==N-1)state<=COMPLETE;else begin output_index<=output_index+1'b1;state<=ADDRESS;end
    end
    COMPLETE:if(done_ready)state<=IDLE;
    FAILED:if(done_ready)state<=IDLE;
    default:begin error_code<=8'h94;pending_valid<=0;state<=FAILED;end
   endcase
  end
 end
endmodule
