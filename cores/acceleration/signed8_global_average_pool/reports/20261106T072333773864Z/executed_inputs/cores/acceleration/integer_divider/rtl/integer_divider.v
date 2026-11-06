// Autonomous unsigned restoring division, W>=1. Fixed W-cycle calculation.
module integer_divider #(parameter W=32)(
    input wire clk,rst,
    input wire s_valid,output wire s_ready,
    input wire [W-1:0] s_numerator,s_denominator,
    output wire m_valid,input wire m_ready,
    output reg [W-1:0] m_quotient,m_remainder,
    output reg m_divzero
);
    localparam CW=(W<2)?1:$clog2(W);
    reg busy,out_valid,divzero;
    reg [W-1:0] quotient,remainder,divisor;
    reg [CW-1:0] step;
    wire [W:0] shifted={remainder,quotient[W-1]};
    wire [W:0] difference=shifted-{1'b0,divisor};
    // For nonzero divisor the restored remainder is < divisor. Consequently
    // a successful subtraction is <2^W, and difference[W] signals underflow.
    // For divisor zero, each prefix fits W bits: quotient becomes all ones.
    wire fits=!difference[W];
    wire [W-1:0] next_remainder=fits ? difference[W-1:0] : shifted[W-1:0];
    wire [W-1:0] next_quotient=(quotient<<1)|fits;
    assign s_ready=!rst && !busy && (!out_valid || m_ready);
    assign m_valid=!rst && out_valid;
    always @(posedge clk) begin
        if(rst) begin busy<=0;out_valid<=0;step<=0;end
        else begin
            if(out_valid && m_ready) out_valid<=0;
            if(s_valid && s_ready) begin
                quotient<=s_numerator;divisor<=s_denominator;
                remainder<=0;step<=0;busy<=1;divzero<=(s_denominator==0);
            end else if(busy) begin
                quotient<=next_quotient;remainder<=next_remainder;
                if(step==W-1) begin
                    busy<=0;out_valid<=1;
                    m_quotient<=next_quotient;m_remainder<=next_remainder;
                    m_divzero<=divzero;
                end else step<=step+1'b1;
            end
        end
    end
endmodule
