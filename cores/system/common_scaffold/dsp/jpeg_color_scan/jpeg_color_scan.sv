// Paired quant tables, MCU-ordered component blocks -> baseline color entropy scan.
module jpeg_color_scan(
 input wire clk,rst_n,ce,
 input wire table_id,table_valid,output wire table_ready,input wire [5:0] table_index,input wire [7:0] table_value,
 input wire cfg_valid,output wire cfg_ready,output reg cfg_done,cfg_error,
 input wire start_valid,output wire start_ready,input wire [31:0] cfg_total_mcus,
 input wire [15:0] cfg_restart_interval,input wire cfg_sampling_420,abort,
 input wire [7:0] s_data,input wire [1:0] s_component,input wire s_valid,output wire s_ready,
 input wire s_block_first,s_block_last,s_frame_last,
 output wire [7:0] m_data,output wire m_valid,input wire m_ready,
 output wire m_marker,m_scan_last,done_valid,input wire done_ready,
 output wire [7:0] error_code,output reg busy
);
 localparam CI=0,VR=1,VC=2,CR=3,CW=4;
 reg [2:0] config_state;
 reg [7:0] shadow[0:127],active[0:127],table_q;
 reg [127:0] written;
 reg [6:0] config_index;
 reg bad_table,configured,failed,block_enabled,next_restart;
 reg [7:0] local_error;
 reg [5:0] pixel_index,coefficient_index;
 reg [2:0] component_slot,blocks_per_mcu;
 reg [1:0] block_component;
 reg [31:0] total_blocks,restart_blocks,input_blocks,entropy_blocks,since_restart;
 localparam QIDLE=0,QR=1,QW=2,QC=3,QWAIT=4;
 reg [2:0] reload_state;
 reg [5:0] reload_index;
 reg [7:0] reload_q;
 reg reload_needed;
 wire [1:0] expected_component=(blocks_per_mcu==6)?((component_slot<4)?2'd0:((component_slot==4)?2'd1:2'd2)):component_slot[1:0];
 wire [2:0] start_bpm=cfg_sampling_420?3'd6:3'd3;
 wire [34:0] requested_blocks=cfg_sampling_420?({3'd0,cfg_total_mcus}<<2)+({3'd0,cfg_total_mcus}<<1):({3'd0,cfg_total_mcus}<<1)+cfg_total_mcus;
 wire [31:0] requested_restart=cfg_sampling_420?({16'd0,cfg_restart_interval}<<2)+({16'd0,cfg_restart_interval}<<1):({16'd0,cfg_restart_interval}<<1)+cfg_restart_interval;
 wire bad_start=cfg_total_mcus==0 || requested_blocks>35'h0ffffffff;
 wire dready,dvalid,dsat,qready,qvalid,qsat,coeff_ready,quant_cfg_ready,quant_table_ready,qcfg_done,qcfg_error;
 wire signed [15:0] ddata,qdata;
 wire signed [15:0] shifted=$signed({1'b0,s_data})-16'sd128;
 wire pixel_enable=busy&&block_enabled&&!failed&&!abort;
 wire scan_start_ready,predictor_reset_valid;
 wire [3:0] scan_error;
 assign cfg_ready=rst_n&&ce&&config_state==CI&&!busy&&!failed;
 assign table_ready=cfg_ready&&!cfg_valid;
 assign start_ready=rst_n&&ce&&configured&&!busy&&!failed&&config_state==CI&&scan_start_ready&&!cfg_valid&&!table_valid;
 assign s_ready=pixel_enable&&dready;
 assign error_code=local_error!=0?local_error:{4'd0,scan_error};
 dct8x8_serial dct(.clk(clk),.rst_n(rst_n),.ce(ce),.cfg_valid(1'b0),.cfg_inverse(1'b0),.cfg_ready(),.cfg_done(),
  .s_data(shifted),.s_valid(s_valid&&pixel_enable),.s_ready(dready),.m_data(ddata),.m_valid(dvalid),.m_ready(qready),.busy(),.saturated(dsat));
 jpeg_quant_zigzag quant(.clk(clk),.rst_n(rst_n),.ce(ce),
  .table_valid(reload_state==QW&&!failed),.table_ready(quant_table_ready),.table_index(reload_index),.table_value(reload_q),
  .cfg_valid(reload_state==QC&&!failed),.cfg_inverse(1'b0),.cfg_ready(quant_cfg_ready),.cfg_done(qcfg_done),.cfg_error(qcfg_error),
  .s_data(ddata),.s_valid(dvalid&&!failed),.s_ready(qready),.m_data(qdata),.m_valid(qvalid),.m_ready(coeff_ready),.busy(),.saturated(qsat));
 wire token_valid,token_ready,token_dc,token_end,token_restart;
 wire [3:0] token_run,token_size,symbol_error,huffman_error;
 wire [15:0] token_amplitude;
 wire [1:0] token_component;
 jpeg_baseline_symbols symbols(.clk(clk),.rst(!rst_n),.ce(ce),.s_coefficient(qdata),.s_valid(qvalid&&!failed),.s_ready(coeff_ready),
  .s_first(coefficient_index==0),.s_last(coefficient_index==63),.s_component(block_component),.s_restart(next_restart&&coefficient_index==0),
  .token_valid(token_valid),.token_ready(token_ready),.token_dc(token_dc),.token_run(token_run),.token_size(token_size),
  .token_amplitude(token_amplitude),.token_block_end(token_end),.token_restart(token_restart),.token_component(token_component),.error_code(symbol_error));
 wire hv,hr,hend;wire [15:0] hc,ha;wire [4:0] hcb,hab;
 jpeg_default_huffman huffman(.clk(clk),.rst_n(rst_n),.ce(ce),.s_valid(token_valid&&!failed),.s_ready(token_ready),
  .s_dc(token_dc),.s_run(token_run),.s_size(token_size),.s_amplitude(token_amplitude),.s_block_end(token_end),.s_restart(token_restart),.s_component(token_component),
  .m_valid(hv),.m_ready(hr),.m_code(hc),.m_code_bits(hcb),.m_amplitude(ha),.m_amplitude_bits(hab),.m_block_end(hend),.m_restart(),.m_component(),.error_code(huffman_error));
 wire pipeline_error=dsat||qsat||qcfg_error||symbol_error!=0||huffman_error!=0;
 jpeg_entropy_scan_controller scan(.clk(clk),.rst(!rst_n),.ce(ce),
  .start_valid(start_valid&&start_ready),.start_ready(scan_start_ready),.cfg_total_blocks(bad_start?32'd0:requested_blocks[31:0]),
  .cfg_restart_interval(requested_restart),.abort(abort||failed||pipeline_error),
  .s_code(hc),.s_amplitude(ha),.s_code_bits(hcb),.s_amplitude_bits(hab),.s_block_end(hend),
  .s_scan_last(hend&&entropy_blocks==total_blocks-1),.s_valid(hv&&!failed),.s_ready(hr),
  .m_data(m_data),.m_valid(m_valid),.m_ready(m_ready),.m_marker(m_marker),.m_scan_last(m_scan_last),
  .predictor_reset_valid(predictor_reset_valid),.predictor_reset_ready(busy&&!failed),
  .scan_done(done_valid),.scan_done_ready(done_ready),.error_code(scan_error),.busy(),.blocks_completed(),.restarts_emitted());
 always @(posedge clk)if(rst_n&&ce)begin
  if(table_valid&&table_ready)shadow[{table_id,table_index}]<=table_value;
  if(config_state==VR || config_state==CR)table_q<=shadow[config_index];
  if(config_state==CW)active[config_index]<=table_q;
  if(reload_state==QR)reload_q<=active[{expected_component!=0,reload_index}];
 end
 always @(posedge clk)begin
  if(!rst_n)begin
   config_state<=CI;written<=0;config_index<=0;bad_table<=0;cfg_done<=0;cfg_error<=0;configured<=0;
   failed<=0;block_enabled<=0;next_restart<=0;local_error<=0;busy<=0;pixel_index<=0;coefficient_index<=0;
   component_slot<=0;blocks_per_mcu<=3;block_component<=0;total_blocks<=0;restart_blocks<=0;input_blocks<=0;entropy_blocks<=0;since_restart<=0;
   reload_state<=QIDLE;reload_index<=0;reload_needed<=0;
  end else if(ce)begin
   cfg_done<=0;cfg_error<=0;
   if(table_valid&&table_ready)written[{table_id,table_index}]<=1;
   case(config_state)
    CI:if(cfg_valid&&cfg_ready)begin
     if(written!={128{1'b1}})cfg_error<=1;
     else begin config_index<=0;bad_table<=0;config_state<=VR;end
    end
    VR:config_state<=VC;
    VC:begin
     if(table_q==0)bad_table<=1;
     if(config_index==127)begin config_index<=0;if(bad_table||table_q==0)begin cfg_error<=1;config_state<=CI;end else config_state<=CR;end
     else begin config_index<=config_index+1'b1;config_state<=VR;end
    end
    CR:config_state<=CW;
    CW:begin if(config_index==127)begin configured<=1;cfg_done<=1;config_index<=0;config_state<=CI;written<=0;end
     else begin config_index<=config_index+1'b1;config_state<=CR;end end
   endcase
   if(start_valid&&start_ready)begin
    busy<=1;block_enabled<=0;next_restart<=0;pixel_index<=0;coefficient_index<=0;component_slot<=0;
    blocks_per_mcu<=start_bpm;total_blocks<=requested_blocks[31:0];restart_blocks<=requested_restart;
    input_blocks<=0;entropy_blocks<=0;since_restart<=0;local_error<=bad_start?8'h87:0;
    reload_state<=QIDLE;reload_needed<=0;
   end
   if(busy&&predictor_reset_valid&&!failed)begin next_restart<=1;since_restart<=0;reload_needed<=1;end
   case(reload_state)
    QIDLE:if(reload_needed&&!failed)begin reload_index<=0;reload_needed<=0;reload_state<=QR;end
    QR:reload_state<=QW;
    QW:if(quant_table_ready)begin if(reload_index==63)reload_state<=QC;else begin reload_index<=reload_index+1'b1;reload_state<=QR;end end
    QC:if(quant_cfg_ready)reload_state<=QWAIT;
    QWAIT:if(qcfg_done)begin block_component<=expected_component;block_enabled<=1;reload_state<=QIDLE;end
   endcase
   if(s_valid&&s_ready)begin
    if(s_component!=expected_component || s_block_first!=(pixel_index==0) || s_block_last!=(pixel_index==63) ||
      s_frame_last!=(input_blocks==total_blocks-1 && pixel_index==63))begin failed<=1;local_error<=8'h81;block_enabled<=0;end
    if(pixel_index==63)begin pixel_index<=0;input_blocks<=input_blocks+1'b1;block_enabled<=0;end else pixel_index<=pixel_index+1'b1;
   end
   if(qvalid&&coeff_ready&&!failed)begin coefficient_index<=coefficient_index+1'b1;if(coefficient_index==0)next_restart<=0;end
   if(hv&&hr&&!failed&&hend)begin
    entropy_blocks<=entropy_blocks+1'b1;since_restart<=since_restart+1'b1;
    component_slot<=(component_slot==blocks_per_mcu-1)?0:component_slot+1'b1;
    if(entropy_blocks+1<total_blocks && (restart_blocks==0 || since_restart+1<restart_blocks))reload_needed<=1;
   end
   if(busy&&!done_valid&&!failed&&(abort||pipeline_error))begin
    failed<=1;block_enabled<=0;
    if(abort)local_error<=8'h86;else if(dsat)local_error<=8'h82;else if(qsat||qcfg_error)local_error<=8'h83;
    else if(symbol_error!=0)local_error<=8'h84;else local_error<=8'h85;
   end
   if(done_valid&&done_ready)begin busy<=0;block_enabled<=0;end
  end
 end
endmodule
