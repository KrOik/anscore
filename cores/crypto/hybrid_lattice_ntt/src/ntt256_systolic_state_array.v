module ntt256_systolic_state_array (
    input  wire        clk,
    input  wire        rst_n,
    input  wire        start,
    input  wire [2:0]  op,
    input  wire        auto_init,
    input  wire        check_expected,
    input  wire        coeff_load_valid,
    input  wire [7:0]  coeff_load_addr,
    input  wire [22:0] coeff_load_data,
    output wire        coeff_load_ready,
    output wire        start_ready,
    output reg         busy,
    output reg         done,
    output reg         pass,
    output reg         error,
    output reg         out_valid,
    output reg  [2:0]  out_op,
    output reg  [4:0]  out_index,
    output reg  [22:0] out_y0,
    output reg  [22:0] out_y1,
    output reg  [15:0] issue_count,
    output reg  [15:0] output_count,
    output reg  [15:0] bubble_count,
    output reg  [15:0] bank_check_count,
    output reg  [15:0] first_latency,
    output reg  [31:0] digest,
    output reg  [31:0] signature
);

localparam [2:0] OP_KEM_NTT  = 3'd0;
localparam [2:0] OP_DSA_NTT  = 3'd1;
localparam [2:0] OP_KEM_INTT = 3'd2;
localparam [2:0] OP_DSA_INTT = 3'd3;

localparam [3:0] S_IDLE              = 4'd0;
localparam [3:0] S_INIT              = 4'd1;
localparam [3:0] S_STAGE_SETUP       = 4'd2;
localparam [3:0] S_STAGE_READ        = 4'd3;
localparam [3:0] S_STAGE_DRAIN       = 4'd4;
localparam [3:0] S_STAGE_FLUSH_SETUP = 4'd5;
localparam [3:0] S_STAGE_FLUSH       = 4'd6;
localparam [3:0] S_SCALE_SETUP       = 4'd7;
localparam [3:0] S_SCALE_READ        = 4'd8;
localparam [3:0] S_SCALE_DRAIN       = 4'd9;
localparam [3:0] S_DIGEST_INIT       = 4'd10;
localparam [3:0] S_DIGEST_READ       = 4'd11;
localparam [3:0] S_DIGEST_RUN        = 4'd12;

localparam integer META_LATENCY = 24;
localparam [15:0] STAGE_SLOTS = 16'd128;
localparam [15:0] SCALE_SLOTS = 16'd256;
localparam [15:0] EXPECTED_LATENCY = 16'd23;

reg [3:0] state;
reg [2:0] current_op;
reg current_check_expected;
reg [2:0] current_stage;
reg [6:0] issue_bfly;
reg [6:0] prefetch_bfly;
reg [6:0] flush_index;
reg [7:0] init_index;
reg [7:0] scale_index;
reg [7:0] digest_index;
reg [7:0] digest_active_index;
reg [15:0] segment_output_count;
reg [15:0] segment_slot_total;
reg [15:0] segment_cycle;
reg segment_out_started;
reg [31:0] digest_acc;
reg [22:0] digest_coeff_reg;
reg active_buf;
reg [15:0] pipe_accepted_base;

(* ram_style = "block", syn_ramstyle = "block_ram" *)
reg [22:0] coeff0_r0 [0:255];
(* ram_style = "block", syn_ramstyle = "block_ram" *)
reg [22:0] coeff0_r1 [0:255];
(* ram_style = "block", syn_ramstyle = "block_ram" *)
reg [22:0] coeff1_r0 [0:255];
(* ram_style = "block", syn_ramstyle = "block_ram" *)
reg [22:0] coeff1_r1 [0:255];
reg coeff0_we;
reg coeff1_we;
reg [7:0] coeff0_w_addr;
reg [7:0] coeff1_w_addr;
reg [22:0] coeff0_w_data;
reg [22:0] coeff1_w_data;
reg [7:0] coeff0_r0_addr;
reg [7:0] coeff0_r1_addr;
reg [7:0] coeff1_r0_addr;
reg [7:0] coeff1_r1_addr;
reg coeff0_r0_re;
reg coeff0_r1_re;
reg coeff1_r0_re;
reg coeff1_r1_re;
reg [22:0] coeff0_r0_dout;
reg [22:0] coeff0_r1_dout;
reg [22:0] coeff1_r0_dout;
reg [22:0] coeff1_r1_dout;

(* ram_style = "distributed", syn_ramstyle = "distributed" *)
reg [17:0] pending_y1_lo [0:127];
(* ram_style = "distributed", syn_ramstyle = "distributed" *)
reg [12:0] pending_y1_hi [0:127];
reg [6:0] pending_y1_r_addr;
reg pending_y1_re;
reg [17:0] pending_y1_lo_dout;
reg [12:0] pending_y1_hi_dout;

reg req_valid;
reg [2:0] req_op;
reg [4:0] req_index;
reg [7:0] req_addr_a;
reg [7:0] req_addr_b;
reg req_scale;
reg [22:0] req_a_value;
reg [22:0] req_b_value;
reg [22:0] req_twiddle;

reg meta_valid [0:META_LATENCY-1];
reg [2:0] meta_op [0:META_LATENCY-1];
reg [4:0] meta_index [0:META_LATENCY-1];
reg [7:0] meta_addr_a [0:META_LATENCY-1];
reg [7:0] meta_addr_b [0:META_LATENCY-1];
reg meta_scale [0:META_LATENCY-1];

integer i;

wire current_inverse = is_inverse_op(current_op);
wire [7:0] map_addr_a;
wire [7:0] map_addr_b;
wire [1:0] map_bank_a;
wire [1:0] map_bank_b;
wire map_conflict;
wire [7:0] first_addr_a;
wire [7:0] first_addr_b;
wire [7:0] prefetch_addr_a;
wire [7:0] prefetch_addr_b;
wire [2:0] scale_pipe_op = is_dsa_op(current_op) ? OP_DSA_NTT : OP_KEM_NTT;
wire [22:0] coeff_active_a = active_buf ? coeff1_r0_dout : coeff0_r0_dout;
wire [22:0] coeff_active_b = active_buf ? coeff1_r1_dout : coeff0_r1_dout;
wire [7:0] scale_prefetch_addr = scale_index + 8'd1;
wire [7:0] digest_prefetch_addr = digest_active_index + 8'd1;
wire pipe_valid = req_valid;
wire segment_drain = (state == S_STAGE_DRAIN) || (state == S_SCALE_DRAIN);
wire segment_active = pipe_valid || segment_drain;
wire [2:0] pipe_op = req_op;
wire [4:0] pipe_index = req_index;
wire [7:0] pipe_addr_a = req_addr_a;
wire [7:0] pipe_addr_b = req_addr_b;
wire pipe_scale = req_scale;
wire [22:0] pipe_a = req_a_value;
wire [22:0] pipe_b = req_b_value;
wire [22:0] pipe_twiddle = req_twiddle;
wire pipe_ready;
wire pipe_out_valid;
wire [2:0] pipe_out_op;
wire [4:0] pipe_out_index;
wire [22:0] pipe_out_y0;
wire [22:0] pipe_out_y1;
wire [15:0] pipe_accepted_count;
wire [31:0] digest_next =
    rotl5(digest_acc) ^ {9'd0, digest_coeff_reg} ^ {24'd0, digest_active_index};
