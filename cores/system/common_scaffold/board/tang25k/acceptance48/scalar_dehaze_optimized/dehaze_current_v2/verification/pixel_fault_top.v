module acceptance48_top #(parameter UART_DIV=434,parameter TIMEOUT_CYCLES=50000000)(
 input wire clk,uart_rx_pin,output wire uart_tx,dbg_uart);
reg [10:0] por=0;reg rst_n=0;always @(posedge clk)begin if(!(&por))por<=por+1'b1;rst_n<=&por;end
assign dbg_uart=uart_tx;
wire [15:0] ci,ii,ai,ki,ei;wire ce,cv,cr,rv,rr,sv,sr,av,ar,kv,kr,mv,mr,ms,me;
wire [7:0] tag,rt;wire [1:0] re;wire [23:0] md;wire [31:0] ddata=md;
wire mem_valid,mem_write,mem_response_ready;wire [31:0] errors,digest;wire timed_out,finished;
reg [383:0] configuration_rom;always @* begin configuration_rom=0;case(ci)
16'd0: configuration_rom=384'h1000100000000000000000000000000c0d0e0200075300001000100010001300;
16'd1: configuration_rom=384'h40004000000000001000100000000000000000000000001c0d0e0200075300001000100010001311;
16'd2: configuration_rom=384'h80008000000000001000100000000000000000000000001c0d0e0200075300001000100010001322;
16'd3: configuration_rom=384'hc000c000000000001000100000000000000000000000009c0d0e0200075300001000100010001333;
16'd4: configuration_rom=384'h100010000000000006000600000000000000000000000000c0d0e0200075300002000300020003340;
16'd5: configuration_rom=384'h280028000000000006000600000000000000000000000001c0d0e0200075300002000300020003351;
16'd6: configuration_rom=384'h400040000000000006000600000000000000000000000001c0d0e0200075300002000300020003362;
16'd7: configuration_rom=384'h580058000000000006000600000000000000000000000009c0d0e0200075300002000300020003373;
16'd8: configuration_rom=384'h700070000000000009000900000000000000000000000000c0d0e0200075300003000300030003380;
16'd9: configuration_rom=384'h940094000000000009000900000000000000000000000001c0d0e0200075300003000300030003391;
16'd10: configuration_rom=384'hb800b8000000000009000900000000000000000000000001c0d0e02000753000030003000300033a2;
16'd11: configuration_rom=384'hdc00dc000000000009000900000000000000000000000009c0d0e02000753000030003000300033b3;
16'd12: configuration_rom=384'h10001010000000000000000000000000000000000000000000000000000000000020002000200023cf;
default:configuration_rom=0;endcase end
reg [383:0] configuration;always @(posedge clk) configuration<=configuration_rom;
reg [33:0] input_word_rom;always @* begin input_word_rom=0;case(ii)
16'd0: input_word_rom=34'h300000000;
16'd1: input_word_rom=34'h300ffffff;
16'd2: input_word_rom=34'h300a5f978;
16'd3: input_word_rom=34'h300ce33d5;
16'd4: input_word_rom=34'h200000000;
16'd5: input_word_rom=34'h0;
16'd6: input_word_rom=34'h100000000;
16'd7: input_word_rom=34'h0;
16'd8: input_word_rom=34'h0;
16'd9: input_word_rom=34'h100000000;
16'd10: input_word_rom=34'h200ffffff;
16'd11: input_word_rom=34'hffffff;
16'd12: input_word_rom=34'h100ffffff;
16'd13: input_word_rom=34'hffffff;
16'd14: input_word_rom=34'hffffff;
16'd15: input_word_rom=34'h100ffffff;
16'd16: input_word_rom=34'h200a42096;
16'd17: input_word_rom=34'h546e35;
16'd18: input_word_rom=34'h10063ec59;
16'd19: input_word_rom=34'h496895;
16'd20: input_word_rom=34'ha5e653;
16'd21: input_word_rom=34'h100ace9f4;
16'd22: input_word_rom=34'h200fee02d;
16'd23: input_word_rom=34'h139cfc;
16'd24: input_word_rom=34'h1002a13a3;
16'd25: input_word_rom=34'h2cca3d;
16'd26: input_word_rom=34'hd66a33;
16'd27: input_word_rom=34'h100513394;
16'd28: input_word_rom=34'h200000000;
16'd29: input_word_rom=34'h0;
16'd30: input_word_rom=34'h100000000;
16'd31: input_word_rom=34'h0;
16'd32: input_word_rom=34'h0;
16'd33: input_word_rom=34'h100000000;
16'd34: input_word_rom=34'h0;
16'd35: input_word_rom=34'h0;
16'd36: input_word_rom=34'h100000000;
16'd37: input_word_rom=34'h200ffffff;
16'd38: input_word_rom=34'hffffff;
16'd39: input_word_rom=34'h100ffffff;
16'd40: input_word_rom=34'hffffff;
16'd41: input_word_rom=34'hffffff;
16'd42: input_word_rom=34'h100ffffff;
16'd43: input_word_rom=34'hffffff;
16'd44: input_word_rom=34'hffffff;
16'd45: input_word_rom=34'h100ffffff;
16'd46: input_word_rom=34'h200360024;
16'd47: input_word_rom=34'h776f13;
16'd48: input_word_rom=34'h100898d40;
16'd49: input_word_rom=34'h41b231;
16'd50: input_word_rom=34'h73c02e;
16'd51: input_word_rom=34'h10044bdba;
16'd52: input_word_rom=34'hed9ecc;
16'd53: input_word_rom=34'h1cce55;
16'd54: input_word_rom=34'h1000267fc;
16'd55: input_word_rom=34'h200cd9f85;
16'd56: input_word_rom=34'h5595c1;
16'd57: input_word_rom=34'h100d244cb;
16'd58: input_word_rom=34'hef261f;
16'd59: input_word_rom=34'h6883dd;
16'd60: input_word_rom=34'h100bdfc4b;
16'd61: input_word_rom=34'hd70be5;
16'd62: input_word_rom=34'he96b87;
16'd63: input_word_rom=34'h100df14a5;
default:input_word_rom=0;endcase end
reg [33:0] input_word;always @(posedge clk) input_word<=input_word_rom;
reg [33:0] expected_word_rom;always @* begin expected_word_rom=0;case(ei)
16'd0: expected_word_rom=34'h300000001;
16'd1: expected_word_rom=34'h300ffffff;
16'd2: expected_word_rom=34'h3008cff14;
16'd3: expected_word_rom=34'h300ce33d5;
16'd4: expected_word_rom=34'h200000000;
16'd5: expected_word_rom=34'h0;
16'd6: expected_word_rom=34'h100000000;
16'd7: expected_word_rom=34'h0;
16'd8: expected_word_rom=34'h0;
16'd9: expected_word_rom=34'h100000000;
16'd10: expected_word_rom=34'h200ffffff;
16'd11: expected_word_rom=34'hffffff;
16'd12: expected_word_rom=34'h100ffffff;
16'd13: expected_word_rom=34'hffffff;
16'd14: expected_word_rom=34'hffffff;
16'd15: expected_word_rom=34'h100ffffff;
16'd16: expected_word_rom=34'h200a0048a;
16'd17: expected_word_rom=34'h435e19;
16'd18: expected_word_rom=34'h1004af334;
16'd19: expected_word_rom=34'h365789;
16'd20: expected_word_rom=34'ha1e93c;
16'd21: expected_word_rom=34'h100a7eff9;
16'd22: expected_word_rom=34'h200fee02d;
16'd23: expected_word_rom=34'h298ff;
16'd24: expected_word_rom=34'h1001b04ab;
16'd25: expected_word_rom=34'h1dc93e;
16'd26: expected_word_rom=34'hd46233;
16'd27: expected_word_rom=34'h10045279b;
16'd28: expected_word_rom=34'h200000000;
16'd29: expected_word_rom=34'h0;
16'd30: expected_word_rom=34'h100000000;
16'd31: expected_word_rom=34'h0;
16'd32: expected_word_rom=34'h0;
16'd33: expected_word_rom=34'h100000000;
16'd34: expected_word_rom=34'h0;
16'd35: expected_word_rom=34'h0;
16'd36: expected_word_rom=34'h100000000;
16'd37: expected_word_rom=34'h200ffffff;
16'd38: expected_word_rom=34'hffffff;
16'd39: expected_word_rom=34'h100ffffff;
16'd40: expected_word_rom=34'hffffff;
16'd41: expected_word_rom=34'hffffff;
16'd42: expected_word_rom=34'h100ffffff;
16'd43: expected_word_rom=34'hffffff;
16'd44: expected_word_rom=34'hffffff;
16'd45: expected_word_rom=34'h100ffffff;
16'd46: expected_word_rom=34'h200360024;
16'd47: expected_word_rom=34'h776f13;
16'd48: expected_word_rom=34'h100858833;
16'd49: expected_word_rom=34'h41b231;
16'd50: expected_word_rom=34'h73c02e;
16'd51: expected_word_rom=34'h10043bdba;
16'd52: expected_word_rom=34'hf397c9;
16'd53: expected_word_rom=34'h1bce54;
16'd54: expected_word_rom=34'h1000166fc;
16'd55: expected_word_rom=34'h200cdb078;
16'd56: expected_word_rom=34'h37a8bf;
16'd57: expected_word_rom=34'h100d244cb;
16'd58: expected_word_rom=34'hf42100;
16'd59: expected_word_rom=34'h4f91e1;
16'd60: expected_word_rom=34'h100b7ff26;
16'd61: expected_word_rom=34'hd701e9;
16'd62: expected_word_rom=34'hee7378;
16'd63: expected_word_rom=34'h100e2079b;
default:expected_word_rom=0;endcase end
reg [33:0] expected_word;always @(posedge clk) expected_word<=expected_word_rom;
reg [33:0] aux_word_rom;always @* begin aux_word_rom=0;case(ai)
default:aux_word_rom=0;endcase end
reg [33:0] aux_word;always @(posedge clk) aux_word<=aux_word_rom;
reg [47:0] coefficient_word_rom;always @* begin coefficient_word_rom=0;case(ki)
default:coefficient_word_rom=0;endcase end
reg [47:0] coefficient_word;always @(posedge clk) coefficient_word<=coefficient_word_rom;

