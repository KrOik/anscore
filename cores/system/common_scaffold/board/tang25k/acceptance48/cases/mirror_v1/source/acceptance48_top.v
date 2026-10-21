module acceptance48_top #(parameter UART_DIV=434,parameter TIMEOUT_CYCLES=50000000)(
 input wire clk,uart_rx_pin,output wire uart_tx,dbg_uart);
reg [10:0] por=0;reg rst_n=0;always @(posedge clk)begin if(!(&por))por<=por+1'b1;rst_n<=&por;end
assign dbg_uart=uart_tx;
wire [15:0] ci,ii,ai,ki,ei;wire ce,cv,cr,rv,rr,sv,sr,av,ar,kv,kr,mv,mr,ms,me;
wire [7:0] tag,rt;wire [1:0] re;wire [23:0] md;wire [31:0] ddata=md;
wire mem_valid,mem_write,mem_response_ready;wire [31:0] errors,digest;wire timed_out,finished;
reg [383:0] configuration;always @* begin configuration=0;case(ci)
16'd0: configuration=384'hc000c00000000000000000000000000000000000000000003000400030004300;
16'd1: configuration=384'h30003000000000000c000c00000000000000000000000000000000000000000003000400030004311;
16'd2: configuration=384'h60006000000000000c000c00000000000000000000000000000000000000000003000400030004322;
16'd3: configuration=384'h90009000000000000c000c00000000000000000000000000000000000000000003000400030004333;
16'd4: configuration=384'hc000c1000000000000000000000000000000000000000000000000000000000002000200020002344;
16'd5: configuration=384'hc000c2000000000000000000000000000000000000000000000000000000000002000300020002350;
default:configuration=0;endcase end
reg [33:0] input_word;always @* begin input_word=0;case(ii)
16'd0: input_word=34'h2002c22b9;
16'd1: input_word=34'h25f36c;
16'd2: input_word=34'h8acecc;
16'd3: input_word=34'h10099b363;
16'd4: input_word=34'hd9d557;
16'd5: input_word=34'h3b77ed;
16'd6: input_word=34'h118d96;
16'd7: input_word=34'h1001c5890;
16'd8: input_word=34'h63fd43;
16'd9: input_word=34'h6d8ed4;
16'd10: input_word=34'hfc3377;
16'd11: input_word=34'h10041f2ce;
16'd12: input_word=34'h200cee5fd;
16'd13: input_word=34'hcf61d1;
16'd14: input_word=34'hd8351;
16'd15: input_word=34'h100618f76;
16'd16: input_word=34'hfc357d;
16'd17: input_word=34'h99ab57;
16'd18: input_word=34'h62bd4;
16'd19: input_word=34'h100eea676;
16'd20: input_word=34'h2a91f6;
16'd21: input_word=34'h1cc2ff;
16'd22: input_word=34'h76fc0d;
16'd23: input_word=34'h100811e44;
16'd24: input_word=34'h2006ce87a;
16'd25: input_word=34'heb19b9;
16'd26: input_word=34'h82dfd7;
16'd27: input_word=34'h10043add5;
16'd28: input_word=34'hee2ce0;
16'd29: input_word=34'h2e4b2f;
16'd30: input_word=34'h442873;
16'd31: input_word=34'h1006c9c6b;
16'd32: input_word=34'h4c5e7a;
16'd33: input_word=34'h6fd123;
16'd34: input_word=34'h23c480;
16'd35: input_word=34'h1009a4fb2;
16'd36: input_word=34'h200ae41cc;
16'd37: input_word=34'h7105f1;
16'd38: input_word=34'hda37d0;
16'd39: input_word=34'h100578ff6;
16'd40: input_word=34'h15219f;
16'd41: input_word=34'hb5539a;
16'd42: input_word=34'hf9cf54;
16'd43: input_word=34'h1001748a1;
16'd44: input_word=34'h48bbf7;
16'd45: input_word=34'h6fec75;
16'd46: input_word=34'h1bb683;
16'd47: input_word=34'h100d48cb6;
default:input_word=0;endcase end
reg [33:0] expected_word;always @* begin expected_word=0;case(ei)
16'd0: expected_word=34'h2002c22b9;
16'd1: expected_word=34'h25f36c;
16'd2: expected_word=34'h8acecc;
16'd3: expected_word=34'h10099b363;
16'd4: expected_word=34'hd9d557;
16'd5: expected_word=34'h3b77ed;
16'd6: expected_word=34'h118d96;
16'd7: expected_word=34'h1001c5890;
16'd8: expected_word=34'h63fd43;
16'd9: expected_word=34'h6d8ed4;
16'd10: expected_word=34'hfc3377;
16'd11: expected_word=34'h10041f2ce;
16'd12: expected_word=34'h200618f76;
16'd13: expected_word=34'hd8351;
16'd14: expected_word=34'hcf61d1;
16'd15: expected_word=34'h100cee5fd;
16'd16: expected_word=34'heea676;
16'd17: expected_word=34'h62bd4;
16'd18: expected_word=34'h99ab57;
16'd19: expected_word=34'h100fc357d;
16'd20: expected_word=34'h811e44;
16'd21: expected_word=34'h76fc0d;
16'd22: expected_word=34'h1cc2ff;
16'd23: expected_word=34'h1002a91f6;
16'd24: expected_word=34'h2004c5e7a;
16'd25: expected_word=34'h6fd123;
16'd26: expected_word=34'h23c480;
16'd27: expected_word=34'h1009a4fb2;
16'd28: expected_word=34'hee2ce0;
16'd29: expected_word=34'h2e4b2f;
16'd30: expected_word=34'h442873;
16'd31: expected_word=34'h1006c9c6b;
16'd32: expected_word=34'h6ce87a;
16'd33: expected_word=34'heb19b9;
16'd34: expected_word=34'h82dfd7;
16'd35: expected_word=34'h10043add5;
16'd36: expected_word=34'h200d48cb6;
16'd37: expected_word=34'h1bb683;
16'd38: expected_word=34'h6fec75;
16'd39: expected_word=34'h10048bbf7;
16'd40: expected_word=34'h1748a1;
16'd41: expected_word=34'hf9cf54;
16'd42: expected_word=34'hb5539a;
16'd43: expected_word=34'h10015219f;
16'd44: expected_word=34'h578ff6;
16'd45: expected_word=34'hda37d0;
16'd46: expected_word=34'h7105f1;
16'd47: expected_word=34'h100ae41cc;
default:expected_word=0;endcase end
reg [33:0] aux_word;always @* begin aux_word=0;case(ai)
default:aux_word=0;endcase end
reg [47:0] coefficient_word;always @* begin coefficient_word=0;case(ki)
default:coefficient_word=0;endcase end

