// Authored kernel. See ip/de_timing/SPEC.md for exact semantics.
// Transfer on clk_en && valid && ready. Output and state freeze when !clk_en.
module acc_de_timing (
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
    if(c[31]) begin
    if(b[31]!=0 || c[30:0]!=0) begin
        f=1'b1; r=0; x=0; state_n=state_r;
    end else begin
        pa={22'd0,a[9:0]};
        pb=pa+{15'd0,a[16:10]};
        pc=pb+{15'd0,a[24:17]};
        ph=pc+{16'd0,a[30:25]};
        temp={21'd0,b[10:0]};
        mask=temp+{15'd0,b[18:11]};
        ext=mask+{19'd0,b[22:19]};
        wide=ext+{16'd0,b[30:23]};
        if(pa==0 || temp==0 || a[24:17]==0 || b[22:19]==0 ||
           ph>32'd1023 || wide>64'd1023) begin
            f=1'b1; r=0; x=0; state_n=state_r;
        end else begin
            state_n=0;
            state_n[53:44]=pa[9:0]; state_n[65:54]=pb[11:0];
            state_n[77:66]=pc[11:0]; state_n[31:20]=ph[11:0];
            state_n[87:78]=temp[9:0]; state_n[99:88]=mask[11:0];
            state_n[111:100]=ext[11:0]; state_n[43:32]=wide[11:0];
            state_n[120]=1'b1;
        end
    end
end else begin
    if(a[31:10]!=0 || b[31:10]!=0 || c!=0 || !state_r[120]) begin
        f=1'b1; r=0; x=0; state_n=state_r;
    end else begin
        temp={21'd0,state_r[9:0]}+32'd1;
        mask={21'd0,state_r[19:10]};
        if(temp>={20'd0,state_r[31:20]}) begin
            temp=0;
            mask=mask+32'd1;
            if(mask>={20'd0,state_r[43:32]}) begin
                mask=0;
                state_n[119:112]=state_r[119:112]+8'd1;
            end
        end
        state_n[9:0]=temp[9:0]; state_n[19:10]=mask[9:0];
    end
end
if(!f) begin
    temp=state_n[9:0]; mask=state_n[19:10];
    pa=state_n[53:44]; pb=state_n[65:54]; pc=state_n[77:66];
    ph=state_n[31:20]; pl=state_n[87:78];
    wide=state_n[99:88]; wide2=state_n[111:100];
    ext=state_n[43:32];
    r[9:0]=temp[9:0]; r[19:10]=mask[9:0];
    if(temp<pa && mask<pl) r[20]=1'b1;
    if(temp>=pb && temp<pc) r[21]=1'b1;
    if(mask>=wide && mask<wide2) r[22]=1'b1;
    if(mask<pl) r[23]=1'b1;
    if(temp>=pa) begin
        r[25:24]=2'd1;
        if(temp>=pb) begin
            r[25:24]=2'd2;
            if(temp>=pc) r[25:24]=2'd3;
        end
    end
    if(temp==0) r[26]=1'b1;
    if(temp==ph-32'd1) r[27]=1'b1;
    if(temp==0 && mask==0) r[28]=1'b1;
    if(temp==ph-32'd1 && mask==ext-33'd1) r[29]=1'b1;
    r[30]=c[31];
    if(!c[31] && a[9:0]!=0 && ph>{22'd0,a[9:0]}) r[31]=1'b1;
    x[9:0]=ph[9:0]; x[19:10]=ext[9:0];
    if(mask==wide) x[20]=1'b1;
    if(temp==pb) x[21]=1'b1;
    if(temp==pa-32'd1 && mask<pl) x[22]=1'b1;
    if(!c[31] && b[9:0]!=0 && ext>{23'd0,b[9:0]}) x[23]=1'b1;
    x[31:24]=state_n[119:112];
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
