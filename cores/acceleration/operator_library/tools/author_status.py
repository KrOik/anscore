"""Supervise the parallel family authors from the outside, read-only.

Reports, per expected family, whether the plug-in file exists, imports, declares
the assigned cores, has a working selftest(), and whether the generated artifacts
and evidence an author's own runs would have produced are present. This is how a
dead or stalled author is told apart from a slow one before deciding to take over.
"""
import importlib
import json
import time
from datetime import datetime, timezone
from pathlib import Path

from generate_lib import ROOT

EXPECTED = {
    'crypto': 'aes128_round aes_key_schedule sha256_round sha1_round md5_round '
              'chacha20_quarterround sm4_round xtea_block ghash_mul32 lfsr_galois_keystream',
    'fft': 'r2_bfly_s12 r4_bfly_s12 twiddle_index16 cordic_rotate complex_add_sat '
           'cmul_q15 mag_approx_s12 stockham_addr dit_stage_map chirp_mult_s12',
    'fec': 'ldpc_cn_minsum ldpc_vn_update rs255_syndrome_acc gf256_poly_eval '
           'bch31_syndrome convk7_acs16 puncture_map_r13 turbo_alpha_step '
           'hamming74_correct interleave_convex',
    'netio': 'lpm_trie_step ipv4_hdr_csum toeplitz_rss qinq_walk bloom4_update '
             'countmin_update hll_reg_update bitmap_scan radix_tree_step pacing_wf2q',
    'motor': 'clarke_s12 park_s12 inv_park_s12 svpwm_sector ipi_pid_s12 '
             'backemf_obs_s12 mt_speed pwm_deadband sinc3_decim cordic_sincos',
    'video': 'rgb2yuv709 yuv2rgb709 yuv420_pack yuv422_unpack osd_blend_u8 chroma_key '
             'bresenham_step sprite_blend lvds_scramble20 de_timing',
    'audio': 'biquad_df1_s12 biquad_df2_s12 biquad_cascade_step poly2_interp '
             'cic_comp_s12 goertzel_dtmf karplus_strong dsm2_mod envelope_ar tdm8_demux',
    'memsys': 'afifo_gray fifo_wm lru8_victim cam_match bank_alloc tlb8_lookup '
              'ecc72_gen raid5_pq march_engine addr_scramble',
    'arith': 'cordic_atan nr_recip div_nonrestoring isqrt fix2float float2fix_rne '
             'fadd_s32 bf16_mul csd_recode mont_mul',
    'sensing': 'mahony_ahrs kalman1d kalman2d_cv ca_correlator manchester_io dmx512_frame '
               'onewire_slot ws2812_serial crc16_modbus quadrature_jitter',
}


def age(path):
    return round((time.time() - path.stat().st_mtime) / 60, 1)


def artifacts(name):
    return sum(1 for relative in (f'rtl/acc_{name}.v', f'vectors/{name}.mem',
                                  f'sim/tb_{name}.sv', f'ip/{name}/manifest.json')
               if (ROOT / relative).is_file())


def main():
    now = datetime.now(timezone.utc).strftime('%Y-%m-%d %H:%M:%SZ')
    print(f'author status at {now}; 4 artifact files per generated core\n')
    print(f'{"family":8} {"file":6} {"age":>6} {"cores":>5} {"match":>5} '
          f'{"selftest":>9} {"gen":>4}  notes')
    for family, wanted in EXPECTED.items():
        wanted = wanted.split()
        path = ROOT / 'tools' / f'fam_{family}.py'
        note, count, matched, selftest = [], 0, '-', 'none'
        if not path.is_file():
            print(f'{family:8} {"-":6} {"-":>6} {"-":>5} {"-":>5} {"-":>9} {"-":>4}  '
                  f'no file yet')
            continue
        try:
            module = importlib.import_module(f'fam_{family}')
            names = [entry['name'] for entry in module.CORES]
            count = len(names)
            matched = f'{len(set(names) & set(wanted))}/{len(wanted)}'
            extra = sorted(set(names) - set(wanted))
            gap = sorted(set(wanted) - set(names))
            if extra:
                note.append('unassigned:' + ','.join(extra[:3]))
            if gap:
                note.append('missing:' + ','.join(gap[:3]))
            if getattr(module, 'FAMILY', None) != family:
                note.append(f'FAMILY={module.__dict__.get("FAMILY")!r}')
            function = getattr(module, 'selftest', None)
            if callable(function):
                try:
                    value = function()
                    selftest = str(value) if isinstance(value, int) else 'NOT-INT'
                    if not isinstance(value, int):
                        note.append('selftest returns ' + repr(value)[:20])
                except Exception as exc:
                    selftest = 'RAISES'
                    note.append(f'selftest {exc.__class__.__name__}: {str(exc)[:60]}')
            else:
                selftest = 'absent'
            generated = sum(artifacts(name) > 3 for name in names)
            print(f'{family:8} {"yes":6} {age(path):>6} {count:>5} {matched:>5} '
                  f'{selftest:>9} {generated:>4}  ' + '; '.join(note))
        except Exception as exc:
            print(f'{family:8} {"yes":6} {age(path):>6} {"?":>5} {"?":>5} {"?":>9} '
                  f'{"?":>4}  IMPORT FAILS {exc.__class__.__name__}: {str(exc)[:70]}')
    print('\nselftest column = check count (a RAISES/NOT-INT/absent family is not done)')


if __name__ == '__main__':
    main()
