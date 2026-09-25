// Authored kernel. See ip/pwm_deadband/SPEC.md for exact semantics.
// Transfer on clk_en && valid && ready. Output and state freeze when !clk_en.
module acc_pwm_deadband (
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
reg [11:0] dbphi, dbph0, dbph1, dbpem1, dbphn, dbdv, dbpr, dbbeat, dbbeatn;
reg [11:0] dbrun12;
reg signed [13:0] dbs2, dbdev;
reg [13:0] dbabs;
reg [15:0] dbrun, dbrunn;
reg [7:0] dbnb, dbth;
reg [3:0] dbedge, dbsupp, dbedgen, dbsuppn;
reg dbdir, dbdirn, dbreqp, dbreq, dbhip, dblop, dbhi, dblo, dbev, dbct;
reg dbsame, dbpass, dbshort, dbtoggle, dbdutybad, dbnbad, dbovl, dbalarm;
reg dbgate, dbctr, dbres, dbseen;
assign in_ready = clk_en && (!out_valid || out_ready);
always @* begin
    r=0; x=0; f=0; temp=0; mask=0; pa=0; pb=0; pc=0; ph=0; pl=0;
    ext=0; wide=0; wide2=0; swide=0; swide2=0; data={a,b,c};
    sa=$signed(a); sb=$signed(b); sc=$signed(c);
    i=0; j=0; idx=0; lane=0; sh=0; state_n=state_r;
    dbdv = a[11:0];
dbpr = a[23:12];
dbnb = b[7:0];
dbth = b[15:8];
dbres = c[31];
dbctr = c[30];
dbgate = c[29];
if(dbres) begin
    dbphi = 12'd0; dbdir = 1'b0; dbrun = 16'd0; dbreqp = 1'b0;
    dbhip = 1'b0; dblop = 1'b0; dbbeat = 12'd0; dbedge = 4'd0;
    dbsupp = 4'd0; dbseen = 1'b0;
end else begin
    dbphi = state_r[11:0]; dbdir = state_r[12]; dbrun = state_r[28:13];
    dbreqp = state_r[29]; dbhip = state_r[30]; dblop = state_r[31];
    dbbeat = state_r[43:32]; dbedge = state_r[47:44]; dbsupp = state_r[51:48];
    dbseen = state_r[52];
end
dbph0 = dbphi + 12'd1;
dbph1 = dbphi - 12'd1;
dbpem1 = dbpr - 12'd1;
dbev = (dbphi < dbdv);
dbs2 = $signed({2'b00, dbphi, 1'b0});
dbdev = dbs2 - ($signed({2'b00, dbpr}) - 14'sd1);
dbabs = dbdev < 14'sd0 ? -dbdev : dbdev;
dbct = (dbabs < {2'd0, dbdv});
dbreq = dbctr ? dbct : dbev;
dbsame = (dbreq == dbreqp);
if(dbsame) dbrunn = (dbrun == 16'hffff) ? dbrun : (dbrun + 16'd1);
else dbrunn = 16'd1;
dbpass = dbgate && (dbrunn > {8'd0, dbnb});
dbhi = dbpass && dbreq;
dblo = dbpass && !dbreq;
dbshort = (!dbsame) && (dbrun != 16'd0) && (dbrun <= {8'd0, dbnb});
dbtoggle = (dbhi != dbhip) || (dblo != dblop);
dbbeatn = (dbbeat == 12'hfff) ? dbbeat : (dbbeat + 12'd1);
dbseen = dbseen || dbhi || dblo;
dbedgen = dbtoggle ? ((dbedge == 4'hf) ? dbedge : (dbedge + 4'd1)) : dbedge;
dbsuppn = dbshort ? ((dbsupp == 4'hf) ? dbsupp : (dbsupp + 4'd1)) : dbsupp;
if(dbctr) begin
    if(!dbdir) begin
        if(dbphi >= dbpem1) begin dbphn = dbpem1; dbdirn = 1'b1; end
        else begin dbphn = dbph0; dbdirn = 1'b0; end
    end else begin
        if(dbphi == 12'd0) begin dbphn = 12'd0; dbdirn = 1'b0; end
        else begin dbphn = dbph1; dbdirn = 1'b1; end
    end
end else begin
    dbphn = (dbph0 >= dbpr) ? 12'd0 : dbph0;
    dbdirn = dbdir;
end
dbdutybad = ({2'd0, dbdv} > {2'd0, dbpr});
dbnbad = ({6'd0, dbnb} > {2'd0, dbpr});
dbovl = dbhi && dblo;
dbalarm = (dbth != 8'd0) && (dbbeatn > {4'd0, dbth}) && !dbseen;
dbrun12 = (dbrunn > 16'd4095) ? 12'hfff : dbrunn[11:0];
if(a[31:24]!=0 || dbpr==12'd0 || b[31:16]!=0 || c[28:8]!=0) f=1'b1;
else begin
    state_n[11:0] = dbphn;
    state_n[12] = dbdirn;
    state_n[28:13] = dbrunn;
    state_n[29] = dbreq;
    state_n[30] = dbhi;
    state_n[31] = dblo;
    state_n[43:32] = dbbeatn;
    state_n[47:44] = dbedgen;
    state_n[51:48] = dbsuppn;
    state_n[52] = dbseen;
    r = {dbsuppn, dbedgen, dbtoggle, dbshort, dbovl, dbalarm, dbnbad, dbdutybad,
         dbres, dbctr, dbgate, dbreq, dbhi, dblo, dbrun12};
    x = {dbhi, dblo, dbdirn, dbreq, dbrunn, dbphn};
    f = dbdutybad || dbnbad || dbovl || dbalarm;
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
