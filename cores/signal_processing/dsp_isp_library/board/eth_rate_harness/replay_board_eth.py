"""Replay archived eth_rate_harness board traffic back into the RTL simulation.

Reads a board round's per-case ``frames/<name>_req.bin`` UDP payloads and the
round verdict's case order, rebuilds the exact octet streams the host put on
the wire, runs them back-to-back through ``tb_eth_rate`` and reports a
three-way comparison per case: model oracle vs simulated reply vs recorded
board reply.  Nothing is regenerated from the sweep planner, so the stimulus is
byte-identical to the session being explained.

    python replay_board_eth.py --round evidence/<run>/round_01 --core duc

The simulation runs the CURRENT working-tree RTL, so a clean sim with a dirty
board means silicon dependence; a sim that reproduces the board's wrong words
means an RTL/harness bug reproducible without hardware.
"""
import argparse, datetime, hashlib, json, os, re, shutil, struct, subprocess
from pathlib import Path

HERE = Path(__file__).resolve().parent
LIB = HERE.parents[1]
ROOT = LIB.parents[1]

import eth_protocol as ep
import run_eth as reth


def load_round(round_dir):
    rd = Path(round_dir)
    verdict = json.loads((rd / 'verdict.json').read_text(encoding='utf-8'))
    frames = rd / 'frames'
    cases = []
    for c in verdict['cases']:
        req = frames / ('%s_req.bin' % c['name'])
        if not req.exists():
            continue
        cases.append(dict(name=c['name'], payload=req.read_bytes(),
                          board=(frames / ('%s_resp.bin' % c['name'])).read_bytes()
                          if (frames / ('%s_resp.bin' % c['name'])).exists()
                          else None,
                          config=c['config'], in_count=c['in_count'],
                          stall=c['stall'], error=c.get('error'),
                          ok=c.get('ok')))
    return verdict, cases


def decode_reply(data):
    """Lenient RES2 decode (the strict verifier raises on the failures we want)."""
    if data[:4] != ep.RES_MAGIC:
        return None
    tag, cfg, n, flags, inc, outc, cycles = struct.unpack(ep.RPT, data[4:20])
    words = list(struct.unpack('<%dI' % min(outc, ep.MAX_RESULT_WORDS),
                               data[20:20 + 4 * min(outc, ep.MAX_RESULT_WORDS)]))
    return dict(tag=tag, config=cfg, in_count=n, flags=flags, inc=inc,
                outc=outc, cycles=cycles, words=words)


def mismatch(words, want):
    """Index ranges where the reply differs from the model."""
    bad = [i for i, w in enumerate(want) if i >= len(words) or words[i] != w]
    if not bad:
        return 'none', 0, len(want)
    groups, start, prev = [], bad[0], bad[0]
    for i in bad[1:] + [None]:
        if i is None or i != prev + 1:
            groups.append('%d' % start if start == prev else
                          '%d-%d' % (start, prev))
            start = i
        prev = i
    return ','.join(groups), len(bad), len(want)


def stage(core_id, dest):
    dest.mkdir(parents=True, exist_ok=True)
    cad = ROOT / 'tools/oss-cad-suite/oss-cad-suite'
    env = dict(os.environ)
    env['PATH'] = (str(cad / 'bin') + os.pathsep + str(cad / 'lib')
                   + os.pathsep + env['PATH'])
    sim_only = [HERE / 'pll_6m_sim.v', HERE / 'tb_eth_rate.sv']
    synth_only = [HERE / 'PLL_6M.v']
    files = ([HERE / 'eth_rate_harness.v', HERE / 'rmii_eth_pipe.sv',
              HERE / 'eth_support.sv',
              LIB / 'board/dsp_rate_harness/dsp_rate_harness_rom.vh']
             + [LIB / s for s in reth.CORE_RTL[core_id] + reth.SHARED_RTL]
             + [ROOT / 'cores/image_processing/window/sim/gowin_bsram_sim.v'])
    for f in files + sim_only + synth_only:
        if not f.is_file():
            raise FileNotFoundError(str(f))
        shutil.copy2(f, dest / f.name)
    (dest / 'hashes.json').write_text(json.dumps(
        {f.name: hashlib.sha256(f.read_bytes()).hexdigest()
         for f in files + sim_only}, indent=2))
    return files, sim_only, env


