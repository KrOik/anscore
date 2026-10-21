from pathlib import Path
HERE=Path(__file__).resolve().parent
source=(HERE/'bilateral_harness_v2/source/img_filter_bilateral3x3.v').read_text()
source=source.replace('CFG_HIGH=16;', 'CFG_HIGH=16,WEIGHT_CAPTURE=17;')
source=source.replace('wire [15:0] weight;', 'wire [15:0] weight;\n    reg [15:0] weight_q;')
source=source.replace('weighted_sample=sample_q*weight;', 'weighted_sample=sample_q*weight_q;')
source=source.replace('distance_q<=0;product_q<=0;', 'distance_q<=0;product_q<=0;weight_q<=0;')
source=source.replace('state<=WEIGHT_PRODUCT;end', 'state<=WEIGHT_CAPTURE;end')
source=source.replace('                WEIGHT_PRODUCT:begin', '                WEIGHT_CAPTURE:begin weight_q<=weight;state<=WEIGHT_PRODUCT;end\n                WEIGHT_PRODUCT:begin')
source=source.replace('denominator<=denominator+weight;', 'denominator<=denominator+weight_q;')
(HERE/'img_filter_bilateral3x3.v').write_text(source)