acceptance48_driver #(.COMMANDS(13),.CASE_ID(32'h4448415a),.UART_DIV(UART_DIV),.TIMEOUT_CYCLES(TIMEOUT_CYCLES)) driver(
 .clk(clk),.rst_n(rst_n),.command_index(ci),.configuration(configuration),.input_index(ii),.aux_index(ai),.coefficient_index(ki),.expected_index(ei),
 .input_word(input_word),.aux_word(aux_word),.expected_word(expected_word),.coefficient_word(coefficient_word),.ce(ce),.cmd_valid(cv),.cmd_ready(cr),.cmd_tag(tag),
 .rsp_valid(rv),.rsp_ready(rr),.rsp_tag(rt),.rsp_error(re),.s_valid(sv),.s_ready(sr),.aux_valid(av),.aux_ready(ar),.coeff_valid(kv),.coeff_ready(kr),
 .m_valid(mv),.m_ready(mr),.m_data(ddata),.m_sof(ms),.m_eol(me),.unexpected_memory(mem_valid || mem_write || mem_response_ready),
 .uart_tx(uart_tx),.done(finished),.error_count(errors),.digest(digest),.timed_out(timed_out));
cip_image_dehaze #(.DATA_W(24),.TAG_W(8),.MAX_WIDTH(3),.MAX_HEIGHT(3)) dut(.clk(clk),.rst_n(rst_n),.clk_en(ce),.cmd_valid(cv),.cmd_ready(cr),.cmd_tag(tag),.rsp_valid(rv),.rsp_ready(rr),.rsp_tag(rt),.rsp_error(re),
 .cfg_mode(configuration[3:0]),.cfg_src_width(configuration[27:12]),.cfg_src_height(configuration[43:28]),.cfg_dst_width(configuration[59:44]),.cfg_dst_height(configuration[75:60]),
 .cfg_param0(configuration[107:76]),.cfg_param1(configuration[139:108]),.cfg_frame_base(configuration[171:140]),.cfg_frame_stride(configuration[203:172]),.cfg_aux_base(configuration[235:204]),
 .coeff_valid(kv),.coeff_ready(kr),.coeff_addr(coefficient_word[47:32]),.coeff_data(coefficient_word[31:0]),
 .aux_data(aux_word[23:0]),.aux_valid(av),.aux_sof(aux_word[33]),.aux_eol(aux_word[32]),.aux_ready(ar),
 .mem_req_valid(mem_valid),.mem_req_write(mem_write),.mem_rsp_ready(mem_response_ready),.mem_req_ready(1'b0),.mem_rsp_valid(1'b0),.mem_rsp_rdata(32'd0),.mem_rsp_error(1'b0),
 .s_data(input_word[23:0]),.s_valid(sv),.s_sof(input_word[33]),.s_eol(input_word[32]),.s_ready(sr),.m_data(md),.m_valid(mv),.m_sof(ms),.m_eol(me),.m_ready(mr));
endmodule
