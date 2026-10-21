// N-stage CIC, differential delay M=1. All transfers require clk_en.
// Exact signed ACC_W-bit modular arithmetic, no gain normalization.
// Each RATE accepted samples produces one result. A partial packet produces
// one terminal result at last; history clears after that result is computed.
module cip_dsp_cic_decimator #(
    parameter integer DATA_W=16, RATE=8, STAGES=3,
    parameter integer ACC_W=DATA_W+STAGES*$clog2(RATE)
)(
    input wire clk, rst_n, clk_en,
    input wire signed [DATA_W-1:0] s_data,
    input wire s_valid, s_last,
    output wire s_ready,
    output reg signed [ACC_W-1:0] m_data,
    output reg m_valid, m_last,
    input wire m_ready
);
reg signed [ACC_W-1:0] integ [0:STAGES-1];
reg signed [ACC_W-1:0] delay [0:STAGES-1];
reg signed [ACC_W-1:0] next_integ [0:STAGES-1];
reg signed [ACC_W-1:0] comb [0:STAGES];
localparam integer COUNT_W=(RATE>1)?$clog2(RATE):1;
reg [COUNT_W-1:0] count;
integer k,j;
assign s_ready = !m_valid || m_ready;
always @* begin
    next_integ[0]=integ[0]+{{(ACC_W-DATA_W){s_data[DATA_W-1]}},s_data};
    for(j=1;j<STAGES;j=j+1) next_integ[j]=integ[j]+next_integ[j-1];
    comb[0]=next_integ[STAGES-1];
    for(j=0;j<STAGES;j=j+1) comb[j+1]=comb[j]-delay[j];
end
always @(posedge clk or negedge rst_n) begin
    if(!rst_n) begin
        count<=0; m_data<=0; m_valid<=0; m_last<=0;
        for(k=0;k<STAGES;k=k+1) begin integ[k]<=0; delay[k]<=0; end
    end else if(clk_en) begin
        if(m_valid && m_ready) m_valid<=0;
        if(s_valid && s_ready) begin
            for(k=0;k<STAGES;k=k+1) integ[k]<=next_integ[k];
            if(count==RATE-1 || s_last) begin
                count<=0; m_data<=comb[STAGES]; m_valid<=1; m_last<=s_last;
                for(k=0;k<STAGES;k=k+1) delay[k]<=comb[k];
            end else count<=count+1'b1;
            if(s_last) begin
                count<=0;
                for(k=0;k<STAGES;k=k+1) begin integ[k]<=0; delay[k]<=0; end
            end
        end
    end
end
endmodule
