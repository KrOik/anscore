from pathlib import Path
HERE=Path(__file__).resolve().parent
source=(HERE/'bilateral_weight_v3/source/img_filter_bilateral3x3.v').read_text()
source=source.replace("wire [DIV_W:0] index_sum={1'b0,spatial_index}+{1'b0,quotient};", "wire [8:0] index_sum={1'b0,spatial_index[7:0]}+{1'b0,quotient[7:0]};\n    wire index_high=(|spatial_index[DIV_W-1:8]) || (|quotient[DIV_W-1:8]);")
source=source.replace('(index_sum>255)?255:', '(index_high || index_sum[8])?255:')
begin=source.index("    wire [16:0] low_sub=")
end=source.index('    wire take_subtract',begin)
source=source[:begin]+'''    // Exact unsigned17-bit subtraction with independent byte comparisons.
    function [17:0] subtract17;
        input [16:0] a,b;
        input borrow_in;
        reg borrow8,borrow16,borrow17;
        begin
            borrow8=(a[7:0]<b[7:0]) || ((a[7:0]==b[7:0]) && borrow_in);
            borrow16=(a[15:8]<b[15:8]) || ((a[15:8]==b[15:8]) && borrow8);
            borrow17=(a[16]<b[16]) || ((a[16]==b[16]) && borrow16);
            subtract17[7:0]=a[7:0]-b[7:0]-borrow_in;
            subtract17[15:8]=a[15:8]-b[15:8]-borrow8;
            subtract17[16]=a[16]^b[16]^borrow16;
            subtract17[17]=borrow17;
        end
    endfunction
    wire [17:0] low_wide=subtract17({1'b0,trial[15:0]},{1'b0,divisor_q[15:0]},1'b0);
    wire [16:0] low_sub={low_wide[17],low_wide[15:0]};
    wire [17:0] high_sub=subtract17(trial_q[32:16],{1'b0,divisor_q[31:16]},low_borrow);
'''+source[end:]
target=HERE/'bilateral_borrow_source'
target.mkdir(exist_ok=True)
(target/'img_filter_bilateral3x3.v').write_text(source)
