from pathlib import Path

HERE = Path(__file__).resolve().parent
source = (HERE / 'awb_harness_v3/source/img_isp_awb_stats.v').read_text()
start = source.index('    // Retained nibble predicates')
end = source.index('    wire stats_slot_free', start)
source = source[:start] + '''    // Exact parallel byte carries: preserve saturation and frame wrap.
    function [31:0] increment_count;
        input [31:0] value;
        begin
            increment_count[7:0]=value[7:0]+8'd1;
            increment_count[15:8]=value[15:8]+(&value[7:0]);
            increment_count[23:16]=value[23:16]+(&value[15:0]);
            increment_count[31:24]=value[31:24]+(&value[23:0]);
        end
    endfunction
    wire [31:0] pixel_increment=increment_count(pixel_count);
    wire [31:0] line_increment=increment_count(line_count);
    wire [31:0] frame_increment=increment_count(frame_id);
    wire pixel_saturated=&pixel_count;
    wire line_saturated=&line_count;
''' + source[end:]
(HERE / 'img_isp_awb_stats.v').write_text(source)
