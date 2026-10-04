// Complex multiply-accumulate run core: out = sat(RNE(sum(a*b) / 2**SHIFT)).
// s_tdata = {a_im,a_re,b_im,b_re} packed little-endian per DATA_W lane:
//   [DATA_W-1:0]=a_re, [2*DATA_W-1:DATA_W]=a_im,
//   [3*DATA_W-1:2*DATA_W]=b_re, [4*DATA_W-1:3*DATA_W]=b_im, all signed.
// s_tlast marks the final product of a run; a run of >=1 beat produces one
// output beat {im,re} saturated to OUT_W. Accumulator saturates at ACC_W
// with a sticky per-run overflow flag (m_tuser[1]); m_tuser[0]=output clip.
// Products are accepted at II=1 whenever the output path is not blocked;
// a completed run stalls the pipeline only while the output slot is held.
// Latency: last input beat -> earliest output transfer = 3 cycles.
module cplx_mac #(
 parameter integer DATA_W=16,parameter integer ACC_W=48,
 parameter integer OUT_W=32,parameter integer SHIFT=0
)(
 input wire clk,rst_n,
 input wire [4*DATA_W-1:0] s_tdata,input wire s_tlast,
 input wire s_tvalid,output wire s_tready,
 output reg [2*OUT_W-1:0] m_tdata,output reg [1:0] m_tuser,
 output reg m_tvalid,input wire m_tready
);
 // stage0: operand registers; stage1: product registers; stage2: accumulator
 reg signed [DATA_W-1:0] r0_ar,r0_ai,r0_br,r0_bi;reg v0,l0;
 reg signed [2*DATA_W-1:0] r1_p1,r1_p2,r1_p3,r1_p4;reg v1,l1;
 reg signed [ACC_W-1:0] acc_re,acc_im;reg accv,runovf;
 reg res_valid,res_ovf;reg signed [ACC_W-1:0] res_re,res_im;
 wire m_free=!m_tvalid || m_tready;
 wire advance=!(res_valid && m_tvalid && !m_tready);
 assign s_tready=rst_n && advance;
 // accumulate math on the stage1 product registers
 wire signed [2*DATA_W:0] term_re=r1_p1-r1_p2;
 wire signed [2*DATA_W:0] term_im=r1_p3+r1_p4;
 wire signed [ACC_W+1:0] base_re=accv ? {{2{acc_re[ACC_W-1]}},acc_re} : {(ACC_W+2){1'b0}};
 wire signed [ACC_W+1:0] base_im=accv ? {{2{acc_im[ACC_W-1]}},acc_im} : {(ACC_W+2){1'b0}};
 localparam signed [ACC_W+1:0] AMAX={3'b000,{(ACC_W-1){1'b1}}};
 localparam signed [ACC_W+1:0] AMIN={3'b111,{(ACC_W-1){1'b0}}};
 wire signed [ACC_W+1:0] sum_re=base_re+{{(ACC_W-2*DATA_W+1){term_re[2*DATA_W]}},term_re};
 wire signed [ACC_W+1:0] sum_im=base_im+{{(ACC_W-2*DATA_W+1){term_im[2*DATA_W]}},term_im};
 wire ovf_re=sum_re>AMAX || sum_re<AMIN;
 wire ovf_im=sum_im>AMAX || sum_im<AMIN;
 wire signed [ACC_W-1:0] nacc_re=ovf_re ? (sum_re>AMAX ? AMAX[ACC_W-1:0] : AMIN[ACC_W-1:0]) : sum_re[ACC_W-1:0];
 wire signed [ACC_W-1:0] nacc_im=ovf_im ? (sum_im>AMAX ? AMAX[ACC_W-1:0] : AMIN[ACC_W-1:0]) : sum_im[ACC_W-1:0];
 // output RNE + saturate on a completed run accumulator
 function signed [ACC_W:0] out_rne;
  input signed [ACC_W-1:0] v;
  reg signed [ACC_W:0] q;reg [ACC_W-1:0] f;
  begin
   if(SHIFT>0)begin
    q=v>>>SHIFT;f={{(ACC_W-SHIFT){1'b0}},v[SHIFT-1:0]};
    if(f>({{(ACC_W-1){1'b0}},1'b1}<<(SHIFT-1)) ||
       (f==({{(ACC_W-1){1'b0}},1'b1}<<(SHIFT-1)) && q[0]))q=q+1'b1;
   end else q={{1{v[ACC_W-1]}},v};
   out_rne=q;
  end
 endfunction
 localparam signed [ACC_W:0] OMAX={{(ACC_W-OUT_W+2){1'b0}},{(OUT_W-1){1'b1}}};
 localparam signed [ACC_W:0] OMIN={{(ACC_W-OUT_W+2){1'b1}},{(OUT_W-1){1'b0}}};
 function signed [OUT_W-1:0] out_pack;
  input signed [ACC_W-1:0] v;
  reg signed [ACC_W:0] q;
  begin
   q=out_rne(v);
   if(q>OMAX)out_pack={(OUT_W-1){1'b1}};
   else if(q<OMIN)out_pack={1'b1,{(OUT_W-1){1'b0}}};
   else out_pack=q[OUT_W-1:0];
  end
 endfunction
 function out_clip;
  input signed [ACC_W-1:0] v;
  reg signed [ACC_W:0] q;
  begin
   q=out_rne(v);
   out_clip=q>OMAX || q<OMIN;
  end
 endfunction
 always @(posedge clk) begin
  if(!rst_n) begin
   v0<=0;l0<=0;v1<=0;l1<=0;accv<=0;runovf<=0;res_valid<=0;m_tvalid<=0;
   res_ovf<=0;acc_re<=0;acc_im<=0;
  end else begin
   if(m_tready)m_tvalid<=1'b0;
   // completed-run holding register drains into the output slot
   if(res_valid && m_free) begin
    m_tvalid<=1'b1;
    m_tdata<={out_pack(res_im),out_pack(res_re)};
    m_tuser<={res_ovf,out_clip(res_im)|out_clip(res_re)};
    res_valid<=1'b0;
   end
   if(advance) begin
    v0<=s_tvalid;l0<=s_tlast;
    if(s_tvalid)begin
     r0_ar<=s_tdata[DATA_W-1:0];r0_ai<=s_tdata[2*DATA_W-1:DATA_W];
     r0_br<=s_tdata[3*DATA_W-1:2*DATA_W];r0_bi<=s_tdata[4*DATA_W-1:3*DATA_W];
    end
    v1<=v0;l1<=l0;
    if(v0)begin
     r1_p1<=r0_ar*r0_br;r1_p2<=r0_ai*r0_bi;
     r1_p3<=r0_ar*r0_bi;r1_p4<=r0_ai*r0_br;
    end
    if(v1)begin
     if(l1)begin
      accv<=1'b0;runovf<=1'b0;
      if(res_valid || !m_free)begin
       res_valid<=1'b1;res_re<=nacc_re;res_im<=nacc_im;
       res_ovf<=runovf|ovf_re|ovf_im;
      end else begin
       m_tvalid<=1'b1;
       m_tdata<={out_pack(nacc_im),out_pack(nacc_re)};
       m_tuser<={runovf|ovf_re|ovf_im,out_clip(nacc_im)|out_clip(nacc_re)};
      end
     end else begin
      acc_re<=nacc_re;acc_im<=nacc_im;accv<=1'b1;
      runovf<=runovf|ovf_re|ovf_im;
     end
    end
   end
  end
 end
`ifndef SYNTHESIS
 initial begin
  if(DATA_W<2 || DATA_W>18 || ACC_W<2*DATA_W+1 || OUT_W<2 || OUT_W>ACC_W+1 ||
     SHIFT<0 || SHIFT>=ACC_W)
   $fatal(1,"cplx_mac: unsupported static configuration");
 end
`endif
endmodule
