// Signed serial-MAC FIR. Native CE handshake: transfers require clk_en.
// Coefficient writes are allowed only while idle, with no pending output.
// History starts at zero; last clears history after computing that sample.
module cip_dsp_fir #(
    parameter integer DATA_W=16, COEFF_W=16, TAPS=16,
    parameter integer SHIFT=15,
    parameter integer ACC_W=DATA_W+COEFF_W+$clog2(TAPS)+1
)(
    input wire clk, rst_n, clk_en,
    input wire coeff_valid,
    output wire coeff_ready,
    input wire [31:0] coeff_addr,
    input wire signed [COEFF_W-1:0] coeff_data,
    input wire signed [DATA_W-1:0] s_data,
    input wire s_valid, s_last,
    output wire s_ready,
    output reg signed [DATA_W-1:0] m_data,
    output reg m_valid, m_last,
    input wire m_ready
);
reg signed [COEFF_W-1:0] coeff [0:TAPS-1];
reg signed [DATA_W-1:0] history [0:TAPS-1];
reg signed [ACC_W-1:0] acc;
reg busy, packet_last;
integer tap, k;
wire signed [DATA_W+COEFF_W-1:0] product = history[tap]*coeff[tap];
wire signed [ACC_W-1:0] total = acc + product;
wire signed [ACC_W-1:0] scaled = total >>> SHIFT;
localparam signed [ACC_W-1:0] MAXIMUM = ({{(ACC_W-1){1'b0}},1'b1} << (DATA_W-1))-1;
localparam signed [ACC_W-1:0] MINIMUM = -(MAXIMUM+1);
assign coeff_ready = !busy && !m_valid;
assign s_ready = !busy && (!m_valid || m_ready) && !coeff_valid;
always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        busy<=0; m_valid<=0; m_last<=0; m_data<=0;
        acc<=0; tap<=0; packet_last<=0;
        for(k=0;k<TAPS;k=k+1) begin coeff[k]<=0; history[k]<=0; end
    end else if(clk_en) begin
        if(m_valid && m_ready) m_valid<=0;
        if(coeff_valid && coeff_ready && coeff_addr<TAPS)
            coeff[coeff_addr]<=coeff_data;
        if(s_valid && s_ready) begin
            for(k=TAPS-1;k>0;k=k-1) history[k]<=history[k-1];
            history[0]<=s_data; packet_last<=s_last;
            acc<=0; tap<=0; busy<=1;
        end else if(busy) begin
            if(tap==TAPS-1) begin
                m_data <= scaled>MAXIMUM ? MAXIMUM[DATA_W-1:0] :
                          scaled<MINIMUM ? MINIMUM[DATA_W-1:0] : scaled[DATA_W-1:0];
                m_valid<=1; m_last<=packet_last; busy<=0;
                if(packet_last) for(k=0;k<TAPS;k=k+1) history[k]<=0;
            end else begin acc<=total; tap<=tap+1; end
        end
    end
end
endmodule
