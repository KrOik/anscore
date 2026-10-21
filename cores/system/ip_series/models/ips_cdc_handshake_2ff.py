"""Independent golden model for ips_cdc_handshake_2ff.

Contract (written, not derived from the RTL):
  * one physical clock, two enable streams: src_tick when beat % 7 == 0,
    dst_tick when beat % 5 == 0.
  * source: on src_tick with src_start and no transfer in flight, the payload
    is held, the request becomes pending, busy is set and the launch count
    advances; the same request with busy set is a collision and advances the
    error count plus the sticky flag.
  * a pending request raises req on the NEXT source tick, so the multi-bit bus
    is stable for a full source cycle first.
  * req is synchronised into the destination by two stages; hop_count counts
    the level changes landing there.  When the synced request is high and the
    destination holds neither a displayed word nor ack, the whole held word is
    captured, valid rises and the receive count advances.  A take while valid
    raises ack and clears valid.  ack falls when the synchronised req falls,
    and req falls when the source sees ack high; the source leaves busy only
    after it sees ack fall again: that is the four phase sequence.
  * stimulus: src_start on beats n%70==21 and, for n>=330, on every source
    tick; dst_take on every third destination tick outside 320 <= n < 470;
    src_data is driven 17 bits wide as (0x10000 + n) and truncated by the
    DATA_W bit port exactly as the testbench's DATA_W bit wire is.
  * fold order matches tb_ips_cdc_handshake_2ff: source word (pend, busy,
    phase, req, src_start, data_hold) on source ticks, destination word
    (valid, ack, req_s1, req_s2, dst_take, data_dst) on destination ticks,
    then tx_count, rx_count, err_count, hop_count, err_sticky, busy every
    beat, then the beat count.
"""

from ips_model_common import emit, u, MASK32

DATA_W = 16
TBW = 17
CNT_W = 4
BEATS = 500


def src_tick(i):
    return i % 7 == 0


def dst_tick(i):
    return i % 5 == 0


def start(n):
    return (n % 70 == 21) or (n >= 330 and n % 7 == 0)


def take(n):
    return (n % 5 == 0) and ((n // 5) % 3 == 1) and not (320 <= n < 470)


def data(n):
    return u(0x10000 + n, DATA_W)


words = []
hold = req = pend = busy = phase = 0
tx = err = sticky = 0
ack_s1 = ack_s2 = 0
dst = valid = ack = 0
rx = hop = 0
s1 = s2 = 0

for i in range(BEATS):
    ss, tk, dd = 1 if start(i) else 0, 1 if take(i) else 0, data(i)
    # every register reads the value it held before this edge, whichever domain
    # writes it, so the crossing is sampled as the hardware samples it
    p = dict(hold=hold, req=req, pend=pend, busy=busy, phase=phase, tx=tx,
             err=err, sticky=sticky, ack_s1=ack_s1, ack_s2=ack_s2, dst=dst,
             valid=valid, ack=ack, rx=rx, hop=hop, s1=s1, s2=s2)

    if src_tick(i):
        n_hold, n_req, n_pend, n_busy = p['hold'], p['req'], p['pend'], p['busy']
        n_phase, n_tx, n_err, n_sticky = p['phase'], p['tx'], p['err'], p['sticky']
        if ss and not p['busy']:
            n_hold, n_pend, n_busy, n_tx = dd, 1, 1, u(p['tx'] + 1, CNT_W)
        if ss and p['busy']:
            n_err, n_sticky = u(p['err'] + 1, CNT_W), 1
        if p['pend']:
            n_req, n_pend = 1, 0
        n_a1, n_a2 = p['ack'], p['ack_s1']
        if p['busy'] and p['req'] and p['ack_s2']:
            n_req, n_phase = 0, 1
        if p['phase'] and not p['ack_s2']:
            n_phase, n_busy = 0, 0
        hold, req, pend, busy = n_hold, n_req, n_pend, n_busy
        phase, tx, err, sticky = n_phase, n_tx, n_err, n_sticky
        ack_s1, ack_s2 = n_a1, n_a2

    if dst_tick(i):
        n_s1, n_s2 = p['req'], p['s1']
        n_hop = u(p['hop'] + 1, CNT_W) if p['s2'] != p['s1'] else p['hop']
        n_dst, n_valid, n_rx, n_ack = p['dst'], p['valid'], p['rx'], p['ack']
        if p['s2'] and not p['valid'] and not p['ack']:
            n_dst, n_valid, n_rx = p['hold'], 1, u(p['rx'] + 1, CNT_W)
        if tk and p['valid']:
            n_ack, n_valid = 1, 0
        if not p['s2'] and p['ack']:
            n_ack = 0
        s1, s2, hop = n_s1, n_s2, n_hop
        dst, valid, rx, ack = n_dst, n_valid, n_rx, n_ack

    if src_tick(i):
        words.append(u((pend << 21) | (busy << 20) | (phase << 19) |
                       (req << 18) | (ss << 17) | hold, MASK32))
    if dst_tick(i):
        words.append(u((valid << 21) | (ack << 20) | (s1 << 19) |
                       (s2 << 18) | (tk << 17) | dst, MASK32))
    words.append(u(tx, CNT_W))
    words.append(u(rx, CNT_W))
    words.append(u(err, CNT_W))
    words.append(u(hop, CNT_W))
    words.append(u(sticky, 1))
    words.append(u(busy, 1))

words.append(BEATS)

if __name__ == "__main__":
    emit("ips_cdc_handshake_2ff", words)
