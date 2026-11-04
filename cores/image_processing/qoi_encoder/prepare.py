"""Prepare the authorized finite B25 fixtures/plan only; never invoke HDL tools."""
from collections import Counter
import hashlib
import json
from pathlib import Path
import random
import sys

sys.dont_write_bytecode = True
from oracle import INITIAL, certify, digest, hand_anchors

HERE = Path(__file__).resolve().parent
REPO = HERE.parents[2]
BASELINE = 'd35d71be3bfc76f272809ae250d19cba92dbb18c'
STATES = dict(CAPTURE=0, CHECK=1, CLEAR=2, HEADER=3, PIXEL_READ=4, CLASSIFY=5,
              IREAD=6, ICHECK=7, CHOOSE=8, NEXT=9, FOOTER=10, SEND=11, DONE=12)
PROFILES = [(1, 1, 3, 1), (1, 1, 4, 1), (1, 7, 3, 3), (7, 1, 4, 8),
            (3, 5, 3, 5), (8, 8, 4, 8), (16, 16, 3, 32), (64, 64, 4, 32)]
TARGET_NAMES = [
    'CAPTURE empty before first accepted pixel',
    'CAPTURE malformed nonempty prefix after one accepted pixel',
    'CHECK successful complete frame', 'CHECK combined-error complete frame',
    'CLEAR cursor0', 'CLEAR cursor31', 'CLEAR cursor63',
    'HEADER cursor0 before first byte preparation', 'HEADER cursor14 after last header byte',
    'PIXEL_READ address0', 'CLASSIFY same pixel run0', 'CLASSIFY same pixel pending run',
    'CLASSIFY different pixel run0', 'CLASSIFY different pixel pending run',
    'IREAD no pending-run flush', 'ICHECK cache miss', 'ICHECK cache hit',
    'CHOOSE DIFF', 'CHOOSE LUMA', 'CHOOSE RGB', 'CHOOSE RGBA',
    'NEXT nonfinal pixel', 'NEXT final pixel', 'FOOTER cursor0', 'FOOTER cursor8',
    'DONE success held three cycles', 'DONE error held three cycles',
    'SEND first header byte held three cycles', 'SEND last header byte held three cycles',
    'SEND first footer byte held three cycles', 'SEND final footer LAST byte held three cycles',
    'SEND RUN held three cycles', 'SEND INDEX held three cycles', 'SEND DIFF held three cycles',
    'SEND LUMA remaining2 held three cycles', 'SEND LUMA remaining1 held three cycles',
    'SEND RGB remaining4 held three cycles', 'SEND RGB remaining3 held three cycles',
    'SEND RGB remaining2 held three cycles', 'SEND RGB remaining1 held three cycles',
    'SEND RGBA remaining5 held three cycles', 'SEND RGBA remaining4 held three cycles',
    'SEND RGBA remaining3 held three cycles', 'SEND RGBA remaining2 held three cycles',
    'SEND RGBA remaining1 held three cycles', 'CLASSIFY run61 before 62-pixel flush',
    'CLASSIFY last pixel with pending run', 'IREAD after pending-run flush',
    'NEXT nonfinal row wrap', 'CAPTURE malformed prefix at a nonfinal row wrap']


def dump(path, data):
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(data, indent=2, sort_keys=True) + '\n', encoding='utf-8', newline='\n')


def fill(prefix, n, channels, rest=None):
    p = [tuple(x[:channels]) for x in prefix]
    assert p
    return (p + [tuple((rest or p[-1])[:channels])] * max(0, n - len(p)))[:n]


def random_pixels(n, channels, seed):
    rng = random.Random(seed)
    return [tuple(rng.randrange(256) for _ in range(channels)) for _ in range(n)]


