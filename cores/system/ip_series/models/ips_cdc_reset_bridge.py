"""Independent golden model for ips_cdc_reset_bridge.

Written from the core's documented contract, never from simulation output
(docs/IP_CORE_SOP.md trap T1):

  source domain, enabled on src_tick
      por_count wraps at POR_W bits
      por_done latches the first time por_count >= POR_LAST - 1 (evaluated with
      the pre-increment count, and only while por_done is still clear)
      src_ok = por_done_q && !req_latch_q
  request catcher, enabled on every clk_en edge
      req_latch = 1 while arst_req is high, else cleared on src_tick
  destination domain, enabled on dst_tick
      sync1 <= src_ok, sync2 <= sync1, released <= sync1 && sync2
      sync2 && !sync1  -> re-assert: glitch_sticky set, glitch_count + 1 (4-bit wrap)
      !sync2 && sync1  -> release: rst_events + 1 (4-bit wrap)
      rst_out_n == sync2

Stimulus contract shared with sim/tb_ips_cdc_reset_bridge.v: beat i drives
src_tick = (i % 7 == 0), dst_tick = (i % 5 == 0) and the arst_at(i) pattern.
Folded word order per beat, matching the testbench:
    {por_done, src_ok, sync1, sync2, released, glitch_sticky, rst_out_n},
    por_count, {glitch_count, rst_events};  then BEATS once at the end.
"""

import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

from ips_model_common import emit, u

POR_W = 5
POR_LAST = 12
BEATS = 600
POR_MASK = (1 << POR_W) - 1


def arst_at(n):
    runs = ((60, 64), (200, 235), (400, 404), (560, 566))
    singles = (120, 300, 302, 500, 520)
    for lo, hi in runs:
        if lo <= n <= hi:
            return 1
    return 1 if n in singles else 0


def main():
    st = dict(src_ok=0, por_done=0, por_count=0, req_latch=0, sync1=0, sync2=0,
              released=0, glitch_sticky=0, glitch_count=0, rst_events=0)
    words = []

    for i in range(BEATS):
        src_tick = 1 if i % 7 == 0 else 0
        dst_tick = 1 if i % 5 == 0 else 0
        arst = arst_at(i)

        # request catcher (clk_en only gate)
        req_latch = st["req_latch"]
        if arst:
            req_latch = 1
        elif src_tick:
            req_latch = 0

        src_ok = st["src_ok"]
        por_done = st["por_done"]
        por_count = st["por_count"]
        if src_tick:
            por_count = u(por_count + 1, POR_W)
            if por_done == 0 and st["por_count"] >= POR_LAST - 1:
                por_done = 1
            src_ok = 1 if (st["por_done"] and not st["req_latch"]) else 0

        sync1, sync2 = st["sync1"], st["sync2"]
        released = st["released"]
        glitch_sticky = st["glitch_sticky"]
        glitch_count = st["glitch_count"]
        rst_events = st["rst_events"]
        if dst_tick:
            sync1 = st["src_ok"]
            sync2 = st["sync1"]
            released = 1 if (st["sync1"] and st["sync2"]) else 0
            if st["sync2"] and not st["sync1"]:
                glitch_sticky = 1
                glitch_count = u(glitch_count + 1, 4)
            if not st["sync2"] and st["sync1"]:
                rst_events = u(rst_events + 1, 4)

        st.update(src_ok=src_ok, por_done=por_done, por_count=por_count,
                  req_latch=req_latch, sync1=sync1, sync2=sync2,
                  released=released, glitch_sticky=glitch_sticky,
                  glitch_count=glitch_count, rst_events=rst_events)

        rst_out_n = st["sync2"]
        flags = ((st["por_done"] << 6) | (st["src_ok"] << 5) |
                 (st["sync1"] << 4) | (st["sync2"] << 3) |
                 (st["released"] << 2) | (st["glitch_sticky"] << 1) | rst_out_n)
        words.append(flags)
        words.append(st["por_count"])
        words.append(((st["glitch_count"] & 0xF) << 4) | (st["rst_events"] & 0xF))

    words.append(BEATS)
    emit('ips_cdc_reset_bridge', words)


if __name__ == '__main__':
    main()