wire [7:0] pending_y1_addr_dout = pending_y1_hi_dout[12:5];
wire [22:0] pending_y1_value_dout = {pending_y1_hi_dout[4:0], pending_y1_lo_dout};

assign start_ready = (state == S_IDLE) && !busy;
assign coeff_load_ready = start_ready && !start;

ntt256_systolic_bank_mapper mapper (
    .inverse(current_inverse),
    .stage(current_stage),
    .butterfly_index(issue_bfly),
    .addr_a(map_addr_a),
    .addr_b(map_addr_b),
    .bank_a(map_bank_a),
    .bank_b(map_bank_b),
    .conflict(map_conflict)
);

ntt256_systolic_bank_mapper first_mapper (
    .inverse(current_inverse),
    .stage(current_stage),
    .butterfly_index(7'd0),
    .addr_a(first_addr_a),
    .addr_b(first_addr_b),
    .bank_a(),
    .bank_b(),
    .conflict()
);

ntt256_systolic_bank_mapper prefetch_mapper (
    .inverse(current_inverse),
    .stage(current_stage),
    .butterfly_index(prefetch_bfly),
    .addr_a(prefetch_addr_a),
    .addr_b(prefetch_addr_b),
    .bank_a(),
    .bank_b(),
    .conflict()
);

ntt256_systolic_arith_pipe arith_pipe (
    .clk(clk),
    .rst_n(rst_n),
    .in_valid(pipe_valid),
    .in_op(pipe_op),
    .in_index(pipe_index),
    .in_a(pipe_a),
    .in_b(pipe_b),
    .in_twiddle(pipe_twiddle),
    .in_ready(pipe_ready),
    .out_valid(pipe_out_valid),
    .out_op(pipe_out_op),
    .out_index(pipe_out_index),
    .out_y0(pipe_out_y0),
    .out_y1(pipe_out_y1),
    .accepted_count(pipe_accepted_count)
);

function is_dsa_op;
    input [2:0] op_value;
    begin
        is_dsa_op = (op_value == OP_DSA_NTT) || (op_value == OP_DSA_INTT);
    end
endfunction

function is_inverse_op;
    input [2:0] op_value;
    begin
        is_inverse_op = (op_value == OP_KEM_INTT) || (op_value == OP_DSA_INTT);
    end
endfunction

function [22:0] q_value;
    input [2:0] op_value;
    begin
        q_value = is_dsa_op(op_value) ? 23'd8380417 : 23'd3329;
    end
endfunction

function [22:0] n_inv_value;
    input [2:0] op_value;
    begin
        n_inv_value = is_dsa_op(op_value) ? 23'd8347681 : 23'd3316;
    end
endfunction

function [22:0] init_value;
    input [2:0] op_value;
    input [7:0] index;
    reg [31:0] raw;
    reg [31:0] q_ext;
    begin
        q_ext = {9'd0, q_value(op_value)};
        if (is_dsa_op(op_value)) begin
            raw = ({24'd0, index} << 16) + {24'd0, index} + 32'd12345;
        end else begin
            raw = ({24'd0, index} << 4) + {24'd0, index} + 32'd5;
        end
        if (raw >= q_ext) begin
            raw = raw - q_ext;
        end
        init_value = raw[22:0];
    end
endfunction

function [22:0] twiddle_value;
    input mode_dsa;
    input [7:0] index;
    begin
        case (index)
            8'd0: twiddle_value = 23'd1;
            8'd1: twiddle_value = 23'd1;
            8'd2: twiddle_value = mode_dsa ? 23'd4808194 : 23'd1729;
            8'd3: twiddle_value = 23'd1;
            8'd4: twiddle_value = mode_dsa ? 23'd3765607 : 23'd2580;
            8'd5: twiddle_value = mode_dsa ? 23'd4808194 : 23'd1729;
            8'd6: twiddle_value = mode_dsa ? 23'd3761513 : 23'd3289;
            8'd7: twiddle_value = 23'd1;
            8'd8: twiddle_value = mode_dsa ? 23'd5178923 : 23'd2642;
            8'd9: twiddle_value = mode_dsa ? 23'd3765607 : 23'd2580;
            8'd10: twiddle_value = mode_dsa ? 23'd5234739 : 23'd1897;
            8'd11: twiddle_value = mode_dsa ? 23'd4808194 : 23'd1729;
            8'd12: twiddle_value = mode_dsa ? 23'd5496691 : 23'd630;
            8'd13: twiddle_value = mode_dsa ? 23'd3761513 : 23'd3289;
            8'd14: twiddle_value = mode_dsa ? 23'd5178987 : 23'd848;
            8'd15: twiddle_value = 23'd1;
            8'd16: twiddle_value = mode_dsa ? 23'd7778734 : 23'd1062;
            8'd17: twiddle_value = mode_dsa ? 23'd5178923 : 23'd2642;
            8'd18: twiddle_value = mode_dsa ? 23'd3764867 : 23'd2786;
            8'd19: twiddle_value = mode_dsa ? 23'd3765607 : 23'd2580;
            8'd20: twiddle_value = mode_dsa ? 23'd2682288 : 23'd193;
            8'd21: twiddle_value = mode_dsa ? 23'd5234739 : 23'd1897;
            8'd22: twiddle_value = mode_dsa ? 23'd557458 : 23'd569;
            8'd23: twiddle_value = mode_dsa ? 23'd4808194 : 23'd1729;
            8'd24: twiddle_value = mode_dsa ? 23'd3542485 : 23'd1919;
            8'd25: twiddle_value = mode_dsa ? 23'd5496691 : 23'd630;
            8'd26: twiddle_value = mode_dsa ? 23'd7375178 : 23'd3260;
            8'd27: twiddle_value = mode_dsa ? 23'd3761513 : 23'd3289;
            8'd28: twiddle_value = mode_dsa ? 23'd2129892 : 23'd797;
            8'd29: twiddle_value = mode_dsa ? 23'd5178987 : 23'd848;
            8'd30: twiddle_value = mode_dsa ? 23'd7159240 : 23'd1746;
            8'd31: twiddle_value = 23'd1;
            8'd32: twiddle_value = mode_dsa ? 23'd5010068 : 23'd296;
            8'd33: twiddle_value = mode_dsa ? 23'd7778734 : 23'd1062;
            8'd34: twiddle_value = mode_dsa ? 23'd5152541 : 23'd1426;
            8'd35: twiddle_value = mode_dsa ? 23'd5178923 : 23'd2642;
            8'd36: twiddle_value = mode_dsa ? 23'd4855975 : 23'd3046;
            8'd37: twiddle_value = mode_dsa ? 23'd3764867 : 23'd2786;
            8'd38: twiddle_value = mode_dsa ? 23'd7737789 : 23'd2393;
            8'd39: twiddle_value = mode_dsa ? 23'd3765607 : 23'd2580;
            8'd40: twiddle_value = mode_dsa ? 23'd2663378 : 23'd1339;
            8'd41: twiddle_value = mode_dsa ? 23'd2682288 : 23'd193;
            8'd42: twiddle_value = mode_dsa ? 23'd2453983 : 23'd535;
            8'd43: twiddle_value = mode_dsa ? 23'd5234739 : 23'd1897;
            8'd44: twiddle_value = mode_dsa ? 23'd676590 : 23'd2240;
            8'd45: twiddle_value = mode_dsa ? 23'd557458 : 23'd569;
            8'd46: twiddle_value = mode_dsa ? 23'd2815639 : 23'd1974;
            8'd47: twiddle_value = mode_dsa ? 23'd4808194 : 23'd1729;
            8'd48: twiddle_value = mode_dsa ? 23'd4317364 : 23'd2447;
            8'd49: twiddle_value = mode_dsa ? 23'd3542485 : 23'd1919;
            8'd50: twiddle_value = mode_dsa ? 23'd1714295 : 23'd2094;
            8'd51: twiddle_value = mode_dsa ? 23'd5496691 : 23'd630;
            8'd52: twiddle_value = mode_dsa ? 23'd7946292 : 23'd56;
            8'd53: twiddle_value = mode_dsa ? 23'd7375178 : 23'd3260;
            8'd54: twiddle_value = mode_dsa ? 23'd4795319 : 23'd2879;
            8'd55: twiddle_value = mode_dsa ? 23'd3761513 : 23'd3289;
            8'd56: twiddle_value = mode_dsa ? 23'd6705802 : 23'd1476;
            8'd57: twiddle_value = mode_dsa ? 23'd2129892 : 23'd797;
            8'd58: twiddle_value = mode_dsa ? 23'd1460718 : 23'd2882;
            8'd59: twiddle_value = mode_dsa ? 23'd5178987 : 23'd848;
            8'd60: twiddle_value = mode_dsa ? 23'd7044481 : 23'd1333;
            8'd61: twiddle_value = mode_dsa ? 23'd7159240 : 23'd1746;
            8'd62: twiddle_value = mode_dsa ? 23'd2283733 : 23'd821;
            8'd63: twiddle_value = 23'd1;
            8'd64: twiddle_value = mode_dsa ? 23'd3602218 : 23'd289;
            8'd65: twiddle_value = mode_dsa ? 23'd5010068 : 23'd296;
            8'd66: twiddle_value = mode_dsa ? 23'd3415069 : 23'd2319;
            8'd67: twiddle_value = mode_dsa ? 23'd7778734 : 23'd1062;
            8'd68: twiddle_value = mode_dsa ? 23'd394148 : 23'd650;
            8'd69: twiddle_value = mode_dsa ? 23'd5152541 : 23'd1426;
            8'd70: twiddle_value = mode_dsa ? 23'd5483103 : 23'd2647;
            8'd71: twiddle_value = mode_dsa ? 23'd5178923 : 23'd2642;
            8'd72: twiddle_value = mode_dsa ? 23'd5269599 : 23'd1197;
            8'd73: twiddle_value = mode_dsa ? 23'd4855975 : 23'd3046;
            8'd74: twiddle_value = mode_dsa ? 23'd3756790 : 23'd1438;
            8'd75: twiddle_value = mode_dsa ? 23'd3764867 : 23'd2786;
            8'd76: twiddle_value = mode_dsa ? 23'd2071829 : 23'd2865;
            8'd77: twiddle_value = mode_dsa ? 23'd7737789 : 23'd2393;
            8'd78: twiddle_value = mode_dsa ? 23'd2917338 : 23'd2474;
            8'd79: twiddle_value = mode_dsa ? 23'd3765607 : 23'd2580;
            8'd80: twiddle_value = mode_dsa ? 23'd2740543 : 23'd3253;
            8'd81: twiddle_value = mode_dsa ? 23'd2663378 : 23'd1339;
            8'd82: twiddle_value = mode_dsa ? 23'd7562881 : 23'd807;
            8'd83: twiddle_value = mode_dsa ? 23'd2682288 : 23'd193;
            8'd84: twiddle_value = mode_dsa ? 23'd1095468 : 23'd2513;
            8'd85: twiddle_value = mode_dsa ? 23'd2453983 : 23'd535;
            8'd86: twiddle_value = mode_dsa ? 23'd556856 : 23'd1481;
            8'd87: twiddle_value = mode_dsa ? 23'd5234739 : 23'd1897;
            8'd88: twiddle_value = mode_dsa ? 23'd3704823 : 23'd2277;
            8'd89: twiddle_value = mode_dsa ? 23'd676590 : 23'd2240;
            8'd90: twiddle_value = mode_dsa ? 23'd6663429 : 23'd1534;
            8'd91: twiddle_value = mode_dsa ? 23'd557458 : 23'd569;
            8'd92: twiddle_value = mode_dsa ? 23'd3241972 : 23'd1320;
            8'd93: twiddle_value = mode_dsa ? 23'd2815639 : 23'd1974;
            8'd94: twiddle_value = mode_dsa ? 23'd3345963 : 23'd1227;
            8'd95: twiddle_value = mode_dsa ? 23'd4808194 : 23'd1729;
            8'd96: twiddle_value = mode_dsa ? 23'd3182878 : 23'd331;
            8'd97: twiddle_value = mode_dsa ? 23'd4317364 : 23'd2447;
            8'd98: twiddle_value = mode_dsa ? 23'd1759347 : 23'd1435;
            8'd99: twiddle_value = mode_dsa ? 23'd3542485 : 23'd1919;
            8'd100: twiddle_value = mode_dsa ? 23'd928749 : 23'd1977;
            8'd101: twiddle_value = mode_dsa ? 23'd1714295 : 23'd2094;
            8'd102: twiddle_value = mode_dsa ? 23'd3192354 : 23'd2617;
            8'd103: twiddle_value = mode_dsa ? 23'd5496691 : 23'd630;
            8'd104: twiddle_value = mode_dsa ? 23'd2101410 : 23'd2304;
            8'd105: twiddle_value = mode_dsa ? 23'd7946292 : 23'd56;
            8'd106: twiddle_value = mode_dsa ? 23'd6444618 : 23'd2868;
            8'd107: twiddle_value = mode_dsa ? 23'd7375178 : 23'd3260;
            8'd108: twiddle_value = mode_dsa ? 23'd4361428 : 23'd33;
            8'd109: twiddle_value = mode_dsa ? 23'd4795319 : 23'd2879;
            8'd110: twiddle_value = mode_dsa ? 23'd1853806 : 23'd3110;
            8'd111: twiddle_value = mode_dsa ? 23'd3761513 : 23'd3289;
            8'd112: twiddle_value = mode_dsa ? 23'd4793971 : 23'd1756;
            8'd113: twiddle_value = mode_dsa ? 23'd6705802 : 23'd1476;
            8'd114: twiddle_value = mode_dsa ? 23'd4805951 : 23'd452;
            8'd115: twiddle_value = mode_dsa ? 23'd2129892 : 23'd797;
            8'd116: twiddle_value = mode_dsa ? 23'd4874037 : 23'd632;
            8'd117: twiddle_value = mode_dsa ? 23'd1460718 : 23'd2882;
            8'd118: twiddle_value = mode_dsa ? 23'd3870317 : 23'd648;
            8'd119: twiddle_value = mode_dsa ? 23'd5178987 : 23'd848;
            8'd120: twiddle_value = mode_dsa ? 23'd1159875 : 23'd2055;
            8'd121: twiddle_value = mode_dsa ? 23'd7044481 : 23'd1333;
            8'd122: twiddle_value = mode_dsa ? 23'd4430364 : 23'd2402;
            8'd123: twiddle_value = mode_dsa ? 23'd7159240 : 23'd1746;
            8'd124: twiddle_value = mode_dsa ? 23'd2156050 : 23'd1915;
            8'd125: twiddle_value = mode_dsa ? 23'd2283733 : 23'd821;
            8'd126: twiddle_value = mode_dsa ? 23'd1858416 : 23'd910;
            8'd127: twiddle_value = 23'd1;
            8'd128: twiddle_value = mode_dsa ? 23'd3073009 : 23'd17;
            8'd129: twiddle_value = mode_dsa ? 23'd3602218 : 23'd289;
            8'd130: twiddle_value = mode_dsa ? 23'd5801164 : 23'd1584;
            8'd131: twiddle_value = mode_dsa ? 23'd5010068 : 23'd296;
            8'd132: twiddle_value = mode_dsa ? 23'd1528066 : 23'd1703;
            8'd133: twiddle_value = mode_dsa ? 23'd3415069 : 23'd2319;
            8'd134: twiddle_value = mode_dsa ? 23'd1356448 : 23'd2804;
            8'd135: twiddle_value = mode_dsa ? 23'd7778734 : 23'd1062;
            8'd136: twiddle_value = mode_dsa ? 23'd2508980 : 23'd1409;
            8'd137: twiddle_value = mode_dsa ? 23'd394148 : 23'd650;
            8'd138: twiddle_value = mode_dsa ? 23'd7062739 : 23'd1063;
            8'd139: twiddle_value = mode_dsa ? 23'd5152541 : 23'd1426;
            8'd140: twiddle_value = mode_dsa ? 23'd4213992 : 23'd939;
            8'd141: twiddle_value = mode_dsa ? 23'd5483103 : 23'd2647;
            8'd142: twiddle_value = mode_dsa ? 23'd348812 : 23'd1722;
            8'd143: twiddle_value = mode_dsa ? 23'd5178923 : 23'd2642;
            8'd144: twiddle_value = mode_dsa ? 23'd4183372 : 23'd1637;
            8'd145: twiddle_value = mode_dsa ? 23'd5269599 : 23'd1197;
            8'd146: twiddle_value = mode_dsa ? 23'd3482206 : 23'd375;
            8'd147: twiddle_value = mode_dsa ? 23'd4855975 : 23'd3046;
            8'd148: twiddle_value = mode_dsa ? 23'd7814814 : 23'd1847;
            8'd149: twiddle_value = mode_dsa ? 23'd3756790 : 23'd1438;
            8'd150: twiddle_value = mode_dsa ? 23'd4912752 : 23'd1143;
            8'd151: twiddle_value = mode_dsa ? 23'd3764867 : 23'd2786;
            8'd152: twiddle_value = mode_dsa ? 23'd2811291 : 23'd756;
            8'd153: twiddle_value = mode_dsa ? 23'd2071829 : 23'd2865;
            8'd154: twiddle_value = mode_dsa ? 23'd3901472 : 23'd2099;
            8'd155: twiddle_value = mode_dsa ? 23'd7737789 : 23'd2393;
            8'd156: twiddle_value = mode_dsa ? 23'd1736313 : 23'd733;
            8'd157: twiddle_value = mode_dsa ? 23'd2917338 : 23'd2474;
            8'd158: twiddle_value = mode_dsa ? 23'd4561790 : 23'd2110;
            8'd159: twiddle_value = mode_dsa ? 23'd3765607 : 23'd2580;
            8'd160: twiddle_value = mode_dsa ? 23'd5744944 : 23'd583;
            8'd161: twiddle_value = mode_dsa ? 23'd2740543 : 23'd3253;
            8'd162: twiddle_value = mode_dsa ? 23'd5989328 : 23'd2037;
            8'd163: twiddle_value = mode_dsa ? 23'd2663378 : 23'd1339;
            8'd164: twiddle_value = mode_dsa ? 23'd1148858 : 23'd2789;
            8'd165: twiddle_value = mode_dsa ? 23'd7562881 : 23'd807;
            8'd166: twiddle_value = mode_dsa ? 23'd2683270 : 23'd403;
            8'd167: twiddle_value = mode_dsa ? 23'd2682288 : 23'd193;
            8'd168: twiddle_value = mode_dsa ? 23'd1937570 : 23'd3281;
            8'd169: twiddle_value = mode_dsa ? 23'd1095468 : 23'd2513;
            8'd170: twiddle_value = mode_dsa ? 23'd3035980 : 23'd2773;
            8'd171: twiddle_value = mode_dsa ? 23'd2453983 : 23'd535;
            8'd172: twiddle_value = mode_dsa ? 23'd1987814 : 23'd2437;
            8'd173: twiddle_value = mode_dsa ? 23'd556856 : 23'd1481;
            8'd174: twiddle_value = mode_dsa ? 23'd1011223 : 23'd1874;
            8'd175: twiddle_value = mode_dsa ? 23'd5234739 : 23'd1897;
            8'd176: twiddle_value = mode_dsa ? 23'd5258977 : 23'd2288;
            8'd177: twiddle_value = mode_dsa ? 23'd3704823 : 23'd2277;
            8'd178: twiddle_value = mode_dsa ? 23'd7080401 : 23'd2090;
            8'd179: twiddle_value = mode_dsa ? 23'd676590 : 23'd2240;
            8'd180: twiddle_value = mode_dsa ? 23'd2462444 : 23'd1461;
            8'd181: twiddle_value = mode_dsa ? 23'd6663429 : 23'd1534;
            8'd182: twiddle_value = mode_dsa ? 23'd7727142 : 23'd2775;
            8'd183: twiddle_value = mode_dsa ? 23'd557458 : 23'd569;
            8'd184: twiddle_value = mode_dsa ? 23'd7270901 : 23'd3015;
            8'd185: twiddle_value = mode_dsa ? 23'd3241972 : 23'd1320;
            8'd186: twiddle_value = mode_dsa ? 23'd2925816 : 23'd2466;
            8'd187: twiddle_value = mode_dsa ? 23'd2815639 : 23'd1974;
            8'd188: twiddle_value = mode_dsa ? 23'd5130263 : 23'd268;
            8'd189: twiddle_value = mode_dsa ? 23'd3345963 : 23'd1227;
            8'd190: twiddle_value = mode_dsa ? 23'd6143691 : 23'd885;
            8'd191: twiddle_value = mode_dsa ? 23'd4808194 : 23'd1729;
            8'd192: twiddle_value = mode_dsa ? 23'd1277625 : 23'd2761;
            8'd193: twiddle_value = mode_dsa ? 23'd3182878 : 23'd331;
            8'd194: twiddle_value = mode_dsa ? 23'd1787943 : 23'd2298;
            8'd195: twiddle_value = mode_dsa ? 23'd4317364 : 23'd2447;
            8'd196: twiddle_value = mode_dsa ? 23'd482649 : 23'd1651;
            8'd197: twiddle_value = mode_dsa ? 23'd1759347 : 23'd1435;
            8'd198: twiddle_value = mode_dsa ? 23'd5604662 : 23'd1092;
            8'd199: twiddle_value = mode_dsa ? 23'd3542485 : 23'd1919;
            8'd200: twiddle_value = mode_dsa ? 23'd2028118 : 23'd2662;
            8'd201: twiddle_value = mode_dsa ? 23'd928749 : 23'd1977;
            8'd202: twiddle_value = mode_dsa ? 23'd2461387 : 23'd319;
            8'd203: twiddle_value = mode_dsa ? 23'd1714295 : 23'd2094;
            8'd204: twiddle_value = mode_dsa ? 23'd4892034 : 23'd2308;
            8'd205: twiddle_value = mode_dsa ? 23'd3192354 : 23'd2617;
            8'd206: twiddle_value = mode_dsa ? 23'd8052569 : 23'd1212;
            8'd207: twiddle_value = mode_dsa ? 23'd5496691 : 23'd630;
            8'd208: twiddle_value = mode_dsa ? 23'd5157610 : 23'd723;
            8'd209: twiddle_value = mode_dsa ? 23'd2101410 : 23'd2304;
            8'd210: twiddle_value = mode_dsa ? 23'd4197502 : 23'd2549;
            8'd211: twiddle_value = mode_dsa ? 23'd7946292 : 23'd56;
            8'd212: twiddle_value = mode_dsa ? 23'd169688 : 23'd952;
            8'd213: twiddle_value = mode_dsa ? 23'd6444618 : 23'd2868;
            8'd214: twiddle_value = mode_dsa ? 23'd2312838 : 23'd2150;
            8'd215: twiddle_value = mode_dsa ? 23'd7375178 : 23'd3260;
            8'd216: twiddle_value = mode_dsa ? 23'd5396636 : 23'd2156;
            8'd217: twiddle_value = mode_dsa ? 23'd4361428 : 23'd33;
            8'd218: twiddle_value = mode_dsa ? 23'd7153756 : 23'd561;
            8'd219: twiddle_value = mode_dsa ? 23'd4795319 : 23'd2879;
            8'd220: twiddle_value = mode_dsa ? 23'd235407 : 23'd2337;
            8'd221: twiddle_value = mode_dsa ? 23'd1853806 : 23'd3110;
            8'd222: twiddle_value = mode_dsa ? 23'd6458164 : 23'd2935;
            8'd223: twiddle_value = mode_dsa ? 23'd3761513 : 23'd3289;
            8'd224: twiddle_value = mode_dsa ? 23'd3852015 : 23'd2649;
            8'd225: twiddle_value = mode_dsa ? 23'd4793971 : 23'd1756;
            8'd226: twiddle_value = mode_dsa ? 23'd6125690 : 23'd3220;
            8'd227: twiddle_value = mode_dsa ? 23'd6705802 : 23'd1476;
            8'd228: twiddle_value = mode_dsa ? 23'd5418153 : 23'd1789;
            8'd229: twiddle_value = mode_dsa ? 23'd4805951 : 23'd452;
            8'd230: twiddle_value = mode_dsa ? 23'd5601629 : 23'd1026;
            8'd231: twiddle_value = mode_dsa ? 23'd2129892 : 23'd797;
            8'd232: twiddle_value = mode_dsa ? 23'd4564692 : 23'd233;
            8'd233: twiddle_value = mode_dsa ? 23'd4874037 : 23'd632;
            8'd234: twiddle_value = mode_dsa ? 23'd621164 : 23'd757;
            8'd235: twiddle_value = mode_dsa ? 23'd1460718 : 23'd2882;
            8'd236: twiddle_value = mode_dsa ? 23'd5183169 : 23'd2388;
            8'd237: twiddle_value = mode_dsa ? 23'd3870317 : 23'd648;
            8'd238: twiddle_value = mode_dsa ? 23'd6026202 : 23'd1029;
            8'd239: twiddle_value = mode_dsa ? 23'd5178987 : 23'd848;
            8'd240: twiddle_value = mode_dsa ? 23'd8106357 : 23'd1100;
            8'd241: twiddle_value = mode_dsa ? 23'd1159875 : 23'd2055;
            8'd242: twiddle_value = mode_dsa ? 23'd6018354 : 23'd1645;
            8'd243: twiddle_value = mode_dsa ? 23'd7044481 : 23'd1333;
            8'd244: twiddle_value = mode_dsa ? 23'd5046034 : 23'd2687;
            8'd245: twiddle_value = mode_dsa ? 23'd4430364 : 23'd2402;
            8'd246: twiddle_value = mode_dsa ? 23'd7921254 : 23'd886;
            8'd247: twiddle_value = mode_dsa ? 23'd7159240 : 23'd1746;
            8'd248: twiddle_value = mode_dsa ? 23'd4158088 : 23'd3050;
            8'd249: twiddle_value = mode_dsa ? 23'd2156050 : 23'd1915;
            8'd250: twiddle_value = mode_dsa ? 23'd3374250 : 23'd2594;
            8'd251: twiddle_value = mode_dsa ? 23'd2283733 : 23'd821;
            8'd252: twiddle_value = mode_dsa ? 23'd3258457 : 23'd641;
            8'd253: twiddle_value = mode_dsa ? 23'd1858416 : 23'd910;
            default: twiddle_value = mode_dsa ? 23'd1744507 : 23'd2154;
        endcase
    end
endfunction

function [7:0] twiddle_exponent;
    input [2:0] op;
    input [2:0] stage;
    input [6:0] bfly;
    reg [2:0] gap_log;
    reg [7:0] low_mask;
    reg [7:0] j_value;
    reg [3:0] shift_value;
    begin
        gap_log = is_inverse_op(op) ? (3'd7 - stage) : stage;
        low_mask = (8'd1 << gap_log) - 8'd1;
        j_value = {1'b0, bfly} & low_mask;
        shift_value = 4'd7 - {1'b0, gap_log};
        twiddle_exponent = j_value << shift_value;
    end
endfunction

function [7:0] forward_twiddle_index;
    input [2:0] stage;
    input [6:0] bfly;
    reg [7:0] m_value;
    reg [7:0] low_mask;
    reg [7:0] j_value;
    begin
        m_value = 8'd1 << stage;
        low_mask = m_value - 8'd1;
        j_value = {1'b0, bfly} & low_mask;
        forward_twiddle_index = (m_value - 8'd1) + j_value;
    end
endfunction

function [22:0] inverse_twiddle_value;
    input mode_dsa;
    input [7:0] exponent;
    reg [22:0] q;
    reg [22:0] forward_value;
    begin
        q = mode_dsa ? 23'd8380417 : 23'd3329;
        if (exponent == 8'd0) begin
            inverse_twiddle_value = 23'd1;
        end else begin
            forward_value = twiddle_value(mode_dsa, 8'd255 - exponent);
            inverse_twiddle_value = q - forward_value;
        end
    end
endfunction

function [22:0] twiddle_for_slot;
    input [2:0] op;
    input [2:0] stage;
    input [6:0] bfly;
    reg [7:0] exponent;
    reg [7:0] table_index;
    reg mode_dsa;
    begin
        exponent = twiddle_exponent(op, stage, bfly);
        table_index = forward_twiddle_index(stage, bfly);
        mode_dsa = is_dsa_op(op);
        twiddle_for_slot = is_inverse_op(op)
            ? inverse_twiddle_value(mode_dsa, exponent)
            : twiddle_value(mode_dsa, table_index);
    end
endfunction


function [31:0] expected_digest;
    input [2:0] op_value;
    begin
        case (op_value)
            OP_KEM_NTT: expected_digest = 32'h1e664367;
            OP_DSA_NTT: expected_digest = 32'h7fc8e2fc;
            OP_KEM_INTT: expected_digest = 32'hb88a6c64;
            default: expected_digest = 32'hd23ecef9;
        endcase
    end
endfunction

function [15:0] expected_issue_slots;
    input [2:0] op_value;
    begin
        expected_issue_slots = is_inverse_op(op_value)
            ? (STAGE_SLOTS * 16'd8) + SCALE_SLOTS
            : (STAGE_SLOTS * 16'd8);
    end
endfunction

function [31:0] rotl5;
    input [31:0] value;
    begin
        rotl5 = {value[26:0], value[31:27]};
    end
endfunction

always @* begin
    coeff0_we = 1'b0;
    coeff1_we = 1'b0;
    coeff0_w_addr = 8'd0;
    coeff1_w_addr = 8'd0;
    coeff0_w_data = 23'd0;
    coeff1_w_data = 23'd0;
    coeff0_r0_addr = 8'd0;
    coeff0_r1_addr = 8'd0;
    coeff1_r0_addr = 8'd0;
    coeff1_r1_addr = 8'd0;
    coeff0_r0_re = 1'b0;
    coeff0_r1_re = 1'b0;
    coeff1_r0_re = 1'b0;
    coeff1_r1_re = 1'b0;
    pending_y1_r_addr = 7'd0;
    pending_y1_re = 1'b0;

    if (coeff_load_ready && coeff_load_valid) begin
        if (active_buf) begin
            coeff1_we = 1'b1;
            coeff1_w_addr = coeff_load_addr;
            coeff1_w_data = coeff_load_data;
        end else begin
            coeff0_we = 1'b1;
            coeff0_w_addr = coeff_load_addr;
            coeff0_w_data = coeff_load_data;
        end
    end

    case (state)
        S_INIT: begin
            coeff0_we = 1'b1;
            coeff0_w_addr = init_index;
            coeff0_w_data = init_value(current_op, init_index);
        end

        S_STAGE_SETUP: begin
            if (active_buf) begin
                coeff1_r0_re = 1'b1;
                coeff1_r1_re = 1'b1;
                coeff1_r0_addr = first_addr_a;
                coeff1_r1_addr = first_addr_b;
            end else begin
                coeff0_r0_re = 1'b1;
                coeff0_r1_re = 1'b1;
                coeff0_r0_addr = first_addr_a;
                coeff0_r1_addr = first_addr_b;
            end
        end

        S_STAGE_READ: begin
            if (active_buf) begin
                coeff1_r0_re = 1'b1;
                coeff1_r1_re = 1'b1;
                coeff1_r0_addr = prefetch_addr_a;
                coeff1_r1_addr = prefetch_addr_b;
            end else begin
                coeff0_r0_re = 1'b1;
                coeff0_r1_re = 1'b1;
                coeff0_r0_addr = prefetch_addr_a;
                coeff0_r1_addr = prefetch_addr_b;
            end
        end

        S_SCALE_SETUP: begin
            if (active_buf) begin
                coeff1_r0_re = 1'b1;
                coeff1_r0_addr = 8'd0;
            end else begin
                coeff0_r0_re = 1'b1;
                coeff0_r0_addr = 8'd0;
            end
        end

        S_SCALE_READ: begin
            if (active_buf) begin
                coeff1_r0_re = 1'b1;
                coeff1_r0_addr = scale_prefetch_addr;
            end else begin
                coeff0_r0_re = 1'b1;
                coeff0_r0_addr = scale_prefetch_addr;
            end
        end

        S_DIGEST_INIT: begin
            if (active_buf) begin
                coeff1_r0_re = 1'b1;
                coeff1_r0_addr = 8'd0;
            end else begin
                coeff0_r0_re = 1'b1;
                coeff0_r0_addr = 8'd0;
            end
        end

        S_DIGEST_READ: begin
            if (active_buf) begin
                coeff1_r0_re = 1'b1;
                coeff1_r0_addr = digest_index;
            end else begin
                coeff0_r0_re = 1'b1;
                coeff0_r0_addr = digest_index;
            end
        end

        S_DIGEST_RUN: begin
            if (active_buf) begin
                coeff1_r0_re = 1'b1;
                coeff1_r0_addr = digest_prefetch_addr;
            end else begin
                coeff0_r0_re = 1'b1;
                coeff0_r0_addr = digest_prefetch_addr;
            end
        end

        S_STAGE_FLUSH_SETUP: begin
            pending_y1_re = 1'b1;
            pending_y1_r_addr = flush_index;
        end

        S_STAGE_FLUSH: begin
            pending_y1_re = 1'b1;
            pending_y1_r_addr = flush_index + 7'd1;
            if (active_buf) begin
                coeff0_we = 1'b1;
                coeff0_w_addr = pending_y1_addr_dout;
                coeff0_w_data = pending_y1_value_dout;
            end else begin
                coeff1_we = 1'b1;
                coeff1_w_addr = pending_y1_addr_dout;
                coeff1_w_data = pending_y1_value_dout;
            end
        end

        default: begin
        end
    endcase

    if (pipe_out_valid) begin
        if (active_buf) begin
            coeff0_we = 1'b1;
            coeff0_w_addr = meta_addr_a[META_LATENCY-1];
            coeff0_w_data = pipe_out_y0;
        end else begin
            coeff1_we = 1'b1;
            coeff1_w_addr = meta_addr_a[META_LATENCY-1];
            coeff1_w_data = pipe_out_y0;
        end
    end
end

always @(posedge clk) begin
    if (rst_n && pipe_out_valid && !meta_scale[META_LATENCY-1]) begin
        pending_y1_lo[segment_output_count[6:0]] <= pipe_out_y1[17:0];
        pending_y1_hi[segment_output_count[6:0]] <= {
            meta_addr_b[META_LATENCY-1],
            pipe_out_y1[22:18]
        };
    end
    if (rst_n && pending_y1_re) begin
        pending_y1_lo_dout <= pending_y1_lo[pending_y1_r_addr];
        pending_y1_hi_dout <= pending_y1_hi[pending_y1_r_addr];
    end

    if (coeff0_we) begin
        coeff0_r0[coeff0_w_addr] <= coeff0_w_data;
        coeff0_r1[coeff0_w_addr] <= coeff0_w_data;
    end
    if (rst_n && coeff0_r0_re) begin
        if (coeff0_we && (coeff0_w_addr == coeff0_r0_addr)) begin
            coeff0_r0_dout <= coeff0_w_data;
        end else begin
            coeff0_r0_dout <= coeff0_r0[coeff0_r0_addr];
        end
    end
    if (rst_n && coeff0_r1_re) begin
        if (coeff0_we && (coeff0_w_addr == coeff0_r1_addr)) begin
            coeff0_r1_dout <= coeff0_w_data;
        end else begin
            coeff0_r1_dout <= coeff0_r1[coeff0_r1_addr];
        end
    end

    if (coeff1_we) begin
        coeff1_r0[coeff1_w_addr] <= coeff1_w_data;
        coeff1_r1[coeff1_w_addr] <= coeff1_w_data;
    end
    if (rst_n && coeff1_r0_re) begin
        if (coeff1_we && (coeff1_w_addr == coeff1_r0_addr)) begin
            coeff1_r0_dout <= coeff1_w_data;
        end else begin
            coeff1_r0_dout <= coeff1_r0[coeff1_r0_addr];
        end
    end
    if (rst_n && coeff1_r1_re) begin
        if (coeff1_we && (coeff1_w_addr == coeff1_r1_addr)) begin
            coeff1_r1_dout <= coeff1_w_data;
        end else begin
            coeff1_r1_dout <= coeff1_r1[coeff1_r1_addr];
        end
    end
end

always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        state <= S_IDLE;
        current_op <= OP_KEM_NTT;
        current_check_expected <= 1'b0;
        current_stage <= 3'd0;
        issue_bfly <= 7'd0;
        prefetch_bfly <= 7'd0;
        flush_index <= 7'd0;
        init_index <= 8'd0;
        scale_index <= 8'd0;
        digest_index <= 8'd0;
        digest_active_index <= 8'd0;
        segment_output_count <= 16'd0;
        segment_slot_total <= STAGE_SLOTS;
        segment_cycle <= 16'd0;
        segment_out_started <= 1'b0;
        digest_acc <= 32'd0;
        digest_coeff_reg <= 23'd0;
        active_buf <= 1'b0;
        pipe_accepted_base <= 16'd0;
        req_valid <= 1'b0;
        req_op <= OP_KEM_NTT;
        req_index <= 5'd0;
        req_addr_a <= 8'd0;
        req_addr_b <= 8'd0;
        req_scale <= 1'b0;
        req_a_value <= 23'd0;
        req_b_value <= 23'd0;
        req_twiddle <= 23'd1;
        busy <= 1'b0;
        done <= 1'b0;
        pass <= 1'b0;
        error <= 1'b0;
        out_valid <= 1'b0;
        out_op <= OP_KEM_NTT;
        out_index <= 5'd0;
        out_y0 <= 23'd0;
        out_y1 <= 23'd0;
        issue_count <= 16'd0;
        output_count <= 16'd0;
        bubble_count <= 16'd0;
        bank_check_count <= 16'd0;
        first_latency <= 16'hffff;
        digest <= 32'd0;
        signature <= 32'h53544152;
        for (i = 0; i < META_LATENCY; i = i + 1) begin
            meta_valid[i] <= 1'b0;
            meta_op[i] <= OP_KEM_NTT;
            meta_index[i] <= 5'd0;
            meta_addr_a[i] <= 8'd0;
            meta_addr_b[i] <= 8'd0;
            meta_scale[i] <= 1'b0;
        end
    end else begin
        out_valid <= pipe_out_valid;
        out_op <= pipe_out_op;
        out_index <= pipe_out_index;
        out_y0 <= pipe_out_y0;
        out_y1 <= pipe_out_y1;

        meta_valid[0] <= pipe_valid && pipe_ready;
        meta_op[0] <= pipe_op;
        meta_index[0] <= pipe_index;
        meta_addr_a[0] <= pipe_addr_a;
        meta_addr_b[0] <= pipe_addr_b;
        meta_scale[0] <= pipe_scale;
        for (i = 1; i < META_LATENCY; i = i + 1) begin
            meta_valid[i] <= meta_valid[i - 1];
            meta_op[i] <= meta_op[i - 1];
            meta_index[i] <= meta_index[i - 1];
            meta_addr_a[i] <= meta_addr_a[i - 1];
            meta_addr_b[i] <= meta_addr_b[i - 1];
            meta_scale[i] <= meta_scale[i - 1];
        end

        if (segment_active) begin
            segment_cycle <= segment_cycle + 16'd1;
        end

        req_valid <= 1'b0;

        if (pipe_out_valid) begin
            if (!meta_valid[META_LATENCY-1] ||
                (pipe_out_op != meta_op[META_LATENCY-1]) ||
                (pipe_out_index != meta_index[META_LATENCY-1]) ||
                (segment_output_count >= segment_slot_total)) begin
                error <= 1'b1;
            end

            if (!segment_out_started) begin
                segment_out_started <= 1'b1;
                first_latency <= segment_cycle - 16'd1;
                if ((segment_cycle - 16'd1) != EXPECTED_LATENCY) begin
                    error <= 1'b1;
                end
            end

            segment_output_count <= segment_output_count + 16'd1;
            output_count <= output_count + 16'd1;
        end else if (segment_active && segment_out_started &&
                     (segment_output_count < segment_slot_total)) begin
            bubble_count <= bubble_count + 16'd1;
            error <= 1'b1;
        end

        case (state)
            S_IDLE: begin
                busy <= 1'b0;
                if (start) begin
                    done <= 1'b0;
                    pass <= 1'b0;
                    error <= (op > OP_DSA_INTT);
                    current_op <= op;
                    current_check_expected <= check_expected;
                    current_stage <= 3'd0;
                    issue_bfly <= 7'd0;
                    prefetch_bfly <= 7'd0;
                    flush_index <= 7'd0;
                    init_index <= 8'd0;
                    scale_index <= 8'd0;
                    digest_index <= 8'd0;
                    digest_active_index <= 8'd0;
                    segment_output_count <= 16'd0;
                    segment_slot_total <= STAGE_SLOTS;
                    segment_cycle <= 16'd0;
                    segment_out_started <= 1'b0;
                    digest_acc <= 32'd0;
                    digest_coeff_reg <= 23'd0;
                    req_valid <= 1'b0;
                    issue_count <= 16'd0;
                    output_count <= 16'd0;
                    bubble_count <= 16'd0;
                    bank_check_count <= 16'd0;
                    first_latency <= 16'hffff;
                    digest <= 32'd0;
                    signature <= 32'h53544152 ^ {29'd0, op};
                    pipe_accepted_base <= pipe_accepted_count;
                    if (op > OP_DSA_INTT) begin
                        done <= 1'b1;
                        pass <= 1'b0;
                        busy <= 1'b0;
                    end else begin
                        busy <= 1'b1;
                        if (auto_init) begin
                            active_buf <= 1'b0;
                            state <= S_INIT;
                        end else begin
                            state <= S_STAGE_SETUP;
                        end
                    end
                end
            end

            S_INIT: begin
                active_buf <= 1'b0;
                if (init_index == 8'd255) begin
                    current_stage <= 3'd0;
                    state <= S_STAGE_SETUP;
                end else begin
                    init_index <= init_index + 8'd1;
                end
            end

            S_STAGE_SETUP: begin
                issue_bfly <= 7'd0;
                prefetch_bfly <= 7'd1;
                segment_output_count <= 16'd0;
                segment_slot_total <= STAGE_SLOTS;
                segment_cycle <= 16'd0;
                segment_out_started <= 1'b0;
                state <= S_STAGE_READ;
            end

            S_STAGE_READ: begin
                req_valid <= 1'b1;
                req_op <= current_op;
                req_index <= issue_bfly[4:0];
                req_addr_a <= map_addr_a;
                req_addr_b <= map_addr_b;
                req_scale <= 1'b0;
                req_a_value <= coeff_active_a;
                req_b_value <= coeff_active_b;
                req_twiddle <= twiddle_for_slot(current_op, current_stage, issue_bfly);
                issue_count <= issue_count + 16'd1;
                bank_check_count <= bank_check_count + 16'd1;
                if (map_conflict || (map_bank_a == map_bank_b) ||
                    (map_addr_b <= map_addr_a)) begin
                    error <= 1'b1;
                end

                if (issue_bfly == 7'd127) begin
                    state <= S_STAGE_DRAIN;
                end else begin
                    issue_bfly <= issue_bfly + 7'd1;
                    prefetch_bfly <= issue_bfly + 7'd2;
                end
            end

            S_STAGE_DRAIN: begin
                if (segment_output_count == STAGE_SLOTS) begin
                    flush_index <= 7'd0;
                    state <= S_STAGE_FLUSH_SETUP;
                end
            end

            S_STAGE_FLUSH_SETUP: begin
                state <= S_STAGE_FLUSH;
            end

            S_STAGE_FLUSH: begin
                if (flush_index == 7'd127) begin
                    active_buf <= !active_buf;
                    if (current_stage == 3'd7) begin
                        state <= current_inverse ? S_SCALE_SETUP : S_DIGEST_INIT;
                    end else begin
                        current_stage <= current_stage + 3'd1;
                        state <= S_STAGE_SETUP;
                    end
                end else begin
                    flush_index <= flush_index + 7'd1;
                end
            end

            S_SCALE_SETUP: begin
                scale_index <= 8'd0;
                segment_output_count <= 16'd0;
                segment_slot_total <= SCALE_SLOTS;
                segment_cycle <= 16'd0;
                segment_out_started <= 1'b0;
                state <= S_SCALE_READ;
            end

            S_SCALE_READ: begin
                req_valid <= 1'b1;
                req_op <= scale_pipe_op;
                req_index <= scale_index[4:0];
                req_addr_a <= scale_index;
                req_addr_b <= scale_index;
                req_scale <= 1'b1;
                req_a_value <= 23'd0;
                req_b_value <= coeff_active_a;
                req_twiddle <= n_inv_value(current_op);
                issue_count <= issue_count + 16'd1;
                if (scale_index == 8'd255) begin
                    state <= S_SCALE_DRAIN;
                end else begin
                    scale_index <= scale_index + 8'd1;
                end
            end

            S_SCALE_DRAIN: begin
                if (segment_output_count == SCALE_SLOTS) begin
                    active_buf <= !active_buf;
                    state <= S_DIGEST_INIT;
                end
            end

            S_DIGEST_INIT: begin
                digest_acc <= 32'h4e545432;
                digest_index <= 8'd0;
                digest_active_index <= 8'd0;
                digest_coeff_reg <= 23'd0;
                state <= S_DIGEST_READ;
            end

            S_DIGEST_READ: begin
                digest_coeff_reg <= coeff_active_a;
                digest_active_index <= digest_index;
                state <= S_DIGEST_RUN;
            end

            S_DIGEST_RUN: begin
                digest_acc <= digest_next;
                if (digest_active_index == 8'd255) begin
                    digest <= digest_next;
                    signature <= rotl5(signature) ^ digest_next ^
                        {16'd0, issue_count} ^ {16'd0, output_count} ^
                        {16'd0, bank_check_count};
                    done <= 1'b1;
                    busy <= 1'b0;
                    pass <= !error &&
                        (bubble_count == 16'd0) &&
                        (issue_count == expected_issue_slots(current_op)) &&
                        (output_count == expected_issue_slots(current_op)) &&
                        ((pipe_accepted_count - pipe_accepted_base) ==
                         expected_issue_slots(current_op)) &&
                        (!current_check_expected ||
                         (digest_next == expected_digest(current_op)));
                    if ((current_check_expected &&
                         (digest_next != expected_digest(current_op))) ||
                        (bubble_count != 16'd0) ||
                        (issue_count != expected_issue_slots(current_op)) ||
                        (output_count != expected_issue_slots(current_op)) ||
                        ((pipe_accepted_count - pipe_accepted_base) !=
                         expected_issue_slots(current_op))) begin
                        error <= 1'b1;
                    end
                    state <= S_IDLE;
                end else begin
                    digest_index <= digest_active_index + 8'd1;
                    state <= S_DIGEST_READ;
                end
            end

            default: begin
                error <= 1'b1;
                done <= 1'b1;
                pass <= 1'b0;
                busy <= 1'b0;
                state <= S_IDLE;
            end
        endcase
    end
end

endmodule

