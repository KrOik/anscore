module acceptance48_top #(parameter UART_DIV=434,parameter TIMEOUT_CYCLES=50000000)(
 input wire clk,uart_rx_pin,output wire uart_tx,dbg_uart);
reg [10:0] por=0;reg rst_n=0;always @(posedge clk)begin if(!(&por))por<=por+1'b1;rst_n<=&por;end
assign dbg_uart=uart_tx;
wire [15:0] ci,ii,ai,ki,ei;wire ce,cv,cr,rv,rr,sv,sr,av,ar,kv,kr,mv,mr,ms,me;
wire [7:0] tag,rt;wire [1:0] re;wire [23:0] md;wire [31:0] ddata=md;
wire mem_valid,mem_write,mem_response_ready;wire [31:0] errors,digest;wire timed_out,finished;
reg [383:0] configuration;always @* begin configuration=0;case(ci)
16'd0: configuration=384'h1000900000000000000000000000000000000000000000001000100030003800;
16'd1: configuration=384'h40024000000000003000f00000000000000000000000000000000000000000001000300030005810;
16'd2: configuration=384'h100060000000000001000900000000000000000000000000000000000000000001000100030003821;
16'd3: configuration=384'h140084000000000003000f00000000000000000000000000000000000000000001000300030005831;
16'd4: configuration=384'h2000c0000000000001000900000000000000000000000000000000000000000001000100030003842;
16'd5: configuration=384'h2400e4000000000003000f00000000000000000000000000000000000000000001000300030005852;
16'd6: configuration=384'h300120000000000001000900000000000000000000000000000000000000000001000100030003863;
16'd7: configuration=384'h340144000000000003000f00000000000000000000000000000000000000000001000300030005873;
16'd8: configuration=384'h40018100000000000000000000000000000000000000000000000000000000000200030004000588f;
16'd9: configuration=384'h400182000000000000000000000000000000000000000000000000000000000002000000040002890;
16'd10: configuration=384'h4001820000000000000000000000000000000000000000000000000000000000000003000200058a0;
16'd11: configuration=384'h4001820000000000000000000000000000000000000000000000000000000000020007000400098b0;
16'd12: configuration=384'h4001820000000000000000000000000000000000000000000000000000000000040005000400058c0;
16'd13: configuration=384'h4001820000000000000000000000000000000000000000000000000000000100020003000400058d0;
16'd14: configuration=384'h4001820000000000000000000000000000000000000000000000010000000000020003000400058e0;
16'd15: configuration=384'h4001800000000000010009000000000000000000000000000000000000000000010001000300038f3;
default:configuration=0;endcase end
reg [33:0] input_word;always @* begin input_word=0;case(ii)
16'd0: input_word=34'h2000000eb;
16'd1: input_word=34'he;
16'd2: input_word=34'h100000092;
16'd3: input_word=34'h2;
16'd4: input_word=34'hec;
16'd5: input_word=34'h100000054;
16'd6: input_word=34'h4e;
16'd7: input_word=34'h2a;
16'd8: input_word=34'h1000000ca;
16'd9: input_word=34'h2000000ed;
16'd10: input_word=34'hb5;
16'd11: input_word=34'h17;
16'd12: input_word=34'h80;
16'd13: input_word=34'h100000086;
16'd14: input_word=34'h5;
16'd15: input_word=34'h83;
16'd16: input_word=34'h94;
16'd17: input_word=34'h47;
16'd18: input_word=34'h100000003;
16'd19: input_word=34'h34;
16'd20: input_word=34'ha7;
16'd21: input_word=34'hd4;
16'd22: input_word=34'h24;
16'd23: input_word=34'h1000000dc;
16'd24: input_word=34'h2000000cb;
16'd25: input_word=34'h1b;
16'd26: input_word=34'h100000051;
16'd27: input_word=34'ha7;
16'd28: input_word=34'hb4;
16'd29: input_word=34'h1000000ce;
16'd30: input_word=34'h60;
16'd31: input_word=34'hfb;
16'd32: input_word=34'h100000045;
16'd33: input_word=34'h200000059;
16'd34: input_word=34'heb;
16'd35: input_word=34'h8a;
16'd36: input_word=34'h40;
16'd37: input_word=34'h100000050;
16'd38: input_word=34'h67;
16'd39: input_word=34'h80;
16'd40: input_word=34'h94;
16'd41: input_word=34'h23;
16'd42: input_word=34'h1000000c3;
16'd43: input_word=34'h49;
16'd44: input_word=34'ha4;
16'd45: input_word=34'h9c;
16'd46: input_word=34'h44;
16'd47: input_word=34'h100000053;
16'd48: input_word=34'h200000099;
16'd49: input_word=34'hbb;
16'd50: input_word=34'h10000008b;
16'd51: input_word=34'h52;
16'd52: input_word=34'hd1;
16'd53: input_word=34'h100000032;
16'd54: input_word=34'h4;
16'd55: input_word=34'ha3;
16'd56: input_word=34'h1000000ef;
16'd57: input_word=34'h2000000e9;
16'd58: input_word=34'h71;
16'd59: input_word=34'h1f;
16'd60: input_word=34'h4f;
16'd61: input_word=34'h1000000bd;
16'd62: input_word=34'hc2;
16'd63: input_word=34'hbe;
16'd64: input_word=34'h37;
16'd65: input_word=34'hd7;
16'd66: input_word=34'h10000002f;
16'd67: input_word=34'h1;
16'd68: input_word=34'hc4;
16'd69: input_word=34'h92;
16'd70: input_word=34'hab;
16'd71: input_word=34'h10000004f;
16'd72: input_word=34'h2000000c6;
16'd73: input_word=34'hf8;
16'd74: input_word=34'h100000068;
16'd75: input_word=34'ha8;
16'd76: input_word=34'h1b;
16'd77: input_word=34'h1000000eb;
16'd78: input_word=34'h6a;
16'd79: input_word=34'h61;
16'd80: input_word=34'h1000000cf;
16'd81: input_word=34'h20000001d;
16'd82: input_word=34'h0;
16'd83: input_word=34'h57;
16'd84: input_word=34'h1e;
16'd85: input_word=34'h100000041;
16'd86: input_word=34'had;
16'd87: input_word=34'h6f;
16'd88: input_word=34'he2;
16'd89: input_word=34'h3;
16'd90: input_word=34'h100000068;
16'd91: input_word=34'h68;
16'd92: input_word=34'hb1;
16'd93: input_word=34'h23;
16'd94: input_word=34'h7d;
16'd95: input_word=34'h1000000cc;
16'd96: input_word=34'h200000000;
16'd97: input_word=34'h0;
16'd98: input_word=34'h100000000;
16'd99: input_word=34'h0;
16'd100: input_word=34'h0;
16'd101: input_word=34'h100000000;
16'd102: input_word=34'h0;
16'd103: input_word=34'h0;
16'd104: input_word=34'h100000000;
default:input_word=0;endcase end
reg [33:0] expected_word;always @* begin expected_word=0;case(ei)
16'd0: expected_word=34'h300a524ec;
16'd1: expected_word=34'h200837d83;
16'd2: expected_word=34'h769465;
16'd3: expected_word=34'h100934f47;
16'd4: expected_word=34'h3008bb4bb;
16'd5: expected_word=34'h200c8807e;
16'd6: expected_word=34'h857294;
16'd7: expected_word=34'h1004223ac;
16'd8: expected_word=34'h30042d1af;
16'd9: expected_word=34'h2007dbe9b;
16'd10: expected_word=34'h37928c;
16'd11: expected_word=34'h10033d77d;
16'd12: expected_word=34'h3001bbb9a;
16'd13: expected_word=34'h2006f9040;
16'd14: expected_word=34'h39e23d;
16'd15: expected_word=34'h100037962;
16'd16: expected_word=34'h300000000;
default:expected_word=0;endcase end
reg [33:0] aux_word;always @* begin aux_word=0;case(ai)
default:aux_word=0;endcase end
reg [47:0] coefficient_word;always @* begin coefficient_word=0;case(ki)
default:coefficient_word=0;endcase end

