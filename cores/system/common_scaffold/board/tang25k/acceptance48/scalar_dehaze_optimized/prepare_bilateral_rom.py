from pathlib import Path
import re
HERE=Path(__file__).resolve().parent
COMMON=HERE.parents[3]
source=(HERE/'bilateral_accumulate_v6/source/img_filter_bilateral3x3.v').read_text()
values=re.findall(r"8'd(\d+):weight=16'd(\d+);",(COMMON/'image/filters/rtl/img_filter_exp_weight.v').read_text())
assert [int(i) for i,_ in values]==list(range(256))
rom='    (* ram_style="block",syn_ramstyle="block_ram" *) reg [15:0] weight_rom[0:255];\n    initial begin\n'
rom+=''.join(f"        weight_rom[{i}]=16'd{value};\n" for i,value in values)
rom+='    end\n    always @(posedge clk)if(clk_en && state==WEIGHT_CAPTURE)weight_q<=weight_rom[weight_index];\n'
source=source.replace('    img_filter_exp_weight exp_lut(.index(weight_index),.weight(weight));',rom)
source=source.replace('weight_q<=0;','')
source=source.replace('WEIGHT_CAPTURE:begin weight_q<=weight;state<=WEIGHT_PRODUCT;end','WEIGHT_CAPTURE:begin state<=WEIGHT_PRODUCT;end')
target=HERE/'bilateral_rom_source'
target.mkdir(exist_ok=True)
(target/'img_filter_bilateral3x3.v').write_text(source)
