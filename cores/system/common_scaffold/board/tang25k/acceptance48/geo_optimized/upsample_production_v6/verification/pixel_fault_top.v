module acceptance48_top #(parameter UART_DIV=434,parameter TIMEOUT_CYCLES=50000000)(
 input wire clk,uart_rx_pin,output wire uart_tx,dbg_uart);
reg [10:0] por=0;reg rst_n=0;always @(posedge clk)begin if(!(&por))por<=por+1'b1;rst_n<=&por;end
assign dbg_uart=uart_tx;
wire [15:0] ci,ii,ai,ki,ei;wire ce,cv,cr,rv,rr,sv,sr,av,ar,kv,kr,mv,mr,ms,me;
wire [7:0] tag,rt;wire [1:0] re;wire [23:0] md;wire [31:0] ddata=md;
wire mem_valid,mem_write,mem_response_ready;wire [31:0] errors,digest;wire timed_out,finished;
reg [383:0] configuration_rom;always @* begin configuration_rom=0;case(ci)
16'd0: configuration_rom=384'h10000400000000000000000000000000000000000000020004000400020002300;
16'd1: configuration_rom=384'h400010000000000036000600000000000000000000000000000000000000030006000900020003310;
16'd2: configuration_rom=384'h1180028000000000004000100000000000000000000000000000000000000020002000200010001320;
16'd3: configuration_rom=384'h128002c00000000000c000300000000000000000000000000000000000000020006000200030001330;
16'd4: configuration_rom=384'h1580039000000000000000000000000000000000000000000000000000000020004000400020002341;
16'd5: configuration_rom=384'h158003a000000000000000000000000000000000000000000000000000000000004000400020002350;
default:configuration_rom=0;endcase end
reg [383:0] configuration;always @(posedge clk) configuration<=configuration_rom;
reg [33:0] input_word_rom;always @* begin input_word_rom=0;case(ii)
16'd0: input_word_rom=34'h2002c22b9;
16'd1: input_word_rom=34'h10025f36c;
16'd2: input_word_rom=34'h8acecc;
16'd3: input_word_rom=34'h10099b363;
16'd4: input_word_rom=34'h200d9d557;
16'd5: input_word_rom=34'h3b77ed;
16'd6: input_word_rom=34'h100118d96;
16'd7: input_word_rom=34'h1c5890;
16'd8: input_word_rom=34'h63fd43;
16'd9: input_word_rom=34'h1006d8ed4;
16'd10: input_word_rom=34'h300fc3377;
16'd11: input_word_rom=34'h30041f2ce;
16'd12: input_word_rom=34'h100cee5fd;
16'd13: input_word_rom=34'h100cf61d1;
default:input_word_rom=0;endcase end
reg [33:0] input_word;always @(posedge clk) input_word<=input_word_rom;
reg [33:0] expected_word_rom;always @* begin expected_word_rom=0;case(ei)
16'd0: expected_word_rom=34'h2002c22b8;
16'd1: expected_word_rom=34'h298b93;
16'd2: expected_word_rom=34'h25f36c;
16'd3: expected_word_rom=34'h10025f36c;
16'd4: expected_word_rom=34'h5b78c3;
16'd5: expected_word_rom=34'h5da695;
16'd6: expected_word_rom=34'h5fd368;
16'd7: expected_word_rom=34'h1005fd368;
16'd8: expected_word_rom=34'h8acecc;
16'd9: expected_word_rom=34'h92c198;
16'd10: expected_word_rom=34'h99b363;
16'd11: expected_word_rom=34'h10099b363;
16'd12: expected_word_rom=34'h8acecc;
16'd13: expected_word_rom=34'h92c198;
16'd14: expected_word_rom=34'h99b363;
16'd15: expected_word_rom=34'h10099b363;
16'd16: expected_word_rom=34'h200d9d557;
16'd17: expected_word_rom=34'ha5b689;
16'd18: expected_word_rom=34'h7097bb;
16'd19: expected_word_rom=34'h3b77ed;
16'd20: expected_word_rom=34'h2d7ed0;
16'd21: expected_word_rom=34'h1f86b3;
16'd22: expected_word_rom=34'h118d96;
16'd23: expected_word_rom=34'h118d96;
16'd24: expected_word_rom=34'h100118d96;
16'd25: expected_word_rom=34'h9aab6a;
16'd26: expected_word_rom=34'h7fa983;
16'd27: expected_word_rom=34'h64a69b;
16'd28: expected_word_rom=34'h48a3b5;
16'd29: expected_word_rom=34'h409cb1;
16'd30: expected_word_rom=34'h3895ae;
16'd31: expected_word_rom=34'h308dab;
16'd32: expected_word_rom=34'h308dab;
16'd33: expected_word_rom=34'h100308dab;
16'd34: expected_word_rom=34'h5b827d;
16'd35: expected_word_rom=34'h5a9c7d;
16'd36: expected_word_rom=34'h58b67c;
16'd37: expected_word_rom=34'h56d07c;
16'd38: expected_word_rom=34'h53ba92;
16'd39: expected_word_rom=34'h51a4a9;
16'd40: expected_word_rom=34'h4e8ebf;
16'd41: expected_word_rom=34'h4e8ebf;
16'd42: expected_word_rom=34'h1004e8ebf;
16'd43: expected_word_rom=34'h1c5890;
16'd44: expected_word_rom=34'h348f76;
16'd45: expected_word_rom=34'h4bc65d;
16'd46: expected_word_rom=34'h63fd43;
16'd47: expected_word_rom=34'h66d873;
16'd48: expected_word_rom=34'h6ab3a3;
16'd49: expected_word_rom=34'h6d8ed4;
16'd50: expected_word_rom=34'h6d8ed4;
16'd51: expected_word_rom=34'h1006d8ed4;
16'd52: expected_word_rom=34'h1c5890;
16'd53: expected_word_rom=34'h348f76;
16'd54: expected_word_rom=34'h4bc65d;
16'd55: expected_word_rom=34'h63fd43;
16'd56: expected_word_rom=34'h66d873;
16'd57: expected_word_rom=34'h6ab3a3;
16'd58: expected_word_rom=34'h6d8ed4;
16'd59: expected_word_rom=34'h6d8ed4;
16'd60: expected_word_rom=34'h1006d8ed4;
16'd61: expected_word_rom=34'h1c5890;
16'd62: expected_word_rom=34'h348f76;
16'd63: expected_word_rom=34'h4bc65d;
16'd64: expected_word_rom=34'h63fd43;
16'd65: expected_word_rom=34'h66d873;
16'd66: expected_word_rom=34'h6ab3a3;
16'd67: expected_word_rom=34'h6d8ed4;
16'd68: expected_word_rom=34'h6d8ed4;
16'd69: expected_word_rom=34'h1006d8ed4;
16'd70: expected_word_rom=34'h200fc3377;
16'd71: expected_word_rom=34'h100fc3377;
16'd72: expected_word_rom=34'hfc3377;
16'd73: expected_word_rom=34'h100fc3377;
16'd74: expected_word_rom=34'h20041f2ce;
16'd75: expected_word_rom=34'h10041f2ce;
16'd76: expected_word_rom=34'h88ece6;
16'd77: expected_word_rom=34'h10088ece6;
16'd78: expected_word_rom=34'hcee5fd;
16'd79: expected_word_rom=34'h100cee5fd;
16'd80: expected_word_rom=34'hcfa3e7;
16'd81: expected_word_rom=34'h100cfa3e7;
16'd82: expected_word_rom=34'hcf61d1;
16'd83: expected_word_rom=34'h100cf61d1;
16'd84: expected_word_rom=34'hcf61d1;
16'd85: expected_word_rom=34'h100cf61d1;
default:expected_word_rom=0;endcase end
reg [33:0] expected_word;always @(posedge clk) expected_word<=expected_word_rom;
reg [33:0] aux_word_rom;always @* begin aux_word_rom=0;case(ai)
default:aux_word_rom=0;endcase end
reg [33:0] aux_word;always @(posedge clk) aux_word<=aux_word_rom;
reg [47:0] coefficient_word_rom;always @* begin coefficient_word_rom=0;case(ki)
default:coefficient_word_rom=0;endcase end
reg [47:0] coefficient_word;always @(posedge clk) coefficient_word<=coefficient_word_rom;

