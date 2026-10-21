// Authored kernel. See ip/hamming13_decode8/SPEC.md for exact semantics.
// Transfer on clk_en && valid && ready. Output and state freeze when !clk_en.
module prod_hamming13_decode8 (
    input wire clk, input wire rst_n, input wire clk_en,
    input wire in_valid, output wire in_ready,
    input wire [31:0] a, b, c,
    output reg out_valid, input wire out_ready,
    output reg [31:0] result, aux, output reg fault
);
reg [95:0] state_r, state_n;
reg [31:0] r, x, temp, mask;
reg [32:0] ext;
reg [63:0] wide;
reg f;
integer i, j, idx;
assign in_ready = clk_en && (!out_valid || out_ready);
always @* begin
    r=0; x=0; f=0; temp=0; mask=0; ext=0; wide=0;
    i=0; j=0; idx=0; state_n=state_r;
    temp=a; idx=0; for(j=0;j<4;j=j+1) begin mask=0; for(i=1;i<=12;i=i+1) if((i&(1<<j))!=0) mask[0]=mask[0]^a[i-1]; if(mask[0]) idx=idx|(1<<j); end x=idx<<4; if(a[31:13]!=0) begin f=1; x=x|2; end else if((^a[12:0])==1'b1) begin if(idx>12) begin f=1; x=x|2; end else begin x=x|1; if(idx!=0) temp[idx-1]=~temp[idx-1]; end end else if(idx!=0) begin f=1; x=x|2; end if(!f) r={24'd0,temp[11],temp[10],temp[9],temp[8],temp[6],temp[5],temp[4],temp[2]};
end
always @(posedge clk or negedge rst_n) begin
    if(!rst_n) begin
        out_valid<=0; result<=0; aux<=0; fault<=0; state_r<=0;
    end else if(clk_en) begin
        if(in_ready) begin
            out_valid<=in_valid;
            if(in_valid) begin
                result<=r; aux<=x; fault<=f; state_r<=state_n;
            end
        end
    end
end
endmodule
