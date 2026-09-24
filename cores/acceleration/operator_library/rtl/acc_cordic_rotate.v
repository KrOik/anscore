// Authored kernel. See ip/cordic_rotate/SPEC.md for exact semantics.
// Transfer on clk_en && valid && ready. Output and state freeze when !clk_en.
module acc_cordic_rotate (
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
reg signed [11:0] q_x0, q_y0;
reg signed [13:0] q_th;
reg signed [16:0] q_x, q_y, q_tx, q_ty;
reg signed [15:0] q_z;
reg signed [13:0] q_ox, q_oy;
reg [3:0] q_it, q_k;
reg [1:0] q_pre;
reg q_sr, q_si;
function signed [15:0] q_atan;
    input [3:0] k;
    begin
        case (k)
            4'd0: q_atan = 16'sd2048;
            4'd1: q_atan = 16'sd1209;
            4'd2: q_atan = 16'sd639;
            4'd3: q_atan = 16'sd324;
            4'd4: q_atan = 16'sd163;
            4'd5: q_atan = 16'sd81;
            4'd6: q_atan = 16'sd41;
            4'd7: q_atan = 16'sd20;
            4'd8: q_atan = 16'sd10;
            4'd9: q_atan = 16'sd5;
            4'd10: q_atan = 16'sd3;
            4'd11: q_atan = 16'sd1;
            default: q_atan = 16'sd0;
        endcase
    end
endfunction
assign in_ready = clk_en && (!out_valid || out_ready);
always @* begin
    r=0; x=0; f=0; temp=0; mask=0; pa=0; pb=0; pc=0; ph=0; pl=0;
    ext=0; wide=0; wide2=0; swide=0; swide2=0; data={a,b,c};
    sa=$signed(a); sb=$signed(b); sc=$signed(c);
    i=0; j=0; idx=0; lane=0; sh=0; state_n=state_r;
    q_x0=a[11:0]; q_y0=a[23:12]; q_th=b[13:0]; q_it=c[3:0];
q_sr=1'b0; q_si=1'b0;
if(a[31:24]!=0 || b[31:14]!=0 || c[31:4]!=0 || q_it==4'd0 || q_it>4'd12)
    f=1'b1;
else begin
    q_x=q_x0; q_y=q_y0; q_z=q_th; q_pre=2'd0;
    if(q_z>16'sd4096) begin
        q_tx=q_x; q_x=-q_y; q_y=q_tx; q_z=q_z-16'sd4096; q_pre=2'd1;
    end else if(q_z<-16'sd4096) begin
        q_tx=q_x; q_x=q_y; q_y=-q_tx; q_z=q_z+16'sd4096; q_pre=2'd2;
    end
    for(q_k=4'd0; q_k<4'd12; q_k=q_k+4'd1) begin
        q_tx=q_x>>>q_k; q_ty=q_y>>>q_k;
        q_x=(q_k<q_it) ? ((q_z<16'sd0) ? q_x+q_ty : q_x-q_ty) : q_x;
        q_y=(q_k<q_it) ? ((q_z<16'sd0) ? q_y-q_tx : q_y+q_tx) : q_y;
        q_z=(q_k<q_it) ? ((q_z<16'sd0) ? q_z+q_atan(q_k) : q_z-q_atan(q_k)) : q_z;
    end
    if(q_x>17'sd8191) begin q_ox=14'h1fff; q_sr=1'b1; end
    else if(q_x<-17'sd8192) begin q_ox=14'h2000; q_sr=1'b1; end
    else q_ox=q_x[13:0];
    if(q_y>17'sd8191) begin q_oy=14'h1fff; q_si=1'b1; end
    else if(q_y<-17'sd8192) begin q_oy=14'h2000; q_si=1'b1; end
    else q_oy=q_y[13:0];
    r[13:0]=q_ox; r[27:14]=q_oy; r[28]=q_sr; r[29]=q_si; r[31:30]=q_pre;
    x[15:0]=q_z[15:0]; x[19:16]=q_it; x[23:20]={2'd0, q_pre};
    x[31:24]=8'd0;
    f=q_sr|q_si;
end
end
always @(posedge clk or negedge rst_n) begin
    if(!rst_n) begin
        out_valid<=0; result<=0; aux<=0; fault<=0; state_r<=0;
    end else if(clk_en) begin
        if(in_ready) begin
            out_valid<=in_valid;
            if(in_valid) begin
                result<=r; aux<=x; fault<=f;
            end
        end
    end
end
endmodule
