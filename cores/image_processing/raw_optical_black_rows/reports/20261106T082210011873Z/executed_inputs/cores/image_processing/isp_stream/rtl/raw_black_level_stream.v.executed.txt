// Manual four-plane black-level correction, one elastic register, no frame RAM.
// Pixel coordinates advance only on accepted data. Upstream owns geometry checks.
module raw_black_level_stream #(parameter RAW_BITS=10)(
 input wire clk,rst_n,
 input wire cfg_valid,output wire cfg_ready,input wire [1:0] cfg_pattern,
 input wire [4*RAW_BITS-1:0] cfg_levels,input wire [RAW_BITS-1:0] cfg_target,
 input wire cfg_bypass,
 input wire s_valid,output wire s_ready,input wire [RAW_BITS-1:0] s_data,
 input wire s_sof,s_eol,input wire [15:0] s_frame_id,
 output reg m_valid,input wire m_ready,output reg [RAW_BITS-1:0] m_data,
 output reg m_sof,m_eol,output reg [15:0] m_frame_id,
 output reg [31:0] clip_low_count,clip_high_count
);
 reg pending;
 reg [1:0] shadow_pattern,pattern;
 reg [4*RAW_BITS-1:0] shadow_levels,levels;
 reg [RAW_BITS-1:0] shadow_target,target;
 reg shadow_bypass,bypass,x_odd,y_odd;
 wire apply=pending&&s_sof;
 wire [1:0] selected_pattern=apply?shadow_pattern:pattern;
 wire [4*RAW_BITS-1:0] selected_levels=apply?shadow_levels:levels;
 wire [RAW_BITS-1:0] selected_target=apply?shadow_target:target;
 wire selected_bypass=apply?shadow_bypass:bypass;
 wire [1:0] plane={((s_sof?1'b0:y_odd)^selected_pattern[1]),
                   ((s_sof?1'b0:x_odd)^selected_pattern[0])};
 wire [RAW_BITS-1:0] black=selected_levels[plane*RAW_BITS+:RAW_BITS];
 wire signed [RAW_BITS+1:0] corrected=$signed({2'b0,s_data})-
  $signed({2'b0,black})+$signed({2'b0,selected_target});
 localparam [RAW_BITS-1:0] MAX_PIXEL={RAW_BITS{1'b1}};
 assign cfg_ready=rst_n&&!pending;
 assign s_ready=rst_n&&(!m_valid||m_ready);
 always @(posedge clk or negedge rst_n)begin
  if(!rst_n)begin
   pending<=0;shadow_pattern<=0;pattern<=0;shadow_levels<=0;levels<=0;
   shadow_target<=0;target<=0;shadow_bypass<=0;bypass<=0;x_odd<=0;y_odd<=0;
   m_valid<=0;m_data<=0;m_sof<=0;m_eol<=0;m_frame_id<=0;clip_low_count<=0;clip_high_count<=0;
  end else begin
   if(cfg_valid&&cfg_ready)begin
    shadow_pattern<=cfg_pattern;shadow_levels<=cfg_levels;shadow_target<=cfg_target;
    shadow_bypass<=cfg_bypass;pending<=1;
   end
   if(s_ready)begin
    m_valid<=s_valid;
    if(s_valid)begin
     m_sof<=s_sof;m_eol<=s_eol;m_frame_id<=s_frame_id;
     if(selected_bypass)m_data<=s_data;
     else if(corrected<0)begin m_data<=0;clip_low_count<=clip_low_count+1'b1;end
     else if(corrected>$signed({2'b0,MAX_PIXEL}))begin m_data<=MAX_PIXEL;clip_high_count<=clip_high_count+1'b1;end
     else m_data<=corrected[RAW_BITS-1:0];
     if(apply)begin
      pattern<=shadow_pattern;levels<=shadow_levels;target<=shadow_target;
      bypass<=shadow_bypass;pending<=0;
     end
     if(s_sof)begin x_odd<=!s_eol;y_odd<=s_eol;end
     else if(s_eol)begin x_odd<=0;y_odd<=!y_odd;end
     else x_odd<=!x_odd;
    end
   end
  end
 end
 initial if(RAW_BITS!=8&&RAW_BITS!=10&&RAW_BITS!=12)$fatal(1,"RAW_BITS must be8/10/12");
endmodule
