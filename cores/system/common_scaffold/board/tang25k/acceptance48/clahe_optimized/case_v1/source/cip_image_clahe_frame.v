// Runtime-size CLAHE helper derived from img_hist_frame_engine.
// Bounded synchronous RAM, exact strict redistribution and center interpolation.
// Development implementation: resource/timing/board qualification is pending.
// Every memory read is registered; reset invalidates control, not RAM contents.
// One frame is captured, processed, and replayed internally before another start.
//
// Per-tile strict clipping, iterative unit redistribution, direct-CDF
// LUTs, tile-center bilinear interpolation, and nearest-tile border extension.
module cip_image_clahe_frame #(
    parameter integer MAX_WIDTH=64, MAX_HEIGHT=64,
    parameter integer COUNT_WIDTH=24, FRACTION_BITS=8, TAG_WIDTH=8
) (
    input wire clk,
    input wire rst_n,
    input wire clk_en,
    input wire [15:0] cfg_width,cfg_height,cfg_tile_width,cfg_tile_height,
    input wire start_valid,
    output wire start_ready,
    input wire [TAG_WIDTH-1:0] start_tag,
    input wire [COUNT_WIDTH-1:0] start_clip_limit,
    input wire s_valid,
    output wire s_ready,
    input wire [7:0] s_gray,
    input wire s_sof,
    input wire s_eol,
    output wire m_valid,
    input wire m_ready,
    output wire [7:0] m_gray,
    output wire m_sof,
    output wire m_eol,
    output wire m_last,
    output wire [TAG_WIDTH-1:0] m_tag,
    output wire m_error,
    output reg done_valid,
    input wire done_ready,
    output reg done_error,
    output reg [7:0] done_error_code,
    output reg [COUNT_WIDTH-1:0] done_count,
    output reg [TAG_WIDTH-1:0] done_tag,
    output wire busy
);
    localparam ADAPTIVE=1;
    localparam FRAME_DEPTH=MAX_WIDTH*MAX_HEIGHT;
    localparam MAX_TILES=(MAX_WIDTH*MAX_HEIGHT<256)?MAX_WIDTH*MAX_HEIGHT:256;
    localparam LUT_DEPTH=256*MAX_TILES;
    localparam FRAME_INDEX_W=32,FRAME_X_W=16,FRAME_Y_W=16,TILE_INDEX_W=9,TILE_X_W=9,TILE_Y_W=9,LOCAL_X_W=16,LOCAL_Y_W=16;
    localparam UNIT=1<<FRACTION_BITS;
    reg [15:0] FRAME_WIDTH,FRAME_HEIGHT,SAFE_EW,SAFE_EH;
