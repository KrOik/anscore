// Authored kernel. See ip/dsp_fir3_s12/SPEC.md for exact semantics.
// Transfer on clk_en && valid && ready. Output and state freeze when !clk_en.
module acc_dsp_fir3_s12 (
    input wire clk, input wire rst_n, input wire clk_en,
    input wire in_valid, output wire in_ready,
    input wire [31:0] a, b, c,
    output reg out_valid, input wire out_ready,
    output reg [31:0] result, aux, output reg fault
);
reg [255:0] state_r, state_n;
reg [31:0] r, x, temp, mask, pa, pb, pc, ph, pl;
reg [32:0] ext;
reg [63:0] wide, wide2;
reg signed [63:0] swide, swide2;
reg signed [31:0] sa, sb, sc;
reg [95:0] data;
reg f;
integer i, j, idx, lane, sh;
reg [11:0] t0_a, t0_b, t1_a, t1_b, t2_a, t2_b;
reg signed [25:0] sum;
wire [23:0] t0_raw;
wire signed [23:0] t0 = $signed(t0_raw);
MULT12X12 u_t0 (.DOUT(t0_raw), .A(t0_a), .B(t0_b), .CLK(2'b00), .CE(2'b00), .RESET(2'b00));
wire [23:0] t1_raw;
wire signed [23:0] t1 = $signed(t1_raw);
MULT12X12 u_t1 (.DOUT(t1_raw), .A(t1_a), .B(t1_b), .CLK(2'b00), .CE(2'b00), .RESET(2'b00));
wire [23:0] t2_raw;
wire signed [23:0] t2 = $signed(t2_raw);
MULT12X12 u_t2 (.DOUT(t2_raw), .A(t2_a), .B(t2_b), .CLK(2'b00), .CE(2'b00), .RESET(2'b00));
assign in_ready = clk_en && (!out_valid || out_ready);
always @* begin
    r=0; x=0; f=0; temp=0; mask=0; pa=0; pb=0; pc=0; ph=0; pl=0;
    ext=0; wide=0; wide2=0; swide=0; swide2=0; data={a,b,c};
    sa=$signed(a); sb=$signed(b); sc=$signed(c);
    i=0; j=0; idx=0; lane=0; sh=0; state_n=state_r;
    t0_a=a[11:0]; t0_b=state_r[11:0];
t1_a=state_r[47:36]; t1_b=state_r[23:12];
t2_a=state_r[59:48]; t2_b=state_r[35:24];
if(c[30:8]!=0) f=1'b1;
else if(c[31]) begin
    state_n = {196'd0, state_r[59:36], b[11:0], a[23:12], a[11:0]};
    r = {20'd0, b[11:0]};
    x = {8'd0, a[23:12], a[11:0]};
end else begin
    sum = t0 + t1 + t2;
    sh=c[7:4];
    if(sh==0) swide=sum;
    else swide=(sum+(26'sd1<<<(sh-1)))>>>sh;
    if(swide>64'sd32767) begin r={16'd0, 16'h7fff}; x[24]=1'b1; f=1'b1; end
    else if(swide<-64'sd32768) begin r={16'd0, 16'h8000}; x[24]=1'b1; f=1'b1; end
    else r={16'd0, swide[15:0]};
    x[11:0]=a[11:0];
    x[23:12]=state_r[47:36];
    state_n = {196'd0, state_r[47:36], a[11:0], state_r[35:0]};
end
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
