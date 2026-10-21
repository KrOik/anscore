module acceptance48_top #(parameter UART_DIV=434,parameter TIMEOUT_CYCLES=50000000)(
 input wire clk,uart_rx_pin,output wire uart_tx,dbg_uart);
reg [10:0] por=0;reg rst_n=0;always @(posedge clk)begin if(!(&por))por<=por+1'b1;rst_n<=&por;end
assign dbg_uart=uart_tx;
wire [15:0] ci,ii,ai,ki,ei;wire ce,cv,cr,rv,rr,sv,sr,av,ar,kv,kr,mv,mr,ms,me;
wire [7:0] tag,rt;wire [1:0] re;wire [7:0] md;wire [31:0] ddata=md;
wire mem_valid,mem_write,mem_response_ready;wire [31:0] errors,digest;wire timed_out,finished;
reg [383:0] configuration;always @* begin configuration=0;case(ci)
16'd0: configuration=384'hc000c00000000000000000000000000000000000000000003000400030004300;
16'd1: configuration=384'h300030000000000001000100000000000000000000000000000000000000000001000100010001310;
16'd2: configuration=384'h340034000000000014001400000000000000000000000000000000000000000004000500040005320;
16'd3: configuration=384'h840085000000000000000000000000000000000000000000000000000000000002000200020002331;
16'd4: configuration=384'h840086000000000000000000000000000000000000000000000000000000000002000200020000340;
16'd5: configuration=384'h840086000000000004000400000000000000000000000000000000000000000002000200020002350;
default:configuration=0;endcase end
reg [33:0] input_word;always @* begin input_word=0;case(ii)
16'd0: input_word=34'h200000000;
16'd1: input_word=34'h0;
16'd2: input_word=34'hf;
16'd3: input_word=34'h10000000f;
16'd4: input_word=34'h28;
16'd5: input_word=34'h46;
16'd6: input_word=34'h5a;
16'd7: input_word=34'h100000078;
16'd8: input_word=34'h96;
16'd9: input_word=34'hc8;
16'd10: input_word=34'hff;
16'd11: input_word=34'h1000000ff;
16'd12: input_word=34'h300000089;
16'd13: input_word=34'h20000005b;
16'd14: input_word=34'h5b;
16'd15: input_word=34'h5b;
16'd16: input_word=34'h5b;
16'd17: input_word=34'h10000005b;
16'd18: input_word=34'h5b;
16'd19: input_word=34'h5b;
16'd20: input_word=34'h5b;
16'd21: input_word=34'h5b;
16'd22: input_word=34'h10000005b;
16'd23: input_word=34'h5b;
16'd24: input_word=34'h5b;
16'd25: input_word=34'h5b;
16'd26: input_word=34'h5b;
16'd27: input_word=34'h10000005b;
16'd28: input_word=34'h5b;
16'd29: input_word=34'h5b;
16'd30: input_word=34'h5b;
16'd31: input_word=34'h5b;
16'd32: input_word=34'h10000005c;
16'd33: input_word=34'h200000000;
16'd34: input_word=34'h10000001e;
16'd35: input_word=34'h5a;
16'd36: input_word=34'hff;
default:input_word=0;endcase end
reg [33:0] expected_word;always @* begin expected_word=0;case(ei)
16'd0: expected_word=34'h200000001;
16'd1: expected_word=34'h0;
16'd2: expected_word=34'h33;
16'd3: expected_word=34'h100000033;
16'd4: expected_word=34'h4c;
16'd5: expected_word=34'h66;
16'd6: expected_word=34'h7f;
16'd7: expected_word=34'h100000099;
16'd8: expected_word=34'hb2;
16'd9: expected_word=34'hcc;
16'd10: expected_word=34'hff;
16'd11: expected_word=34'h1000000ff;
16'd12: expected_word=34'h300000089;
16'd13: expected_word=34'h200000000;
16'd14: expected_word=34'h0;
16'd15: expected_word=34'h0;
16'd16: expected_word=34'h0;
16'd17: expected_word=34'h100000000;
16'd18: expected_word=34'h0;
16'd19: expected_word=34'h0;
16'd20: expected_word=34'h0;
16'd21: expected_word=34'h0;
16'd22: expected_word=34'h100000000;
16'd23: expected_word=34'h0;
16'd24: expected_word=34'h0;
16'd25: expected_word=34'h0;
16'd26: expected_word=34'h0;
16'd27: expected_word=34'h100000000;
16'd28: expected_word=34'h0;
16'd29: expected_word=34'h0;
16'd30: expected_word=34'h0;
16'd31: expected_word=34'h0;
16'd32: expected_word=34'h1000000ff;
16'd33: expected_word=34'h200000000;
16'd34: expected_word=34'h100000055;
16'd35: expected_word=34'haa;
16'd36: expected_word=34'h1000000ff;
default:expected_word=0;endcase end
reg [33:0] aux_word;always @* begin aux_word=0;case(ai)
default:aux_word=0;endcase end
reg [47:0] coefficient_word;always @* begin coefficient_word=0;case(ki)
default:coefficient_word=0;endcase end

