module acceptance48_top #(parameter UART_DIV=434,parameter TIMEOUT_CYCLES=50000000)(
 input wire clk,uart_rx_pin,output wire uart_tx,dbg_uart);
reg [10:0] por=0;reg rst_n=0;always @(posedge clk)begin if(!rst_n)begin if(&por)rst_n<=1'b1;else por<=por+1'b1;end end
assign dbg_uart=uart_tx;
wire [15:0] ci,ii,ai,ki,ei;wire ce,cv,cr,rv,rr,sv,sr,av,ar,kv,kr,mv,mr,ml;
wire [7:0] tag,rt;wire [1:0] re;wire [15:0] md;wire [31:0] ddata={16'd0,md};
wire [31:0] errors,digest;wire timed_out,finished;
reg [383:0] configuration;always @* begin configuration=0;case(ci)
16'd0: configuration=384'h100000000000000000000000000000000000000000000000000000000000000000000000020f;
16'd1: configuration=384'h2000000000000000000000000000000000000000000000001000000000000000000000000210;
16'd2: configuration=384'h6000200000000000000000000000000000000000000000000000000000000220;
16'd3: configuration=384'h180008000000000006000200000000000000000000000000000000000064880000000000000000230;
16'd4: configuration=384'h300010000000000006000200000000000000000000000000000000ffff9b780000000000000000240;
16'd5: configuration=384'h4800180000000000060002000000000000000000000000000000000001ffff0000000000000000250;
16'd6: configuration=384'h600020000000000006000200000000000000000000000000000000fffe00000000000000000000260;
16'd7: configuration=384'h780028000000000006000200000000000000000000000000000000000000000000000000000000271;
16'd8: configuration=384'h900030000000000006000200000000000000000000000000000000000064880000000000000000281;
16'd9: configuration=384'ha80038000000000006000200000000000000000000000000000000ffff9b780000000000000000291;
16'd10: configuration=384'hc000400000000000060002000000000000000000000000000000000001ffff00000000000000002a1;
16'd11: configuration=384'hd80048000000000006000200000000000000000000000000000000fffe000000000000000000002b1;
16'd12: configuration=384'hf000520000000000000000000000000000000000000000000000000002000000000000000000002c0;
16'd13: configuration=384'hf000520000000000000000000000000000000000000000000000010000000000000000000000002d1;
default:configuration=0;endcase end
reg [33:0] input_word;always @* begin input_word=0;case(ii)
16'd0: input_word=34'h4e20;
16'd1: input_word=34'h100000000;
16'd2: input_word=34'h89;
16'd3: input_word=34'h10000fc85;
16'd4: input_word=34'h8000;
16'd5: input_word=34'h100007fff;
16'd6: input_word=34'h7fff;
16'd7: input_word=34'h100007fff;
16'd8: input_word=34'h0;
16'd9: input_word=34'h100008000;
16'd10: input_word=34'h4e20;
16'd11: input_word=34'h100000000;
16'd12: input_word=34'h89;
16'd13: input_word=34'h10000fc85;
16'd14: input_word=34'h8000;
16'd15: input_word=34'h100007fff;
16'd16: input_word=34'h7fff;
16'd17: input_word=34'h100007fff;
16'd18: input_word=34'h0;
16'd19: input_word=34'h100008000;
default:input_word=0;endcase end
reg [33:0] expected_word;always @* begin expected_word=0;case(ei)
16'd0: expected_word=34'h80a9;
16'd1: expected_word=34'h0;
16'd2: expected_word=34'h0;
16'd3: expected_word=34'h0;
16'd4: expected_word=34'hffff;
16'd5: expected_word=34'h10000ffff;
16'd6: expected_word=34'h5bc;
16'd7: expected_word=34'h0;
16'd8: expected_word=34'he0;
16'd9: expected_word=34'h0;
16'd10: expected_word=34'hffff;
16'd11: expected_word=34'h10000ffff;
16'd12: expected_word=34'hd2c6;
16'd13: expected_word=34'h0;
16'd14: expected_word=34'hd2ca;
16'd15: expected_word=34'h0;
16'd16: expected_word=34'hffff;
16'd17: expected_word=34'h10000ffff;
16'd18: expected_word=34'h10ce;
16'd19: expected_word=34'hffff;
16'd20: expected_word=34'hb1e0;
16'd21: expected_word=34'h0;
16'd22: expected_word=34'h0;
16'd23: expected_word=34'h100000000;
16'd24: expected_word=34'h2f74;
16'd25: expected_word=34'hffff;
16'd26: expected_word=34'h1eac;
16'd27: expected_word=34'h0;
16'd28: expected_word=34'hffff;
16'd29: expected_word=34'h10000ffff;
16'd30: expected_word=34'h80ac;
16'd31: expected_word=34'h0;
16'd32: expected_word=34'h0;
16'd33: expected_word=34'h0;
16'd34: expected_word=34'h1;
16'd35: expected_word=34'h100000000;
16'd36: expected_word=34'h5cd;
16'd37: expected_word=34'h0;
16'd38: expected_word=34'h0;
16'd39: expected_word=34'h0;
16'd40: expected_word=34'h9df;
16'd41: expected_word=34'h100000000;
16'd42: expected_word=34'h2a1a;
16'd43: expected_word=34'h1;
16'd44: expected_word=34'h1;
16'd45: expected_word=34'h0;
16'd46: expected_word=34'h3243;
16'd47: expected_word=34'h100000000;
16'd48: expected_word=34'h2a1a;
16'd49: expected_word=34'h1;
16'd50: expected_word=34'h0;
16'd51: expected_word=34'h0;
16'd52: expected_word=34'ha022;
16'd53: expected_word=34'h100000000;
16'd54: expected_word=34'hd2cd;
16'd55: expected_word=34'h0;
16'd56: expected_word=34'h0;
16'd57: expected_word=34'h0;
16'd58: expected_word=34'hbfb9;
16'd59: expected_word=34'h100000000;
default:expected_word=0;endcase end

acceptance48_driver #(.COMMANDS(14),.CASE_ID(32'h434f5244),.UART_DIV(UART_DIV),.TIMEOUT_CYCLES(TIMEOUT_CYCLES)) driver(
 .clk(clk),.rst_n(rst_n),.command_index(ci),.configuration(configuration),.input_index(ii),.aux_index(ai),.coefficient_index(ki),.expected_index(ei),
 .input_word(input_word),.aux_word(34'd0),.expected_word(expected_word),.coefficient_word(48'd0),.ce(ce),.cmd_valid(cv),.cmd_ready(cr),.cmd_tag(tag),
 .rsp_valid(rv),.rsp_ready(rr),.rsp_tag(rt),.rsp_error(re),.s_valid(sv),.s_ready(sr),.aux_valid(av),.aux_ready(1'b0),.coeff_valid(kv),.coeff_ready(1'b0),
 .m_valid(mv),.m_ready(mr),.m_data(ddata),.m_sof(1'b0),.m_eol(ml),.unexpected_memory(1'b0),
 .uart_tx(uart_tx),.done(finished),.error_count(errors),.digest(digest),.timed_out(timed_out));
cip_cordic_stream #(.DATA_W(16),.TAG_W(8)) dut(.clk(clk),.rst_n(rst_n),.clk_en(ce),.cmd_valid(cv),.cmd_ready(cr),.cmd_tag(tag),.rsp_valid(rv),.rsp_ready(rr),.rsp_tag(rt),.rsp_error(re),
 .cfg_opcode({4'd0,configuration[3:0]}),.cfg_param0(configuration[107:76]),.cfg_param1(configuration[139:108]),
 .s_data(input_word[15:0]),.s_valid(sv),.s_last(input_word[32]),.s_ready(sr),.m_data(md),.m_valid(mv),.m_last(ml),.m_ready(mr));
endmodule
