module ntt256_serial_core (
    input  wire        clk,
    input  wire        rst_n,
    input  wire        start,
    input  wire        mode_dsa,
    input  wire        inverse,
    output reg         busy,
    output reg         done,
    output reg  [31:0] digest,
    output reg  [31:0] cycle_count
);

localparam [4:0] S_IDLE          = 5'd0;
localparam [4:0] S_INIT          = 5'd1;
localparam [4:0] S_STAGE         = 5'd2;
localparam [4:0] S_READ_A_REQ    = 5'd3;
localparam [4:0] S_READ_A_LATCH  = 5'd4;
localparam [4:0] S_READ_B_REQ    = 5'd5;
localparam [4:0] S_READ_B_LATCH  = 5'd6;
localparam [4:0] S_BFLY_START    = 5'd7;
localparam [4:0] S_BFLY_WAIT     = 5'd8;
localparam [4:0] S_WRITE_A       = 5'd9;
localparam [4:0] S_WRITE_B       = 5'd10;
localparam [4:0] S_DIGEST_INIT   = 5'd14;
localparam [4:0] S_DIGEST_REQ    = 5'd15;
localparam [4:0] S_DIGEST_LATCH  = 5'd16;
localparam [4:0] S_DONE          = 5'd17;
localparam [4:0] S_SCALE_INIT    = 5'd18;
localparam [4:0] S_SCALE_REQ     = 5'd19;
localparam [4:0] S_SCALE_LATCH   = 5'd20;
localparam [4:0] S_SCALE_START   = 5'd21;
localparam [4:0] S_SCALE_WAIT    = 5'd22;
localparam [4:0] S_SCALE_WRITE   = 5'd23;

reg [4:0] state;
reg mode_reg;
reg inverse_reg;
reg butterfly_start;
reg butterfly_mode_dsa;
reg butterfly_inverse_mode;
reg [22:0] butterfly_a;
reg [22:0] butterfly_b;
reg [22:0] butterfly_twiddle;
wire [22:0] butterfly_y0;
wire [22:0] butterfly_y1;
wire butterfly_done;
wire butterfly_busy;
reg butterfly1_start;
reg butterfly1_mode_dsa;
reg butterfly1_inverse_mode;
reg [22:0] butterfly1_a;
reg [22:0] butterfly1_b;
reg [22:0] butterfly1_twiddle;
wire [22:0] butterfly1_y0;
wire [22:0] butterfly1_y1;
wire butterfly1_done;
wire butterfly1_busy;

(* ram_style = "block", syn_ramstyle = "block_ram" *)
reg [22:0] mem_even [0:127];
(* ram_style = "block", syn_ramstyle = "block_ram" *)
reg [22:0] mem_odd [0:127];
reg mem_even_we;
reg mem_odd_we;
reg [6:0] mem_even_addr;
reg [6:0] mem_odd_addr;
reg [22:0] mem_even_din;
reg [22:0] mem_odd_din;
reg [22:0] mem_even_dout;
reg [22:0] mem_odd_dout;

reg [7:0] init_index;
reg [2:0] stage;
reg [7:0] m_value;
reg [7:0] block_start;
reg [7:0] j_index;
reg [7:0] idx0;
reg [7:0] idx1;
reg [7:0] idx2;
reg [7:0] idx3;
reg batch_pair;
reg [7:0] digest_index;
reg [7:0] scale_index;