acceptance48_driver #(.COMMANDS(6),.CASE_ID(32'h4d495252),.UART_DIV(UART_DIV),.TIMEOUT_CYCLES(TIMEOUT_CYCLES)) driver(
 .clk(clk),.rst_n(rst_n),.command_index(ci),.configuration(configuration),.input_index(ii),.aux_index(ai),.coefficient_index(ki),.expected_index(ei),
 .input_word(input_word),.aux_word(aux_word),.expected_word(expected_word),.coefficient_word(coefficient_word),.ce(ce),.cmd_valid(cv),.cmd_ready(cr),.cmd_tag(tag),
 .rsp_valid(rv),.rsp_ready(rr),.rsp_tag(rt),.rsp_error(re),.s_valid(sv),.s_ready(sr),.aux_valid(av),.aux_ready(ar),.coeff_valid(kv),.coeff_ready(kr),
 .m_valid(mv),.m_ready(mr),.m_data(ddata),.m_sof(ms),.m_eol(me),.unexpected_memory(mem_valid || mem_write || mem_response_ready),
 .uart_tx(uart_tx),.done(finished),.error_count(errors),.digest(digest),.timed_out(timed_out));
cip_image_mirror_flip #(.DATA_W(24),.TAG_W(8),.MAX_WIDTH(8),.MAX_HEIGHT(6)) dut(.clk(clk),.rst_n(rst_n),.clk_en(ce),.cmd_valid(cv),.cmd_ready(cr),.cmd_tag(tag),.rsp_valid(rv),.rsp_ready(rr),.rsp_tag(rt),.rsp_error(re),
 .cfg_mode(configuration[3:0]),.cfg_src_width(configuration[27:12]),.cfg_src_height(configuration[43:28]),.cfg_dst_width(configuration[59:44]),.cfg_dst_height(configuration[75:60]),
 .cfg_param0(configuration[107:76]),.cfg_param1(configuration[139:108]),.cfg_frame_base(configuration[171:140]),.cfg_frame_stride(configuration[203:172]),.cfg_aux_base(configuration[235:204]),
 .coeff_valid(kv),.coeff_ready(kr),.coeff_addr(coefficient_word[47:32]),.coeff_data(coefficient_word[31:0]),
 .aux_data(aux_word[23:0]),.aux_valid(av),.aux_sof(aux_word[33]),.aux_eol(aux_word[32]),.aux_ready(ar),
 .mem_req_valid(mem_valid),.mem_req_write(mem_write),.mem_rsp_ready(mem_response_ready),.mem_req_ready(1'b0),.mem_rsp_valid(1'b0),.mem_rsp_rdata(32'd0),.mem_rsp_error(1'b0),
 .s_data(input_word[23:0]),.s_valid(sv),.s_sof(input_word[33]),.s_eol(input_word[32]),.s_ready(sr),.m_data(md),.m_valid(mv),.m_sof(ms),.m_eol(me),.m_ready(mr));
endmodule
