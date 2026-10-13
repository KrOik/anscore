// Eight-digit BCD converter with two elastic pipeline stages.
// Latency=2 enabled edges, II=1. Registered 16-step double-dabble boundary.
module prod_bcd8_encode (
    input wire clk, rst_n, clk_en, in_valid, output wire in_ready,
    input wire [31:0] a,b,c, output reg out_valid, input wire out_ready,
    output reg [31:0] result, aux, output reg fault
);
reg stage_valid, stage_fault;
reg [63:0] stage_data;
reg [63:0] first, second;
integer i,j;
wire output_ready=(!out_valid || out_ready);
assign in_ready=clk_en && (!stage_valid || output_ready);
always @* begin
    first={32'd0,a};
    second=stage_data;
    for(i=0;i<16;i=i+1) begin
        for(j=0;j<8;j=j+1) begin
            if(first[32+j*4+:4]>=5) first[32+j*4+:4]=first[32+j*4+:4]+4'd3;
            if(second[32+j*4+:4]>=5) second[32+j*4+:4]=second[32+j*4+:4]+4'd3;
        end
        first=first<<1; second=second<<1;
    end
end
always @(posedge clk or negedge rst_n) begin
    if(!rst_n) begin
        stage_valid<=0; stage_fault<=0; stage_data<=0;
        out_valid<=0; result<=0; aux<=0; fault<=0;
    end else if(clk_en) begin
        if(output_ready) begin
            out_valid<=stage_valid;
            if(stage_valid) begin
                result<=stage_fault?32'd0:second[63:32]; aux<=0; fault<=stage_fault;
            end
        end
        if(in_ready) begin
            stage_valid<=in_valid;
            if(in_valid) begin stage_data<=first; stage_fault<=(a>99999999); end
        end
    end
end
endmodule
