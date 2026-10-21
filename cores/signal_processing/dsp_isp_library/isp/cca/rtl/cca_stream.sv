`timescale 1ns/1ps
// ============================================================================
// cca_stream -- connected-component analysis (CCA) over a binary raster stream.
//
// Streaming single-pass labelling with a deferred union-find equivalence
// table and an end-of-frame resolve pass (SPEC.md has the full contract):
//   scan:  provisional label = min of the distinct nonzero neighbour labels
//          (left always; up-left/up/up-right in 8-conn, up only in 4-conn);
//          sorted distinct neighbour sets with >= 2 members are pushed into
//          the equivalence table; features accumulate on the provisional label.
//   EOF:   apply unions with min-root find -> pointer-doubling flatten ->
//          merge child features into roots -> emit one beat per root region
//          (ascending label) plus one summary beat (m_tuser=1, m_tlast=1).
// No per-pixel label re-emission (features only; documented limitation).
// Label budget NL and merge-event budget EQT overflow -> sticky frame flags
// reported in the summary beat; excess pixels/merge events are dropped.
// ============================================================================
module cca_stream #(
 parameter W_MAX=256,   // maximum frame width,  pixels (runtime legal 3..W_MAX)
 parameter H_MAX=256,   // maximum frame height, lines  (runtime legal 1..H_MAX)
 parameter NL=128,      // provisional-label budget per frame (2..254)
 parameter EQT=256,     // merge-event (equivalence entry) budget per frame
 localparam XW=(W_MAX>1)?$clog2(W_MAX):1,
 localparam YW=(H_MAX>1)?$clog2(H_MAX):1,
 localparam LBLW=$clog2(NL+2),          // labels 0..NL, plus sentinel room
 localparam AW=$clog2(W_MAX*H_MAX)+1,   // area field width
 localparam SW=AW+XW,                   // coordinate-sum field width
 localparam FW=AW+2*SW+2*XW+2*YW,       // feature word width
 localparam RW=LBLW+FW,                 // result beat width
 localparam EQAW=$clog2(EQT+1),         // equivalence count width
 localparam FPASS=$clog2(NL+1)          // pointer-doubling flatten passes
)(
 input wire clk,rst_n,
 // binary pixel stream: tuser=SOF at (0,0), tlast=EOL at x==W-1
 input wire s_tdata,
 input wire s_tvalid,s_tuser,s_tlast,
 output wire s_tready,
 // result stream: one beat per region (m_tuser=0) then one summary beat
 // (m_tuser=1, m_tlast=1). Region beat = {label,area,sumX,sumY,minX,maxX,
 // minY,maxY}; summary = {..,oerr,ovf_eq,ovf_lbl,nalloc,nregions}.
 output reg [RW-1:0] m_tdata,
 output reg m_tvalid,m_tuser,m_tlast,
 input wire m_tready,
 // scalar config bundle; accepted bundle is pending, commits at next SOF
 input wire cfg_valid,output wire cfg_ready,
 input wire [XW:0] cfg_width,
 input wire [YW:0] cfg_height,
 input wire cfg_conn8,
 output reg cfg_done,cfg_error,
 output reg o_error,     // stream protocol violation pulse
 output wire busy
);
localparam [LBLW-1:0] SENT={LBLW{1'b1}};  // > any legal label (sentinel)
// feature field offsets (LSB->MSB): maxY,minY,maxX,minX,sumY,sumX,area
localparam F_MAXY=0,F_MINY=YW,F_MAXX=2*YW,F_MINX=2*YW+XW,
           F_SY=2*YW+2*XW,F_SX=F_SY+SW,F_AR=F_SX+SW;
// FSM states
localparam ST_RUN=0,ST_U_EQRD=1,ST_U_EQCAP=2,ST_U_R1=3,ST_U_R1C=4,
           ST_U_J=5,ST_U_R2=6,ST_U_R2C=7,ST_U_APP=8,
           ST_FL_RD=9,ST_FL_C1=10,ST_FL_C2=11,
           ST_MG_RD=12,ST_MG_C=13,ST_MG_F1=14,ST_MG_F2=15,
           ST_EM_RD=16,ST_EM_C=17,ST_EM_F=18,ST_EM_W=19,
           ST_SUM=20,ST_SUMW=21;

// ------------------------------------------------------------- storage
reg [LBLW-1:0] linebuf[0:W_MAX-1];  // provisional labels, previous row
reg [LBLW-1:0] parent[0:NL];        // union-find parent table
reg [FW-1:0]   feat[0:NL];          // per-label feature word
reg [4*LBLW-1:0] eqtab[0:EQT-1];    // sorted distinct neighbour sets {n1..n4}
reg [LBLW-1:0] rd_q,par_q;          // sync read data registers
reg [FW-1:0] feat_q;
reg [4*LBLW-1:0] eq_q;

// ------------------------------------------------------ config / position
reg [XW:0] a_w; reg [YW:0] a_h; reg a_conn8;
reg [XW:0] p_w; reg [YW:0] p_h; reg p_conn8,pend_valid;
reg [XW-1:0] x; reg [YW-1:0] y; reg in_frame,pending_frame;

// --------------------------------------------------------- scan pipeline
reg f_v,f_pix; reg [XW-1:0] f_x; reg [YW-1:0] f_y;
reg pend_v,p_pix; reg [XW-1:0] p_x; reg [YW-1:0] p_y; reg [LBLW-1:0] p_u;
reg [LBLW-1:0] prev_u,left_lbl;
reg wb_v,wb_new; reg [LBLW-1:0] wb_lbl; reg [XW-1:0] wb_x; reg [YW-1:0] wb_y;
reg [LBLW-1:0] wr_lbl; reg [FW-1:0] wr_data;  // in-flight write forwarding
reg [LBLW-1:0] alloc;
reg [EQAW-1:0] eq_cnt;
reg ovf_lbl,ovf_eq,oerr_f;
reg [LBLW-1:0] nregs;

// ------------------------------------------------------------- FSM regs
reg [4:0] st;
reg [EQAW-1:0] eq_i;
reg [LBLW-1:0] u_i; reg [2:0] u_j;
reg [4:0] fpass;
reg [LBLW-1:0] fc,r1,r2,mroot;
reg [4*LBLW-1:0] eq_d;
reg [FW-1:0] mf;
// Resolve-FSM parent-RAM address mux: combinational (Mealy on st) so the
// registered read data is valid in the state right after the address state.
reg  [LBLW-1:0] par_addr_c;
always @(*) begin
 case(st)
  ST_FL_RD,ST_MG_RD,ST_EM_RD: par_addr_c=u_i;
  ST_FL_C1:                   par_addr_c=par_q;
  ST_FL_C2:                   par_addr_c=u_i;
  ST_U_APP:                   par_addr_c=(r1<r2)?r2:r1;
  default:                    par_addr_c=fc;
 endcase
end

// -------------------------------------------------------------- handshake
wire run=(st==ST_RUN);
wire configured=(a_w!=0);
wire [XW-1:0] a_wm1=a_w[XW-1:0]-1'b1;
// process stage: a pending pixel resolves when the *next* pixel's line-buffer
// read is in flight (f_v) -- that read data doubles as its up-right label --
// or immediately when it is the last column (no UR neighbour).
wire proc_go=run && pend_v && ((p_x==a_wm1) || f_v);
wire f_move=f_v && (!pend_v || proc_go);
assign s_tready=rst_n && run && (in_frame || !pending_frame)
                && (configured || pend_valid) && (!f_v || f_move);
wire fire=s_tvalid && s_tready;
wire commit_edge=fire && s_tuser && pend_valid;
assign cfg_ready=rst_n && (!pend_valid || commit_edge);
assign busy=in_frame||f_v||pend_v||wb_v||pending_frame||!run;

// --------------------------------- effective config for the accept cycle
wire e_pick=s_tuser && pend_valid;
wire [XW:0] e_w=e_pick?p_w:a_w;
wire [YW:0] e_h=e_pick?p_h:a_h;
wire [XW-1:0] e_wm1=e_w[XW-1:0]-1'b1;
wire [YW-1:0] e_hm1=e_h[YW-1:0]-1'b1;
wire [XW-1:0] cx=s_tuser?{XW{1'b0}}:x;
wire [YW-1:0] cy=s_tuser?{YW{1'b0}}:y;

wire proto_viol=(s_tuser && in_frame)||(!s_tuser && !in_frame)
               ||(s_tlast && cx!=e_wm1)||(!s_tlast && cx==e_wm1);
wire cfg_bad=(cfg_width<3)||(cfg_width>W_MAX)||(cfg_height<1)
             ||(cfg_height>H_MAX);

// ------------------------------------------------- neighbour label select
// pend.u was captured as U(pend) = label(x,y-1); rd_q at proc time is
// label(f.x,f.y-1) with f.x==p_x+1 -> the up-right neighbour; prev_u keeps
// U(p_x-1) = up-left; left_lbl is this row's previous assigned label.
wire [LBLW-1:0] n_l =(p_x=={XW{1'b0}})?{LBLW{1'b0}}:left_lbl;
wire [LBLW-1:0] n_u =(p_y=={YW{1'b0}})?{LBLW{1'b0}}:p_u;
wire [LBLW-1:0] n_ul=(!a_conn8||p_x=={XW{1'b0}}||p_y=={YW{1'b0}})
                     ?{LBLW{1'b0}}:prev_u;
wire [LBLW-1:0] n_ur=(!a_conn8||p_x==a_wm1||p_y=={YW{1'b0}})
                     ?{LBLW{1'b0}}:rd_q;
// sort the four neighbours ascending (0 -> sentinel, sorts to the top)
function [LBLW-1:0] fmin; input [LBLW-1:0] a,b; fmin=(a<b)?a:b; endfunction
function [LBLW-1:0] fmax; input [LBLW-1:0] a,b; fmax=(a<b)?b:a; endfunction
wire [LBLW-1:0] t1=(n_l==0)?SENT:n_l,  t2=(n_ul==0)?SENT:n_ul;
wire [LBLW-1:0] t3=(n_u==0)?SENT:n_u,  t4=(n_ur==0)?SENT:n_ur;
wire [LBLW-1:0] s1a=fmin(t1,t2),s2a=fmax(t1,t2);
wire [LBLW-1:0] s3a=fmin(t3,t4),s4a=fmax(t3,t4);
wire [LBLW-1:0] s1=fmin(s1a,s3a),s3x=fmax(s1a,s3a);
wire [LBLW-1:0] s2x=fmin(s2a,s4a),s4=fmax(s2a,s4a);
wire [LBLW-1:0] s2=fmin(s2x,s3x),s3=fmax(s2x,s3x);
// distinct nonzero labels in ascending order, zero-padded
wire [LBLW-1:0] n1=(s1==SENT)?{LBLW{1'b0}}:s1;
wire [LBLW-1:0] n2=(s2==SENT||s2==s1)?{LBLW{1'b0}}:s2;
wire [LBLW-1:0] n3=(s3==SENT||s3==s2)?{LBLW{1'b0}}:s3;
wire [LBLW-1:0] n4=(s4==SENT||s4==s3)?{LBLW{1'b0}}:s4;

wire alloc_ok=(alloc<=NL);
wire p_new=p_pix && (n1==0) && alloc_ok;
wire p_drop=p_pix && (n1==0) && !alloc_ok;
wire [LBLW-1:0] L_p=(!p_pix)?{LBLW{1'b0}}
                   :(n1!={LBLW{1'b0}})?n1
                   :(p_new?alloc:{LBLW{1'b0}});
// >=2 distinct nonzero neighbour labels -> equivalence entry.  Note the
// dedup below can leave interior holes (e.g. {4,4,5,X}->{4,0,5,0}), so the
// merge event must test all three remaining slots, not just n2.
wire eq_ev=p_pix && (n2!={LBLW{1'b0}} || n3!={LBLW{1'b0}} || n4!={LBLW{1'b0}});

// -------------------------------------------------------- feature update
wire [FW-1:0] wb_base=(wb_lbl==wr_lbl)?wr_data:feat_q;
function [FW-1:0] facc;  // accumulate one pixel into feature word
 input [FW-1:0] f; input [XW-1:0] px; input [YW-1:0] py;
 begin
  facc={ f[F_AR+:AW]+{{(AW-1){1'b0}},1'b1},
         f[F_SX+:SW]+{{(SW-XW){1'b0}},px},
         f[F_SY+:SW]+{{(SW-YW){1'b0}},py},
         (f[F_MINX+:XW]<px)?f[F_MINX+:XW]:px,
         (f[F_MAXX+:XW]>px)?f[F_MAXX+:XW]:px,
         (f[F_MINY+:YW]<py)?f[F_MINY+:YW]:py,
         (f[F_MAXY+:YW]>py)?f[F_MAXY+:YW]:py };
 end
endfunction
function [FW-1:0] finit; // first pixel of a new label
 input [XW-1:0] px; input [YW-1:0] py;
 begin
  finit={ {{(AW-1){1'b0}},1'b1},{{(SW-XW){1'b0}},px},{{(SW-YW){1'b0}},py},
          px,px,py,py };
 end
endfunction
wire [FW-1:0] wb_feat=wb_new?finit(wb_x,wb_y):facc(wb_base,wb_x,wb_y);
function [FW-1:0] fmerge; // merge child feature word into root's
 input [FW-1:0] r,c;
 begin
  fmerge={ r[F_AR+:AW]+c[F_AR+:AW],
           r[F_SX+:SW]+c[F_SX+:SW],
           r[F_SY+:SW]+c[F_SY+:SW],
           (r[F_MINX+:XW]<c[F_MINX+:XW])?r[F_MINX+:XW]:c[F_MINX+:XW],
           (r[F_MAXX+:XW]>c[F_MAXX+:XW])?r[F_MAXX+:XW]:c[F_MAXX+:XW],
           (r[F_MINY+:YW]<c[F_MINY+:YW])?r[F_MINY+:YW]:c[F_MINY+:YW],
           (r[F_MAXY+:YW]>c[F_MAXY+:YW])?r[F_MAXY+:YW]:c[F_MAXY+:YW] };
 end
endfunction

// resolve-FSM write strobes / parent write data (combinational on st)
wire par_we=(st==ST_U_APP && r1!=r2)||(st==ST_FL_C2);
wire [LBLW-1:0] par_wdata=(st==ST_FL_C2)?par_q:((r1<r2)?r1:r2);
// feature RAM: scan path (proc read / wb write) or FSM path, never both
wire feat_re_w=run?proc_go
                :((st==ST_MG_C)||(st==ST_MG_F1)||(st==ST_EM_C));
wire [LBLW-1:0] feat_ra=run?L_p:((st==ST_MG_F1)?mroot:u_i);
wire feat_we_w=run?(wb_v && wb_lbl!={LBLW{1'b0}}):(st==ST_MG_F2);
wire [LBLW-1:0] feat_wa=run?wb_lbl:mroot;
wire [FW-1:0] feat_wd=run?wb_feat:fmerge(feat_q,mf);
always @(posedge clk) begin
 if(feat_re_w) feat_q<=feat[feat_ra];
 if(feat_we_w) feat[feat_wa]<=feat_wd;
end
// line buffer: read at fire (up label of fired pixel), write at proc
always @(posedge clk) begin
 if(fire) rd_q<=linebuf[cx];
 if(proc_go) linebuf[p_x]<=L_p;
end
// parent table: init at label allocation, FSM accesses otherwise
always @(posedge clk) begin
 par_q<=parent[par_addr_c];
 if(run && proc_go && p_new) parent[L_p]<=L_p[LBLW-1:0];
 else if(par_we) parent[par_addr_c]<=par_wdata;
end
// equivalence table: written during scan, read during resolve
always @(posedge clk) begin
 eq_q<=eqtab[eq_i[EQAW-1:0]];
 if(proc_go && eq_ev && eq_cnt<EQT)
  eqtab[eq_cnt[EQAW-1:0]]<={n4,n3,n2,n1};   // n1 at [LBLW-1:0]
end
// current union target inside eq_d (slots 1..3 = n2..n4)
wire [LBLW-1:0] uj_n=eq_d[u_j*LBLW +: LBLW];
wire [LBLW-1:0] alloc_m1=alloc-1'b1;

// ------------------------------------------------------------- main block
always @(posedge clk) begin
 if(!rst_n) begin
  a_w<=0;a_h<=0;a_conn8<=0;p_w<=0;p_h<=0;p_conn8<=0;pend_valid<=0;
  x<=0;y<=0;in_frame<=0;pending_frame<=0;
  f_v<=0;f_pix<=0;f_x<=0;f_y<=0;
  pend_v<=0;p_pix<=0;p_x<=0;p_y<=0;p_u<=0;prev_u<=0;left_lbl<=0;
  wb_v<=0;wb_new<=0;wb_lbl<=0;wb_x<=0;wb_y<=0;wr_lbl<=0;wr_data<=0;
  alloc<=0;eq_cnt<=0;ovf_lbl<=0;ovf_eq<=0;oerr_f<=0;nregs<=0;
  st<=ST_RUN;eq_i<=0;u_i<=0;u_j<=0;fpass<=0;
  fc<=0;r1<=0;r2<=0;mroot<=0;eq_d<=0;mf<=0;
  m_tdata<=0;m_tvalid<=0;m_tuser<=0;m_tlast<=0;
  cfg_done<=0;cfg_error<=0;o_error<=0;
 end else begin
  cfg_done<=0;cfg_error<=0;o_error<=0;
  // ----------------------------- scalar config accept / commit at SOF
  if(commit_edge) begin
   a_w<=p_w;a_h<=p_h;a_conn8<=p_conn8;pend_valid<=0;
  end
  if(cfg_valid && cfg_ready) begin
   if(cfg_bad) cfg_error<=1;
   else begin
    p_w<=cfg_width;p_h<=cfg_height;p_conn8<=cfg_conn8;
    pend_valid<=1;cfg_done<=1;
   end
  end
  // --------------------------------------- pixel accept + position/markers
  if(fire) begin
   if(proto_viol) begin o_error<=1;oerr_f<=1; end
   if(s_tuser) begin
    pending_frame<=1;ovf_lbl<=0;ovf_eq<=0;oerr_f<=proto_viol?1'b1:1'b0;
    alloc<=1'b1;eq_cnt<=0;
   end
   if(s_tlast || cx==e_wm1) begin
    x<={XW{1'b0}};
    if(cy==e_hm1) begin y<={YW{1'b0}};in_frame<=1'b0; end
    else begin y<=cy+1'b1;in_frame<=1'b1; end
   end else begin
    x<=cx+1'b1;y<=cy;in_frame<=1'b1;
   end
   f_v<=1;f_pix<=s_tdata;f_x<=cx;f_y<=cy;
  end else if(f_move) f_v<=0;
  // ------------------------------------------------ f -> pend transfer
  if(f_move) begin
   pend_v<=1;p_pix<=f_pix;p_x<=f_x;p_y<=f_y;p_u<=rd_q;
  end else if(proc_go) pend_v<=0;
  // -------------------------------------------------- proc stage
  if(proc_go) begin
   prev_u<=p_u;left_lbl<=L_p;
   if(p_new) alloc<=alloc+1'b1;
   if(p_drop) ovf_lbl<=1;
   if(eq_ev) begin
    if(eq_cnt<EQT) eq_cnt<=eq_cnt+1'b1;
    else ovf_eq<=1;
   end
   wb_v<=1;wb_lbl<=L_p;wb_x<=p_x;wb_y<=p_y;wb_new<=p_new;
  end else wb_v<=0;
  // -------------------------------------------------- wb stage forwarding
  if(wb_v && wb_lbl!={LBLW{1'b0}}) begin wr_lbl<=wb_lbl;wr_data<=wb_feat; end
  // ====================================================== resolve FSM
  case(st)
   ST_RUN: begin
    if(pending_frame && !in_frame && !f_v && !pend_v && !wb_v) begin
     eq_i<=0;u_i<=1'b1;fpass<=0;nregs<=0;
     if(eq_cnt!=0) st<=ST_U_EQRD;
     else if(alloc>1) st<=ST_FL_RD;
     else st<=ST_SUM;
    end
   end
   // ---------------- union pass: for each recorded neighbour set apply
   // union(n1,nj) on roots, smaller root absorbs the larger.  All RAM
   // addresses are combinational (par_addr_c / feat_ra keyed by st), so the
   // registered read data is valid one state later.
   ST_U_EQRD: st<=ST_U_EQCAP;                 // eq_q <= eqtab[eq_i]
   ST_U_EQCAP: begin eq_d<=eq_q;fc<=eq_q[LBLW-1:0];u_j<=1;st<=ST_U_R1; end
   ST_U_R1: st<=ST_U_R1C;                     // par_q <= parent[fc]
   ST_U_R1C: begin
    if(par_q==fc) begin r1<=fc;st<=ST_U_J; end
    else begin fc<=par_q;st<=ST_U_R1; end    // find(): chain hop
   end
   ST_U_J: begin
    if(u_j>3) begin
     if(eq_i+1'b1>=eq_cnt) begin
      u_i<=1'b1;st<=ST_FL_RD;
     end else begin eq_i<=eq_i+1'b1;st<=ST_U_EQRD; end
    end else if(uj_n=={LBLW{1'b0}}) u_j<=u_j+1'b1;
    else begin fc<=uj_n;st<=ST_U_R2; end
   end
   ST_U_R2: st<=ST_U_R2C;                     // par_q <= parent[fc]
   ST_U_R2C: begin
    if(par_q==fc) begin r2<=fc;st<=ST_U_APP; end
    else begin fc<=par_q;st<=ST_U_R2; end    // find(): chain hop
   end
   ST_U_APP: begin                            // par_we writes parent[max]=min
    if(r2!=r1) r1<=(r1<r2)?r1:r2;
    u_j<=u_j+1'b1;st<=ST_U_J;
   end
   // ---------------- flatten: parent[i]=parent[parent[i]], FPASS passes
   ST_FL_RD: begin                            // par_q <= parent[u_i]
    if(u_i<alloc) st<=ST_FL_C1;
    else begin
     fpass<=fpass+1'b1;u_i<=1'b1;
     if(fpass+1'b1>=FPASS) begin nregs<=0;st<=ST_MG_RD; end
    end
   end
   ST_FL_C1: begin                            // par_q == parent[u_i]
    if(par_q==u_i) begin u_i<=u_i+1'b1;st<=ST_FL_RD; end
    else st<=ST_FL_C2;                       // par_q <= parent[parent[u_i]]
   end
   ST_FL_C2: begin                            // par_we writes parent[u_i]
    u_i<=u_i+1'b1;st<=ST_FL_RD;
   end
   // ---------------- merge: child features fold into their root, ascending
   ST_MG_RD: begin                            // par_q <= parent[u_i]
    if(u_i<alloc) st<=ST_MG_C;
    else begin u_i<=1'b1;st<=ST_EM_RD; end
   end
   ST_MG_C: begin                             // feat_q <= feat[u_i]
    if(par_q==u_i) begin
     nregs<=nregs+1'b1;u_i<=u_i+1'b1;st<=ST_MG_RD;
    end else begin mroot<=par_q;st<=ST_MG_F1; end
   end
   ST_MG_F1: begin mf<=feat_q;st<=ST_MG_F2; end  // feat_q <= feat[mroot]
   ST_MG_F2: begin                            // feat[mroot] <= fmerge
    u_i<=u_i+1'b1;st<=ST_MG_RD;
   end
   // ---------------- emit: one beat per root, ascending label order
   ST_EM_RD: begin                            // par_q <= parent[u_i]
    if(u_i<alloc) st<=ST_EM_C;
    else st<=ST_SUM;
   end
   ST_EM_C: begin                             // feat_q <= feat[u_i]
    if(par_q==u_i) st<=ST_EM_F;
    else begin u_i<=u_i+1'b1;st<=ST_EM_RD; end
   end
   ST_EM_F: begin
    m_tdata<={u_i,feat_q};m_tvalid<=1;m_tuser<=0;m_tlast<=0;st<=ST_EM_W;
   end
   ST_EM_W: begin
    if(m_tready) begin
     m_tvalid<=0;u_i<=u_i+1'b1;st<=ST_EM_RD;
    end
   end
   // ---------------- summary beat (tuser=1, tlast=1) then reopen input
   ST_SUM: begin
    m_tdata<={{(RW-2*LBLW-3){1'b0}},oerr_f,ovf_eq,ovf_lbl,alloc_m1,nregs};
    m_tvalid<=1;m_tuser<=1;m_tlast<=1;st<=ST_SUMW;
   end
   ST_SUMW: begin
    if(m_tready) begin
     m_tvalid<=0;m_tuser<=0;m_tlast<=0;pending_frame<=0;st<=ST_RUN;
    end
   end
   default: st<=ST_RUN;
  endcase
 end
end
initial begin
 if(W_MAX<3) $fatal(1,"unsupported W_MAX (<3)");
 if(H_MAX<1) $fatal(1,"unsupported H_MAX (<1)");
 if(NL<2 || NL>254) $fatal(1,"unsupported NL (2..254)");
 if(EQT<1) $fatal(1,"unsupported EQT (<1)");
end
endmodule
