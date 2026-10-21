// Exact unsigned carry-save shift/add multiplier. B_W CSA iterations,
// then ceil((A_W+B_W)/8) byte-carry fold iterations. Shared CE/ready handshake.
module cip_fusion_scalar_multiply #(parameter A_W=64,B_W=32)(
 input wire clk,rst_n,clk_en,input wire s_valid,output wire s_ready,
 input wire [A_W-1:0] s_a,input wire [B_W-1:0] s_b,
 output reg m_valid,input wire m_ready,output reg [A_W+B_W-1:0] m_product
);
localparam W=A_W+B_W,PAD_W=((W+7)/8)*8,CHUNKS=PAD_W/8;
localparam CW=$clog2(B_W+CHUNKS+1)>0?$clog2(B_W+CHUNKS+1):1;
reg [1:0] state;
reg [PAD_W-1:0] multiplicand,sum_vector,carry_vector,fold_product;
reg [B_W-1:0] multiplier;
reg [CW-1:0] remaining;
reg fold_carry;
wire [PAD_W-1:0] addend=multiplier[0]?multiplicand:{PAD_W{1'b0}};
wire [PAD_W-1:0] csa_sum=sum_vector^carry_vector^addend;
wire [PAD_W-1:0] csa_carry=((sum_vector&carry_vector)|(sum_vector&addend)|(carry_vector&addend))<<1;
wire [8:0] fold_sum={1'b0,sum_vector[7:0]}+{1'b0,carry_vector[7:0]}+fold_carry;
wire [PAD_W-1:0] next_product=(fold_product>>8)|({{(PAD_W-8){1'b0}},fold_sum[7:0]}<<(PAD_W-8));
assign s_ready=rst_n && state==0 && !m_valid;
always @(posedge clk or negedge rst_n)begin
 if(!rst_n)begin state<=0;m_valid<=0;m_product<=0;multiplicand<=0;sum_vector<=0;carry_vector<=0;fold_product<=0;multiplier<=0;remaining<=0;fold_carry<=0;end
 else if(clk_en)begin
 if(m_valid && m_ready)m_valid<=0;
 if(s_valid && s_ready)begin
 multiplicand<=s_a;multiplier<=s_b;sum_vector<=0;carry_vector<=0;remaining<=B_W;state<=1;fold_carry<=0;fold_product<=0;
 end else if(state==1)begin
 sum_vector<=csa_sum;carry_vector<=csa_carry;multiplicand<=multiplicand<<1;multiplier<=multiplier>>1;
 if(remaining==1)begin remaining<=CHUNKS;state<=2;end else remaining<=remaining-1'b1;
 end else if(state==2)begin
 sum_vector<=sum_vector>>8;carry_vector<=carry_vector>>8;fold_carry<=fold_sum[8];fold_product<=next_product;
 if(remaining==1)begin m_product<=next_product[W-1:0];m_valid<=1;state<=0;end else remaining<=remaining-1'b1;
 end
 end
end
endmodule
