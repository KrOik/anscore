"""Actual FAST9 -> NMS -> oriented BRIEF, independent centroid/rotation oracle.

Reuse only the already frozen FAST/NMS transport testbench, replacing its plain
BRIEF instance and assertions. Neither local descriptor oracle is imported.
"""
import hashlib
import math
import random
import tempfile
from pathlib import Path

from tooling import PACKAGE, ROOT, evidence_dir, execute, write_json
from test_fast_brief import TB as TRANSPORT_TB

SOURCES = [PACKAGE / p for p in (
    'image/fast9/img_fast9_frame.sv', 'image/corner_nms/img_corner_nms.v',
    'image/oriented_brief/oriented_brief_frame.sv')]
CIRCLE = ((0,-3),(1,-3),(2,-2),(3,-1),(3,0),(3,1),(2,2),(1,3),
          (0,3),(-1,3),(-2,2),(-3,1),(-3,0),(-3,-1),(-2,-2),(-1,-3))


def oracle(image, w, h, radius, pattern, threshold):
    score = [0] * len(image)
    for y in range(3, h-3):
        for x in range(3, w-3):
            ring = [image[(y+dy)*w+x+dx]-image[y*w+x] for dx,dy in CIRCLE]
            strength = max([0] + [min(ring[(j+k)%16] for k in range(9))
                                    for j in range(16)] +
                           [-max(ring[(j+k)%16] for k in range(9)) for j in range(16)])
            score[y*w+x] = max(0, strength-1)
    result = []
    coefficients = [(round(127*math.cos(a*math.pi/8)),
                     round(127*math.sin(a*math.pi/8))) for a in range(16)]
    def nearest(v):
        return int(math.copysign(math.floor(abs(v)+0.5), v))
    for y in range(1, h-1):
        for x in range(1, w-1):
            i = y*w+x
            if score[i] <= threshold:
                continue
            neighbors = [(y+dy)*w+x+dx for dy in (-1,0,1) for dx in (-1,0,1) if dx or dy]
            if any(score[n] > score[i] or (score[n] == score[i] and n < i) for n in neighbors):
                continue
            invalid = min(x,y) < radius+1 or x+radius+1 >= w or y+radius+1 >= h
            descriptor, angle, oriented = 0, 0, False
            if not invalid:
                mx = my = 0
                for dy in range(-radius,radius+1):
                    for dx in range(-radius,radius+1):
                        if dx*dx+dy*dy <= radius*radius:
                            value = image[(y+dy)*w+x+dx]
                            mx += dx*value
                            my += dy*value
                angle = max(range(16),key=lambda a:mx*coefficients[a][0]+my*coefficients[a][1])
                oriented = bool(mx or my)
                c,s = math.cos(angle*math.pi/8), math.sin(angle*math.pi/8)
                for bit,(ax,ay,bx,by) in enumerate(pattern):
                    xa,ya = nearest(ax*c-ay*s),nearest(ax*s+ay*c)
                    xb,yb = nearest(bx*c-by*s),nearest(bx*s+by*c)
                    descriptor |= int(image[(y+ya)*w+x+xa] < image[(y+yb)*w+x+xb]) << bit
            meta = (i << 32) | (x << 16) | y
            result.append((descriptor, angle, int(oriented), int(invalid), meta))
    return result


