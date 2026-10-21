"""Small public-wrapper board fixtures backed by existing independent oracles.
No programming occurs here. A fixture is not a board PASS until frozen, simulated,
synthesized, routed, programmed and checked by the acceptance workflow.
"""
from pathlib import Path
import math
import random
import sys

HERE=Path(__file__).resolve().parent
COMMON=HERE.parents[2]
SV=COMMON/'signal_video'
if str(SV) not in sys.path:sys.path.insert(0,str(SV))
CASE_NAMES=['clahe','he','histogram','rotate','mirror','downsample','upsample','scaler_bicubic']
IDS={'clahe':b'CLAH','he':b'HEQU','histogram':b'HIST','rotate':b'ROTA','mirror':b'MIRR','downsample':b'DOWN','upsample':b'UPSM','scaler_bicubic':b'BICU'}

def describe(name):
    if name not in CASE_NAMES:raise KeyError(name)
    module='cip_image_'+('scaler' if name=='scaler_bicubic' else 'mirror_flip' if name=='mirror' else name)
    sources=[SV/'rtl'/f'{module}.v']
    parameters={'MAX_WIDTH':8,'MAX_HEIGHT':6}
    data_w=8 if name in ('clahe','he') else 32 if name=='histogram' else 24
    geo=COMMON/'image/geometry/rtl'
    if name=='clahe':
        sources += [SV/'rtl/cip_image_clahe_frame.v']
        sources += [COMMON/'image/histogram/rtl'/n for n in ['img_hist_ratio_u8.v','img_hist_clahe_interp.v','img_hist_serial_multiply.v']]
    elif name in ('he','histogram'):
        sources += [SV/'rtl/cip_image_histogram_frame.v',COMMON/'image/histogram/rtl/img_hist_ratio_u8.v']
    elif name=='mirror':sources += [SV/'rtl/cip_image_permute_frame.v']
    elif name in ('rotate','scaler_bicubic'):
        parameters['PIXEL_W']=8
        sources += [SV/'rtl/cip_image_rotate_angle_frame.v',SV/'rtl/cip_image_permute_frame.v'] if name=='rotate' else [SV/'rtl/cip_image_bicubic_frame.v']
        sources += sorted(geo.glob('*.v'))
    elif name=='downsample':
        parameters['PIXEL_W']=8
        sources += [geo/'img_geo_area_resample.v',geo/'img_geo_crop_decimate.v']
    elif name=='upsample':sources += [geo/'img_geo_integer_upsample.v']
    return dict(module=module,data_w=data_w,parameters=parameters,sources=[p.resolve() for p in sources],case_id=int.from_bytes(IDS[name],'big'),simulation_timeout_cycles=2000000)


