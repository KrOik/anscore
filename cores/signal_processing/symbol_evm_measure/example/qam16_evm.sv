// SPDX-License-Identifier: Apache-2.0
// Decision-reference EVM measurement from the original QAM16 nearest indices.
module qam16_evm #(
 parameter integer SPACING=3
)(
 input wire clk,rst,
 input wire c_valid,output wire c_ready,input wire[31:0]c_symbols,input wire[7:0]c_tag,
 input wire s_valid,output wire s_ready,input wire[15:0]s_rx,input wire s_last,
 output wire m_valid,input wire m_ready,output wire[2:0]m_status,
 output wire[31:0]m_symbols,output wire[7:0]m_tag,
 output wire[26:0]m_error_energy,output wire[25:0]m_reference_energy,
 output wire[16:0]m_peak_error,output wire[31:0]m_peak_index,m_evm2_q16,
 output wire m_clip,output reg[31:0]m_qam_faults,m_qam_over_range
);
 reg helper_rst_n=0;
 always @(posedge clk)helper_rst_n<=!rst;
 wire core_c_ready,core_s_ready,demap_ready,demap_valid,demap_fault;
 wire[31:0]demap_llr,demap_aux;
 reg meta_full;
 reg[15:0]rx;
 reg last;
 assign c_ready=!rst &&helper_rst_n &&!meta_full &&core_c_ready;
 assign s_ready=!rst &&helper_rst_n &&!meta_full &&core_s_ready &&demap_ready;
 // Constant CE explicitly adapts the original CE-qualified transaction API.
 acc_comm_qam16_llr demapper(.clk(clk),.rst_n(helper_rst_n),.clk_en(1'b1),
   .in_valid(s_valid &&s_ready),.in_ready(demap_ready),.a({16'b0,s_rx}),.b(32'(SPACING)),.c(32'b0),
   .out_valid(demap_valid),.out_ready(meta_full &&core_s_ready &&!rst),
   .result(demap_llr),.aux(demap_aux),.fault(demap_fault));
 // Widen before arithmetic: k in 0..3, full integer SPACING in 1..7,
 // so each resulting reference coordinate is exactly in [-21,+21].
 wire signed[8:0]iref=9'(-3*SPACING)+9'(2*SPACING)*$signed({1'b0,demap_aux[5:4]});
 wire signed[8:0]qref=9'(-3*SPACING)+9'(2*SPACING)*$signed({1'b0,demap_aux[7:6]});
 symbol_evm_measure #(.DATA_W(8),.MAX_SYMBOLS(1024),.TAG_W(8)) measure(
   .clk(clk),.rst(rst),.c_valid(c_valid &&helper_rst_n &&!meta_full),.c_ready(core_c_ready),
   .c_symbols(c_symbols),.c_tag(c_tag),.s_valid(demap_valid &&meta_full &&!rst),.s_ready(core_s_ready),
   .s_rx(rx),.s_ref({qref[7:0],iref[7:0]}),.s_last(last),
   .m_valid(m_valid),.m_ready(m_ready),.m_status(m_status),.m_symbols(m_symbols),.m_tag(m_tag),
   .m_error_energy(m_error_energy),.m_reference_energy(m_reference_energy),.m_peak_error(m_peak_error),
   .m_peak_index(m_peak_index),.m_evm2_q16(m_evm2_q16),.m_clip(m_clip));
 always @(posedge clk)begin
   if(rst)begin meta_full<=0;rx<=0;last<=0;m_qam_faults<=0;m_qam_over_range<=0;end
   else begin
     if(c_valid &&c_ready)begin m_qam_faults<=0;m_qam_over_range<=0;end
     if(s_valid &&s_ready)begin meta_full<=1;rx<=s_rx;last<=s_last;end
     if(demap_valid &&meta_full &&core_s_ready)begin
       meta_full<=0;
       if(demap_fault)m_qam_faults<=m_qam_faults+1'b1;
       if(demap_aux[15])m_qam_over_range<=m_qam_over_range+1'b1;
     end
   end
 end
`ifndef SYNTHESIS
 initial if(SPACING<1 ||SPACING>7)$fatal(1,"qam16_evm: full-width SPACING must be 1..7");
`endif
endmodule