def profile(bits, radius, folder):
    w,h = (19,17) if radius == 3 else (39,37)
    rng = random.Random(0x4f5242 + bits + radius)
    maximum = (1 << bits)-1
    rom = PACKAGE/f'image/oriented_brief/pattern_r{radius}.mem'
    words = [int(v,16) for v in rom.read_text(encoding='ascii').split()]
    def signed6(n):
        return n-64 if n & 32 else n
    pattern = [tuple(signed6((v >> shift) & 63) for shift in (18,12,6,0)) for v in words[:256]]
    images = [[0]*(w*h), [maximum]*(w*h)]
    images += [[rng.randrange(maximum+1) for _ in range(w*h)] for _ in range(4)]
    # Isolated FAST corner with a surrounding directional field exercises valid
    # descriptors even for the default 31-pixel centroid patch.
    field = [int(maximum*(x+y)/(w+h-2)) for y in range(h) for x in range(w)]
    cx,cy = w//2,h//2
    field[cy*w+cx] = 0
    for dx,dy in CIRCLE:
        field[(cy+dy)*w+cx+dx] = maximum
    images.append(field)
    expected = [oracle(im,w,h,radius,pattern,maximum//16) for im in images]
    rows = [row for frame in expected for row in frame]
    assert not expected[0] and not expected[1]
    assert any(not row[3] for row in rows) and any(row[3] for row in rows)
    with tempfile.TemporaryDirectory(prefix='fast_oriented_') as tmp:
        td = Path(tmp)
        def mem(name, values):
            (td/name).write_text(''.join(f'{v:x}\n' for v in values),encoding='ascii')
        mem('pixels.hex',[p for im in images for p in im])
        mem('counts.hex',[len(frame) for frame in expected])
        mem('descriptors.hex',[(d << 54) | (a << 50) | (o << 49) | (bad << 48) | meta
                               for d,a,o,bad,meta in rows])
        tb = TRANSPORT_TB
        tb = tb.replace('cycles>1000000', 'cycles>10000000')
        tb = tb.replace('$fatal(1,"timeout")',
                        '$fatal(1,"timeout f=%0d received=%0d target=%0d fast=%0d nms=%0d brief=%0d x=%0d y=%0d",f,received,target,fast.state,nms.state,brief.state,xpos,ypos)')
        a = tb.index('brief_descriptor #(')
        b = tb.index('reg[B-1:0] pixels',a)
        tb = tb[:a] + '''wire[3:0] angle;wire orientation_valid;
oriented_brief_frame #(.BITS(B),.WIDTH(W),.HEIGHT(H),.RADIUS(R),.PATTERN_FILE("@ROM@")) brief(
 .clk(clk),.rst_n(rst_n),.ce(ce),
 .s_pixel(pixel),.s_valid(sv&&fr),.s_sof(sof),.s_eol(eol),.s_ready(br),
 .kp_valid(nv&&nc),.kp_ready(kr),.kp_x(kx),.kp_y(ky),.kp_id(kid),
 .release_valid(ack),.release_ready(rr),.frame_available(loaded),
 .m_descriptor(descriptor),.m_angle(angle),.m_orientation_valid(orientation_valid),
 .m_invalid(invalid),.m_valid(mv),.m_x(mx),.m_y(my),.m_id(mid),.m_ready(mr),.error_code(berror));
''' + tb[b:]
        tb = tb.replace('reg[D-1:0] expected','reg[309:0] expected')
        tb = tb.replace('reg[D+48:0] hold_payload','reg[309:0] hold_payload')
        tb = tb.replace('{descriptor,invalid,mid,mx,my}',
                        '{descriptor,angle,orientation_valid,invalid,mid,mx,my}')
        tb = tb.replace('invalid||descriptor!==expected[received]||{mid,mx,my}!==metadata[received]',
                        '{descriptor,angle,orientation_valid,invalid,mid,mx,my}!==expected[received]')
        tb = tb.replace('$readmemh("pattern.hex",patterns);','')
        tb = tb.replace('$readmemh("metadata.hex",metadata);','')
        a = tb.index(' for(i=0;i<D;i=i+1)begin pv=1;')
        b = tb.index(' ncfg=1;',a)
        tb = tb[:a] + tb[b:]
        for key,value in dict(BITS=bits,DESC=256,WIDTH=w,HEIGHT=h,RADIUS=radius,
                              FRAMES=len(images),OUTPUTS=len(rows),THRESHOLD=maximum//16,
                              ROM=rom.as_posix()).items():
            tb = tb.replace('@'+key+'@',str(value))
        (td/'tb.sv').write_text(tb,encoding='utf-8')
        label = f'b{bits}_r{radius}'
        execute(['iverilog','-g2012','-s','tb','-o',td/'sim',*SOURCES,td/'tb.sv'],
                td,folder/f'{label}_compile.log')
        out = execute(['vvp',td/'sim'],td,folder/f'{label}_simulation.log',timeout=240)
        assert 'FAST_NMS_BRIEF PASS' in out,out
    return dict(bits=bits,radius=radius,frames=len(images),descriptors=len(rows),
                valid_descriptors=sum(not r[3] for r in rows),
                observed_angles=sorted(set(r[1] for r in rows if not r[3])),status='PASS')


if __name__ == '__main__':
    folder = evidence_dir('fast_oriented_brief')
    results = [profile(bits,r,folder) for bits,r in ((8,3),(12,15))]
    write_json(folder/'results.json',dict(status='PASS',results=results,board_tested=False,
        rtl_sha256={str(p.relative_to(ROOT)):hashlib.sha256(p.read_bytes()).hexdigest() for p in SOURCES}))
    print(folder,flush=True)
