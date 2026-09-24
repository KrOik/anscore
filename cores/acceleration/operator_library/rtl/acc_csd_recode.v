// Authored kernel. See ip/csd_recode/SPEC.md for exact semantics.
// Transfer on clk_en && valid && ready. Output and state freeze when !clk_en.
module acc_csd_recode (
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
reg [16:0] cv, cvn;
reg [31:0] cacc, caccn;
reg [4:0] cnt, cntn, cnz, cnzn;
reg cdone, cdonen, chold, csig, cmgneg, csinn, cnzsig;
reg [1:0] ccode;
assign in_ready = clk_en && (!out_valid || out_ready);
always @* begin
    r=0; x=0; f=0; temp=0; mask=0; pa=0; pb=0; pc=0; ph=0; pl=0;
    ext=0; wide=0; wide2=0; swide=0; swide2=0; data={a,b,c};
    sa=$signed(a); sb=$signed(b); sc=$signed(c);
    i=0; j=0; idx=0; lane=0; sh=0; state_n=state_r;
    cv=state_r[16:0]; cacc=state_r[48:17]; cnt=state_r[53:49];
cnz=state_r[58:54]; cdone=state_r[59]; csinn=state_r[60];
cvn=cv; caccn=cacc; cntn=cnt; cnzn=cnz; cdonen=cdone;
chold=1'b0; ccode=2'b00; cnzsig=1'b0; csig=1'b0;
if(c[31]) begin
    csinn=a[15];
    cv=a[15] ? ({1'b0,~a[15:0]}+17'd1) : {1'b0,a[15:0]};
    cacc=32'd0; cnt=5'd0; cnz=5'd0; cdone=1'b0;
    cvn=cv; caccn=cacc; cntn=cnt; cnzn=cnz; cdonen=cdone;
end else if(cdone) begin
    chold=1'b1;
end
if(!chold) begin
    if(cv[0]) begin
        csig=csinn ? !cv[1] : cv[1];
        ccode=csig ? 2'b11 : 2'b01;
        cvn=(csig^csinn) ? ((cv+17'd1)>>1) : ((cv-17'd1)>>1);
        cnzsig=1'b1;
      end else begin
        ccode=2'b00; cvn=cv>>1;
    end
    sh=cnt+cnt;
    caccn=cacc|({30'd0,ccode}<<<sh);
    cntn=cnt+5'd1;
    cnzn=cnz+(cnzsig ? 5'd1 : 5'd0);
    cdonen=(cntn==5'd16);
end
r=caccn;
x[4:0]=cntn; x[5]=cdonen; x[6]=chold; x[7]=cnzsig; x[8]=csig;
x[13:9]=cnzn; x[14]=csinn; x[15]=1'b0; x[31:16]=cvn[15:0];
state_n={195'd0, csinn, cdonen, cnzn, cntn, caccn, cvn};
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
