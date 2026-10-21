// Authored kernel. See ip/yuv420_pack/SPEC.md for exact semantics.
// Transfer on clk_en && valid && ready. Output and state freeze when !clk_en.
module acc_yuv420_pack (
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
    if(b[31:1]!=0 || c[30:1]!=0) f=1'b1;
else begin
    if(c[31]) state_n=0;
    idx=state_n[2:0];
    lane=(idx>>1)&1;
    sh=idx&1;
    if(b[0]!=lane) begin
        f=1'b1; r=0; x=0;
        if(c[31]) state_n=0; else state_n=state_r;
    end else begin
        r[7:0]=a[7:0]; r[15:8]=a[15:8];
        x[2:0]=idx; x[3]=lane;
        if(a[15:8]<32'd16 || a[15:8]>32'd240 || a[31:24]<32'd16 ||
           a[31:24]>32'd240) x[27]=1'b1;
        if(a[7:0]==a[15:8]) x[28]=1'b1;
        if(state_n[6:3]==4'd7) x[30]=1'b1;
        if(state_n[9:7]==3'd1) x[29]=1'b1;
        if(idx!=32'd3 && idx!=32'd7) x[31]=1'b1;
        if(lane==0) begin
            state_n[10+(sh<<3) +: 8]=a[15:8];
            state_n[26+(sh<<3) +: 8]=a[31:24];
            x[4]=1'b1;
        end else begin
            pa={24'd0,state_r[10+(sh<<3) +: 8]}+{24'd0,a[15:8]}+32'd1;
            pb={24'd0,state_r[26+(sh<<3) +: 8]}+{24'd0,a[31:24]}+32'd1;
            r[23:16]=pa[8:1]; r[31:24]=pb[8:1];
            x[5]=1'b1;
            if(r[23:16]!=state_r[10+(sh<<3) +: 8] ||
               r[31:24]!=state_r[26+(sh<<3) +: 8]) x[26]=1'b1;
            pc={24'd0,state_r[10+(sh<<3) +: 8]}+{24'd0,a[15:8]};
            ph={24'd0,state_r[26+(sh<<3) +: 8]}+{24'd0,a[31:24]};
            if(pc[0] || ph[0]) x[25]=1'b1;
            state_n[10+(sh<<3) +: 8]=8'd0;
            state_n[26+(sh<<3) +: 8]=8'd0;
        end
        x[15:8]=state_n[6:3]; x[23:16]=state_n[9:7];
        if(idx==32'd3 || idx==32'd7) x[6]=1'b1;
        if(idx==32'd7) begin
            x[7]=1'b1;
            if(state_r[6:3]==4'd7) begin
                if(state_r[9:7]==3'd1) begin
                    x[24]=1'b1;
                    state_n[9:7]=0;
                    state_n[43+:8]=state_r[43+:8]+8'd1;
                end else state_n[9:7]=state_r[9:7]+3'd1;
                state_n[6:3]=0;
            end else state_n[6:3]=state_r[6:3]+4'd1;
            state_n[2:0]=0;
        end else state_n[2:0]=idx+32'd1;
    end
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
