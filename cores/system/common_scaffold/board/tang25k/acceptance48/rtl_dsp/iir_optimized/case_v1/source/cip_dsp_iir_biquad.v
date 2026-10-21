// Direct-form I biquad: (b0*x+b1*x1+b2*x2-a1*y1-a2*y2) >>> SHIFT.
// Feedback uses the quantized saturated output. a0 is implicitly 1.
// Coefficients [b0,b1,b2,a1,a2] share a single serial multiplier.
module cip_dsp_iir_biquad #(
    parameter integer DATA_W=16, COEFF_W=16, SHIFT=14,
    parameter integer ACC_W=DATA_W+COEFF_W+3
)(
    input wire clk, rst_n, clk_en,
    input wire coeff_valid,
    output wire coeff_ready,
    input wire [2:0] coeff_addr,
    input wire signed [COEFF_W-1:0] coeff_data,
    input wire signed [DATA_W-1:0] s_data,
    input wire s_valid, s_last,
    output wire s_ready,
    output reg signed [DATA_W-1:0] m_data,
    output reg m_valid, m_last,
    input wire m_ready
);
reg signed [COEFF_W-1:0] coeff [0:4];
reg signed [DATA_W-1:0] x,x1,x2,y1,y2,operand;
reg signed [ACC_W-1:0] acc;
reg [2:0] tap;
reg busy, packet_last;
reg [1:0] phase;
reg signed [DATA_W+COEFF_W-1:0] product_reg;
integer k;
always @* begin
    case(tap)
        0: operand=x;
        1: operand=x1;
        2: operand=x2;
        3: operand=y1;
        default: operand=y2;
    endcase
end
wire signed [DATA_W+COEFF_W-1:0] product=operand*coeff[tap];
wire signed [ACC_W-1:0] product_ext=product_reg;
wire signed [ACC_W-1:0] total=(tap>=3)?acc-product_ext:acc+product_ext;
wire signed [ACC_W-1:0] scaled=acc >>> SHIFT;
localparam signed [ACC_W-1:0] MAXIMUM=({{(ACC_W-1){1'b0}},1'b1} << (DATA_W-1))-1;
localparam signed [ACC_W-1:0] MINIMUM=-(MAXIMUM+1);
wire signed [DATA_W-1:0] quantized=scaled>MAXIMUM ? MAXIMUM[DATA_W-1:0] :
    scaled<MINIMUM ? MINIMUM[DATA_W-1:0] : scaled[DATA_W-1:0];
assign coeff_ready=!busy && !m_valid;
assign s_ready=!busy && (!m_valid || m_ready) && !coeff_valid;
always @(posedge clk or negedge rst_n) begin
    if(!rst_n) begin
        x<=0; x1<=0; x2<=0; y1<=0; y2<=0;
        acc<=0; tap<=0; busy<=0;phase<=0;product_reg<=0; packet_last<=0;
        m_data<=0; m_valid<=0; m_last<=0;
        for(k=0;k<5;k=k+1) coeff[k]<=0;
    end else if(clk_en) begin
        if(m_valid && m_ready) m_valid<=0;
        if(coeff_valid && coeff_ready && coeff_addr<5) coeff[coeff_addr]<=coeff_data;
        if(s_valid && s_ready) begin
            x<=s_data; acc<=0; tap<=0; busy<=1;phase<=0; packet_last<=s_last;
        end else if(busy) begin
            case(phase)
                0:begin product_reg<=product;phase<=1;end
                1:begin
                    acc<=total;
                    if(tap==4)phase<=2;
                    else begin tap<=tap+1'b1;phase<=0;end
                end
                2:begin
                    m_data<=quantized;m_last<=packet_last;m_valid<=1;busy<=0;
                    x2<=x1;x1<=x;y2<=y1;y1<=quantized;
                    if(packet_last)begin x1<=0;x2<=0;y1<=0;y2<=0;end
                end
                default:begin busy<=0;phase<=0;end
            endcase
        end
    end
end
endmodule
