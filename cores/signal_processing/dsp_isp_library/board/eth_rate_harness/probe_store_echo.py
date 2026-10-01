"""Prove what the harness actually stored, not just what the link delivered.

pay_ok verifies the CRC-32 of the octets the pipe emitted, and flags[1] verifies
that a word was stored for every declared input - but neither proves the stored
WORD is the word the host sent.  That is the last unmeasured mechanism behind the
saturation-constant family (ddc long blocks, duc at any length, hb_interp, pfb):
one absurd word is enough to drive a 41-bit accumulator out of range, which is
exactly what the silicon reports - one wrong word per block, always 32767 or
-32768, with the clip bit set, while every other word is byte-exact.

XG1 asks the harness for `rxor` over the words it stored, how many it stored, and
the first and last of them, right after a block runs.  Compare against what was
sent:

    python probe_store_echo.py --core ddc                  # against the dock
    python probe_store_echo.py --core ddc --sim /tmp/xg_ddc  # validate the path
                                                             # in simulation first

Interpretation:
  echo matches, outputs wrong  -> the assembly is clean; the divergence starts
                                 inside the core's accumulating state
  echo differs                 -> a word is lost, duplicated or mis-assembled in
                                 the harness, and no core is at fault
"""
import argparse, json, os, struct, subprocess, sys, time
from datetime import datetime
from pathlib import Path

HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[3]
sys.path.insert(0, str(HERE))
import eth_protocol as ep
import run_eth as reth

TOOL = ROOT / 'tools/oss-cad-suite/oss-cad-suite'
ENV = dict(os.environ)
ENV['PATH'] = (str(TOOL / 'lib') + os.pathsep + str(TOOL / 'bin')
               + os.pathsep + ENV['PATH'])


XR_SEED = 0xA55A5A5A   # must match eth_rate_harness.v


def expect_of(words):
    x = XR_SEED
    for w in words:
        x ^= (w & 0xFFFFFFFF)
    return dict(rxor=x, words_written=len(words), word_first=words[0],
                word_last=words[-1], count=len(words),
                data_words=len(words))


def check(got, words, tag):
    want = expect_of(words)
    # `count` is the parse-time register and is already cleared by the time the
    # echo is answered, so it is printed for context, not asserted.
    want.pop('count')
    # data_words is a convenience view of data_bytes and is not part of the claim
    want.pop('data_words')
    bad = [k for k in want if (got[k] & 0xFFFFFFFF) != want[k]]
    # input_count is the parse-time counter and has advanced past the block
    print('%-26s rxor %08s/%08s stored %2d/%2d first %08s last %08s  %s'
          % (tag, '%08x' % got['rxor'], '%08x' % want['rxor'],
             got['words_written'], want['words_written'],
             '%08x' % got['word_first'], '%08x' % got['word_last'],
             'OK' if not bad else 'MISMATCH ' + ','.join(bad)))
    return not bad


def run_sim(dest, cases):
    """Drive the compiled eth_rate_harness simulation with blocks + XG1 polls."""
    dest = Path(dest)
    stim = ''
    seq = 0
    for words, stall, core in cases:
        payload = ep.make_block_request(0x5CF00000 + seq, 0, words, stall, core)
        octets = reth.rmii_octets(reth.udp_frame(payload, seq))
        seq += 1
        stim += '%d %d\n' % (len(octets), 54 + ep.BLK_RESP_BYTES)
        stim += ''.join('%02x\n' % b for b in octets)
        octets = reth.rmii_octets(reth.udp_frame(ep.make_store_request(), seq))
        seq += 1
        stim += '%d %d\n' % (len(octets), 54 + ep.STA_RESP_BYTES)
        stim += ''.join('%02x\n' % b for b in octets)
    (dest / 'stim_echo.txt').write_text(stim)
    subprocess.run([str(TOOL / 'bin/vvp.exe'), 'sim.vvp',
                    '+stim=stim_echo.txt', '+trace=trace_echo.txt',
                    '+len=trace_echo.txt.len'], cwd=dest, env=ENV,
                   capture_output=True, text=True, timeout=900)
    raw = bytes(int(x, 16) for x in
                (dest / 'trace_echo.txt').read_text().split())
    lengths = [int(v) for v in
               (dest / 'trace_echo.txt.len').read_text().split()]
    frames = reth.parse_frames(raw, lengths)
    return frames


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--core', default='ddc')
    ap.add_argument('--sim', type=Path, default=None,
                    help='evidence dir with a compiled sim.vvp, to validate first')
    ap.add_argument('--lengths', default='8,16,32,64')
    ap.add_argument('--stall', type=int, default=0)
    a = ap.parse_args()
    core_id = ep.core_id(a.core)
    rng = 12345
    cases = []
    for n in [int(x) for x in a.lengths.split(',')]:
        words = []
        for i in range(n):
            rng = (rng * 1103515245 + 12345) & 0x7FFFFFFF
            words.append((rng & 0xFFFF) << 16 | ((rng >> 16) & 0x7FFF) + 1)
        # distinctive edges so a lost/duplicated word cannot hide
        words[0] = 0x1234_5678
        words[-1] = 0x7FFF_0001
        cases.append((words, a.stall, core_id))

    if a.sim:
        frames = run_sim(a.sim, cases)
        print('sim replies:', len(frames), '(expected %d)' % (2 * len(cases)))
        ok = True
        for k, (words, stall, _c) in enumerate(cases):
            blk, echo = frames[2 * k], frames[2 * k + 1]
            got = ep.parse_store_response(echo)
            ok &= check(got, words, 'sim n=%d' % len(words))
            # the block itself must still be answered by the model
            struct.unpack(ep.RPT, blk[4:20])
        print('ECHO', 'OK' if ok else 'MISMATCH', '(simulation path)')
        return 0 if ok else 1

    cli = ep.EthClient(broadcast=True, timeout=5.0)
    rows = []
    for words, stall, _c in cases:
        tag = (0x5CF00000 + len(rows)) & 0xFFFFFFFF
        req = ep.make_block_request(tag, 0, words, stall, core_id)
        try:
            data, rtt = cli.exchange(req, ep.RES_MAGIC)
        except Exception as e:
            print('n=%d block ERROR %s' % (len(words), e))
            continue
        t, cfg, nc, flags, inc, outc, cyc = struct.unpack(ep.RPT, data[4:20])
        board = list(struct.unpack('<%dI' % outc, data[20:20 + 4 * outc]))
        want = ep.model_oracle(cfg, words, core_id)
        bad = [i for i in range(min(len(want), len(board)))
               if want[i] != board[i]]
        echo_data, _r = cli.exchange(ep.make_store_request(), ep.XG_MAGIC_RESP)
        got = ep.parse_store_response(echo_data)
        good = check(got, words, 'board n=%d out-wrong %d'
                     % (len(words), len(bad)))
        rows.append(dict(n=len(words), stall=stall, out_wrong=len(bad),
                         echo_ok=good, flags=flags, got=got))
        time.sleep(0.25)
    cli.close()
    out = HERE / 'evidence' / ('store_echo_%s_%s'
                               % (a.core, datetime.now().strftime('%Y%m%d_%H%M%S')))
    out.mkdir(parents=True, exist_ok=True)
    (out / 'probe.json').write_text(json.dumps(rows, indent=1), encoding='utf-8')
    print('PROBE', out)
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
