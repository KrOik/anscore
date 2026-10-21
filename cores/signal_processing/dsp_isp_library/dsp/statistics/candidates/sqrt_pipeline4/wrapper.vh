// Prototype candidate; no physical acceptance claimed. Per-stage elastic.
module statistics_stream #(parameter integer LOGIC_SQUARE=0)(
 input wire clk,rst_n,
 input wire signed [15:0] s_tdata,input wire s_tvalid,output wire s_tready,
 output wire [127:0] m_tdata,output wire [1:0] m_tuser,
 output wire m_tvalid,input wire m_tready,
 input wire cfg_valid,output wire cfg_ready,
 input wire cfg_block,input wire [3:0] cfg_log2,
 input wire signed [4:0] cfg_scale,input wire [31:0] cfg_threshold,
 output wire cfg_done,cfg_error
);
 wire [127:0] leaf_data;wire [1:0] leaf_user;
 wire leaf_valid,leaf_ready,leaf_input_ready,leaf_cfg_ready;
 reg [3:0] valid;
 wire [3:0] ready;
 reg [33:0] rem_stage[0:3];reg [15:0] root_stage[0:3];
 reg [31:0] rad_stage[0:3];reg [127:0] metadata[0:3];
 reg [1:0] user_stage[0:3];
 assign cfg_ready=rst_n && leaf_cfg_ready && !(|valid);
 assign s_tready=leaf_input_ready && !cfg_valid;
 assign leaf_ready=ready[0];
 statistics_leaf_no_rms #(.LOGIC_SQUARE(LOGIC_SQUARE)) leaf(
 .clk(clk),.rst_n(rst_n),.s_tdata(s_tdata),
 .s_tvalid(s_tvalid && !cfg_valid),.s_tready(leaf_input_ready),
 .m_tdata(leaf_data),.m_tuser(leaf_user),.m_tvalid(leaf_valid),.m_tready(leaf_ready),
 .cfg_valid(cfg_valid && cfg_ready),.cfg_ready(leaf_cfg_ready),
 .cfg_block(cfg_block),.cfg_log2(cfg_log2),.cfg_scale(cfg_scale),
 .cfg_threshold(cfg_threshold),.cfg_done(cfg_done),.cfg_error(cfg_error));
 // Four binary restoring iterations per register: 16 iterations in four stages.
 function [81:0] root_four;
 input [33:0] prior_rem;input [15:0] prior_root;input [31:0] rad;
 reg [33:0] remainder,trial;reg [15:0] root;reg [31:0] bits_left;
 integer k;
 begin
 remainder=prior_rem;root=prior_root;bits_left=rad;
 for(k=0;k<4;k=k+1) begin
 remainder=(remainder<<2)|{32'b0,bits_left[31:30]};bits_left=bits_left<<2;
 trial=({18'b0,root}<<2)|34'd1;root=root<<1;
 if(remainder>=trial)begin remainder=remainder-trial;root=root|16'd1;end
 end
 root_four={remainder,root,bits_left};
 end
 endfunction
 genvar g;
 generate for(g=0;g<4;g=g+1)begin: stage
 wire incoming_valid;wire [127:0] incoming_data;wire [1:0] incoming_user;
 wire [81:0] calc;
 if(g==0)begin
 assign incoming_valid=leaf_valid;assign incoming_data=leaf_data;assign incoming_user=leaf_user;
 assign calc=root_four(34'b0,16'b0,leaf_data[95:64]);
 end else begin
 assign incoming_valid=valid[g-1];assign incoming_data=metadata[g-1];assign incoming_user=user_stage[g-1];
 assign calc=root_four(rem_stage[g-1],root_stage[g-1],rad_stage[g-1]);
 end
 if(g==3)assign ready[g]=!valid[g] || m_tready;
 else assign ready[g]=!valid[g] || ready[g+1];
 always @(posedge clk)begin
 if(!rst_n)valid[g]<=0;
 else if(ready[g])begin
 valid[g]<=incoming_valid;
 if(incoming_valid)begin
 {rem_stage[g],root_stage[g],rad_stage[g]}<=calc;
 metadata[g]<=incoming_data;user_stage[g]<=incoming_user;
 end
 end
 end
 end endgenerate
 assign m_tvalid=valid[3];assign m_tuser=user_stage[3];
 assign m_tdata={metadata[3][127:48],root_stage[3],metadata[3][31:0]};
endmodule
