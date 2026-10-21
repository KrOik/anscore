module acceptance48_top #(parameter UART_DIV=434,parameter TIMEOUT_CYCLES=50000000)(
 input wire clk,uart_rx_pin,output wire uart_tx,dbg_uart);
reg [10:0] por=0;reg rst_n=0;always @(posedge clk)begin if(!(&por))por<=por+1'b1;rst_n<=&por;end
assign dbg_uart=uart_tx;
wire [15:0] ci,ii,ai,ki,ei;wire ce,cv,cr,rv,rr,sv,sr,av,ar,kv,kr,mv,mr,ms,me;
wire [7:0] tag,rt;wire [1:0] re;wire [23:0] md;wire [31:0] ddata=md;
wire mem_valid,mem_write,mem_response_ready;wire [31:0] errors,digest;wire timed_out,finished;
reg [383:0] configuration;always @* begin configuration=0;case(ci)
16'd0: configuration=384'h14001400000000000000000000000000000000000000000004000500040005a00;
16'd1: configuration=384'h500050000000000014001400000000000000000000000000000000000000000004000500040005a11;
16'd2: configuration=384'ha000a0000000000014001400000000000000000000000000000000000000000004000500040005a20;
16'd3: configuration=384'hf000f0000000000014001400000000000000000000000000000000000000000004000500040005a31;
16'd4: configuration=384'h1400141000000000000000000000000000000000000000000000000000000000001000100010001a42;
16'd5: configuration=384'h1400142000000000000000000000000000000000000000000000000000000010002000200020002a50;
default:configuration=0;endcase end
reg [33:0] input_word;always @* begin input_word=0;case(ii)
16'd0: input_word=34'h200000000;
16'd1: input_word=34'hffffff;
16'd2: input_word=34'hff0000;
16'd3: input_word=34'hff00;
16'd4: input_word=34'h1000000ff;
16'd5: input_word=34'h808080;
16'd6: input_word=34'h8ffddf;
16'd7: input_word=34'hbfe44e;
16'd8: input_word=34'h2b29fa;
16'd9: input_word=34'h1000b1d7f;
16'd10: input_word=34'h2a645e;
16'd11: input_word=34'h2ed91c;
16'd12: input_word=34'h5540df;
16'd13: input_word=34'hf5e927;
16'd14: input_word=34'h100a1a6bd;
16'd15: input_word=34'hea09c9;
16'd16: input_word=34'hbb7a85;
16'd17: input_word=34'haeb634;
16'd18: input_word=34'hb83bc9;
16'd19: input_word=34'h100d0f13c;
16'd20: input_word=34'h200000000;
16'd21: input_word=34'hffffff;
16'd22: input_word=34'hff0000;
16'd23: input_word=34'hff00;
16'd24: input_word=34'h1000000ff;
16'd25: input_word=34'h808080;
16'd26: input_word=34'h77381;
16'd27: input_word=34'had7a16;
16'd28: input_word=34'h3d3be7;
16'd29: input_word=34'h10024028b;
16'd30: input_word=34'h374141;
16'd31: input_word=34'h4ad488;
16'd32: input_word=34'hbbeb1;
16'd33: input_word=34'h9db87f;
16'd34: input_word=34'h10094c049;
16'd35: input_word=34'hce29df;
16'd36: input_word=34'hac37cf;
16'd37: input_word=34'ha46d7a;
16'd38: input_word=34'h9e96fb;
16'd39: input_word=34'h1001aae27;
16'd40: input_word=34'h200000000;
16'd41: input_word=34'hffffff;
16'd42: input_word=34'hff0000;
16'd43: input_word=34'hff00;
16'd44: input_word=34'h1000000ff;
16'd45: input_word=34'h808080;
16'd46: input_word=34'h2811d5;
16'd47: input_word=34'he01d82;
16'd48: input_word=34'ha8e184;
16'd49: input_word=34'h100e3aaa4;
16'd50: input_word=34'hdafc56;
16'd51: input_word=34'he5af32;
16'd52: input_word=34'hf83800;
16'd53: input_word=34'h5aaf71;
16'd54: input_word=34'h10014f452;
16'd55: input_word=34'h6158b4;
16'd56: input_word=34'hf2eca8;
16'd57: input_word=34'hc0d67b;
16'd58: input_word=34'h3fab3c;
16'd59: input_word=34'h100ec2258;
16'd60: input_word=34'h200000000;
16'd61: input_word=34'hffffff;
16'd62: input_word=34'hff0000;
16'd63: input_word=34'hff00;
16'd64: input_word=34'h1000000ff;
16'd65: input_word=34'h808080;
16'd66: input_word=34'h1c11a0;
16'd67: input_word=34'hd390ae;
16'd68: input_word=34'h929175;
16'd69: input_word=34'h100d3bbba;
16'd70: input_word=34'h1fe2e;
16'd71: input_word=34'h9f5351;
16'd72: input_word=34'h720b12;
16'd73: input_word=34'hb3d047;
16'd74: input_word=34'h100b1bf6a;
16'd75: input_word=34'hfb63b7;
16'd76: input_word=34'h8c84b6;
16'd77: input_word=34'h848482;
16'd78: input_word=34'h5e7eca;
16'd79: input_word=34'h1005c0eec;
default:input_word=0;endcase end
reg [33:0] expected_word;always @* begin expected_word=0;case(ei)
16'd0: expected_word=34'h200008080;
16'd1: expected_word=34'hff8080;
16'd2: expected_word=34'h4d55ff;
16'd3: expected_word=34'h952b15;
16'd4: expected_word=34'h1001dff6b;
16'd5: expected_word=34'h808080;
16'd6: expected_word=34'hd9834b;
16'd7: expected_word=34'hc83b7a;
16'd8: expected_word=34'h41e870;
16'd9: expected_word=34'h10023b46f;
16'd10: expected_word=34'h528763;
16'd11: expected_word=34'h903e3a;
16'd12: expected_word=34'h58cc7d;
16'd13: expected_word=34'hd71d96;
16'd14: expected_word=34'h100a78c7c;
16'd15: expected_word=34'h62bae1;
16'd16: expected_word=34'h8f7ba0;
16'd17: expected_word=34'ha54087;
16'd18: expected_word=34'h71b2b3;
16'd19: expected_word=34'h100d32b7e;
16'd20: expected_word=34'h200008800;
16'd21: expected_word=34'hff79ff;
16'd22: expected_word=34'h4cff1c;
16'd23: expected_word=34'h30e1;
16'd24: expected_word=34'h100b20000;
16'd25: expected_word=34'h808080;
16'd26: expected_word=34'h80b00;
16'd27: expected_word=34'h18fba2;
16'd28: expected_word=34'hcd0b00;
16'd29: expected_word=34'h100334700;
16'd30: expected_word=34'h7a00;
16'd31: expected_word=34'h5527df;
16'd32: expected_word=34'h500079;
16'd33: expected_word=34'h9c8aff;
16'd34: expected_word=34'h10047a5ff;
16'd35: expected_word=34'hffa834;
16'd36: expected_word=34'hff8d2b;
16'd37: expected_word=34'h9caf82;
16'd38: expected_word=34'hff3fc5;
16'd39: expected_word=34'h100004a6c;
16'd40: expected_word=34'h200008080;
16'd41: expected_word=34'hff8080;
16'd42: expected_word=34'h4d55ff;
16'd43: expected_word=34'h952b15;
16'd44: expected_word=34'h1001dff6b;
16'd45: expected_word=34'h808080;
16'd46: expected_word=34'h2ede7b;
16'd47: expected_word=34'h6392d9;
16'd48: expected_word=34'hc55b6b;
16'd49: expected_word=34'h100ba739d;
16'd50: expected_word=34'hdf337d;
16'd51: expected_word=34'hb138a5;
16'd52: expected_word=34'h6b44e5;
16'd53: expected_word=34'h8e6f5b;
16'd54: expected_word=34'h1009e551d;
16'd55: expected_word=34'h65ac7d;
16'd56: expected_word=34'he65d89;
16'd57: expected_word=34'hc5567c;
16'd58: expected_word=34'h7e5b53;
16'd59: expected_word=34'h1006579e1;
16'd60: expected_word=34'h200008800;
16'd61: expected_word=34'hff79ff;
16'd62: expected_word=34'h4cff1c;
16'd63: expected_word=34'h30e1;
16'd64: expected_word=34'h100b20000;
16'd65: expected_word=34'h808080;
16'd66: expected_word=34'h492b00;
16'd67: expected_word=34'hffadef;
16'd68: expected_word=34'h8394b0;
16'd69: expected_word=34'h100ff95ff;
16'd70: expected_word=34'h10e0;
16'd71: expected_word=34'h5dd04f;
16'd72: expected_word=34'he900;
16'd73: expected_word=34'h63c0ff;
16'd74: expected_word=34'h10092abff;
16'd75: expected_word=34'hffdec8;
16'd76: expected_word=34'hd86493;
16'd77: expected_word=34'h87818b;
16'd78: expected_word=34'hc62a5a;
16'd79: expected_word=34'h100f33600;
default:expected_word=0;endcase end
reg [33:0] aux_word;always @* begin aux_word=0;case(ai)
default:aux_word=0;endcase end
reg [47:0] coefficient_word;always @* begin coefficient_word=0;case(ki)
default:coefficient_word=0;endcase end

