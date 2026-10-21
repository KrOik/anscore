from pathlib import Path
HERE=Path(__file__).resolve().parent
source=(HERE/'framebuffer_v5/source/cip_image_framebuffer.v').read_text()
source=source.replace('IDLE=0,CAPTURE=1,WRITE_REQ=2,WRITE_WAIT=3,READ_REQ=4,READ_WAIT=5,SEND=6,RESPONSE=7,CALC_SPAN=8,CALC_LAST=9,CHECK_LAST=10;',
 'IDLE=11\'h001,CAPTURE=11\'h002,WRITE_REQ=11\'h004,WRITE_WAIT=11\'h008,READ_REQ=11\'h010,READ_WAIT=11\'h020,SEND=11\'h040,RESPONSE=11\'h080,CALC_SPAN=11\'h100,CALC_LAST=11\'h200,CHECK_LAST=11\'h400;')
source=source.replace('reg [3:0] state;', 'reg [10:0] state;')
(HERE/'cip_image_framebuffer_onehot.v').write_text(source)
# stage_harness requires replacement basename to match the frozen source.
target=HERE/'framebuffer_onehot_source'
target.mkdir(exist_ok=True)
(target/'cip_image_framebuffer.v').write_text(source)