acceptance48_driver #(.COMMANDS(6),.CASE_ID(32'h5550534d),.UART_DIV(UART_DIV),.TIMEOUT_CYCLES(TIMEOUT_CYCLES)) driver(
 .clk(clk),.rst_n(rst_n),.command_index(ci),.configuration(configuration),.input_index(ii),.aux_index(ai),.coefficient_index(ki),.expected_index(ei),
 .input_word(input_word),.aux_word(aux_word),.expected_word(expected_word),.coefficient_word(coefficient_word),.ce(ce),.cmd_valid(cv),.cmd_ready(cr),.cmd_tag(tag),
 .rsp_valid(rv),.rsp_ready(rr),.rsp_tag(rt),.rsp_error(re),.s_valid(sv),.s_ready(sr),.aux_valid(av),.aux_ready(ar),.coeff_valid(kv),.coeff_ready(kr),
 .m_valid(mv),.m_ready(mr),.m_data(ddata),.m_sof(ms),.m_eol(me),.unexpected_memory(mem_valid || mem_write || mem_response_ready),
 .uart_tx(uart_tx),.done(finished),.error_count(errors),.digest(digest),.timed_out(timed_out));
cip_image_upsample #(.DATA_W(24),.TAG_W(8),.MAX_WIDTH(8),.MAX_HEIGHT(6)) dut(.clk(clk),.rst_n(rst_n),.clk_en(ce),.cmd_valid(cv),.cmd_ready(cr),.cmd_tag(tag),.rsp_valid(rv),.rsp_ready(rr),.rsp_tag(rt),.rsp_error(re),
 .cfg_mode(configuration[3:0]),.cfg_src_width(configuration[27:12]),.cfg_src_height(configuration[43:28]),.cfg_dst_width(configuration[59:44]),.cfg_dst_height(configuration[75:60]),
 .cfg_param0(configuration[107:76]),.cfg_param1(configuration[139:108]),.cfg_frame_base(configuration[171:140]),.cfg_frame_stride(configuration[203:172]),.cfg_aux_base(configuration[235:204]),
 .coeff_valid(kv),.coeff_ready(kr),.coeff_addr(coefficient_word[47:32]),.coeff_data(coefficient_word[31:0]),
 .aux_data(aux_word[23:0]),.aux_valid(av),.aux_sof(aux_word[33]),.aux_eol(aux_word[32]),.aux_ready(ar),
 .mem_req_valid(mem_valid),.mem_req_write(mem_write),.mem_rsp_ready(mem_response_ready),.mem_req_ready(1'b0),.mem_rsp_valid(1'b0),.mem_rsp_rdata(32'd0),.mem_rsp_error(1'b0),
 .s_data(input_word[23:0]),.s_valid(sv),.s_sof(input_word[33]),.s_eol(input_word[32]),.s_ready(sr),.m_data(md),.m_valid(mv),.m_sof(ms),.m_eol(me),.m_ready(mr));
endmodule
