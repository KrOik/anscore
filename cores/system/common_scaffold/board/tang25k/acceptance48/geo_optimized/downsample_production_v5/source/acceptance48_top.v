module acceptance48_top #(parameter UART_DIV=434,parameter TIMEOUT_CYCLES=50000000)(
 input wire clk,uart_rx_pin,output wire uart_tx,dbg_uart);
reg [10:0] por=0;reg rst_n=0;always @(posedge clk)begin if(!(&por))por<=por+1'b1;rst_n<=&por;end
assign dbg_uart=uart_tx;
wire [15:0] ci,ii,ai,ki,ei;wire ce,cv,cr,rv,rr,sv,sr,av,ar,kv,kr,mv,mr,ms,me;
wire [7:0] tag,rt;wire [1:0] re;wire [23:0] md;wire [31:0] ddata=md;
wire mem_valid,mem_write,mem_response_ready;wire [31:0] errors,digest;wire timed_out,finished;
reg [383:0] configuration_rom;always @* begin configuration_rom=0;case(ci)
16'd0: configuration_rom=384'h6001400000000000000000000000000000000000000000002000300040005300;
16'd1: configuration_rom=384'h180050000000000006002300000000000000000000000000000000000000000003000200050007310;
16'd2: configuration_rom=384'h3000dc000000000006001400000000000000000000000000000002000000020002000300040005321;
16'd3: configuration_rom=384'h48012c000000000002000500000000000000000000000000000003000000030002000100050001331;
16'd4: configuration_rom=384'h500141000000000000000000000000000000000000000000000000000000000001000100020002342;
16'd5: configuration_rom=384'h500142000000000000000000000000000000000000000000000000000000000002000300020002350;
default:configuration_rom=0;endcase end
reg [383:0] configuration;always @(posedge clk) configuration<=configuration_rom;
reg [33:0] input_word_rom;always @* begin input_word_rom=0;case(ii)
16'd0: input_word_rom=34'h2002c22b9;
16'd1: input_word_rom=34'h25f36c;
16'd2: input_word_rom=34'h8acecc;
16'd3: input_word_rom=34'h99b363;
16'd4: input_word_rom=34'h100d9d557;
16'd5: input_word_rom=34'h3b77ed;
16'd6: input_word_rom=34'h118d96;
16'd7: input_word_rom=34'h1c5890;
16'd8: input_word_rom=34'h63fd43;
16'd9: input_word_rom=34'h1006d8ed4;
16'd10: input_word_rom=34'hfc3377;
16'd11: input_word_rom=34'h41f2ce;
16'd12: input_word_rom=34'hcee5fd;
16'd13: input_word_rom=34'hcf61d1;
16'd14: input_word_rom=34'h1000d8351;
16'd15: input_word_rom=34'h618f76;
16'd16: input_word_rom=34'hfc357d;
16'd17: input_word_rom=34'h99ab57;
16'd18: input_word_rom=34'h62bd4;
16'd19: input_word_rom=34'h100eea676;
16'd20: input_word_rom=34'h2002a91f6;
16'd21: input_word_rom=34'h1cc2ff;
16'd22: input_word_rom=34'h76fc0d;
16'd23: input_word_rom=34'h811e44;
16'd24: input_word_rom=34'h6ce87a;
16'd25: input_word_rom=34'heb19b9;
16'd26: input_word_rom=34'h10082dfd7;
16'd27: input_word_rom=34'h43add5;
16'd28: input_word_rom=34'hee2ce0;
16'd29: input_word_rom=34'h2e4b2f;
16'd30: input_word_rom=34'h442873;
16'd31: input_word_rom=34'h6c9c6b;
16'd32: input_word_rom=34'h4c5e7a;
16'd33: input_word_rom=34'h1006fd123;
16'd34: input_word_rom=34'h23c480;
16'd35: input_word_rom=34'h9a4fb2;
16'd36: input_word_rom=34'hae41cc;
16'd37: input_word_rom=34'h7105f1;
16'd38: input_word_rom=34'hda37d0;
16'd39: input_word_rom=34'h578ff6;
16'd40: input_word_rom=34'h10015219f;
16'd41: input_word_rom=34'hb5539a;
16'd42: input_word_rom=34'hf9cf54;
16'd43: input_word_rom=34'h1748a1;
16'd44: input_word_rom=34'h48bbf7;
16'd45: input_word_rom=34'h6fec75;
16'd46: input_word_rom=34'h1bb683;
16'd47: input_word_rom=34'h100d48cb6;
16'd48: input_word_rom=34'h4b1bd4;
16'd49: input_word_rom=34'h3c0c9d;
16'd50: input_word_rom=34'hbfd282;
16'd51: input_word_rom=34'hda1994;
16'd52: input_word_rom=34'h6b3f20;
16'd53: input_word_rom=34'hed4f8a;
16'd54: input_word_rom=34'h100383d88;
16'd55: input_word_rom=34'h200a22b97;
16'd56: input_word_rom=34'h7d68dd;
16'd57: input_word_rom=34'h40fcce;
16'd58: input_word_rom=34'h8d7a33;
16'd59: input_word_rom=34'h100ddd912;
16'd60: input_word_rom=34'hc05ca4;
16'd61: input_word_rom=34'hed8e7d;
16'd62: input_word_rom=34'h9bf7f;
16'd63: input_word_rom=34'h129450;
16'd64: input_word_rom=34'h1001eb8a1;
16'd65: input_word_rom=34'h26b1a9;
16'd66: input_word_rom=34'hacd360;
16'd67: input_word_rom=34'h3ad0ab;
16'd68: input_word_rom=34'h5b9e50;
16'd69: input_word_rom=34'h100ef3e5d;
16'd70: input_word_rom=34'h21c9d0;
16'd71: input_word_rom=34'h47817e;
16'd72: input_word_rom=34'h80dbc7;
16'd73: input_word_rom=34'h4c9d71;
16'd74: input_word_rom=34'h1006dfb09;
16'd75: input_word_rom=34'h300a36995;
16'd76: input_word_rom=34'h1000b5273;
16'd77: input_word_rom=34'h100cfa402;
16'd78: input_word_rom=34'h10094bd53;
16'd79: input_word_rom=34'h1004c40a1;
default:input_word_rom=0;endcase end
reg [33:0] input_word;always @(posedge clk) input_word<=input_word_rom;
reg [33:0] expected_word_rom;always @* begin expected_word_rom=0;case(ei)
16'd0: expected_word_rom=34'h2002a7bb2;
16'd1: expected_word_rom=34'h50aa93;
16'd2: expected_word_rom=34'h10094c17b;
16'd3: expected_word_rom=34'ha87589;
16'd4: expected_word_rom=34'ha1a4b1;
16'd5: expected_word_rom=34'h100767590;
16'd6: expected_word_rom=34'h200578c9c;
16'd7: expected_word_rom=34'h100828c84;
16'd8: expected_word_rom=34'h7a67a9;
16'd9: expected_word_rom=34'h1006a69b0;
16'd10: expected_word_rom=34'h82619e;
16'd11: expected_word_rom=34'h100836f80;
16'd12: expected_word_rom=34'h200a22b97;
16'd13: expected_word_rom=34'h40fcce;
16'd14: expected_word_rom=34'h100ddd912;
16'd15: expected_word_rom=34'h26b1a9;
16'd16: expected_word_rom=34'h3ad0ab;
16'd17: expected_word_rom=34'h100ef3e5d;
16'd18: expected_word_rom=34'h300a36995;
16'd19: expected_word_rom=34'h10094bd53;
default:expected_word_rom=0;endcase end
reg [33:0] expected_word;always @(posedge clk) expected_word<=expected_word_rom;
reg [33:0] aux_word_rom;always @* begin aux_word_rom=0;case(ai)
default:aux_word_rom=0;endcase end
reg [33:0] aux_word;always @(posedge clk) aux_word<=aux_word_rom;
reg [47:0] coefficient_word_rom;always @* begin coefficient_word_rom=0;case(ki)
default:coefficient_word_rom=0;endcase end
reg [47:0] coefficient_word;always @(posedge clk) coefficient_word<=coefficient_word_rom;