def frame(profile, name, pixels, serial, errors=0, variant=None, holds=0, gap=7):
    w, h, c, t = profile
    n = w * h
    assert len(pixels) == n
    tag = ((1 << t) - 1) ^ ((serial * 0x9E3779B9) & ((1 << t) - 1))
    cs = serial & 1
    inputs = []
    for i, pixel in enumerate(pixels):
        sof, eol, upstream = int(i == 0), int(i % w == w - 1), 0
        if errors & 1 and i == 0: sof = 0
        if errors & 2 and i == n - 1: eol ^= 1
        if errors & 4 and i == n - 1: upstream = 1
        if variant == 'late_sof' and i == n - 1: sof = 1
        if variant == 'early_eol' and i == 0: eol ^= 1
        if variant == 'partial_bad' and i == 0: sof, upstream = 0, 1
        inputs.append(dict(pixel=list(pixel), sof=sof, eol=eol, error=upstream,
                           tag=tag if i == 0 else (tag ^ (i * 0x45D9F3B)) & ((1 << t) - 1),
                           colorspace=cs if i == 0 else cs ^ (i & 1)))
    actual_errors = 0
    for i, item in enumerate(inputs):
        actual_errors |= int(item['sof'] != int(i == 0))
        actual_errors |= int(item['eol'] != int(i % w == w - 1)) << 1
        actual_errors |= item['error'] << 2
    data, events, packets, stats, certificate = certify(pixels, w, h, c, cs)
    if actual_errors:
        public = b''
        work = dict(capture_writes=n, raw_reads=0, history_reads=0, history_writes=0,
                    tail=2, different=0, misses=0, payload_bytes=0, bytes=0, opcodes={})
    else:
        public, work = data, stats
    return dict(name=name, inputs=inputs, expected=list(public), errors=actual_errors,
                tag=tag, colorspace=cs, work=work, mathematical_work=stats,
                certificate=certificate, events=events, packets=packets,
                output_holds=holds, source_gap=gap)


def paper_trace(f):
    """Ownership/work schedule only; bytes originate in the numerical oracle."""
    trace = []
    raw, reads, writes, retired = 0, 0, 0, 0

    def add(state, **extra):
        trace.append(dict(state=STATES[state], state_name=state, raw_reads=raw,
                          history_reads=reads, history_writes=writes,
                          retired_bytes=retired, **extra))

    add('CHECK')
    if f['errors']:
        add('DONE', good=False)
        assert len(trace) == 2
        return trace
    for cursor in range(64):
        add('CLEAR', cursor=cursor)
        writes += 1
    for cursor in range(14):
        add('HEADER', cursor=cursor)
        add('SEND', kind='HEADER', position=cursor, remaining=1)
        retired += 1
    add('HEADER', cursor=14)
    for event in f['events']:
        i = event['pixel']
        add('PIXEL_READ', pixel=i)
        raw += 1
        add('CLASSIFY', pixel=i, same=event['same'], run=event['run_before'])
        packets = [f['packets'][j] for j in event['packets']]
        for packet in [p for p in packets if p['phase'] == 'flush']:
            add('SEND', kind='RUN', pixel=i, remaining=1)
            retired += 1
        if not event['same']:
            add('IREAD', pixel=i, after_flush=bool(event['run_before']))
            reads += 1
            add('ICHECK', pixel=i, hit=event['hit'])
            if not event['hit']:
                add('CHOOSE', pixel=i, kind=event['kind'])
                writes += 1
        for packet in [p for p in packets if p['phase'] == 'current']:
            for remaining in range(len(packet['data']), 0, -1):
                add('SEND', kind=packet['kind'], pixel=i, remaining=remaining)
                retired += 1
        add('NEXT', pixel=i)
    for cursor in range(8):
        add('FOOTER', cursor=cursor)
        add('SEND', kind='FOOTER', position=cursor, remaining=1)
        retired += 1
    add('FOOTER', cursor=8)
    add('DONE', good=True)
    assert retired == len(f['expected'])
    assert len(trace) == f['work']['tail']
    assert (raw, reads, writes) == tuple(f['work'][k] for k in ('raw_reads', 'history_reads', 'history_writes'))
    return trace