wire [8:0] next_block = {1'b0, block_start} + {m_value, 1'b0};
wire [8:0] next_j = {1'b0, j_index} + (batch_pair ? 9'd2 : 9'd1);
wire can_pair = ({1'b0, j_index} + 9'd1) < {1'b0, m_value};
wire [7:0] read_idx0 = block_start + j_index;
wire [7:0] read_idx1 = block_start + j_index + m_value;
wire [7:0] read_idx2 = block_start + j_index + 8'd1;
wire [7:0] read_idx3 = block_start + j_index + 8'd1 + m_value;
wire [8:0] twiddle_index_wide = {1'b0, m_value} - 9'd1 + {1'b0, j_index};
wire [8:0] twiddle1_index_wide = twiddle_index_wide + 9'd1;
wire [7:0] scale_idx1 = scale_index + 8'd1;
wire scale_pair = scale_index < 8'd255;
wire [22:0] mem_dout_idx0 = idx0[0] ? mem_odd_dout : mem_even_dout;
wire [22:0] mem_dout_idx1 = idx1[0] ? mem_odd_dout : mem_even_dout;
wire [22:0] mem_dout_idx2 = idx2[0] ? mem_odd_dout : mem_even_dout;
wire [22:0] mem_dout_idx3 = idx3[0] ? mem_odd_dout : mem_even_dout;
wire [22:0] digest_mem_dout = digest_index[0] ? mem_odd_dout : mem_even_dout;

fused_butterfly butterfly (
    .clk(clk),
    .rst_n(rst_n),
    .start(butterfly_start),
    .mode_dsa(butterfly_mode_dsa),
    .inverse_mode(butterfly_inverse_mode),
    .a(butterfly_a),
    .b(butterfly_b),
    .twiddle(butterfly_twiddle),
    .y0(butterfly_y0),
    .y1(butterfly_y1),
    .busy(butterfly_busy),
    .done(butterfly_done)
);

fused_butterfly butterfly1 (
    .clk(clk),
    .rst_n(rst_n),
    .start(butterfly1_start),
    .mode_dsa(butterfly1_mode_dsa),
    .inverse_mode(butterfly1_inverse_mode),
    .a(butterfly1_a),
    .b(butterfly1_b),
    .twiddle(butterfly1_twiddle),
    .y0(butterfly1_y0),
    .y1(butterfly1_y1),
    .busy(butterfly1_busy),
    .done(butterfly1_done)
);

function [22:0] init_value;
    input mode;
    input [7:0] index;
    reg [31:0] raw;
    reg [31:0] q;
    begin
        q = mode ? 32'd8380417 : 32'd3329;
        if (mode) begin
            raw = ({24'd0, index} << 16) + {24'd0, index} + 32'd12345;
        end else begin
            raw = ({24'd0, index} << 4) + {24'd0, index} + 32'd5;
        end
        if (raw >= q) begin
            raw = raw - q;
        end
        init_value = raw[22:0];
    end
endfunction

function [22:0] twiddle_value;
    input mode;
    input [7:0] index;
    begin
        case (index)
            8'd0: twiddle_value = 23'd1;
            8'd1: twiddle_value = 23'd1;
            8'd2: twiddle_value = mode ? 23'd4808194 : 23'd1729;
            8'd3: twiddle_value = 23'd1;
            8'd4: twiddle_value = mode ? 23'd3765607 : 23'd2580;
            8'd5: twiddle_value = mode ? 23'd4808194 : 23'd1729;
            8'd6: twiddle_value = mode ? 23'd3761513 : 23'd3289;
            8'd7: twiddle_value = 23'd1;
            8'd8: twiddle_value = mode ? 23'd5178923 : 23'd2642;
            8'd9: twiddle_value = mode ? 23'd3765607 : 23'd2580;
            8'd10: twiddle_value = mode ? 23'd5234739 : 23'd1897;
            8'd11: twiddle_value = mode ? 23'd4808194 : 23'd1729;
            8'd12: twiddle_value = mode ? 23'd5496691 : 23'd630;
            8'd13: twiddle_value = mode ? 23'd3761513 : 23'd3289;
            8'd14: twiddle_value = mode ? 23'd5178987 : 23'd848;
            8'd15: twiddle_value = 23'd1;
            8'd16: twiddle_value = mode ? 23'd7778734 : 23'd1062;
            8'd17: twiddle_value = mode ? 23'd5178923 : 23'd2642;
            8'd18: twiddle_value = mode ? 23'd3764867 : 23'd2786;
            8'd19: twiddle_value = mode ? 23'd3765607 : 23'd2580;
            8'd20: twiddle_value = mode ? 23'd2682288 : 23'd193;
            8'd21: twiddle_value = mode ? 23'd5234739 : 23'd1897;
            8'd22: twiddle_value = mode ? 23'd557458 : 23'd569;
            8'd23: twiddle_value = mode ? 23'd4808194 : 23'd1729;
            8'd24: twiddle_value = mode ? 23'd3542485 : 23'd1919;
            8'd25: twiddle_value = mode ? 23'd5496691 : 23'd630;
            8'd26: twiddle_value = mode ? 23'd7375178 : 23'd3260;
            8'd27: twiddle_value = mode ? 23'd3761513 : 23'd3289;
            8'd28: twiddle_value = mode ? 23'd2129892 : 23'd797;
            8'd29: twiddle_value = mode ? 23'd5178987 : 23'd848;
            8'd30: twiddle_value = mode ? 23'd7159240 : 23'd1746;
            8'd31: twiddle_value = 23'd1;
            8'd32: twiddle_value = mode ? 23'd5010068 : 23'd296;
            8'd33: twiddle_value = mode ? 23'd7778734 : 23'd1062;
            8'd34: twiddle_value = mode ? 23'd5152541 : 23'd1426;
            8'd35: twiddle_value = mode ? 23'd5178923 : 23'd2642;
            8'd36: twiddle_value = mode ? 23'd4855975 : 23'd3046;
            8'd37: twiddle_value = mode ? 23'd3764867 : 23'd2786;
            8'd38: twiddle_value = mode ? 23'd7737789 : 23'd2393;
            8'd39: twiddle_value = mode ? 23'd3765607 : 23'd2580;
            8'd40: twiddle_value = mode ? 23'd2663378 : 23'd1339;
            8'd41: twiddle_value = mode ? 23'd2682288 : 23'd193;
            8'd42: twiddle_value = mode ? 23'd2453983 : 23'd535;
            8'd43: twiddle_value = mode ? 23'd5234739 : 23'd1897;
            8'd44: twiddle_value = mode ? 23'd676590 : 23'd2240;
            8'd45: twiddle_value = mode ? 23'd557458 : 23'd569;
            8'd46: twiddle_value = mode ? 23'd2815639 : 23'd1974;
            8'd47: twiddle_value = mode ? 23'd4808194 : 23'd1729;
            8'd48: twiddle_value = mode ? 23'd4317364 : 23'd2447;
            8'd49: twiddle_value = mode ? 23'd3542485 : 23'd1919;
            8'd50: twiddle_value = mode ? 23'd1714295 : 23'd2094;
            8'd51: twiddle_value = mode ? 23'd5496691 : 23'd630;
            8'd52: twiddle_value = mode ? 23'd7946292 : 23'd56;
            8'd53: twiddle_value = mode ? 23'd7375178 : 23'd3260;
            8'd54: twiddle_value = mode ? 23'd4795319 : 23'd2879;
            8'd55: twiddle_value = mode ? 23'd3761513 : 23'd3289;
            8'd56: twiddle_value = mode ? 23'd6705802 : 23'd1476;
            8'd57: twiddle_value = mode ? 23'd2129892 : 23'd797;
            8'd58: twiddle_value = mode ? 23'd1460718 : 23'd2882;
            8'd59: twiddle_value = mode ? 23'd5178987 : 23'd848;
            8'd60: twiddle_value = mode ? 23'd7044481 : 23'd1333;
            8'd61: twiddle_value = mode ? 23'd7159240 : 23'd1746;
            8'd62: twiddle_value = mode ? 23'd2283733 : 23'd821;
            8'd63: twiddle_value = 23'd1;
            8'd64: twiddle_value = mode ? 23'd3602218 : 23'd289;
            8'd65: twiddle_value = mode ? 23'd5010068 : 23'd296;
            8'd66: twiddle_value = mode ? 23'd3415069 : 23'd2319;
            8'd67: twiddle_value = mode ? 23'd7778734 : 23'd1062;
            8'd68: twiddle_value = mode ? 23'd394148 : 23'd650;
            8'd69: twiddle_value = mode ? 23'd5152541 : 23'd1426;
            8'd70: twiddle_value = mode ? 23'd5483103 : 23'd2647;
            8'd71: twiddle_value = mode ? 23'd5178923 : 23'd2642;
            8'd72: twiddle_value = mode ? 23'd5269599 : 23'd1197;
            8'd73: twiddle_value = mode ? 23'd4855975 : 23'd3046;
            8'd74: twiddle_value = mode ? 23'd3756790 : 23'd1438;
            8'd75: twiddle_value = mode ? 23'd3764867 : 23'd2786;
            8'd76: twiddle_value = mode ? 23'd2071829 : 23'd2865;
            8'd77: twiddle_value = mode ? 23'd7737789 : 23'd2393;
            8'd78: twiddle_value = mode ? 23'd2917338 : 23'd2474;
            8'd79: twiddle_value = mode ? 23'd3765607 : 23'd2580;
            8'd80: twiddle_value = mode ? 23'd2740543 : 23'd3253;
            8'd81: twiddle_value = mode ? 23'd2663378 : 23'd1339;
            8'd82: twiddle_value = mode ? 23'd7562881 : 23'd807;
            8'd83: twiddle_value = mode ? 23'd2682288 : 23'd193;
            8'd84: twiddle_value = mode ? 23'd1095468 : 23'd2513;
            8'd85: twiddle_value = mode ? 23'd2453983 : 23'd535;
            8'd86: twiddle_value = mode ? 23'd556856 : 23'd1481;
            8'd87: twiddle_value = mode ? 23'd5234739 : 23'd1897;
            8'd88: twiddle_value = mode ? 23'd3704823 : 23'd2277;
            8'd89: twiddle_value = mode ? 23'd676590 : 23'd2240;
            8'd90: twiddle_value = mode ? 23'd6663429 : 23'd1534;
            8'd91: twiddle_value = mode ? 23'd557458 : 23'd569;
            8'd92: twiddle_value = mode ? 23'd3241972 : 23'd1320;
            8'd93: twiddle_value = mode ? 23'd2815639 : 23'd1974;
            8'd94: twiddle_value = mode ? 23'd3345963 : 23'd1227;
            8'd95: twiddle_value = mode ? 23'd4808194 : 23'd1729;
            8'd96: twiddle_value = mode ? 23'd3182878 : 23'd331;
            8'd97: twiddle_value = mode ? 23'd4317364 : 23'd2447;
            8'd98: twiddle_value = mode ? 23'd1759347 : 23'd1435;
            8'd99: twiddle_value = mode ? 23'd3542485 : 23'd1919;
            8'd100: twiddle_value = mode ? 23'd928749 : 23'd1977;
            8'd101: twiddle_value = mode ? 23'd1714295 : 23'd2094;
            8'd102: twiddle_value = mode ? 23'd3192354 : 23'd2617;
            8'd103: twiddle_value = mode ? 23'd5496691 : 23'd630;
            8'd104: twiddle_value = mode ? 23'd2101410 : 23'd2304;
            8'd105: twiddle_value = mode ? 23'd7946292 : 23'd56;
            8'd106: twiddle_value = mode ? 23'd6444618 : 23'd2868;
            8'd107: twiddle_value = mode ? 23'd7375178 : 23'd3260;
            8'd108: twiddle_value = mode ? 23'd4361428 : 23'd33;
            8'd109: twiddle_value = mode ? 23'd4795319 : 23'd2879;
            8'd110: twiddle_value = mode ? 23'd1853806 : 23'd3110;
            8'd111: twiddle_value = mode ? 23'd3761513 : 23'd3289;
            8'd112: twiddle_value = mode ? 23'd4793971 : 23'd1756;
            8'd113: twiddle_value = mode ? 23'd6705802 : 23'd1476;
            8'd114: twiddle_value = mode ? 23'd4805951 : 23'd452;
            8'd115: twiddle_value = mode ? 23'd2129892 : 23'd797;
            8'd116: twiddle_value = mode ? 23'd4874037 : 23'd632;
            8'd117: twiddle_value = mode ? 23'd1460718 : 23'd2882;
            8'd118: twiddle_value = mode ? 23'd3870317 : 23'd648;
            8'd119: twiddle_value = mode ? 23'd5178987 : 23'd848;
            8'd120: twiddle_value = mode ? 23'd1159875 : 23'd2055;
            8'd121: twiddle_value = mode ? 23'd7044481 : 23'd1333;
            8'd122: twiddle_value = mode ? 23'd4430364 : 23'd2402;
            8'd123: twiddle_value = mode ? 23'd7159240 : 23'd1746;
            8'd124: twiddle_value = mode ? 23'd2156050 : 23'd1915;
            8'd125: twiddle_value = mode ? 23'd2283733 : 23'd821;
            8'd126: twiddle_value = mode ? 23'd1858416 : 23'd910;
            8'd127: twiddle_value = 23'd1;
            8'd128: twiddle_value = mode ? 23'd3073009 : 23'd17;
            8'd129: twiddle_value = mode ? 23'd3602218 : 23'd289;
            8'd130: twiddle_value = mode ? 23'd5801164 : 23'd1584;
            8'd131: twiddle_value = mode ? 23'd5010068 : 23'd296;
            8'd132: twiddle_value = mode ? 23'd1528066 : 23'd1703;
            8'd133: twiddle_value = mode ? 23'd3415069 : 23'd2319;
            8'd134: twiddle_value = mode ? 23'd1356448 : 23'd2804;
            8'd135: twiddle_value = mode ? 23'd7778734 : 23'd1062;
            8'd136: twiddle_value = mode ? 23'd2508980 : 23'd1409;
            8'd137: twiddle_value = mode ? 23'd394148 : 23'd650;
            8'd138: twiddle_value = mode ? 23'd7062739 : 23'd1063;
            8'd139: twiddle_value = mode ? 23'd5152541 : 23'd1426;
            8'd140: twiddle_value = mode ? 23'd4213992 : 23'd939;
            8'd141: twiddle_value = mode ? 23'd5483103 : 23'd2647;
            8'd142: twiddle_value = mode ? 23'd348812 : 23'd1722;
            8'd143: twiddle_value = mode ? 23'd5178923 : 23'd2642;
            8'd144: twiddle_value = mode ? 23'd4183372 : 23'd1637;
            8'd145: twiddle_value = mode ? 23'd5269599 : 23'd1197;
            8'd146: twiddle_value = mode ? 23'd3482206 : 23'd375;
            8'd147: twiddle_value = mode ? 23'd4855975 : 23'd3046;
            8'd148: twiddle_value = mode ? 23'd7814814 : 23'd1847;
            8'd149: twiddle_value = mode ? 23'd3756790 : 23'd1438;
            8'd150: twiddle_value = mode ? 23'd4912752 : 23'd1143;
            8'd151: twiddle_value = mode ? 23'd3764867 : 23'd2786;
            8'd152: twiddle_value = mode ? 23'd2811291 : 23'd756;
            8'd153: twiddle_value = mode ? 23'd2071829 : 23'd2865;
            8'd154: twiddle_value = mode ? 23'd3901472 : 23'd2099;
            8'd155: twiddle_value = mode ? 23'd7737789 : 23'd2393;
            8'd156: twiddle_value = mode ? 23'd1736313 : 23'd733;
            8'd157: twiddle_value = mode ? 23'd2917338 : 23'd2474;
            8'd158: twiddle_value = mode ? 23'd4561790 : 23'd2110;
            8'd159: twiddle_value = mode ? 23'd3765607 : 23'd2580;
            8'd160: twiddle_value = mode ? 23'd5744944 : 23'd583;
            8'd161: twiddle_value = mode ? 23'd2740543 : 23'd3253;
            8'd162: twiddle_value = mode ? 23'd5989328 : 23'd2037;
            8'd163: twiddle_value = mode ? 23'd2663378 : 23'd1339;
            8'd164: twiddle_value = mode ? 23'd1148858 : 23'd2789;
            8'd165: twiddle_value = mode ? 23'd7562881 : 23'd807;
            8'd166: twiddle_value = mode ? 23'd2683270 : 23'd403;
            8'd167: twiddle_value = mode ? 23'd2682288 : 23'd193;
            8'd168: twiddle_value = mode ? 23'd1937570 : 23'd3281;
            8'd169: twiddle_value = mode ? 23'd1095468 : 23'd2513;
            8'd170: twiddle_value = mode ? 23'd3035980 : 23'd2773;
            8'd171: twiddle_value = mode ? 23'd2453983 : 23'd535;
            8'd172: twiddle_value = mode ? 23'd1987814 : 23'd2437;
            8'd173: twiddle_value = mode ? 23'd556856 : 23'd1481;
            8'd174: twiddle_value = mode ? 23'd1011223 : 23'd1874;
            8'd175: twiddle_value = mode ? 23'd5234739 : 23'd1897;
            8'd176: twiddle_value = mode ? 23'd5258977 : 23'd2288;
            8'd177: twiddle_value = mode ? 23'd3704823 : 23'd2277;
            8'd178: twiddle_value = mode ? 23'd7080401 : 23'd2090;
            8'd179: twiddle_value = mode ? 23'd676590 : 23'd2240;
            8'd180: twiddle_value = mode ? 23'd2462444 : 23'd1461;
            8'd181: twiddle_value = mode ? 23'd6663429 : 23'd1534;
            8'd182: twiddle_value = mode ? 23'd7727142 : 23'd2775;
            8'd183: twiddle_value = mode ? 23'd557458 : 23'd569;
            8'd184: twiddle_value = mode ? 23'd7270901 : 23'd3015;
            8'd185: twiddle_value = mode ? 23'd3241972 : 23'd1320;
            8'd186: twiddle_value = mode ? 23'd2925816 : 23'd2466;
            8'd187: twiddle_value = mode ? 23'd2815639 : 23'd1974;
            8'd188: twiddle_value = mode ? 23'd5130263 : 23'd268;
            8'd189: twiddle_value = mode ? 23'd3345963 : 23'd1227;
            8'd190: twiddle_value = mode ? 23'd6143691 : 23'd885;
            8'd191: twiddle_value = mode ? 23'd4808194 : 23'd1729;
            8'd192: twiddle_value = mode ? 23'd1277625 : 23'd2761;
            8'd193: twiddle_value = mode ? 23'd3182878 : 23'd331;
            8'd194: twiddle_value = mode ? 23'd1787943 : 23'd2298;
            8'd195: twiddle_value = mode ? 23'd4317364 : 23'd2447;
            8'd196: twiddle_value = mode ? 23'd482649 : 23'd1651;
            8'd197: twiddle_value = mode ? 23'd1759347 : 23'd1435;
            8'd198: twiddle_value = mode ? 23'd5604662 : 23'd1092;
            8'd199: twiddle_value = mode ? 23'd3542485 : 23'd1919;
            8'd200: twiddle_value = mode ? 23'd2028118 : 23'd2662;
            8'd201: twiddle_value = mode ? 23'd928749 : 23'd1977;
            8'd202: twiddle_value = mode ? 23'd2461387 : 23'd319;
            8'd203: twiddle_value = mode ? 23'd1714295 : 23'd2094;
            8'd204: twiddle_value = mode ? 23'd4892034 : 23'd2308;
            8'd205: twiddle_value = mode ? 23'd3192354 : 23'd2617;
            8'd206: twiddle_value = mode ? 23'd8052569 : 23'd1212;
            8'd207: twiddle_value = mode ? 23'd5496691 : 23'd630;
            8'd208: twiddle_value = mode ? 23'd5157610 : 23'd723;
            8'd209: twiddle_value = mode ? 23'd2101410 : 23'd2304;
            8'd210: twiddle_value = mode ? 23'd4197502 : 23'd2549;
            8'd211: twiddle_value = mode ? 23'd7946292 : 23'd56;
            8'd212: twiddle_value = mode ? 23'd169688 : 23'd952;
            8'd213: twiddle_value = mode ? 23'd6444618 : 23'd2868;
            8'd214: twiddle_value = mode ? 23'd2312838 : 23'd2150;
            8'd215: twiddle_value = mode ? 23'd7375178 : 23'd3260;
            8'd216: twiddle_value = mode ? 23'd5396636 : 23'd2156;
            8'd217: twiddle_value = mode ? 23'd4361428 : 23'd33;
            8'd218: twiddle_value = mode ? 23'd7153756 : 23'd561;
            8'd219: twiddle_value = mode ? 23'd4795319 : 23'd2879;
            8'd220: twiddle_value = mode ? 23'd235407 : 23'd2337;
            8'd221: twiddle_value = mode ? 23'd1853806 : 23'd3110;
            8'd222: twiddle_value = mode ? 23'd6458164 : 23'd2935;
            8'd223: twiddle_value = mode ? 23'd3761513 : 23'd3289;
            8'd224: twiddle_value = mode ? 23'd3852015 : 23'd2649;
            8'd225: twiddle_value = mode ? 23'd4793971 : 23'd1756;
            8'd226: twiddle_value = mode ? 23'd6125690 : 23'd3220;
            8'd227: twiddle_value = mode ? 23'd6705802 : 23'd1476;
            8'd228: twiddle_value = mode ? 23'd5418153 : 23'd1789;
            8'd229: twiddle_value = mode ? 23'd4805951 : 23'd452;
            8'd230: twiddle_value = mode ? 23'd5601629 : 23'd1026;
            8'd231: twiddle_value = mode ? 23'd2129892 : 23'd797;
            8'd232: twiddle_value = mode ? 23'd4564692 : 23'd233;
            8'd233: twiddle_value = mode ? 23'd4874037 : 23'd632;
            8'd234: twiddle_value = mode ? 23'd621164 : 23'd757;
            8'd235: twiddle_value = mode ? 23'd1460718 : 23'd2882;
            8'd236: twiddle_value = mode ? 23'd5183169 : 23'd2388;
            8'd237: twiddle_value = mode ? 23'd3870317 : 23'd648;
            8'd238: twiddle_value = mode ? 23'd6026202 : 23'd1029;
            8'd239: twiddle_value = mode ? 23'd5178987 : 23'd848;
            8'd240: twiddle_value = mode ? 23'd8106357 : 23'd1100;
            8'd241: twiddle_value = mode ? 23'd1159875 : 23'd2055;
            8'd242: twiddle_value = mode ? 23'd6018354 : 23'd1645;
            8'd243: twiddle_value = mode ? 23'd7044481 : 23'd1333;
            8'd244: twiddle_value = mode ? 23'd5046034 : 23'd2687;
            8'd245: twiddle_value = mode ? 23'd4430364 : 23'd2402;
            8'd246: twiddle_value = mode ? 23'd7921254 : 23'd886;
            8'd247: twiddle_value = mode ? 23'd7159240 : 23'd1746;
            8'd248: twiddle_value = mode ? 23'd4158088 : 23'd3050;
            8'd249: twiddle_value = mode ? 23'd2156050 : 23'd1915;
            8'd250: twiddle_value = mode ? 23'd3374250 : 23'd2594;
            8'd251: twiddle_value = mode ? 23'd2283733 : 23'd821;
            8'd252: twiddle_value = mode ? 23'd3258457 : 23'd641;
            8'd253: twiddle_value = mode ? 23'd1858416 : 23'd910;
            default: twiddle_value = mode ? 23'd1744507 : 23'd2154;
        endcase
    end
endfunction

function [31:0] rotl5;
    input [31:0] value;
    begin
        rotl5 = {value[26:0], value[31:27]};
    end
endfunction

function [7:0] twiddle_exponent;
    input [7:0] m;
    input [7:0] j;
    begin
        case (m)
            8'd1: twiddle_exponent = 8'd0;
            8'd2: twiddle_exponent = {j[1:0], 6'd0};
            8'd4: twiddle_exponent = {j[2:0], 5'd0};
            8'd8: twiddle_exponent = {j[3:0], 4'd0};
            8'd16: twiddle_exponent = {j[4:0], 3'd0};
            8'd32: twiddle_exponent = {j[5:0], 2'd0};
            8'd64: twiddle_exponent = {j[6:0], 1'b0};
            default: twiddle_exponent = j;
        endcase
    end
endfunction

function [22:0] inverse_twiddle_value;
    input mode;
    input [7:0] exponent;
    reg [22:0] q;
    reg [22:0] forward_value;
    begin
        q = mode ? 23'd8380417 : 23'd3329;
        if (exponent == 8'd0) begin
            inverse_twiddle_value = 23'd1;
        end else begin
            forward_value = twiddle_value(mode, 8'd255 - exponent);
            inverse_twiddle_value = q - forward_value;
        end
    end
endfunction

function [22:0] n_inv_value;
    input mode;
    begin
        n_inv_value = mode ? 23'd8347681 : 23'd3316;
    end
endfunction

always @* begin
    mem_even_we = 1'b0;
    mem_odd_we = 1'b0;
    mem_even_addr = 7'd0;
    mem_odd_addr = 7'd0;
    mem_even_din = 23'd0;
    mem_odd_din = 23'd0;

    case (state)
        S_INIT: begin
            if (init_index[0]) begin
                mem_odd_we = 1'b1;
                mem_odd_addr = init_index[7:1];
                mem_odd_din = init_value(mode_reg, init_index);
            end else begin
                mem_even_we = 1'b1;
                mem_even_addr = init_index[7:1];
                mem_even_din = init_value(mode_reg, init_index);
            end
        end

        S_READ_A_REQ: begin
            if (read_idx0[0]) begin
                mem_odd_addr = read_idx0[7:1];
            end else begin
                mem_even_addr = read_idx0[7:1];
            end

            if (can_pair) begin
                if (read_idx2[0]) begin
                    mem_odd_addr = read_idx2[7:1];
                end else begin
                    mem_even_addr = read_idx2[7:1];
                end
            end else begin
                if (read_idx1[0]) begin
                    mem_odd_addr = read_idx1[7:1];
                end else begin
                    mem_even_addr = read_idx1[7:1];
                end
            end
        end

        S_READ_B_REQ: begin
            if (idx1[0]) begin
                mem_odd_addr = idx1[7:1];
            end else begin
                mem_even_addr = idx1[7:1];
            end

            if (idx3[0]) begin
                mem_odd_addr = idx3[7:1];
            end else begin
                mem_even_addr = idx3[7:1];
            end
        end

        S_WRITE_A: begin
            if (idx0[0]) begin
                mem_odd_we = 1'b1;
                mem_odd_addr = idx0[7:1];
                mem_odd_din = butterfly_y0;
            end else begin
                mem_even_we = 1'b1;
                mem_even_addr = idx0[7:1];
                mem_even_din = butterfly_y0;
            end

            if (batch_pair) begin
                if (idx2[0]) begin
                    mem_odd_we = 1'b1;
                    mem_odd_addr = idx2[7:1];
                    mem_odd_din = butterfly1_y0;
                end else begin
                    mem_even_we = 1'b1;
                    mem_even_addr = idx2[7:1];
                    mem_even_din = butterfly1_y0;
                end
            end else begin
                if (idx1[0]) begin
                    mem_odd_we = 1'b1;
                    mem_odd_addr = idx1[7:1];
                    mem_odd_din = butterfly_y1;
                end else begin
                    mem_even_we = 1'b1;
                    mem_even_addr = idx1[7:1];
                    mem_even_din = butterfly_y1;
                end
            end
        end

        S_WRITE_B: begin
            if (idx1[0]) begin
                mem_odd_we = 1'b1;
                mem_odd_addr = idx1[7:1];
                mem_odd_din = butterfly_y1;
            end else begin
                mem_even_we = 1'b1;
                mem_even_addr = idx1[7:1];
                mem_even_din = butterfly_y1;
            end

            if (idx3[0]) begin
                mem_odd_we = 1'b1;
                mem_odd_addr = idx3[7:1];
                mem_odd_din = butterfly1_y1;
            end else begin
                mem_even_we = 1'b1;
                mem_even_addr = idx3[7:1];
                mem_even_din = butterfly1_y1;
            end
        end

        S_DIGEST_REQ: begin
            if (digest_index[0]) begin
                mem_odd_addr = digest_index[7:1];
            end else begin
                mem_even_addr = digest_index[7:1];
            end
        end

        S_SCALE_REQ: begin
            if (scale_index[0]) begin
                mem_odd_addr = scale_index[7:1];
            end else begin
                mem_even_addr = scale_index[7:1];
            end

            if (scale_pair) begin
                if (scale_idx1[0]) begin
                    mem_odd_addr = scale_idx1[7:1];
                end else begin
                    mem_even_addr = scale_idx1[7:1];
                end
            end
        end

        S_SCALE_WRITE: begin
            if (scale_index[0]) begin
                mem_odd_we = 1'b1;
                mem_odd_addr = scale_index[7:1];
                mem_odd_din = butterfly_y0;
            end else begin
                mem_even_we = 1'b1;
                mem_even_addr = scale_index[7:1];
                mem_even_din = butterfly_y0;
            end

            if (scale_pair) begin
                if (scale_idx1[0]) begin
                    mem_odd_we = 1'b1;
                    mem_odd_addr = scale_idx1[7:1];
                    mem_odd_din = butterfly1_y0;
                end else begin
                    mem_even_we = 1'b1;
                    mem_even_addr = scale_idx1[7:1];
                    mem_even_din = butterfly1_y0;
                end
            end
        end

        default: begin
            mem_even_we = 1'b0;
            mem_odd_we = 1'b0;
            mem_even_addr = 7'd0;
            mem_odd_addr = 7'd0;
            mem_even_din = 23'd0;
            mem_odd_din = 23'd0;
        end
    endcase
end

always @(posedge clk) begin
    if (mem_even_we) begin
        mem_even[mem_even_addr] <= mem_even_din;
    end
    if (mem_odd_we) begin
        mem_odd[mem_odd_addr] <= mem_odd_din;
    end
    mem_even_dout <= mem_even[mem_even_addr];
    mem_odd_dout <= mem_odd[mem_odd_addr];
end

always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        state <= S_IDLE;
        mode_reg <= 1'b0;
        inverse_reg <= 1'b0;
        butterfly_start <= 1'b0;
        butterfly_mode_dsa <= 1'b0;
        butterfly_inverse_mode <= 1'b0;
        butterfly_a <= 23'd0;
        butterfly_b <= 23'd0;
        butterfly_twiddle <= 23'd0;
        butterfly1_start <= 1'b0;
        butterfly1_mode_dsa <= 1'b0;
        butterfly1_inverse_mode <= 1'b0;
        butterfly1_a <= 23'd0;
        butterfly1_b <= 23'd0;
        butterfly1_twiddle <= 23'd0;
        busy <= 1'b0;
        done <= 1'b0;
        digest <= 32'd0;
        cycle_count <= 32'd0;
        init_index <= 8'd0;
        stage <= 3'd0;
        m_value <= 8'd1;
        block_start <= 8'd0;
        j_index <= 8'd0;
        idx0 <= 8'd0;
        idx1 <= 8'd0;
        idx2 <= 8'd0;
        idx3 <= 8'd0;
        batch_pair <= 1'b0;
        digest_index <= 8'd0;
        scale_index <= 8'd0;
    end else begin
        butterfly_start <= 1'b0;
        butterfly1_start <= 1'b0;
        done <= 1'b0;

        if (busy) begin
            cycle_count <= cycle_count + 32'd1;
        end

        case (state)
            S_IDLE: begin
                busy <= 1'b0;
                if (start) begin
                    busy <= 1'b1;
                    mode_reg <= mode_dsa;
                    inverse_reg <= inverse;
                    cycle_count <= 32'd0;
                    digest <= 32'd0;
                    init_index <= 8'd0;
                    state <= S_INIT;
                end
            end

            S_INIT: begin
                if (init_index == 8'd255) begin
                    stage <= 3'd0;
                    state <= S_STAGE;
                end else begin
                    init_index <= init_index + 8'd1;
                end
            end

            S_STAGE: begin
                m_value <= inverse_reg ? (8'd128 >> stage) : (8'd1 << stage);
                block_start <= 8'd0;
                j_index <= 8'd0;
                state <= S_READ_A_REQ;
            end

            S_READ_A_REQ: begin
                idx0 <= read_idx0;
                idx1 <= read_idx1;
                idx2 <= read_idx2;
                idx3 <= read_idx3;
                batch_pair <= can_pair;
                state <= S_READ_A_LATCH;
            end

            S_READ_A_LATCH: begin
                butterfly_a <= mem_dout_idx0;
                if (batch_pair) begin
                    butterfly1_a <= mem_dout_idx2;
                    state <= S_READ_B_REQ;
                end else begin
                    butterfly_b <= mem_dout_idx1;
                    state <= S_BFLY_START;
                end
            end

            S_READ_B_REQ: begin
                state <= S_READ_B_LATCH;
            end

            S_READ_B_LATCH: begin
                butterfly_b <= mem_dout_idx1;
                butterfly1_b <= mem_dout_idx3;
                state <= S_BFLY_START;
            end

            S_BFLY_START: begin
                butterfly_mode_dsa <= mode_reg;
                butterfly_inverse_mode <= inverse_reg;
                butterfly_twiddle <= inverse_reg
                    ? inverse_twiddle_value(mode_reg, twiddle_exponent(m_value, j_index))
                    : twiddle_value(mode_reg, twiddle_index_wide[7:0]);
                butterfly_start <= 1'b1;
                butterfly1_mode_dsa <= mode_reg;
                butterfly1_inverse_mode <= inverse_reg;
                butterfly1_twiddle <= inverse_reg
                    ? inverse_twiddle_value(mode_reg, twiddle_exponent(m_value, j_index + 8'd1))
                    : twiddle_value(mode_reg, twiddle1_index_wide[7:0]);
                butterfly1_start <= batch_pair;
                state <= S_BFLY_WAIT;
            end

            S_BFLY_WAIT: begin
                if (butterfly_done && (!batch_pair || butterfly1_done)) begin
                    state <= S_WRITE_A;
                end
            end

            S_WRITE_A: begin
                if (batch_pair) begin
                    state <= S_WRITE_B;
                end else if (next_j < {1'b0, m_value}) begin
                    j_index <= next_j[7:0];
                    state <= S_READ_A_REQ;
                end else if (next_block < 9'd256) begin
                    block_start <= next_block[7:0];
                    j_index <= 8'd0;
                    state <= S_READ_A_REQ;
                end else if (stage == 3'd7) begin
                    state <= inverse_reg ? S_SCALE_INIT : S_DIGEST_INIT;
                end else begin
                    stage <= stage + 3'd1;
                    state <= S_STAGE;
                end
            end

            S_WRITE_B: begin
                if (next_j < {1'b0, m_value}) begin
                    j_index <= next_j[7:0];
                    state <= S_READ_A_REQ;
                end else if (next_block < 9'd256) begin
                    block_start <= next_block[7:0];
                    j_index <= 8'd0;
                    state <= S_READ_A_REQ;
                end else if (stage == 3'd7) begin
                    state <= inverse_reg ? S_SCALE_INIT : S_DIGEST_INIT;
                end else begin
                    stage <= stage + 3'd1;
                    state <= S_STAGE;
                end
            end

            S_SCALE_INIT: begin
                scale_index <= 8'd0;
                state <= S_SCALE_REQ;
            end

            S_SCALE_REQ: begin
                state <= S_SCALE_LATCH;
            end

            S_SCALE_LATCH: begin
                butterfly_a <= 23'd0;
                butterfly_b <= scale_index[0] ? mem_odd_dout : mem_even_dout;
                butterfly1_a <= 23'd0;
                butterfly1_b <= scale_idx1[0] ? mem_odd_dout : mem_even_dout;
                state <= S_SCALE_START;
            end

            S_SCALE_START: begin
                butterfly_mode_dsa <= mode_reg;
                butterfly_inverse_mode <= 1'b0;
                butterfly_twiddle <= n_inv_value(mode_reg);
                butterfly_start <= 1'b1;
                butterfly1_mode_dsa <= mode_reg;
                butterfly1_inverse_mode <= 1'b0;
                butterfly1_twiddle <= n_inv_value(mode_reg);
                butterfly1_start <= scale_pair;
                state <= S_SCALE_WAIT;
            end

            S_SCALE_WAIT: begin
                if (butterfly_done && (!scale_pair || butterfly1_done)) begin
                    state <= S_SCALE_WRITE;
                end
            end

            S_SCALE_WRITE: begin
                if (scale_index == 8'd254) begin
                    state <= S_DIGEST_INIT;
                end else begin
                    scale_index <= scale_index + 8'd2;
                    state <= S_SCALE_REQ;
                end
            end

            S_DIGEST_INIT: begin
                digest <= 32'h4e545432;
                digest_index <= 8'd0;
                state <= S_DIGEST_REQ;
            end

            S_DIGEST_REQ: begin
                state <= S_DIGEST_LATCH;
            end

            S_DIGEST_LATCH: begin
                digest <= rotl5(digest) ^ {9'd0, digest_mem_dout} ^ {24'd0, digest_index};
                if (digest_index == 8'd255) begin
                    state <= S_DONE;
                end else begin
                    digest_index <= digest_index + 8'd1;
                    state <= S_DIGEST_REQ;
                end
            end

            S_DONE: begin
                busy <= 1'b0;
                done <= 1'b1;
                state <= S_IDLE;
            end

            default: state <= S_IDLE;
        endcase
    end
end

endmodule
