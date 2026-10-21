// Authored kernel. See ip/img_gaussian5_edge_u8/SPEC.md for exact semantics.
// Transfer on clk_en && valid && ready. Output and state freeze when !clk_en.
module acc_img_gaussian5_edge_u8 (
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

assign in_ready = clk_en && (!out_valid || out_ready);
always @* begin
    r=0; x=0; f=0; temp=0; mask=0; pa=0; pb=0; pc=0; ph=0; pl=0;
    ext=0; wide=0; wide2=0; swide=0; swide2=0; data={a,b,c};
    sa=$signed(a); sb=$signed(b); sc=$signed(c);
    i=0; j=0; idx=0; lane=0; sh=0; state_n=state_r;
    if(c[31:8]!=0) f=1'b1;
else begin
    pa={24'd0,a[7:0]}; pb={24'd0,a[15:8]};
    pc={24'd0,a[23:16]}; ph={24'd0,a[31:24]};
    pl=(c[0]!=0) ? pb : {24'd0,b[7:0]};
    temp=(c[0]!=0) ? pa : {24'd0,b[15:8]};
    ext=pl+(temp<<2)+(pa<<1)+(pa<<2)+(pb<<2)+pc;
    x[0]=ext[3]; ext=ext+33'd8; r[7:0]=ext[11:4];
    ext=temp+(pa<<2)+(pb<<1)+(pb<<2)+(pc<<2)+ph;
    x[1]=ext[3]; ext=ext+33'd8; r[15:8]=ext[11:4];
    mask=(c[1]!=0) ? ph : {24'd0,b[23:16]};
    ext=pa+(pb<<2)+(pc<<1)+(pc<<2)+(ph<<2)+mask;
    x[2]=ext[3]; ext=ext+33'd8; r[23:16]=ext[11:4];
    temp=(c[1]!=0) ? pc : {24'd0,b[31:24]};
    ext=pb+(pc<<2)+(ph<<1)+(ph<<2)+(mask<<2)+temp;
    x[3]=ext[3]; ext=ext+33'd8; r[31:24]=ext[11:4];
    x[4]=c[0]; x[5]=c[1];
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
