from pathlib import Path
HERE=Path(__file__).resolve().parent
source=(HERE/'bilateral_product_v5/source/img_filter_bilateral3x3.v').read_text()
source=source.replace('PRODUCT_WAIT=18;', 'PRODUCT_WAIT=18,ADD_FOLD=19;')
source=source.replace('    reg [4:0] state;', '''    localparam PAD_W=((NUM_W+7)/8)*8,ADD_BYTES=PAD_W/8;
    reg [PAD_W-1:0] add_a,add_b,den_a,den_b,add_result,den_result;
    reg add_carry,den_carry,normalizing;
    reg [$clog2(ADD_BYTES+1)-1:0] add_count;
    wire [8:0] byte_sum={1'b0,add_a[7:0]}+{1'b0,add_b[7:0]}+add_carry;
    wire [8:0] den_sum={1'b0,den_a[7:0]}+{1'b0,den_b[7:0]}+den_carry;
    wire [PAD_W-1:0] add_next={byte_sum[7:0],add_result[PAD_W-1:8]};
    wire [PAD_W-1:0] den_next={den_sum[7:0],den_result[PAD_W-1:8]};
    reg [4:0] state;''')
source=source.replace('state<=IDLE;configured<=0;', 'add_a<=0;add_b<=0;den_a<=0;den_b<=0;add_result<=0;den_result<=0;add_carry<=0;den_carry<=0;normalizing<=0;add_count<=0;\n            state<=IDLE;configured<=0;',1)
begin=source.index('                ACCUM:begin')
end=source.index('                NM_START:',begin)
source=source[:begin]+'''                ACCUM:begin
                    add_a<=numerator;add_b<=product_q;den_a<=denominator;den_b<=weight_q;
                    add_result<=0;den_result<=0;add_carry<=0;den_carry<=0;
                    normalizing<=0;add_count<=ADD_BYTES;state<=ADD_FOLD;
                end
                NM_PREP:begin
                    add_a<=numerator;add_b<=denominator>>1;den_a<=0;den_b<=0;
                    add_result<=0;den_result<=0;add_carry<=0;den_carry<=0;
                    normalizing<=1;add_count<=ADD_BYTES;state<=ADD_FOLD;
                end
                ADD_FOLD:begin
                    add_a<=add_a>>8;add_b<=add_b>>8;den_a<=den_a>>8;den_b<=den_b>>8;
                    add_result<=add_next;den_result<=den_next;
                    add_carry<=byte_sum[8];den_carry<=den_sum[8];add_count<=add_count-1'b1;
                    if(add_count==1)begin
                        if(normalizing)begin
                            // Preserve the original modulo-NUM_W round before divide.
                            dividend<=add_next[NUM_W-1:0];divisor<={12'd0,denominator};
                            output_sof<=saved_sof;output_eol<=saved_eol;
                            if(denominator==0)begin result<=0;output_valid<=1;state<=OUTPUT_HOLD;end
                            else state<=NM_START;
                        end else begin
                            numerator<=add_next[NUM_W-1:0];denominator<=den_next[19:0];
                            if(tap==8)state<=NM_PREP;
                            else begin tap<=tap+1'b1;state<=SAMPLE_REG;end
                        end
                    end
                end
'''+source[end:]
target=HERE/'bilateral_accumulate_source'
target.mkdir(exist_ok=True)
(target/'img_filter_bilateral3x3.v').write_text(source)
