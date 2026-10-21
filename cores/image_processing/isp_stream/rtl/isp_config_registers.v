// CSR adapter around unchanged canonical sys_atomic_config(WORDS=16).
// Shadow 0x20..0x5c; active 0x80..0xbc; 0=status,4=commit/version,8=ID.
module isp_config_registers #(parameter RAW_BITS=10,MAX_WIDTH=640)(
 input wire clk,rst_n,req_valid,req_write,input wire [7:0] req_addr,
 input wire [31:0] req_data,input wire [3:0] req_strobe,
 output wire req_ready,output reg resp_valid,resp_error,output reg [31:0] resp_data,input wire resp_ready,
 output reg cfg_valid,input wire cfg_ready,output wire [511:0] cfg_words,
 output wire [31:0] cfg_version,output wire cfg_pending
);
 reg [511:0] shadow;
 reg waiting;reg [31:0] observed_version;
 wire write_ready,commit_ready,atomic_pending;
 wire accept=req_valid&&req_ready;
 wire aligned=req_addr[1:0]==0;
 wire shadow_address=req_addr>=8'h20&&req_addr<=8'h5c;
 wire active_address=req_addr>=8'h80&&req_addr<=8'hbc;
 wire editable=!waiting&&!cfg_valid&&!atomic_pending;
 wire write_shadow=accept&&req_write&&aligned&&shadow_address&&editable&&req_strobe==15;
 reg valid_config;
 integer i;
 localparam [31:0] RAW_MAX=(32'd1<<RAW_BITS)-1;
 always @* begin
  valid_config=shadow[15:0]>=5&&shadow[15:0]<=MAX_WIDTH&&shadow[31:16]>=5&&
   shadow[63:32]!=0&&shadow[95:64]>=2&&shadow[127:96]<=RAW_MAX&&
   (shadow[159:128]&32'hffffff00)==0&&shadow[191:160]<=RAW_MAX&&shadow[319:304]==0;
  for(i=0;i<4;i=i+1)if(shadow[192+i*16+:16]>RAW_MAX)valid_config=0;
 end
 wire commit=accept&&req_write&&aligned&&req_addr==4&&req_strobe==15&&req_data==1&&editable&&valid_config;
 assign req_ready=rst_n&&!resp_valid;
 assign cfg_pending=waiting||atomic_pending||cfg_valid;
 sys_atomic_config #(.WORDS(16)) atomic_config(
 .clk(clk),.rst_n(rst_n),.write_valid(write_shadow),.write_ready(write_ready),.write_index(req_addr[5:2]-4'd8),
 .write_data(req_data),.write_strb(req_strobe),.commit_valid(commit),.commit_ready(commit_ready),
 .apply_safe(cfg_ready&&!cfg_valid),.active(cfg_words),.version(cfg_version),.pending(atomic_pending));
 always @(posedge clk or negedge rst_n)begin
  if(!rst_n)begin shadow<=0;waiting<=0;observed_version<=0;cfg_valid<=0;resp_valid<=0;resp_error<=0;resp_data<=0;end
  else begin
   if(resp_valid&&resp_ready)resp_valid<=0;
   if(cfg_version!=observed_version)begin observed_version<=cfg_version;cfg_valid<=1;end
   if(cfg_valid&&cfg_ready)begin cfg_valid<=0;waiting<=0;end
   if(accept)begin
    resp_valid<=1;resp_error<=0;resp_data<=0;
    if(!aligned)resp_error<=1;
    else if(req_write)begin
     if(req_strobe!=15)resp_error<=1;
     else if(shadow_address)begin
      if(editable&&write_ready)shadow[(req_addr-8'h20)*8+:32]<=req_data;
      else resp_error<=1;
     end else if(req_addr==4)begin
      if(commit&&commit_ready)waiting<=1;else resp_error<=1;
     end else resp_error<=1;
    end else if(shadow_address)resp_data<=shadow[(req_addr-8'h20)*8+:32];
    else if(active_address)resp_data<=cfg_words[(req_addr-8'h80)*8+:32];
    else case(req_addr)
     0:resp_data<={29'd0,cfg_valid,cfg_pending,cfg_ready};
     4:resp_data<=cfg_version;
     8:resp_data<=32'h49535031;
     default:resp_error<=1;
    endcase
   end
  end
 end
endmodule