acceptance48_driver #(.COMMANDS(6),.CASE_ID(32'h48455155),.UART_DIV(UART_DIV),.TIMEOUT_CYCLES(TIMEOUT_CYCLES)) driver(
 .clk(clk),.rst_n(rst_n),.command_index(ci),.configuration(configuration),.input_index(ii),.aux_index(ai),.coefficient_index(ki),.expected_index(ei),
 .input_word(input_word),.aux_word(aux_word),.expected_word(expected_word),.coefficient_word(coefficient_word),.ce(ce),.cmd_valid(cv),.cmd_ready(cr),.cmd_tag(tag),
 .rsp_valid(rv),.rsp_ready(rr),.rsp_tag(rt),.rsp_error(re),.s_valid(sv),.s_ready(sr),.aux_valid(av),.aux_ready(ar),.coeff_valid(kv),.coeff_ready(kr),
 .m_valid(mv),.m_ready(mr),.m_data(ddata),.m_sof(ms),.m_eol(me),.unexpected_memory(mem_valid || mem_write || mem_response_ready),
 .uart_tx(uart_tx),.done(finished),.error_count(errors),.digest(digest),.timed_out(timed_out));
cip_image_he #(.DATA_W(8),.TAG_W(8),.MAX_WIDTH(8),.MAX_HEIGHT(6)) dut(.clk(clk),.rst_n(rst_n),.clk_en(ce),.cmd_valid(cv),.cmd_ready(cr),.cmd_tag(tag),.rsp_valid(rv),.rsp_ready(rr),.rsp_tag(rt),.rsp_error(re),
 .cfg_mode(configuration[3:0]),.cfg_src_width(configuration[27:12]),.cfg_src_height(configuration[43:28]),.cfg_dst_width(configuration[59:44]),.cfg_dst_height(configuration[75:60]),
 .cfg_param0(configuration[107:76]),.cfg_param1(configuration[139:108]),.cfg_frame_base(configuration[171:140]),.cfg_frame_stride(configuration[203:172]),.cfg_aux_base(configuration[235:204]),
 .coeff_valid(kv),.coeff_ready(kr),.coeff_addr(coefficient_word[47:32]),.coeff_data(coefficient_word[31:0]),
 .aux_data(aux_word[7:0]),.aux_valid(av),.aux_sof(aux_word[33]),.aux_eol(aux_word[32]),.aux_ready(ar),
 .mem_req_valid(mem_valid),.mem_req_write(mem_write),.mem_rsp_ready(mem_response_ready),.mem_req_ready(1'b0),.mem_rsp_valid(1'b0),.mem_rsp_rdata(32'd0),.mem_rsp_error(1'b0),
 .s_data(input_word[7:0]),.s_valid(sv),.s_sof(input_word[33]),.s_eol(input_word[32]),.s_ready(sr),.m_data(md),.m_valid(mv),.m_sof(ms),.m_eol(me),.m_ready(mr));
endmodule