def target_predicate(rid, entry, profile):
    w, h, c, t = profile
    n = w * h
    s = entry['state_name']
    if rid in (2, 3): return s == 'CHECK'
    if rid in (4, 5, 6): return s == 'CLEAR' and entry['cursor'] == {4: 0, 5: 31, 6: 63}[rid]
    if rid in (7, 8): return s == 'HEADER' and entry['cursor'] == (0 if rid == 7 else 14)
    if rid == 9: return s == 'PIXEL_READ' and entry['pixel'] == 0
    if rid in (10, 11, 12, 13):
        return s == 'CLASSIFY' and entry['same'] == (rid in (10, 11)) and bool(entry['run']) == (rid in (11, 13))
    if rid in (14, 47): return s == 'IREAD' and entry['after_flush'] == (rid == 47)
    if rid in (15, 16): return s == 'ICHECK' and entry['hit'] == (rid == 16)
    if rid in (17, 18, 19, 20): return s == 'CHOOSE' and entry['kind'] == {17:'DIFF',18:'LUMA',19:'RGB',20:'RGBA'}[rid]
    if rid in (21, 22): return s == 'NEXT' and (entry['pixel'] == n - 1) == (rid == 22)
    if rid in (23, 24): return s == 'FOOTER' and entry['cursor'] == (0 if rid == 23 else 8)
    if rid in (25, 26): return s == 'DONE' and entry['good'] == (rid == 25)
    if rid in (27, 28, 29, 30):
        return s == 'SEND' and entry['kind'] == ('HEADER' if rid < 29 else 'FOOTER') and entry['position'] == {27:0,28:13,29:0,30:7}[rid]
    if 31 <= rid <= 44:
        kind, remaining = ({31:('RUN',1),32:('INDEX',1),33:('DIFF',1),34:('LUMA',2),35:('LUMA',1),
                            36:('RGB',4),37:('RGB',3),38:('RGB',2),39:('RGB',1),
                            40:('RGBA',5),41:('RGBA',4),42:('RGBA',3),43:('RGBA',2),44:('RGBA',1)})[rid]
        return s == 'SEND' and entry['kind'] == kind and entry['remaining'] == remaining
    if rid == 45: return s == 'CLASSIFY' and entry['same'] and entry['run'] == 61
    if rid == 46: return s == 'CLASSIFY' and entry['same'] and entry['run'] > 0 and entry['pixel'] == n - 1
    if rid == 48: return s == 'NEXT' and entry['pixel'] < n - 1 and (entry['pixel'] + 1) % w == 0
    raise AssertionError(rid)


def inapplicable(rid, profile):
    w, h, c, t = profile
    n = w * h
    if rid in (1, 11, 13, 21, 46, 47) and n == 1: return 'one pixel has no partial/nonfinal/pending-run transition'
    if rid in (48, 49) and h == 1: return 'one row has no nonfinal row wrap'
    if rid == 45 and n < 62: return 'fewer than 62 pixels cannot fill a RUN'
    if rid in (20, 40, 41, 42, 43, 44) and c == 3: return 'RGB input has implicit alpha255; RGBA opcode is unreachable'
    if rid in (16, 32) and c == 3 and n < 3: return 'RGB cannot hit transparent initial cache; reuse needs at least three pixels'
    return None


def reset_owner(profile, rid):
    w, h, c, t = profile
    n = w * h
    prefix = [INITIAL]
    if rid in (12, 14, 15, 19, 36, 37, 38, 39): prefix = [(100, 0, 0, 255)]
    if rid in (13, 47): prefix = [INITIAL, (100, 0, 0, 255)]
    if rid in (16, 32): prefix = [(0, 0, 0, 0)] if c == 4 else [(100,0,0,255),(0,100,0,255),(100,0,0,255)]
    if rid in (17, 33): prefix = [(1, 1, 1, 255)]
    if rid in (18, 34, 35): prefix = [(38, 31, 23, 255)]
    if rid in (20, 40, 41, 42, 43, 44): prefix = [(0, 0, 0, 1)]
    owner = frame(profile, 'reset_%02d_owner' % rid, fill(prefix, n, c), 500 + rid,
                  errors=7 if rid in (3, 26) else 0,
                  variant='partial_bad' if rid in (1, 49) else None, holds=0, gap=0)
    if rid in (0, 1, 49):
        limit = {0:0, 1:1, 49:w}[rid]
        target = dict(state=0, state_name='CAPTURE', capture_limit=limit,
                      raw_reads=0, history_reads=0, history_writes=0, retired_bytes=0, trace_index=None)
    else:
        trace = paper_trace(owner)
        hits = [(i, e) for i, e in enumerate(trace) if target_predicate(rid, e, profile)]
        assert hits, (profile, rid, TARGET_NAMES[rid])
        index, target = hits[0]
        target = dict(target, capture_limit=n, trace_index=index)
    target['held_cycles'] = 3 if target['state_name'] in ('SEND', 'DONE') else 0
    target['retired_prefix_sha256'] = digest(bytes(owner['expected'][:target['retired_bytes']]))
    owner.update(mode=1, reset_id=rid, reset_target=target)
    fresh = frame(profile, 'reset_%02d_full_fresh' % rid,
                  random_pixels(n, c, 0x251000 + 97 * rid + 13 * w + h),
                  800 + rid, holds=1, gap=5)
    fresh.update(mode=0, reset_id=-1, reset_target=None)
    return owner, fresh