acceptance48_driver #(.COMMANDS(6),.CASE_ID(32'h434f4c52),.UART_DIV(UART_DIV),.TIMEOUT_CYCLES(TIMEOUT_CYCLES)) driver(
 .clk(clk),.rst_n(rst_n),.command_index(ci),.configuration(configuration),.input_index(ii),.aux_index(ai),.coefficient_index(ki),.expected_index(ei),
 .input_word(input_word),.aux_word(aux_word),.expected_word(expected_word),.coefficient_word(coefficient_word),.ce(ce),.cmd_valid(cv),.cmd_ready(cr),.cmd_tag(tag),
 .rsp_valid(rv),.rsp_ready(rr),.rsp_tag(rt),.rsp_error(re),.s_valid(sv),.s_ready(sr),.aux_valid(av),.aux_ready(ar),.coeff_valid(kv),.coeff_ready(kr),
 .m_valid(mv),.m_ready(mr),.m_data(ddata),.m_sof(ms),.m_eol(me),.unexpected_memory(mem_valid || mem_write || mem_response_ready),
 .uart_tx(uart_tx),.done(finished),.error_count(errors),.digest(digest),.timed_out(timed_out));
cip_image_color_convert #(.DATA_W(24),.TAG_W(8)) dut(.clk(clk),.rst_n(rst_n),.clk_en(ce),.cmd_valid(cv),.cmd_ready(cr),.cmd_tag(tag),.rsp_valid(rv),.rsp_ready(rr),.rsp_tag(rt),.rsp_error(re),
 .cfg_mode(configuration[3:0]),.cfg_src_width(configuration[27:12]),.cfg_src_height(configuration[43:28]),.cfg_dst_width(configuration[59:44]),.cfg_dst_height(configuration[75:60]),
 .cfg_param0(configuration[107:76]),.cfg_param1(configuration[139:108]),.cfg_frame_base(configuration[171:140]),.cfg_frame_stride(configuration[203:172]),.cfg_aux_base(configuration[235:204]),
 .coeff_valid(kv),.coeff_ready(kr),.coeff_addr(coefficient_word[47:32]),.coeff_data(coefficient_word[31:0]),
 .aux_data(aux_word[23:0]),.aux_valid(av),.aux_sof(aux_word[33]),.aux_eol(aux_word[32]),.aux_ready(ar),
 .mem_req_valid(mem_valid),.mem_req_write(mem_write),.mem_rsp_ready(mem_response_ready),.mem_req_ready(1'b0),.mem_rsp_valid(1'b0),.mem_rsp_rdata(32'd0),.mem_rsp_error(1'b0),
 .s_data(input_word[23:0]),.s_valid(sv),.s_sof(input_word[33]),.s_eol(input_word[32]),.s_ready(sr),.m_data(md),.m_valid(mv),.m_sof(ms),.m_eol(me),.m_ready(mr));
endmodule