acceptance48_driver #(.COMMANDS(16),.CASE_ID(32'h42415952),.UART_DIV(UART_DIV),.TIMEOUT_CYCLES(TIMEOUT_CYCLES)) driver(
 .clk(clk),.rst_n(rst_n),.command_index(ci),.configuration(configuration),.input_index(ii),.aux_index(ai),.coefficient_index(ki),.expected_index(ei),
 .input_word(input_word),.aux_word(aux_word),.expected_word(expected_word),.coefficient_word(coefficient_word),.ce(ce),.cmd_valid(cv),.cmd_ready(cr),.cmd_tag(tag),
 .rsp_valid(rv),.rsp_ready(rr),.rsp_tag(rt),.rsp_error(re),.s_valid(sv),.s_ready(sr),.aux_valid(av),.aux_ready(ar),.coeff_valid(kv),.coeff_ready(kr),
 .m_valid(mv),.m_ready(mr),.m_data(ddata),.m_sof(ms),.m_eol(me),.unexpected_memory(mem_valid || mem_write || mem_response_ready),
 .uart_tx(uart_tx),.done(finished),.error_count(errors),.digest(digest),.timed_out(timed_out));
cip_image_bayer_demosaic #(.DATA_W(24),.TAG_W(8),.MAX_WIDTH(8),.RAW_BITS(8)) dut(.clk(clk),.rst_n(rst_n),.clk_en(ce),.cmd_valid(cv),.cmd_ready(cr),.cmd_tag(tag),.rsp_valid(rv),.rsp_ready(rr),.rsp_tag(rt),.rsp_error(re),
 .cfg_mode(configuration[3:0]),.cfg_src_width(configuration[27:12]),.cfg_src_height(configuration[43:28]),.cfg_dst_width(configuration[59:44]),.cfg_dst_height(configuration[75:60]),
 .cfg_param0(configuration[107:76]),.cfg_param1(configuration[139:108]),.cfg_frame_base(configuration[171:140]),.cfg_frame_stride(configuration[203:172]),.cfg_aux_base(configuration[235:204]),
 .coeff_valid(kv),.coeff_ready(kr),.coeff_addr(coefficient_word[47:32]),.coeff_data(coefficient_word[31:0]),
 .aux_data(aux_word[23:0]),.aux_valid(av),.aux_sof(aux_word[33]),.aux_eol(aux_word[32]),.aux_ready(ar),
 .mem_req_valid(mem_valid),.mem_req_write(mem_write),.mem_rsp_ready(mem_response_ready),.mem_req_ready(1'b0),.mem_rsp_valid(1'b0),.mem_rsp_rdata(32'd0),.mem_rsp_error(1'b0),
 .s_data(input_word[23:0]),.s_valid(sv),.s_sof(input_word[33]),.s_eol(input_word[32]),.s_ready(sr),.m_data(md),.m_valid(mv),.m_sof(ms),.m_eol(me),.m_ready(mr));
endmodule