def main_frames(profile):
    w, h, c, t = profile
    n = w * h
    answer = []

    def add(name, pixels, errors=0, variant=None):
        i = len(answer)
        answer.append(frame(profile, name, pixels, i, errors, variant, holds=2 if i & 1 else 0))

    add('opaque_black_initial_and_long_runs', fill([INITIAL], n, c))
    add('opaque_white_wrap_diff', fill([(255,255,255,255)], n, c))
    add('rgb_literal_red', fill([(100,0,0,255)], n, c))
    add('cache_hit_reuse', fill([(100,0,0,255),(0,100,0,255),(100,0,0,255)], n, c))
    # Same hash, distinct colors: replacing a slot must not leave its prior color.
    add('cache_collision_replacement', fill([(100,0,0,255),(36,0,0,255),(100,0,0,255)], n, c))
    add('channel_byte_ramp', [tuple(((i * (2*j+1) + 97*j) & 255) for j in range(c)) for i in range(n)])
    add('seeded_full_raster', random_pixels(n, c, 0x25A0 + n + c))
    if c == 4:
        add('transparent_initial_index0', fill([(0,0,0,0)], n, c))
        add('rgba_alpha_changes', [((i*47)&255,(i*83)&255,(i*131)&255,(i*19+1)&255) for i in range(n)])
    for mask in range(1, 8): add('error_mask_%d_last_pixel' % mask, random_pixels(n, c, 600 + mask), errors=mask)
    if n > 1:
        add('late_extra_sof', random_pixels(n, c, 700), variant='late_sof')
        add('early_eol_mismatch', random_pixels(n, c, 701), variant='early_eol')
    if n == 1:
        for i, p in enumerate([(1,1,1,255),(38,31,23,255),(216,224,231,255),(0,0,0,1)]):
            if c == 4 or p[3] == 255: add('one_pixel_anchor_%d' % i, fill([p], n, c))
    if profile == (8,8,4,8):
        for dr in range(-2, 2):
            for dg in range(-2, 2):
                for db in range(-2, 2):
                    add('diff_%d_%d_%d' % (dr,dg,db), fill([(128,128,128,255),((128+dr)&255,(128+dg)&255,(128+db)&255,255)], n, c))
        for dg in range(-32,32):
            for rg in (-8,7):
                for bg in (-8,7):
                    add('luma_%d_%d_%d' % (dg,rg,bg), fill([(128,128,128,255),((128+dg+rg)&255,(128+dg)&255,(128+dg+bg)&255,255)],n,c))
        add('all_64_hash_slots', [(((slot-53)*43)&63,0,0,255) for slot in range(64)])
    if profile in ((8,8,4,8),(16,16,3,32)):
        for run in (1,61,62,63,124,125):
            if n >= run + 1:
                add('run_%d_before_different_pixel' % run, fill([INITIAL]*run+[(100,0,0,255)],n,c))
    return answer


def public_certificate(f):
    return dict(name=f['name'], errors=f['errors'], tag=f['tag'], colorspace=f['colorspace'],
                input_sha256=digest(bytes(v for p in f['inputs'] for v in p['pixel'])),
                input_rgba_sha256=f['certificate']['rgba_sha256'],
                canonical_file_sha256=f['certificate']['file_sha256'],
                public_file_sha256=digest(bytes(f['expected'])), public_bytes=len(f['expected']),
                exact_decode=f['certificate'], work=f['work'], output_holds=f['output_holds'],
                source_gap=f['source_gap'], reset_id=f.get('reset_id',-1), reset_target=f.get('reset_target'))


