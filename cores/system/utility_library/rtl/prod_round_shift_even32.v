// Authored kernel. See ip/round_shift_even32/SPEC.md for exact semantics.
// Transfer on clk_en && valid && ready. Output and state freeze when !clk_en.
module prod_round_shift_even32 (
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
    if(b>31) f=1; else if(b==0) r=a; else begin mask=32'hffffffff>>(32-b); temp=a>>b; x=a&mask; r=temp+((x>(32'd1<<(b-1))) || ((x==(32'd1<<(b-1))) && temp[0])); end
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
