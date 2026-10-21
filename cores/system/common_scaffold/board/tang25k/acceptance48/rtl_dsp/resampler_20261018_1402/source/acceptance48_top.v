module acceptance48_top #(parameter UART_DIV=434,parameter TIMEOUT_CYCLES=50000000)(
 input wire clk,uart_rx_pin,output wire uart_tx,dbg_uart);
reg [10:0] por=0;wire rst_n=&por;always @(posedge clk)if(!rst_n)por<=por+1'b1;
assign dbg_uart=uart_tx;
wire [15:0] ci,ii,ai,ki,ei;wire ce,cv,cr,rv,rr,sv,sr,av,ar,kv,kr,mv,mr,ml;
wire [7:0] tag,rt;wire [1:0] re;wire [7:0] md;wire [31:0] ddata={24'd0,md};
wire [31:0] errors,digest;wire timed_out,finished;
reg [383:0] configuration;always @* begin configuration=0;case(ci)
16'd0: configuration=384'h100000000000000000000000000000000000000000000000000000000000000000000000020f;
16'd1: configuration=384'h2000000000000000000000000000000000000000000000000000000010000000000000000210;
16'd2: configuration=384'h20000000000000000000000000221;
16'd3: configuration=384'hffffffef000000010000000000000000231;
16'd4: configuration=384'h3f000000020000000000000000241;
16'd5: configuration=384'h1000000030000000000000000251;
16'd6: configuration=384'hfffffff9000000040000000000000000261;
16'd7: configuration=384'hd000000050000000000000000271;
16'd8: configuration=384'h4000000060000000000000000281;
16'd9: configuration=384'h2000000000000000000000000000000000000000000000005000000070000000000000000291;
16'd10: configuration=384'h20000000000000000000000000000000000000000000000ff0000000000000000000000002a1;
16'd11: configuration=384'h40001000000000000000000000000000000000000000000000000000000002b0;
16'd12: configuration=384'h10000400000000000a0005000000000000000000000000000000000000000000000000000000002c0;
16'd13: configuration=384'h38001800000000001c0011000000000000000000000000000000000000000000000000000000002d0;
16'd14: configuration=384'ha8005c0000000000000000000000000000000000000000000000400000000000000000000000002e1;
16'd15: configuration=384'ha8005c0000000000000000000000000000000000000000000000000000000100000000000000002f1;
16'd16: configuration=384'ha8005c000000000000000000000000000000000000000000000000000000020000000000000000301;
16'd17: configuration=384'ha8005c000000000000000000000000000000000000000000000000000000030000000000000000311;
16'd18: configuration=384'ha8005c000000000000000000000000000000000000000000000000000000040000000000000000321;
16'd19: configuration=384'ha8005c000000000000000000000000000000000000000000000000000000050000000000000000331;
16'd20: configuration=384'ha8005c000000000000000000000000000000000000000000000000000000060000000000000000341;
16'd21: configuration=384'ha8005c000000000007000300000000000000000000000000000000000000000000000000000000350;
default:configuration=0;endcase end
reg [33:0] input_word;always @* begin input_word=0;case(ii)
16'd0: input_word=34'h10000007f;
16'd1: input_word=34'h80;
16'd2: input_word=34'h7f;
16'd3: input_word=34'h0;
16'd4: input_word=34'h1;
16'd5: input_word=34'h1000000ff;
16'd6: input_word=34'h80;
16'd7: input_word=34'hc9;
16'd8: input_word=34'h12;
16'd9: input_word=34'h5b;
16'd10: input_word=34'ha4;
16'd11: input_word=34'hed;
16'd12: input_word=34'h36;
16'd13: input_word=34'h7f;
16'd14: input_word=34'hc8;
16'd15: input_word=34'h11;
16'd16: input_word=34'h5a;
16'd17: input_word=34'ha3;
16'd18: input_word=34'hec;
16'd19: input_word=34'h35;
16'd20: input_word=34'h7e;
16'd21: input_word=34'hc7;
16'd22: input_word=34'h100000010;
16'd23: input_word=34'h80;
16'd24: input_word=34'h0;
16'd25: input_word=34'h10000007f;
default:input_word=0;endcase end
reg [33:0] expected_word;always @* begin expected_word=0;case(ei)
16'd0: expected_word=34'h3f;
16'd1: expected_word=34'h7d;
16'd2: expected_word=34'hf2;
16'd3: expected_word=34'h100000007;
16'd4: expected_word=34'hc0;
16'd5: expected_word=34'h82;
16'd6: expected_word=34'hec;
16'd7: expected_word=34'hf9;
16'd8: expected_word=34'h19;
16'd9: expected_word=34'hff;
16'd10: expected_word=34'hff;
16'd11: expected_word=34'hff;
16'd12: expected_word=34'h0;
16'd13: expected_word=34'h1000000ff;
16'd14: expected_word=34'hc0;
16'd15: expected_word=34'h82;
16'd16: expected_word=34'h1c;
16'd17: expected_word=34'h0;
16'd18: expected_word=34'h6;
16'd19: expected_word=34'he5;
16'd20: expected_word=34'hd4;
16'd21: expected_word=34'hb7;
16'd22: expected_word=34'hf;
16'd23: expected_word=34'h14;
16'd24: expected_word=34'h31;
16'd25: expected_word=34'hd8;
16'd26: expected_word=34'he9;
16'd27: expected_word=34'he2;
16'd28: expected_word=34'h1;
16'd29: expected_word=34'h29;
16'd30: expected_word=34'h5c;
16'd31: expected_word=34'he;
16'd32: expected_word=34'hfa;
16'd33: expected_word=34'hd9;
16'd34: expected_word=34'hf4;
16'd35: expected_word=34'h3e;
16'd36: expected_word=34'h7f;
16'd37: expected_word=34'h1;
16'd38: expected_word=34'he;
16'd39: expected_word=34'h4;
16'd40: expected_word=34'hfe;
16'd41: expected_word=34'h100000001;
16'd42: expected_word=34'h80;
16'd43: expected_word=34'h0;
16'd44: expected_word=34'h0;
16'd45: expected_word=34'h7f;
16'd46: expected_word=34'h0;
16'd47: expected_word=34'h0;
16'd48: expected_word=34'h100000000;
default:expected_word=0;endcase end

acceptance48_driver #(.COMMANDS(22),.CASE_ID(32'h52533332),.UART_DIV(UART_DIV),.TIMEOUT_CYCLES(TIMEOUT_CYCLES)) driver(
 .clk(clk),.rst_n(rst_n),.command_index(ci),.configuration(configuration),.input_index(ii),.aux_index(ai),.coefficient_index(ki),.expected_index(ei),
 .input_word(input_word),.aux_word(34'd0),.expected_word(expected_word),.coefficient_word(48'd0),.ce(ce),.cmd_valid(cv),.cmd_ready(cr),.cmd_tag(tag),
 .rsp_valid(rv),.rsp_ready(rr),.rsp_tag(rt),.rsp_error(re),.s_valid(sv),.s_ready(sr),.aux_valid(av),.aux_ready(1'b0),.coeff_valid(kv),.coeff_ready(1'b0),
 .m_valid(mv),.m_ready(mr),.m_data(ddata),.m_sof(1'b0),.m_eol(ml),.unexpected_memory(1'b0),
 .uart_tx(uart_tx),.done(finished),.error_count(errors),.digest(digest),.timed_out(timed_out));
cip_resampler_stream #(.DATA_W(8),.TAG_W(8),.COEFF_W(8),.TAPS(7),.SHIFT(6),.UP(3),.DOWN(2)) dut(.clk(clk),.rst_n(rst_n),.clk_en(ce),.cmd_valid(cv),.cmd_ready(cr),.cmd_tag(tag),.rsp_valid(rv),.rsp_ready(rr),.rsp_tag(rt),.rsp_error(re),
 .cfg_opcode({4'd0,configuration[3:0]}),.cfg_param0(configuration[107:76]),.cfg_param1(configuration[139:108]),
 .s_data(input_word[7:0]),.s_valid(sv),.s_last(input_word[32]),.s_ready(sr),.m_data(md),.m_valid(mv),.m_last(ml),.m_ready(mr));
endmodule