def write_fixture(path, blocks, profile):
    w,h,c,t=profile
    lines=[]
    for f in blocks:
        target=f.get('reset_target')
        rid=f.get('reset_id',-1)
        limit=target['capture_limit'] if target else w*h
        state=target['state'] if target else -1
        index=target['trace_index'] if target and target['trace_index'] is not None else -1
        held=target['held_cycles'] if target else 0
        lines.append('%d %d %d %d %d %d' % (f.get('mode',0),rid,limit,state,index,held))
        work=f['work']
        fields=[len(f['expected']),f['errors'],f['colorspace'],work['tail'],work['different'],work['misses'],work['payload_bytes'],f['output_holds'],f['source_gap'],target['retired_bytes'] if target else 0,target['raw_reads'] if target else 0,target['history_reads'] if target else 0,target['history_writes'] if target else 0]
        lines.append(' '.join(map(str,fields))+' %08x'%f['tag'])
        for p in f['inputs']:
            pixel=int.from_bytes(bytes(p['pixel']),'big')
            lines.append(('%0*x %d %d %d %08x %d')%(2*c,pixel,p['sof'],p['eol'],p['error'],p['tag'],p['colorspace']))
        lines.extend('%02x'%v for v in f['expected'])
    path.parent.mkdir(parents=True,exist_ok=True)
    path.write_text('\n'.join(lines)+'\n',encoding='ascii',newline='\n')


