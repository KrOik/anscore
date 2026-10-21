// Rational polyphase FIR: insert UP-1 zeros, convolve, keep every DOWNth value.
// Finite packets include the complete convolution tail. TAPS must be >= DOWN
// so every nonempty packet has an output after its final input is accepted.
module cip_dsp_resampler #(
    parameter integer DATA_W=16, COEFF_W=16, UP=3, DOWN=2, TAPS=24,
    parameter integer SHIFT=15,
    parameter integer ACC_W=DATA_W+COEFF_W+$clog2(TAPS)+1
)(
    input wire clk,rst_n,clk_en,
    input wire coeff_valid,
    output wire coeff_ready,
    input wire [31:0] coeff_addr,
    input wire signed [COEFF_W-1:0] coeff_data,
    input wire signed [DATA_W-1:0] s_data,
    input wire s_valid,s_last,
    output wire s_ready,
    output reg signed [DATA_W-1:0] m_data,
    output reg m_valid,m_last,
    input wire m_ready
);
localparam integer HISTORY=(TAPS+UP-1)/UP;
localparam WAIT_INPUT=0, PREPARE=1, MAC=2, OUTPUT=3, ACCUMULATE=4, QUANTIZE=5;
reg [2:0] state;
reg signed [COEFF_W-1:0] coeff [0:TAPS-1];
reg signed [DATA_W-1:0] history [0:HISTORY-1];
reg signed [ACC_W-1:0] acc;
reg ending,packet_active;
localparam integer PHASE_W=$clog2(UP+DOWN+1)>0?$clog2(UP+DOWN+1):1;
localparam integer TAP_W=$clog2(HISTORY)>0?$clog2(HISTORY):1;
localparam integer REMAIN_W=$clog2(TAPS+1)>0?$clog2(TAPS+1):1;
reg [PHASE_W-1:0] phase;
reg [TAP_W-1:0] tap;
reg [REMAIN_W-1:0] remaining;
integer k;
localparam integer ADDR_W=$clog2(UP+DOWN+HISTORY*UP+1);
wire [ADDR_W-1:0] address=phase+tap*UP;
wire signed [COEFF_W-1:0] selected_coeff=(address<TAPS)?coeff[address]:{COEFF_W{1'b0}};
wire signed [DATA_W+COEFF_W-1:0] product=history[tap]*selected_coeff;
reg signed [DATA_W+COEFF_W-1:0] product_q;
wire signed [ACC_W-1:0] total=acc+product_q;
wire signed [ACC_W-1:0] scaled=acc>>>SHIFT;
localparam signed [ACC_W-1:0] MAXIMUM=({{(ACC_W-1){1'b0}},1'b1}<<(DATA_W-1))-1;
localparam signed [ACC_W-1:0] MINIMUM=-(MAXIMUM+1);
assign coeff_ready=state==WAIT_INPUT && !packet_active;
assign s_ready=state==WAIT_INPUT && !coeff_valid;
always @(posedge clk or negedge rst_n) begin
    if(!rst_n) begin
        state<=WAIT_INPUT;ending<=0;packet_active<=0;phase<=0;tap<=0;remaining<=0;
        acc<=0;product_q<=0;m_data<=0;m_valid<=0;m_last<=0;
        for(k=0;k<TAPS;k=k+1) coeff[k]<=0;
        for(k=0;k<HISTORY;k=k+1) history[k]<=0;
    end else if(clk_en) begin
        if(coeff_valid && coeff_ready && coeff_addr<TAPS) coeff[coeff_addr]<=coeff_data;
        case(state)
        WAIT_INPUT: if(s_valid && s_ready) begin
            for(k=HISTORY-1;k>0;k=k-1) history[k]<=history[k-1];
            history[0]<=s_data;ending<=s_last;remaining<=TAPS;
            packet_active<=1;state<=PREPARE;
        end
        PREPARE: begin
            if(phase>=UP) begin
                phase<=phase-UP;
                if(ending) begin
                    remaining<=remaining-UP;
                    for(k=HISTORY-1;k>0;k=k-1) history[k]<=history[k-1];
                    history[0]<=0;
                end else state<=WAIT_INPUT;
            end else begin tap<=0;acc<=0;state<=MAC;end
        end
        MAC: begin
            product_q<=product;
            state<=ACCUMULATE;
        end
        ACCUMULATE: begin
            acc<=total;
            if(tap==HISTORY-1) state<=QUANTIZE;
            else begin tap<=tap+1;state<=MAC;end
        end
        QUANTIZE: begin
            m_data<=scaled>MAXIMUM?MAXIMUM[DATA_W-1:0]:
                    scaled<MINIMUM?MINIMUM[DATA_W-1:0]:scaled[DATA_W-1:0];
            m_last<=ending && phase+DOWN>=remaining;
            m_valid<=1;state<=OUTPUT;
        end
        OUTPUT: if(m_ready) begin
            m_valid<=0;
            if(m_last) begin
                state<=WAIT_INPUT;phase<=0;ending<=0;packet_active<=0;
                for(k=0;k<HISTORY;k=k+1) history[k]<=0;
            end else begin phase<=phase+DOWN;state<=PREPARE;end
        end
        endcase
    end
end
endmodule
