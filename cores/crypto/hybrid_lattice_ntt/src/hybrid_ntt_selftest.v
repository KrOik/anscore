module hybrid_ntt_selftest (
    input  wire        clk,
    input  wire        rst_n,
    output reg         test_done,
    output reg         test_pass,
    output reg         test_fail,
    output reg  [2:0]  case_index,
    output reg  [31:0] cycle_count,
    output reg  [31:0] digest
);

localparam integer CASE_COUNT = 5;

localparam [2:0] S_START = 3'd0;
localparam [2:0] S_WAIT  = 3'd1;
localparam [2:0] S_CHECK = 3'd2;
localparam [2:0] S_NEXT  = 3'd3;
localparam [2:0] S_DONE  = 3'd4;

reg [2:0] state;
reg start;
reg mode_dsa;
reg [22:0] a;
reg [22:0] b;
reg [22:0] twiddle;
wire [22:0] y0;
wire [22:0] y1;
wire busy;
wire done;

fused_butterfly butterfly (
    .clk(clk),
    .rst_n(rst_n),
    .start(start),
    .mode_dsa(mode_dsa),
    .inverse_mode(1'b0),
    .a(a),
    .b(b),
    .twiddle(twiddle),
    .y0(y0),
    .y1(y1),
    .busy(busy),
    .done(done)
);

function case_mode_dsa;
    input [2:0] index;
    begin
        case (index)
            3'd0: case_mode_dsa = 1'b0;
            3'd1: case_mode_dsa = 1'b1;
            3'd2: case_mode_dsa = 1'b0;
            3'd3: case_mode_dsa = 1'b1;
            default: case_mode_dsa = 1'b1;
        endcase
    end
endfunction

function [22:0] case_a;
    input [2:0] index;
    begin
        case (index)
            3'd0: case_a = 23'd1234;
            3'd1: case_a = 23'd1234567;
            3'd2: case_a = 23'd3328;
            3'd3: case_a = 23'd8380416;
            default: case_a = 23'd42;
        endcase
    end
endfunction

function [22:0] case_b;
    input [2:0] index;
    begin
        case (index)
            3'd0: case_b = 23'd2020;
            3'd1: case_b = 23'd7654321;
            3'd2: case_b = 23'd3328;
            3'd3: case_b = 23'd8380415;
            default: case_b = 23'd8380000;
        endcase
    end
endfunction

function [22:0] case_twiddle;
    input [2:0] index;
    begin
        case (index)
            3'd0: case_twiddle = 23'd17;
            3'd1: case_twiddle = 23'd1753;
            3'd2: case_twiddle = 23'd3328;
            3'd3: case_twiddle = 23'd8380414;
            default: case_twiddle = 23'd123456;
        endcase
    end
endfunction

function [22:0] expect_y0;
    input [2:0] index;
    begin
        case (index)
            3'd0: expect_y0 = 23'd2284;
            3'd1: expect_y0 = 23'd2211663;
            3'd2: expect_y0 = 23'd0;
            3'd3: expect_y0 = 23'd5;
            default: expect_y0 = 23'd7181809;
        endcase
    end
endfunction

function [22:0] expect_y1;
    input [2:0] index;
    begin
        case (index)
            3'd0: expect_y1 = 23'd184;
            3'd1: expect_y1 = 23'd257471;
            3'd2: expect_y1 = 23'd3327;
            3'd3: expect_y1 = 23'd8380410;
            default: expect_y1 = 23'd1198692;
        endcase
    end
endfunction

always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        state <= S_START;
        start <= 1'b0;
        mode_dsa <= 1'b0;
        a <= 23'd0;
        b <= 23'd0;
        twiddle <= 23'd0;
        test_done <= 1'b0;
        test_pass <= 1'b0;
        test_fail <= 1'b0;
        case_index <= 3'd0;
        cycle_count <= 32'd0;
        digest <= 32'h484e5454;
    end else begin
        start <= 1'b0;

        if (!test_done) begin
            cycle_count <= cycle_count + 32'd1;
        end

        case (state)
            S_START: begin
                mode_dsa <= case_mode_dsa(case_index);
                a <= case_a(case_index);
                b <= case_b(case_index);
                twiddle <= case_twiddle(case_index);
                start <= 1'b1;
                state <= S_WAIT;
            end

            S_WAIT: begin
                if (done) begin
                    state <= S_CHECK;
                end
            end

            S_CHECK: begin
                digest <= {digest[30:0], digest[31]} ^ {9'd0, y0} ^ {y1, 9'd0} ^ {29'd0, case_index};
                if ((y0 != expect_y0(case_index)) || (y1 != expect_y1(case_index))) begin
                    test_fail <= 1'b1;
                end
                state <= S_NEXT;
            end

            S_NEXT: begin
                if (case_index == CASE_COUNT - 1) begin
                    test_done <= 1'b1;
                    test_pass <= !test_fail;
                    state <= S_DONE;
                end else begin
                    case_index <= case_index + 3'd1;
                    state <= S_START;
                end
            end

            S_DONE: begin
                test_done <= 1'b1;
                test_pass <= !test_fail;
            end

            default: state <= S_START;
        endcase
    end
end

endmodule