def make_vectors(name):
    """Return (384-bit commands,34-bit inputs,34-bit expected,aux,coeff)."""
    describe(name)
    rng=random.Random(55171)
    commands=[];inputs=[];outputs=[];aux=[];coeff=[]
    def markers(values,w):return [v|(int(i==0)<<33)|(int(i%w==w-1)<<32) for i,v in enumerate(values)]
    def add(mode,w,h,dw,dh,p0=0,p1=0,image=None,result=None,error=0,framing=0):
        image=[] if image is None else list(image)
        result=[] if result is None else list(result)
        source=markers(image,w) if image else []
        if framing and source:source[-1]^=1<<32
        fields=[(mode,0),((0x30+len(commands))&255,4),(w,12),(h,28),(dw,44),(dh,60),(p0&0xffffffff,76),(p1&0xffffffff,108),(len(source),236),(len(result),252),(0,268),(0,284),(error,300),(len(inputs),302),(len(outputs),318),(len(aux),334),(len(coeff),350)]
        commands.append(sum(v<<shift for v,shift in fields))
        inputs.extend(source);outputs.extend(markers(result,dw) if result else [])
    def rgb(w,h):return [rng.randrange(1<<24) for _ in range(w*h)]
    if name=='clahe':
        from run_clahe_tests import clahe
        # Original equal tiles plus odd/nonuniform final tiles and unit tile.
        for w,h,tw,th,clip in [(4,4,2,2,1),(7,5,3,3,1),(8,6,3,4,2),(1,1,1,1,1)]:
            im=[rng.randrange(256) for _ in range(w*h)]
            add(0,w,h,w,h,clip,(th<<16)|tw,im,clahe(im,w,h,tw,th,clip))
        add(1,2,2,2,2,error=1)
        add(0,2,2,2,2,1,(2<<16),error=2)
        add(0,2,2,2,2,1,(2<<16)|2,[0,50,100,255],error=2,framing=1)
    elif name in ('he','histogram'):
        from run_histogram_frame_tests import equalize
        for w,h,im in [(4,3,[0,0,15,15,40,70,90,120,150,200,255,255]),(1,1,[137]),(5,4,[91]*19+[92])]:
            counts,equalized=equalize(im)
            out=counts if name=='histogram' else equalized
            dw,dh=(256,1) if name=='histogram' else (w,h)
            add(0,w,h,dw,dh,image=im,result=out)
        dw,dh=(256,1) if name=='histogram' else (2,2)
        add(1,2,2,dw,dh,error=1)
        add(0,0,2,dw,dh,error=2)
        add(0,2,2,dw,dh,image=[0,30,90,255],error=2,framing=1)
    elif name in ('rotate','mirror'):
        from run_permutation_tests import reference
        for mode in range(4):
            im=rgb(4,3);out,dw,dh=reference(im,4,3,mode,name=='rotate')
            add(mode,4,3,dw,dh,image=im,result=out)
        if name=='rotate':
            from run_rotate_angle_tests import reference as angle_reference
            for mode,angle in [(4,30),(5,-45),(5,73)]:
                im=rgb(5,4);c=round(math.cos(math.radians(angle))*65536);s=round(math.sin(math.radians(angle))*65536)
                out=[v&0xffffffff for v in angle_reference(im,5,4,6,5,mode-4,8,3,c,s)]
                add(mode,5,4,6,5,c,s,im,out)
        add(6 if name=='rotate' else 4,2,2,2,2,error=1)
        add(0,2,2,3,2,error=2)
    elif name=='downsample':
        from run_downsample_tests import reference
        for w,h,dw,dh,mode,sx,sy in [(5,4,3,2,0,0,0),(7,5,2,3,0,0,0),(5,4,3,2,1,2,2),(1,5,1,2,1,3,3)]:
            im=rgb(w,h);out=reference(im,w,h,dw,dh,8,3,mode,sx,sy)
            add(mode,w,h,dw,dh,sx,sy,im,out)
        add(2,2,2,1,1,error=1)
        add(0,2,2,3,2,error=2)
    elif name=='upsample':
        from run_upsample_tests import reference
        for w,h,scale in [(2,2,2),(3,2,3),(1,1,2),(1,3,2)]:
            im=rgb(w,h);out=[v&0xffffffff for v in reference(im,w,h,scale,24)]
            add(0,w,h,w*scale,h*scale,scale,0,im,out)
        add(1,2,2,4,4,2,error=1)
        add(0,2,2,4,4,0,error=2)
    else:
        from run_bicubic_tests import reference
        # Genuine negative-lobe bicubic, interleaved with preserved filters.
        for w,h,dw,dh in [(4,3,7,5),(5,4,3,2),(1,4,3,6)]:
            im=rgb(w,h)
            for mode in (2,0,1):
                out=[v&0xffffffff for v in reference(im,w,h,dw,dh,8,3,mode)]
                add(mode,w,h,dw,dh,image=im,result=out)
        add(3,2,2,2,2,error=1)
        add(2,0,2,2,2,error=2)
    for command in commands:
        if command>=1<<384:raise ValueError('command overflow')
    if any(len(v)>65535 for v in (commands,inputs,outputs,aux,coeff)):raise ValueError('ROM index overflow')
    return commands,inputs,outputs,aux,coeff