acceptance48_driver #(.COMMANDS(6),.CASE_ID(32'h444f574e),.UART_DIV(UART_DIV),.TIMEOUT_CYCLES(TIMEOUT_CYCLES)) driver(
 .clk(clk),.rst_n(rst_n),.command_index(ci),.configuration(configuration),.input_index(ii),.aux_index(ai),.coefficient_index(ki),.expected_index(ei),
 .input_word(input_word),.aux_word(aux_word),.expected_word(expected_word),.coefficient_word(coefficient_word),.ce(ce),.cmd_valid(cv),.cmd_ready(cr),.cmd_tag(tag),
 .rsp_valid(rv),.rsp_ready(rr),.rsp_tag(rt),.rsp_error(re),.s_valid(sv),.s_ready(sr),.aux_valid(av),.aux_ready(ar),.coeff_valid(kv),.coeff_ready(kr),
 .m_valid(mv),.m_ready(mr),.m_data(ddata),.m_sof(ms),.m_eol(me),.unexpected_memory(mem_valid || mem_write || mem_response_ready),
 .uart_tx(uart_tx),.done(finished),.error_count(errors),.digest(digest),.timed_out(timed_out));
cip_image_downsample #(.DATA_W(24),.TAG_W(8),.MAX_WIDTH(8),.MAX_HEIGHT(6),.PIXEL_W(8)) dut(.clk(clk),.rst_n(rst_n),.clk_en(ce),.cmd_valid(cv),.cmd_ready(cr),.cmd_tag(tag),.rsp_valid(rv),.rsp_ready(rr),.rsp_tag(rt),.rsp_error(re),
 .cfg_mode(configuration[3:0]),.cfg_src_width(configuration[27:12]),.cfg_src_height(configuration[43:28]),.cfg_dst_width(configuration[59:44]),.cfg_dst_height(configuration[75:60]),
 .cfg_param0(configuration[107:76]),.cfg_param1(configuration[139:108]),.cfg_frame_base(configuration[171:140]),.cfg_frame_stride(configuration[203:172]),.cfg_aux_base(configuration[235:204]),
 .coeff_valid(kv),.coeff_ready(kr),.coeff_addr(coefficient_word[47:32]),.coeff_data(coefficient_word[31:0]),
 .aux_data(aux_word[23:0]),.aux_valid(av),.aux_sof(aux_word[33]),.aux_eol(aux_word[32]),.aux_ready(ar),
 .mem_req_valid(mem_valid),.mem_req_write(mem_write),.mem_rsp_ready(mem_response_ready),.mem_req_ready(1'b0),.mem_rsp_valid(1'b0),.mem_rsp_rdata(32'd0),.mem_rsp_error(1'b0),
 .s_data(input_word[23:0]),.s_valid(sv),.s_sof(input_word[33]),.s_eol(input_word[32]),.s_ready(sr),.m_data(md),.m_valid(mv),.m_sof(ms),.m_eol(me),.m_ready(mr));
endmodule