def run_sim(core_id, dest, payloads, env, files, sim_only):
    stim = ''
    for seq, payload in enumerate(payloads):
        octets = reth.rmii_octets(reth.udp_frame(payload, seq))
        rlen = ep.STA_RESP_BYTES if payload[:4] == ep.STA_MAGIC_REQ \
            else ep.BLK_RESP_BYTES
        wire = 8 + 14 + 28 + rlen + 4
        stim += '%d %d\n' % (len(octets), wire) + \
            ''.join('%02x\n' % b for b in octets)
    (dest / 'stim.txt').write_text(stim)

    def run(cmd, log):
        cmd = [shutil.which(cmd[0], path=env['PATH']) or cmd[0], *cmd[1:]]
        with (dest / log).open('w') as f:
            f.write('$ ' + ' '.join(str(c) for c in cmd) + '\n')
            f.flush()
            r = subprocess.run([str(c) for c in cmd], cwd=dest, env=env,
                               stdout=f, stderr=subprocess.STDOUT)
        if r.returncode:
            raise RuntimeError('%s failed; see %s' % (log, dest))

    rtl = [f.name for f in files if f.suffix in ('.v', '.sv')
           and f.name not in ('tb_eth_rate.sv', 'gowin_bsram_sim.v',
                              'pll_6m_sim.v')]
    run(['iverilog', '-g2012', '-Wall', '-I.', '-I' + str(HERE),
         '-s', 'tb_eth_rate', '-Ptb_eth_rate.CORE=%d' % core_id,
         '-o', 'sim.vvp', 'tb_eth_rate.sv', 'pll_6m_sim.v',
         'gowin_bsram_sim.v', *rtl], 'compile.log')
    run(['vvp', 'sim.vvp', '+stim=stim.txt', '+trace=trace.txt',
         '+len=trace.txt.len'], 'simulation.log')
    toks = (dest / 'trace.txt').read_text().split()
    undef = [t for t in toks if not re.fullmatch(r'[0-9a-f]{2}', t)]
    if undef:
        raise AssertionError(('undefined octets on the wire', undef[:8]))
    raw = bytes(int(x, 16) for x in toks)
    lengths = [int(v) for v in (dest / 'trace.txt.len').read_text().split()]
    return reth.parse_frames(raw, lengths)


def main():
    p = argparse.ArgumentParser()
    p.add_argument('--round', required=True)
    p.add_argument('--core', required=True, choices=sorted(ep.CORE_IDS))
    p.add_argument('--out', default=None)
    p.add_argument('--poll', action='store_true',
                   help='append a STA1 counter poll after the replay')
    a = p.parse_args()
    core_id = ep.core_id(a.core)
    verdict, cases = load_round(a.round)
    if not cases:
        raise SystemExit('no per-case frames under %s' % a.round)
    stamp = datetime.datetime.now().strftime('%Y%m%d_%H%M%S')
    dest = Path(a.out) if a.out else (
        HERE / 'evidence' / ('replay_%s_%s' % (a.core, stamp)))
    files, sim_only, env = stage(core_id, dest)

    payloads = [c['payload'] for c in cases] + \
        ([ep.make_status_request()] if a.poll else [])
    replies = run_sim(core_id, dest, payloads, env, files, sim_only)
    if len(replies) != len(payloads):
        raise AssertionError(('replies', len(replies), 'requests', len(payloads)))

    rows, stats = [], dict(sim_matches_model=0, sim_matches_board=0,
                           board_matches_model=0, total=0)
    for case, data in zip(cases, replies):
        sim = decode_reply(data)
        board = decode_reply(case['board']) if case['board'] else None
        want = ep.model_oracle(case['config'],
                               list(struct.unpack('<%dI' % case['in_count'],
                                                  case['payload'][16:16 + 4 * case['in_count']])),
                               core_id)
        rng_s, bad_s, n = mismatch(sim['words'], want) if sim else ('-', 0, 0)
        rng_b, bad_b, _ = mismatch(board['words'], want) if board else ('-', 0, n)
        sim_ok = sim is not None and bad_s == 0 and sim['outc'] == len(want)
        board_ok = board is not None and bad_b == 0
        same = (sim is not None and board is not None and
                sim['words'] == board['words'] and sim['flags'] == board['flags'])
        stats['total'] += 1
        stats['sim_matches_model'] += int(sim_ok)
        stats['board_matches_model'] += int(board_ok)
        stats['sim_matches_board'] += int(same)
        rows.append(dict(name=case['name'], config=case['config'],
                         in_count=case['in_count'], stall=case['stall'],
                         out_expect=n,
                         sim_flags=sim['flags'] if sim else None,
                         board_flags=board['flags'] if board else None,
                         sim_wrong=bad_s, sim_idx=rng_s,
                         board_wrong=bad_b, board_idx=rng_b,
                         sim_eq_board=same, sim_eq_model=sim_ok,
                         board_eq_model=board_ok,
                         board_error=case['error']))
        print('%-16s cfg%d n%-3d s%d  model:%-4d  sim wrong %-4d flags 0x%02x '
              'idx[%s]  board wrong %-4d flags 0x%02x idx[%s]  sim==board:%s'
              % (case['name'], case['config'], case['in_count'], case['stall'],
                 n, bad_s, sim['flags'] if sim else -1, rng_s,
                 bad_b, board['flags'] if board else -1, rng_b, same), flush=True)
    (dest / 'replay_summary.json').write_text(json.dumps(dict(
        source_round=str(a.round), source_sha=verdict.get('sha256'),
        core=core_id, core_name=a.core, cases=rows, stats=stats,
        rtl_hashes=json.loads((dest / 'hashes.json').read_text())), indent=1))
    print('REPLAY', dest, json.dumps(stats))


if __name__ == '__main__':
    main()
