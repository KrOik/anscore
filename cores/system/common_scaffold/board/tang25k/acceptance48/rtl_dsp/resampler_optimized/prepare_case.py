from pathlib import Path
import sys,re
HERE=Path(__file__).resolve().parent
sys.path.insert(0,str(HERE.parents[1]))
import make_dsp_case as generate
original=generate.dependencies
def dependencies(name):
    return [HERE/'cip_dsp_resampler.v' if p.name=='cip_dsp_resampler.v' else p for p in original(name)]
generate.dependencies=dependencies
original_render=generate.render
def render(name,vectors,corrupt=False):
    text,case_id=original_render(name,vectors,corrupt)
    # CE_DIV=4 leaves three physical clocks for each changed ROM address to
    # settle before the next enabled handshake. Preserve vectors and goldens.
    for signal in ('configuration','input_word','expected_word'):
        pattern=r'reg \[([^]]+)\] '+signal+r';always @\* begin .*?endcase end'
        def register(match):
            block=re.sub(r'\b'+signal+r'\b',signal+'_rom',match.group(0))
            return block+f'\nreg [{match.group(1)}] {signal};always @(posedge clk) {signal}<={signal}_rom;'
        text,count=re.subn(pattern,register,text,flags=re.S)
        if count!=1:raise RuntimeError('missing ROM '+signal)
    return text,case_id
generate.render=render
generate.main()