localparam GRID_X_W=($clog2(MAX_WIDTH+1)>0)?$clog2(MAX_WIDTH+1):1;
function [8:0] grid_x;input [15:0] dimension,tile;integer divisor;reg [GRID_X_W:0] numerator;
begin numerator={1'b0,dimension[GRID_X_W-1:0]}+{1'b0,tile[GRID_X_W-1:0]}-1'b1;grid_x=0;
for(divisor=1;divisor<=MAX_WIDTH;divisor=divisor+1)if(tile==divisor)grid_x=numerator/divisor;
end endfunction
localparam GRID_Y_W=($clog2(MAX_HEIGHT+1)>0)?$clog2(MAX_HEIGHT+1):1;
function [8:0] grid_y;input [15:0] dimension,tile;integer divisor;reg [GRID_Y_W:0] numerator;
begin numerator={1'b0,dimension[GRID_Y_W-1:0]}+{1'b0,tile[GRID_Y_W-1:0]}-1'b1;grid_y=0;
for(divisor=1;divisor<=MAX_HEIGHT;divisor=divisor+1)if(tile==divisor)grid_y=numerator/divisor;
end endfunction
    wire [8:0] NX=grid_x(FRAME_WIDTH,SAFE_EW), NY=grid_y(FRAME_HEIGHT,SAFE_EH);
    wire [31:0] NT=NX*NY;
    wire [31:0] ACTIVE_DEPTH=FRAME_WIDTH*FRAME_HEIGHT;
    wire PARAM_OK=cfg_width>0 && cfg_height>0 && cfg_width<=MAX_WIDTH && cfg_height<=MAX_HEIGHT &&
        cfg_tile_width>=1 && cfg_tile_height>=1 && cfg_tile_width<=cfg_width && cfg_tile_height<=cfg_height &&
        (grid_x(cfg_width,cfg_tile_width)*grid_y(cfg_height,cfg_tile_height))<=256;

    localparam [5:0] IDLE = 0, CAPTURE = 1, CLEAR_HIST = 2,
        TILE_FRAME_READ = 3, TILE_HIST_READ = 4, TILE_HIST_WRITE = 5,
        CLIP_READ = 6, CLIP_WRITE = 7, REDIST_READ = 8, REDIST_WRITE = 9,
        CDF_READ = 10, CDF_CALC = 11, DIV_REQUEST = 12, DIV_RESPONSE = 13,
        LUT_WRITE = 14, OUT_FRAME_READ = 15, OUT_COORD = 16,
        OUT_LUT00_READ = 17, OUT_LUT00_WAIT = 18,
        OUT_LUT10_READ = 19, OUT_LUT10_WAIT = 20,
        OUT_LUT01_READ = 21, OUT_LUT01_WAIT = 22,
        OUT_LUT11_READ = 23, OUT_LUT11_WAIT = 24,
        OUT_INTERP_REQUEST = 25, OUT_INTERP_WAIT = 26;
    localparam [7:0] ERR_PARAM = 8'h01, ERR_FRAME = 8'h02,
        ERR_HIST_OVERFLOW = 8'h04, ERR_REDISTRIBUTION = 8'h08,
        ERR_CDF = 8'h10, ERR_DIV = 8'h20, ERR_INTERPOLATION = 8'h40;

    reg [5:0] state;
    (* ram_style = "block" *) reg [7:0] frame_mem [0:FRAME_DEPTH-1];
    (* ram_style = "block" *) reg [COUNT_WIDTH-1:0] hist_mem [0:255];
    (* ram_style = "block" *) reg [7:0] lut_mem [0:LUT_DEPTH-1];
    reg [7:0] frame_q, lut_q;
    reg [COUNT_WIDTH-1:0] hist_q;
    reg [TAG_WIDTH-1:0] frame_tag;
    reg [COUNT_WIDTH-1:0] clip_limit, capture_count;
    reg [FRAME_INDEX_W-1:0] capture_index;
    reg [FRAME_X_W-1:0] capture_x;
    reg frame_bad;
    reg [TILE_INDEX_W-1:0] tile_index;
    reg [TILE_X_W-1:0] tile_x;
    reg [TILE_Y_W-1:0] tile_y;
    wire [31:0] ACTUAL_EW=(FRAME_WIDTH-tile_x*SAFE_EW)<SAFE_EW ? FRAME_WIDTH-tile_x*SAFE_EW : SAFE_EW;
    wire [31:0] ACTUAL_EH=(FRAME_HEIGHT-tile_y*SAFE_EH)<SAFE_EH ? FRAME_HEIGHT-tile_y*SAFE_EH : SAFE_EH;
    wire [63:0] N_TILE_PIXELS=64'd1*ACTUAL_EW*ACTUAL_EH;
    reg [LOCAL_X_W-1:0] local_x;
    reg [LOCAL_Y_W-1:0] local_y;
    reg [7:0] bin_index, pending_bin, lut_value;
    reg [COUNT_WIDTH:0] excess;
    reg redistribution_progress;
    reg [COUNT_WIDTH-1:0] cdf, cdf_min;
    reg first_nonzero;
    reg [COUNT_WIDTH-1:0] div_numerator, div_denominator;
    reg [FRAME_INDEX_W-1:0] output_index;
    reg [FRAME_X_W-1:0] output_x;
    reg [FRAME_Y_W-1:0] output_y;
    reg [TILE_INDEX_W-1:0] lookup00, lookup10, lookup01, lookup11;
    reg [7:0] current_gray, value00, value10, value01, value11;
    reg [FRACTION_BITS:0] fraction_x, fraction_y;
    reg output_bad;
    // Retain full 32-bit intermediates: integer constant operands widen the
    // coordinate/address expressions before any bounded register assignment.
    integer cx0, cx1, cy0, cy1, computed_fx, computed_fy;

    wire capture_fire = s_valid && s_ready;
    wire input_framing_bad = (s_sof != (capture_index == 0)) ||
                            (s_eol != (capture_x == FRAME_WIDTH-1));
    wire [COUNT_WIDTH-1:0] clipped_value = hist_q > clip_limit ? clip_limit : hist_q;
    wire [COUNT_WIDTH:0] next_excess = excess +
        {1'b0, hist_q} - {1'b0, clipped_value};
    wire can_redistribute = hist_q < clip_limit;
    wire [COUNT_WIDTH:0] next_cdf = {1'b0, cdf} + {1'b0, hist_q};
    wire [COUNT_WIDTH-1:0] next_min = first_nonzero ? cdf_min : hist_q;
    wire [COUNT_WIDTH-1:0] effective_min = ADAPTIVE ?
        {COUNT_WIDTH{1'b0}} : next_min;
    wire [COUNT_WIDTH-1:0] ratio_numerator =
        next_cdf[COUNT_WIDTH-1:0] - effective_min;
    wire [COUNT_WIDTH-1:0] ratio_denominator = N_TILE_PIXELS - effective_min;
    wire div_ready, div_valid, div_error;
    wire [7:0] div_value;
    wire interp_ready, interp_valid, interp_error;
    wire [7:0] interp_gray;
    wire interp_sof, interp_eol;
    wire [TAG_WIDTH-1:0] interp_tag;
    wire output_fire = clk_en && m_valid && m_ready;

    assign start_ready = rst_n && clk_en && state == IDLE && !done_valid;
    assign s_ready = rst_n && clk_en && state == CAPTURE;
    assign busy = state != IDLE;
    assign m_valid = interp_valid && state == OUT_INTERP_WAIT;
    assign m_gray = interp_gray;
    assign m_sof = interp_sof;
    assign m_eol = interp_eol;
    assign m_last = output_index == ACTIVE_DEPTH - 1;
    assign m_tag = interp_tag;
    assign m_error = interp_error;

    img_hist_ratio_u8 #(.COUNT_WIDTH(COUNT_WIDTH)) divide (
        .clk(clk), .rst_n(rst_n), .clk_en(clk_en),
        .s_valid(state == DIV_REQUEST), .s_ready(div_ready),
        .s_numerator(div_numerator), .s_denominator(div_denominator),
        .m_valid(div_valid), .m_ready(state == DIV_RESPONSE),
        .m_value(div_value), .m_error(div_error)
    );
    img_hist_clahe_interp #(.FRACTION_BITS(FRACTION_BITS), .TAG_WIDTH(TAG_WIDTH)) blend (
        .clk(clk), .rst_n(rst_n), .clk_en(clk_en),
        .s_valid(state == OUT_INTERP_REQUEST), .s_ready(interp_ready),
        .s_lut00(value00), .s_lut10(value10),
        .s_lut01(value01), .s_lut11(value11),
        .s_fx(fraction_x), .s_fy(fraction_y),
        .s_sof(output_index == 0), .s_eol(output_x == FRAME_WIDTH-1),
        .s_tag(frame_tag), .m_valid(interp_valid),
        .m_ready(m_ready && state == OUT_INTERP_WAIT),
        .m_gray(interp_gray), .m_sof(interp_sof), .m_eol(interp_eol),
        .m_tag(interp_tag), .m_error(interp_error)
    );

    // Pixel centers use integer coordinates; tile centers are represented in
    // doubled coordinates with the actual final tile size. Outside the first
    // and last centers the nearest tile is extended, avoiding phantom tiles.
    // Explicit sensitivity also schedules the constant HE branch at the
    // output-coordinate reset event. With ADAPTIVE=0, some simulators remove
    // every reference inside @* and would leave the six coordinates X.
    // Find neighboring actual tile centers. Doubled integer coordinates represent
    // both integer and half-integer centers without rounding bias. Only the last
    // interval can differ from the nominal spacing.
    localparam MAX_EXTENT=MAX_WIDTH>MAX_HEIGHT?MAX_WIDTH:MAX_HEIGHT;
    localparam COORD_W=($clog2(2*MAX_EXTENT+1)>0)?$clog2(2*MAX_EXTENT+1):1;
    function [COORD_W-1:0] coordinate_quotient;
        input [COORD_W-1:0] numerator,denominator;integer divisor;
        begin coordinate_quotient=0;
            for(divisor=1;divisor<=2*MAX_EXTENT;divisor=divisor+1)
                if(denominator==divisor)coordinate_quotient=numerator/divisor;
        end
    endfunction
    function [FRACTION_BITS:0] coordinate_fraction;
        input [COORD_W-1:0] offset,span;integer divisor;
        reg [COORD_W+FRACTION_BITS-1:0] numerator;
        begin numerator={offset,{FRACTION_BITS{1'b0}}};coordinate_fraction=0;
            for(divisor=1;divisor<=2*MAX_EXTENT;divisor=divisor+1)
                if(span==divisor)coordinate_fraction=numerator/divisor;
        end
    endfunction
    integer last_center, previous_center, position2;
    always @* begin
        cx0=0;cx1=0;computed_fx=0;cy0=0;cy1=0;computed_fy=0;
        last_center=0;previous_center=0;position2=0;
        if(NX>1)begin
            last_center=(NX-1)*SAFE_EW+FRAME_WIDTH-1;
            previous_center=(2*NX-3)*SAFE_EW-1;
            position2=2*output_x;
            if(position2>=last_center)begin cx0=NX-1;cx1=NX-1;end
            else if(position2>=previous_center)begin
                cx0=NX-2;cx1=NX-1;
                computed_fx=coordinate_fraction(position2-previous_center,last_center-previous_center);
            end else if(position2>SAFE_EW-1)begin
                cx0=coordinate_quotient(position2-(SAFE_EW-1),2*SAFE_EW);cx1=cx0+1;
                computed_fx=coordinate_fraction(position2-((2*cx0+1)*SAFE_EW-1),2*SAFE_EW);
            end
        end
        if(NY>1)begin
            last_center=(NY-1)*SAFE_EH+FRAME_HEIGHT-1;
            previous_center=(2*NY-3)*SAFE_EH-1;
            position2=2*output_y;
            if(position2>=last_center)begin cy0=NY-1;cy1=NY-1;end
            else if(position2>=previous_center)begin
                cy0=NY-2;cy1=NY-1;
                computed_fy=coordinate_fraction(position2-previous_center,last_center-previous_center);
            end else if(position2>SAFE_EH-1)begin
                cy0=coordinate_quotient(position2-(SAFE_EH-1),2*SAFE_EH);cy1=cy0+1;
                computed_fy=coordinate_fraction(position2-((2*cy0+1)*SAFE_EH-1),2*SAFE_EH);
            end
        end
    end

    // Single registered read/write ports are time-multiplexed by the FSM.
    // Histogram read and write occupy different enabled edges, so RAW
    // collisions from equal-valued adjacent source pixels are avoided.
    always @(posedge clk) begin
        if (clk_en) begin
            if (capture_fire)
                frame_mem[capture_index] <= s_gray;
            case (state)
                TILE_FRAME_READ: frame_q <= frame_mem[
                    (tile_y*SAFE_EH+local_y)*FRAME_WIDTH+tile_x*SAFE_EW+local_x];
                OUT_FRAME_READ: frame_q <= frame_mem[output_index];
                CLEAR_HIST: hist_mem[bin_index] <= 0;
                TILE_HIST_READ: hist_q <= hist_mem[frame_q];
                TILE_HIST_WRITE: hist_mem[pending_bin] <=
                    (&hist_q) ? hist_q : hist_q + 1'b1;
                CLIP_READ, REDIST_READ, CDF_READ: hist_q <= hist_mem[bin_index];
                CLIP_WRITE: hist_mem[bin_index] <= clipped_value;
                REDIST_WRITE: begin
                    if (excess != 0 && can_redistribute)
                        hist_mem[bin_index] <= hist_q + 1'b1;
                end
                LUT_WRITE: lut_mem[tile_index*256+bin_index] <= lut_value;
                OUT_LUT00_READ: lut_q <= lut_mem[lookup00*256+current_gray];
                OUT_LUT10_READ: lut_q <= lut_mem[lookup10*256+current_gray];
                OUT_LUT01_READ: lut_q <= lut_mem[lookup01*256+current_gray];
                OUT_LUT11_READ: lut_q <= lut_mem[lookup11*256+current_gray];
                default: begin end
            endcase
        end
    end

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            FRAME_WIDTH<=1;FRAME_HEIGHT<=1;SAFE_EW<=1;SAFE_EH<=1;
            state <= IDLE;
            frame_tag <= 0; clip_limit <= 0; capture_count <= 0;
            capture_index <= 0; capture_x <= 0; frame_bad <= 0;
            tile_index <= 0; tile_x <= 0; tile_y <= 0;
            local_x <= 0; local_y <= 0; bin_index <= 0; pending_bin <= 0;
            lut_value <= 0; excess <= 0; redistribution_progress <= 0;
            cdf <= 0; cdf_min <= 0; first_nonzero <= 0;
            div_numerator <= 0; div_denominator <= 0;
            output_index <= 0; output_x <= 0; output_y <= 0;
            lookup00 <= 0; lookup10 <= 0; lookup01 <= 0; lookup11 <= 0;
            current_gray <= 0; value00 <= 0; value10 <= 0;
            value01 <= 0; value11 <= 0; fraction_x <= 0; fraction_y <= 0;
            output_bad <= 0;
            done_valid <= 0; done_error <= 0; done_error_code <= 0;
            done_count <= 0; done_tag <= 0;
        end else if (clk_en) begin
            if (done_valid && done_ready)
                done_valid <= 0;
            case (state)
                IDLE: begin
                    if (start_valid && start_ready) begin
                        FRAME_WIDTH<=cfg_width;FRAME_HEIGHT<=cfg_height;SAFE_EW<=cfg_tile_width;SAFE_EH<=cfg_tile_height;
                        frame_tag <= start_tag;
                        clip_limit <= start_clip_limit;
                        capture_count <= 0; capture_index <= 0; capture_x <= 0;
                        frame_bad <= 0; output_bad <= 0;
                        tile_index <= 0; tile_x <= 0; tile_y <= 0;
                        local_x <= 0; local_y <= 0; bin_index <= 0;
                        output_index <= 0; output_x <= 0; output_y <= 0;
                        done_error <= 0; done_error_code <= 0;
                        if (!PARAM_OK || (ADAPTIVE &&
                            (start_clip_limit == 0 ||
                             64'd256*start_clip_limit < 64'd1*cfg_tile_width*cfg_tile_height))) begin
                            done_valid <= 1; done_error <= 1;
                            done_error_code <= ERR_PARAM;
                            done_count <= 0; done_tag <= start_tag;
                        end else begin
                            state <= CAPTURE;
                        end
                    end
                end
                CAPTURE: begin
                    if (capture_fire) begin
                        capture_count <= capture_count + 1'b1;
                        capture_x <= capture_x == FRAME_WIDTH-1 ? 0 : capture_x+1;
                        if (input_framing_bad)
                            frame_bad <= 1;
                        if (capture_index == ACTIVE_DEPTH-1) begin
                            if (frame_bad || input_framing_bad) begin
                                done_valid <= 1; done_error <= 1;
                                done_error_code <= ERR_FRAME;
                                done_count <= capture_count+1'b1;
                                done_tag <= frame_tag;
                                state <= IDLE;
                            end else begin
                                bin_index <= 0;
                                state <= CLEAR_HIST;
                            end
                        end else begin
                            capture_index <= capture_index+1;
                        end
                    end
                end
                CLEAR_HIST: begin
                    if (bin_index == 255) begin
                        local_x <= 0; local_y <= 0;
                        state <= TILE_FRAME_READ;
                    end else bin_index <= bin_index+1'b1;
                end
                TILE_FRAME_READ: state <= TILE_HIST_READ;
                TILE_HIST_READ: begin
                    pending_bin <= frame_q;
                    state <= TILE_HIST_WRITE;
                end
                TILE_HIST_WRITE: begin
                    if (&hist_q) begin
                        done_valid <= 1; done_error <= 1;
                        done_error_code <= ERR_HIST_OVERFLOW;
                        done_count <= capture_count; done_tag <= frame_tag;
                        state <= IDLE;
                    end else if (local_x == ACTUAL_EW-1 && local_y == ACTUAL_EH-1) begin
                        bin_index <= 0; cdf <= 0; cdf_min <= 0;
                        first_nonzero <= 0; excess <= 0;
                        redistribution_progress <= 0;
                        state <= ADAPTIVE ? CLIP_READ : CDF_READ;
                    end else begin
                        if (local_x == ACTUAL_EW-1) begin
                            local_x <= 0; local_y <= local_y+1;
                        end else local_x <= local_x+1;
                        state <= TILE_FRAME_READ;
                    end
                end
                CLIP_READ: state <= CLIP_WRITE;
                CLIP_WRITE: begin
                    excess <= next_excess;
                    if (bin_index == 255) begin
                        bin_index <= 0;
                        state <= next_excess == 0 ? CDF_READ : REDIST_READ;
                    end else begin
                        bin_index <= bin_index+1'b1;
                        state <= CLIP_READ;
                    end
                end
                REDIST_READ: state <= REDIST_WRITE;
                REDIST_WRITE: begin
                    if (can_redistribute && excess != 0) begin
                        excess <= excess-1'b1;
                        redistribution_progress <= 1;
                    end
                    if (can_redistribute && excess == 1) begin
                        bin_index <= 0;
                        state <= CDF_READ;
                    end else if (bin_index == 255 &&
                        !redistribution_progress && !can_redistribute) begin
                        done_valid <= 1; done_error <= 1;
                        done_error_code <= ERR_REDISTRIBUTION;
                        done_count <= capture_count; done_tag <= frame_tag;
                        state <= IDLE;
                    end else begin
                        if (bin_index == 255)
                            redistribution_progress <= 0;
                        bin_index <= bin_index+1'b1;
                        state <= REDIST_READ;
                    end
                end
                CDF_READ: state <= CDF_CALC;
                CDF_CALC: begin
                    if (next_cdf > N_TILE_PIXELS ||
                        (bin_index == 255 && next_cdf != N_TILE_PIXELS)) begin
                        done_valid <= 1; done_error <= 1;
                        done_error_code <= ERR_CDF;
                        done_count <= capture_count; done_tag <= frame_tag;
                        state <= IDLE;
                    end else begin
                        cdf <= next_cdf[COUNT_WIDTH-1:0];
                        if (!first_nonzero && hist_q != 0) begin
                            first_nonzero <= 1;
                            cdf_min <= hist_q;
                        end
                        if (effective_min == N_TILE_PIXELS[COUNT_WIDTH-1:0]) begin
                            lut_value <= bin_index;
                            state <= LUT_WRITE;
                        end else if (next_cdf[COUNT_WIDTH-1:0] == effective_min) begin
                            lut_value <= 0;
                            state <= LUT_WRITE;
                        end else if (next_cdf[COUNT_WIDTH-1:0] == N_TILE_PIXELS[COUNT_WIDTH-1:0]) begin
                            lut_value <= 255;
                            state <= LUT_WRITE;
                        end else begin
                            div_numerator <= ratio_numerator;
                            div_denominator <= ratio_denominator;
                            state <= DIV_REQUEST;
                        end
                    end
                end
                DIV_REQUEST: if (div_ready) state <= DIV_RESPONSE;
                DIV_RESPONSE: begin
                    if (div_valid) begin
                        if (div_error) begin
                            done_valid <= 1; done_error <= 1;
                            done_error_code <= ERR_DIV;
                            done_count <= capture_count; done_tag <= frame_tag;
                            state <= IDLE;
                        end else begin
                            lut_value <= div_value;
                            state <= LUT_WRITE;
                        end
                    end
                end
                LUT_WRITE: begin
                    if (bin_index == 255) begin
                        if (tile_index == NT-1) begin
                            state <= OUT_FRAME_READ;
                        end else begin
                            tile_index <= tile_index+1;
                            if (tile_x == NX-1) begin
                                tile_x <= 0; tile_y <= tile_y+1;
                            end else tile_x <= tile_x+1;
                            bin_index <= 0;
                            state <= CLEAR_HIST;
                        end
                    end else begin
                        bin_index <= bin_index+1'b1;
                        state <= CDF_READ;
                    end
                end
                OUT_FRAME_READ: state <= OUT_COORD;
                OUT_COORD: begin
                    current_gray <= frame_q;
                    lookup00 <= cy0*NX+cx0; lookup10 <= cy0*NX+cx1;
                    lookup01 <= cy1*NX+cx0; lookup11 <= cy1*NX+cx1;
                    fraction_x <= computed_fx;
                    fraction_y <= computed_fy;
                    state <= OUT_LUT00_READ;
                end
                OUT_LUT00_READ: state <= OUT_LUT00_WAIT;
                OUT_LUT00_WAIT: begin
                    value00 <= lut_q;
                    if (!ADAPTIVE) begin
                        value10 <= lut_q; value01 <= lut_q; value11 <= lut_q;
                        state <= OUT_INTERP_REQUEST;
                    end else state <= OUT_LUT10_READ;
                end
                OUT_LUT10_READ: state <= OUT_LUT10_WAIT;
                OUT_LUT10_WAIT: begin value10 <= lut_q; state <= OUT_LUT01_READ; end
                OUT_LUT01_READ: state <= OUT_LUT01_WAIT;
                OUT_LUT01_WAIT: begin value01 <= lut_q; state <= OUT_LUT11_READ; end
                OUT_LUT11_READ: state <= OUT_LUT11_WAIT;
                OUT_LUT11_WAIT: begin value11 <= lut_q; state <= OUT_INTERP_REQUEST; end
                OUT_INTERP_REQUEST: if (interp_ready) state <= OUT_INTERP_WAIT;
                OUT_INTERP_WAIT: begin
                    if (output_fire) begin
                        if (interp_error) output_bad <= 1;
                        if (output_index == ACTIVE_DEPTH-1) begin
                            done_valid <= 1;
                            done_error <= output_bad || interp_error;
                            done_error_code <= (output_bad || interp_error) ?
                                                ERR_INTERPOLATION : 8'd0;
                            done_count <= capture_count; done_tag <= frame_tag;
                            state <= IDLE;
                        end else begin
                            output_index <= output_index+1;
                            if (output_x == FRAME_WIDTH-1) begin
                                output_x <= 0; output_y <= output_y+1;
                            end else output_x <= output_x+1;
                            state <= OUT_FRAME_READ;
                        end
                    end
                end
                default: begin
                    done_valid <= 1; done_error <= 1;
                    done_error_code <= ERR_PARAM;
                    done_count <= capture_count; done_tag <= frame_tag;
                    state <= IDLE;
                end
            endcase
        end
    end
endmodule