def prepare():
    assert not (HERE/'MATRIX.json').exists(), 'One-shot freeze: existing matrix must not be overwritten.'
    assert not list(HERE.rglob('*.sv')) and not list(HERE.rglob('*.v')), 'Fixture-only stage prohibits HDL.'
    audit=REPO/'.git/anscore-b25-c-initial.json'
    assert audit.exists()
    dump(HERE/'INITIAL_PROTECTION.json',json.loads(audit.read_text()))
    (HERE/'.gitattributes').write_text('* text eol=lf\n',encoding='ascii',newline='\n')
    jobs,profiles,certificates=[],[],{}
    totals=Counter()
    global_ops=Counter()
    common={0,1,2,3,4,6,9,10,12,14,15,21,22,23,24,25,26,27,30,48,49}
    for profile in PROFILES:
        w,h,c,t=profile
        n=w*h
        name='w%d_h%d_c%d_t%d'%profile
        main=main_frames(profile)
        if profile==(8,8,4,8): chosen=set(range(50))
        elif profile==(64,64,4,32): chosen={0,1,2,3,4,5,6,8,9,11,13,16,20,22,24,25,26,28,30,31,32,44,45,46,47,48,49}
        else:
            chosen=set(common)
            if n==1: chosen|={16,17,18,19,20,32,44}
            if profile==(16,16,3,32): chosen|={17,18,19,34,35,36,39}
        semantic={str(i):reason for i in range(50) if (reason:=inapplicable(i,profile))}
        active=sorted(i for i in chosen if str(i) not in semantic)
        omitted={str(i):'Applicable but outside this profile finite reset selection; default profile covers the semantic state/byte position.' for i in range(50) if i not in chosen and str(i) not in semantic}
        a=max(1,(n-1).bit_length()); x=max(1,(w-1).bit_length()); maximum=(c+1)*n+22; bw=max(1,maximum.bit_length())
        pinfo=dict(name=name,w=w,h=h,c=c,t=t,frames=len(main),reset_ids=active,
                   semantically_inapplicable=semantic,omitted_by_finite_scope=omitted,
                   ram_bits=8*c*n+2048,scalar_bits=135+a+x+8*c+bw+t,
                   max_bytes=maximum,tail_upper=112+(c+7)*n,
                   small_domain_notes={'tag': 'first tag is modulo 2**TAG_W; later accepted values mutate',
                                       'channels3': 'implicit alpha255; no alpha input or RGBA opcode',
                                       'initial_index': 'RGB cannot match transparent zero history',
                                       'one_pixel': 'no in-frame cache reuse, pending run, or nonfinal transition',
                                       'runs': '62+ lengths only claimed where N can contain them'})
        profiles.append(pinfo)
        groups=[]
        if profile==(64,64,4,32): groups.extend(('main%02d'%i,[f]) for i,f in enumerate(main))
        else: groups.append(('main00',main))
        resets=[reset_owner(profile,rid) for rid in active]
        if profile==(64,64,4,32): groups.extend(('reset%02d'%rid,list(pair)) for rid,pair in zip(active,resets))
        else:
            for i in range(0,len(resets),8): groups.append(('reset%02d'%(i//8),[f for pair in resets[i:i+8] for f in pair]))
        for suffix,blocks in groups:
            jobname=name+'_'+suffix
            rel='fixtures/'+jobname+'.txt'
            write_fixture(HERE/rel,blocks,profile)
            records=[public_certificate(f) for f in blocks]
            certpath='fixtures/'+jobname+'.json'
            dump(HERE/certpath,dict(profile=name,blocks=records))
            budget=128
            for f in blocks:
                target=f.get('reset_target')
                if target:
                    edges=target['capture_limit']+(target['trace_index'] or 0)+target['held_cycles']+8
                else:
                    edges=n+(n//max(1,f['source_gap']) if f['source_gap'] else 0)+f['work']['tail']+f['output_holds']*(len(f['expected'])+1)+16
                budget+=2*edges
            info=dict(name=jobname,w=w,h=h,c=c,t=t,fixture=rel,fixture_sha256=digest((HERE/rel).read_bytes()),
                      certificate=certpath,certificate_sha256=digest((HERE/certpath).read_bytes()),
                      blocks=len(blocks),stored_inputs=n*len(blocks),stored_bytes=sum(len(f['expected']) for f in blocks),
                      frames=sum(f.get('mode',0)==0 for f in blocks),reset_ids=[f['reset_id'] for f in blocks if f.get('mode')==1],
                      cycle_limit=budget,queued_main_transitions=max(0,len(blocks)-1) if suffix.startswith('main') else 0)
            jobs.append(info)
            totals['jobs']+=1;totals['stored_inputs']+=info['stored_inputs'];totals['stored_bytes']+=info['stored_bytes'];totals['queued_main_transitions']+=info['queued_main_transitions']
            for f in blocks:
                category='owner' if f.get('mode')==1 else ('fresh' if suffix.startswith('reset') else 'main')
                totals[category+'_frames']+=1
                if category!='owner':
                    for key in ('raw_reads','history_reads','history_writes','capture_writes'):
                        totals[category+'_'+key]+=f['work'][key]
                    totals['exact_tail_frames']+=1
                    global_ops.update(f['work']['opcodes'])
                else:
                    totals['resets']+=1
                    totals['owner_retired_prefix_bytes']+=f['reset_target']['retired_bytes']
        certificates[name]=dict(main_frames=len(main),reset_ids=active,main_opcodes=dict(sum((Counter(f['work']['opcodes']) for f in main),Counter())))
    anchors=hand_anchors()
    assert set(global_ops)=={'RUN','INDEX','DIFF','LUMA','RGB','RGBA'}
    dump(HERE/'CERTIFICATES.json',dict(hand_anchors=anchors,profiles=certificates,
         aggregate_completed_opcodes=dict(sorted(global_ops.items())),
         legal_diff_entries=64,legal_luma_entries=16384,
         fixed_reference=dict(repository='https://github.com/phoboslab/qoi',commit='ffb2d2cb74a1de60819b21b939f7209aa53e91c1',
         files={'qoi.h':{'bytes':18326,'sha256':'7de6fca1a285b1c20d38f2723dec8b774eb9f144edb9710800a95feeea09375a','printed_copyright_year':2021},
                'LICENSE':{'bytes':1075,'sha256':'0caf25d92ae0e7e12107e144a86782ccaad37ddaa3ee51e86e193c7db9ed1487','printed_copyright_year':2022}},
         full_source_and_mit_read=True,upstream_execution=False,adopted_source=False)))
    negatives=[('width0',0,8,4,8),('width65',65,8,4,8),('height0',8,0,4,8),('height65',8,65,4,8),
               ('channels2',8,8,2,8),('channels5',8,8,5,8),('tag0',8,8,4,0),('tag33',8,8,4,33)]
    commands=[['version',['@IVERILOG@','-V'],False],
              ['core_syntax',['@IVERILOG@','-g2012','-Wall','-tnull','-s','qoi_encoder','-f','files.f'],False],
              ['example_syntax',['@IVERILOG@','-g2012','-Wall','-tnull','-s','qoi_encoder_default','-f','example/files.f'],False]]
    for job in jobs:
        argv=['@IVERILOG@','-g2012','-Wall','-s','tb_qoi_encoder','-o','@TEMP@/'+job['name']+'.vvp']
        for key,value in [('W',job['w']),('H',job['h']),('C',job['c']),('T',job['t']),('NUM_BLOCKS',job['blocks']),('NUM_INPUTS',job['stored_inputs']),('NUM_BYTES',job['stored_bytes']),('CYCLE_LIMIT',job['cycle_limit'])]:
            argv.extend(['-P','tb_qoi_encoder.%s=%d'%(key,value)])
        argv.extend(['rtl/qoi_encoder.sv','sim/tb_qoi_encoder.sv'])
        commands.append([job['name']+'_compile',argv,False])
        commands.append([job['name']+'_simulate',['@VVP@','@TEMP@/'+job['name']+'.vvp','+FIXTURE='+str(HERE/job['fixture'])],False])
    for name,w,h,c,t in negatives:
        argv=['@IVERILOG@','-g2012','-Wall','-tnull','-s','qoi_encoder']
        for key,value in [('WIDTH',w),('HEIGHT',h),('CHANNELS',c),('TAG_W',t)]:argv.extend(['-P','qoi_encoder.%s=%d'%(key,value)])
        argv.append('rtl/qoi_encoder.sv');commands.append(['reject_'+name,argv,True])
    totals['children']=len(commands)
    matrix=dict(baseline=BASELINE,stage='FIXTURE_ONLY_COMPLETE_BEFORE_ANY_RTL',timeout_seconds=20,
                timeout_terminal=True,no_adaptation=True,no_hdl_executed=True,
                preparation_sha256=digest(Path(__file__).read_bytes()),oracle_sha256=digest((HERE/'oracle.py').read_bytes()),
                initial_protection_sha256=digest((HERE/'INITIAL_PROTECTION.json').read_bytes()),
                architecture=dict(states=STATES,ram='unreset single-port synchronous frame P*N + history64x32',
                  scalar_formula='135+A+X+8*CHANNELS+BW+TAG_W',max_bytes='(CHANNELS+1)*N+22',
                  fixed_scalar_terms={'history_read_q':32,'previous':32,'packet':40,'remaining':3,'header_footer_cursor':4,'clear_cursor':6,'run':6,'state':4,'return_state':4,'errors':3,'colorspace':1},
                  hash='full weighted sum max6630/13bit; replacing each channel with low6 changes sum by multiple64, reduced weighted sum max1638/11bit; take low6',
                  deltas='All five delta terms explicitly signed8 modulo256; candidate tables decode legal fields',
                  tail='112+3*N+2*different+misses+payload_bytes',tail_bound='112+(CHANNELS+7)*N',
                  first_byte_valid=66,first_byte_accept=67,error_done_valid=1,error_done_accept=2),
                interface=dict(input='ordinary RV; fixed N accepted pixels; SOF/EOL/upstream errors sticky3; snapshot first tag/colorspace; C3 RGB implicit alpha255, C4 RGBA unpremultiplied',
                  output='pure file byte RV with SOF/index/tag; LAST only final footer01; separate held summary RV bytes/errors/tag/colorspace after file; no new input until summary retired',
                  reset='synchronous active-high cancels ownership; level immediately gates ready/valid/markers; RAM unreset; next frame overwrite and success64-clear before use'),
                oracle='original legal DIFF/LUMA decoded-candidate tables + independent strict reverse parser + 8 hand-derived anchors; no upstream execution/no inherited HDL',
                fixture_schema=dict(first_line=['mode(0=complete,1=reset_owner)','reset_id','capture_limit','target_state','paper_trace_index','target_held_cycles'],
                  second_line=['public_bytes','errors','colorspace','tail','different','misses','payload_bytes','output_holds_per_byte_and_summary','source_gap_period','owner_retired_prefix','owner_raw_reads','owner_history_reads','owner_history_writes','tag_hex'],
                  inputs='exactly N rows: pixel_hex sof eol upstream_error tag_hex colorspace',
                  outputs='public_bytes rows: byte_hex; reset owner compares only frozen retired prefix; full file remains stored',
                  reset='assert reset before selected target edge; SEND/DONE first held3; no extra owner retirement, then fresh block runs full same geometry'),
                reset_targets={str(i):v for i,v in enumerate(TARGET_NAMES)},profiles=profiles,jobs=jobs,negatives=negatives,
                children=[c[0] for c in commands],totals=dict(totals),certificate_sha256=digest((HERE/'CERTIFICATES.json').read_bytes()),
                split='maximum main one frame per child; maximum reset one ID per child; other reset at most8 owners+8 complete fresh per child; other main one finite job per profile',
                strict_result_policy='all children hard20s; timeout terminal no retry/reduce/split; ordinary FAIL preserve exact tested sources/receipt/NOT_RUN and stop; legal compile stderr empty; version record only; named reject must mention qoi_encoder_invalid_configuration',
                deferred_hdl_files=['rtl/qoi_encoder.sv','sim/tb_qoi_encoder.sv','files.f','example/files.f','example/qoi_encoder_default.sv'],
                hdl_authorization='NOT_GRANTED; root must independently review this freeze first')
    matrix['verification_timing'] = dict(
        source_gap='Insert one idle input edge before accepted pixel i when i>0 and i%period==0; period0 inserts no gaps. Pixel0 is offered without a gap.',
        output_hold='For each newly presented byte and summary, hold ready low for exactly the block output_holds full active edges, then accept once; output data and all metadata must remain stable.',
        main_queue='After final pixel acceptance, offer the next main frame pixel0 at the following negative edge and hold the complete first beat until accepted. No next-frame input may retire through file output or held summary. Earliest new acceptance is the edge after summary acceptance.',
        exact_tail='Count rising edges strictly after final input acceptance through summary acceptance inclusive: closed tail + output_holds*(public_bytes+1). Capture gaps do not enter this tail.',
        reset_target='With owner output always ready until the chosen target, paper_trace_index0 is CHECK on the first edge after final capture. Assert reset at the negative edge immediately before the target edge; confirm frozen target state, semantic qualifier, retired prefix and issued RAM actions. For SEND/DONE, first hold ready low three edges at that target, check stability, then assert reset without retirement.',
        reset_capture='CAPTURE reset owners stop after capture_limit accepted inputs; wait until the next negative edge, assert reset before another input acceptance. Stored owner inputs remain a complete N-row specification.',
        reset_release='Keep reset high across two rising edges. Check level-gated ready/valid/markers before an edge and cancellation at the first reset edge. Deassert at a negative edge, then offer the full fresh frame from its pixel0; no owner output may reappear.',
        owner_work='Capture writes equal capture_limit. raw/history action counts and retired prefix are the values before the reset target edge; held SEND/DONE adds no work.',
        no_inherited_runs=True)
    dump(HERE/'MATRIX.json',matrix)
    sources={str(p.relative_to(HERE)).replace('\\','/'):digest(p.read_bytes()) for p in sorted(HERE.rglob('*')) if p.is_file() and p.name!='TEST_PLAN.json'}
    plan=dict(baseline=BASELINE,stage='FIXTURE_ONLY_FROZEN_AWAIT_ROOT_RTL_AUTHORIZATION',matrix_sha256=digest((HERE/'MATRIX.json').read_bytes()),
              timeout_seconds=20,source_sha256=sources,commands=commands,
              substitution_only=['@IVERILOG@','@VVP@','@TEMP@'],
              later_source_seal='After root RTL authorization, bind exact RTL/TB/example/runner hashes without changing any fixture, matrix or command membership.',
              no_hdl_executed=True)
    dump(HERE/'TEST_PLAN.json',plan)
    owned={str(p.relative_to(REPO)).replace('\\','/'):digest(p.read_bytes()) for p in sorted(HERE.rglob('*')) if p.is_file()}
    dump(REPO/'.git/anscore-b25-c-owned.json',dict(schema=1,owner='C',stage='FIXTURE_ONLY',files_sha256=owned))
    print(json.dumps(dict(matrix_sha256=digest((HERE/'MATRIX.json').read_bytes()),plan_sha256=digest((HERE/'TEST_PLAN.json').read_bytes()),
                         inventory_sha256=digest((REPO/'.git/anscore-b25-c-owned.json').read_bytes()),files=len(owned),totals=dict(totals)),indent=2))


if __name__ == '__main__':
    prepare()
