"""Is the corrupted half of pfb's input word the IMAGINARY lane?

board_v5_pfb (dsp=4) and board_v6_pfb_nodsp (dsp=0) fail with identical
wrong-word counts; the wrong words differ from the model by single power-of-two
magnitudes where the model says zero; and against all-zero imaginary INPUTS the
silicon reports a non-zero imaginary OUTPUT at 60 of the 96 positions where the
model says zero (evidence/board_v5_pfb_20261003, board_v6_pfb_nodsp_20261004).

pfb is one of the three 32-bit-input cores (ddc, duc, pfb: `.s_tdata(input_q)`).
The cores that pass or nearly pass read only the low half -- resampler
`input_q[15:0]` at 36/36, hb_decim `input_q[15:0]` at 23/24 word-clean on its
first Ethernet round.

This probe sends pfb blocks whose imaginary lane is zero by construction and
compares against the same model, so it is meaningful on either build:

  python probe_pfb_imlane.py                     # against whatever is programmed
  python probe_pfb_imlane.py --expect-clean      # after programming
                                                 # evidence/d1_pfb_maskim

On the masked diagnostic image (g_pfb wired to `s_tdata({16'd0, input_q[15:0]})`)
the two readings are:

  clean        the upper input half arrived as garbage on silicon, i.e. a
               harness/board input-path defect that also covers ddc and duc;
  still wrong  the lane theory is dead and physical timing is all that is left.
"""
import argparse, json, struct, sys, time
from datetime import datetime
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))
import eth_protocol as ep


def s16(u):
    return struct.unpack('<h', struct.pack('<H', u & 0xFFFF))[0]


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--expect-clean', action='store_true',
                    help='fail unless every block is byte-exact')
    ap.add_argument('--target-ip', default=ep.ENDPOINT_IP)
    a = ap.parse_args()
    cli = ep.EthClient(broadcast=True, timeout=5.0, target_ip=a.target_ip)
    rows = []
    for n in (8, 16, 24, 64):
        for stall in (0, 1, 7):
            # real part varies; the imaginary lane is exactly zero
            words = [((3000 + 97 * i) % 6000) - 3000 & 0xFFFF
                     for i in range(n)]
            tag = (0x5E1A0000 + len(rows)) & 0xFFFFFFFF
            req = ep.make_block_request(tag, 0, words, stall, 6)
            want = ep.model_oracle(0, words, 6)
            try:
                data, rtt = cli.exchange(req, ep.RES_MAGIC)
                t, cfg, nc, flags, inc, outc, cyc = struct.unpack(ep.RPT,
                                                                  data[4:20])
                got = list(struct.unpack('<%dI' % outc, data[20:20 + 4 * outc]))
                bad = ([i for i in range(min(len(want), len(got)))
                        if want[i] != got[i]]
                       + list(range(len(got), len(want))))
                zeros = [i for i in range(len(want)) if s16(want[i] >> 16) == 0]
                fab = [i for i in zeros if i < len(got)
                       and s16(got[i] >> 16) != 0]
                rows.append(dict(n=n, stall=stall, flags=flags, outc=outc,
                                 wrong=len(bad), words=len(want),
                                 im_fabricated=len(fab), im_positions=len(zeros),
                                 first=bad[:4]))
                print('n%-3d s%d flags %3d outc %2d wrong %3d/%3d  '
                      'im fabricated %2d/%2d'
                      % (n, stall, flags, outc, len(bad), len(want),
                         len(fab), len(zeros)), flush=True)
            except Exception as e:
                rows.append(dict(n=n, stall=stall, error=str(e)))
                print('n%-3d s%d ERROR %s' % (n, stall, e), flush=True)
            time.sleep(0.25)
    st, rtt = cli.status()
    print('status_after', st)
    cli.close()
    out = HERE / 'evidence' / ('pfb_imlane_'
                               + datetime.now().strftime('%Y%m%d_%H%M%S'))
    out.mkdir(parents=True, exist_ok=True)
    clean = sum(1 for r in rows if r.get('wrong') == 0)
    verdict = 'CLEAN' if clean == len(rows) else 'CORRUPT'
    (out / 'probe.json').write_text(json.dumps(
        dict(rows=rows, status_after=st, clean=clean, total=len(rows),
             verdict=verdict), indent=1), encoding='utf-8')
    print('PROBE', out, '%s: clean %d/%d' % (verdict, clean, len(rows)))
    return 0 if (not a.expect_clean or clean == len(rows)) else 1


if __name__ == '__main__':
    raise SystemExit(main())
