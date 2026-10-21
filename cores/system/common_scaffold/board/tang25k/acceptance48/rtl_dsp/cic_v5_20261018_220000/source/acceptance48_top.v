module acceptance48_top #(parameter UART_DIV=434,parameter TIMEOUT_CYCLES=50000000)(
 input wire clk,uart_rx_pin,output wire uart_tx,dbg_uart);
reg [10:0] por=0;reg rst_n=0;always @(posedge clk)begin if(!rst_n)begin if(&por)rst_n<=1'b1;else por<=por+1'b1;end end
assign dbg_uart=uart_tx;
wire [15:0] ci,ii,ai,ki,ei;wire ce,cv,cr,rv,rr,sv,sr,av,ar,kv,kr,mv,mr,ml;
wire [7:0] tag,rt;wire [1:0] re;wire [7:0] md;wire [31:0] ddata={24'd0,md};
wire [31:0] errors,digest;wire timed_out,finished;
reg [383:0] configuration;always @* begin configuration=0;case(ci)
16'd0: configuration=384'h100000000000000000000000000000000000000000000000000000000000000000000000020f;
16'd1: configuration=384'h2000000000000000000000000000000000000000000000000000000010000000000000000210;
16'd2: configuration=384'h1000100000000000000000000000000000000000000000000000000000000220;
16'd3: configuration=384'h40004000000000001000200000000000000000000000000000000000000000000000000000000230;
16'd4: configuration=384'h8000c000000000001000300000000000000000000000000000000000000000000000000000000240;
16'd5: configuration=384'hc0018000000000002000400000000000000000000000000000000000000000000000000000000250;
16'd6: configuration=384'h140028000000000006001100000000000000000000000000000000000000000000000000000000260;
default:configuration=0;endcase end
reg [33:0] input_word;always @* begin input_word=0;case(ii)
16'd0: input_word=34'h10000007f;
16'd1: input_word=34'h80;
16'd2: input_word=34'h10000007f;
16'd3: input_word=34'h7f;
16'd4: input_word=34'h7f;
16'd5: input_word=34'h10000007f;
16'd6: input_word=34'h80;
16'd7: input_word=34'h80;
16'd8: input_word=34'h80;
16'd9: input_word=34'h100000080;
16'd10: input_word=34'h8a;
16'd11: input_word=34'h31;
16'd12: input_word=34'h39;
16'd13: input_word=34'hf1;
16'd14: input_word=34'hb8;
16'd15: input_word=34'h6f;
16'd16: input_word=34'ha3;
16'd17: input_word=34'h90;
16'd18: input_word=34'h51;
16'd19: input_word=34'h66;
16'd20: input_word=34'hec;
16'd21: input_word=34'h24;
16'd22: input_word=34'ha4;
16'd23: input_word=34'h36;
16'd24: input_word=34'hab;
16'd25: input_word=34'hc6;
16'd26: input_word=34'h10000007c;
default:input_word=0;endcase end
reg [33:0] expected_word;always @* begin expected_word=0;case(ei)
16'd0: expected_word=34'h100000007;
16'd1: expected_word=34'h1000000ef;
16'd2: expected_word=34'h10000004f;
16'd3: expected_word=34'hb0;
16'd4: expected_word=34'h100000050;
16'd5: expected_word=34'he0;
16'd6: expected_word=34'h9;
16'd7: expected_word=34'he3;
16'd8: expected_word=34'h13;
16'd9: expected_word=34'h2;
16'd10: expected_word=34'h10000002f;
default:expected_word=0;endcase end

acceptance48_driver #(.COMMANDS(7),.CASE_ID(32'h43494338),.UART_DIV(UART_DIV),.TIMEOUT_CYCLES(TIMEOUT_CYCLES)) driver(
 .clk(clk),.rst_n(rst_n),.command_index(ci),.configuration(configuration),.input_index(ii),.aux_index(ai),.coefficient_index(ki),.expected_index(ei),
 .input_word(input_word),.aux_word(34'd0),.expected_word(expected_word),.coefficient_word(48'd0),.ce(ce),.cmd_valid(cv),.cmd_ready(cr),.cmd_tag(tag),
 .rsp_valid(rv),.rsp_ready(rr),.rsp_tag(rt),.rsp_error(re),.s_valid(sv),.s_ready(sr),.aux_valid(av),.aux_ready(1'b0),.coeff_valid(kv),.coeff_ready(1'b0),
 .m_valid(mv),.m_ready(mr),.m_data(ddata),.m_sof(1'b0),.m_eol(ml),.unexpected_memory(1'b0),
 .uart_tx(uart_tx),.done(finished),.error_count(errors),.digest(digest),.timed_out(timed_out));
cip_cic_decimator #(.DATA_W(8),.TAG_W(8),.RATE(3),.STAGES(3),.SHIFT(4)) dut(.clk(clk),.rst_n(rst_n),.clk_en(ce),.cmd_valid(cv),.cmd_ready(cr),.cmd_tag(tag),.rsp_valid(rv),.rsp_ready(rr),.rsp_tag(rt),.rsp_error(re),
 .cfg_opcode({4'd0,configuration[3:0]}),.cfg_param0(configuration[107:76]),.cfg_param1(configuration[139:108]),
 .s_data(input_word[7:0]),.s_valid(sv),.s_last(input_word[32]),.s_ready(sr),.m_data(md),.m_valid(mv),.m_last(ml),.m_ready(mr));
endmodule
