// Unsigned shift/add multiply. Fixed B_W enabled iterations, no '*' datapath.
module img_hist_serial_multiply #(parameter A_W=64,B_W=32)(
    input wire clk,rst_n,clk_en,
    input wire s_valid,
    output wire s_ready,
    input wire [A_W-1:0] s_a,
    input wire [B_W-1:0] s_b,
    output reg m_valid,
    input wire m_ready,
    output reg [A_W+B_W-1:0] m_product
);
reg busy;
reg [A_W+B_W-1:0] multiplicand,acc;
reg [B_W-1:0] multiplier;
integer remaining;
wire [A_W+B_W-1:0] next_acc=acc+(multiplier[0]?multiplicand:{(A_W+B_W){1'b0}});
assign s_ready=rst_n && !busy && !m_valid;
always @(posedge clk or negedge rst_n) begin
    if(!rst_n) begin
        busy<=0;m_valid<=0;m_product<=0;multiplicand<=0;multiplier<=0;acc<=0;remaining<=0;
    end else if(clk_en) begin
        if(m_valid && m_ready) m_valid<=0;
        if(s_valid && s_ready) begin
            multiplicand<=s_a;multiplier<=s_b;acc<=0;remaining<=B_W;busy<=1;
        end else if(busy) begin
            acc<=next_acc;multiplicand<=multiplicand<<1;multiplier<=multiplier>>1;
            remaining<=remaining-1;
            if(remaining==1) begin m_product<=next_acc;m_valid<=1;busy<=0;end
        end
    end
end
endmodule
