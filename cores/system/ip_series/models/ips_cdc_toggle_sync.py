"""Independent golden model for ips_cdc_toggle_sync.

Contract (written, not derived from the RTL):
  * one physical clock, two enable streams: src_tick when beat % 7 == 0,
    dst_tick when beat % 5 == 0.
  * source: on src_tick with src_start and no transfer outstanding, the
    payload bus is held, the request becomes pending and the transfer count
    advances; with a transfer outstanding the same request is an error and
    both the error count and the sticky flag advance.
  * a pending request flips the source toggle one source tick after the bus
    was written, so the multi-bit bus is stable for a full tick first.
  * destination: the toggle is sampled by two stages; when they differ the
    held bus is captured in full, dst_valid rises and the receive count
    advances.  A take while dst_valid is set flips the acknowledge toggle and
    clears dst_valid; the acknowledge is sampled by two stages in the source
    domain and ends the transfer when it differs from the value seen before.
  * stimulus: src_start on beats n%42==21 and, for 399<=n<=553, on every
    source tick; dst_take on every second destination tick below 360;
    src_data is driven 13 bits wide as (0x1000 + n), which the DATA_W bit port
    truncates exactly as the testbench's DATA_W bit wire does.
  * fold order matches tb_ips_cdc_toggle_sync: source word (pend, tog_src,
    src_start, data_hold) on source ticks, then the destination words
    (dst_valid, dst_data) and (ack_tog, tog_s1, tog_s2, ack_s1, ack_s2,
    dst_take) on destination ticks, then tx_count, rx_count, err_count,
    err_sticky, outstanding every beat, then the beat count.  data_hold and
    dst_data sit in the low 13 bits of their word, one bit wider than DATA_W.
"""

from ips_model_common import emit, u, MASK32

DATA_W = 12
TBW = 13
CNT_W = 4
BEATS = 600
SEED = 0x5C0CC11E

DMASK = (1 << DATA_W) - 1
CMASK = (1 << CNT_W) - 1


def src_tick(i):
    return i % 7 == 0


def dst_tick(i):
    return i % 5 == 0


def start(n):
    return (n % 42 == 21) or (399 <= n <= 553 and n % 7 == 0)


def take(n):
    return (n % 5 == 0) and (n < 360) and (((n // 5) % 2) == 1)


def data(n):
    return u(0x1000 + n, DATA_W)


words = []
hold = 0
pend = 0
out = 0
ack_tog = 0
ack_seen = 0
tog = 0
dst_data = 0
dst_valid = 0
ack_s1 = 0
ack_s2 = 0
sync1 = 0
sync2 = 0
tx = rx = err = 0
sticky = 0

for i in range(BEATS):
    ss, tk, dd = 1 if start(i) else 0, 1 if take(i) else 0, data(i)
    # every register reads the value it held before this edge, whichever domain
    # writes it, so the crossing is sampled as the hardware samples it
    p = dict(hold=hold, pend=pend, out=out, ack_tog=ack_tog, ack_seen=ack_seen,
             tog=tog, dst_data=dst_data, dst_valid=dst_valid, ack_s1=ack_s1,
             ack_s2=ack_s2, sync1=sync1, sync2=sync2, tx=tx, rx=rx, err=err,
             sticky=sticky)

    if src_tick(i):
        n_hold, n_pend, n_out, n_tx = p['hold'], p['pend'], p['out'], p['tx']
        n_err, n_sticky, n_tog = p['err'], p['sticky'], p['tog']
        if ss and not p['out']:
            n_hold, n_pend, n_out, n_tx = dd, 1, 1, u(p['tx'] + 1, CNT_W)
        if ss and p['out']:
            n_err, n_sticky = u(p['err'] + 1, CNT_W), 1
        if p['pend']:
            n_tog, n_pend = p['tog'] ^ 1, 0
        n_a1, n_a2 = p['ack_tog'], p['ack_s1']
        if p['ack_s2'] != p['ack_seen']:
            n_out, n_ack_seen = 0, p['ack_s2']
        else:
            n_ack_seen = p['ack_seen']
        hold, pend, out, tx = n_hold, n_pend, n_out, n_tx
        err, sticky, tog = n_err, n_sticky, n_tog
        ack_s1, ack_s2, ack_seen = n_a1, n_a2, n_ack_seen

    if dst_tick(i):
        n_ack_tog, n_valid, n_data, n_rx = p['ack_tog'], p['dst_valid'], p['dst_data'], p['rx']
        if tk and p['dst_valid']:
            n_ack_tog, n_valid = p['ack_tog'] ^ 1, 0
        if p['sync2'] != p['sync1']:
            n_data, n_valid, n_rx = p['hold'], 1, u(p['rx'] + 1, CNT_W)
        n_s1, n_s2 = p['tog'], p['sync1']
        ack_tog, dst_valid, dst_data, rx = n_ack_tog, n_valid, n_data, n_rx
        sync1, sync2 = n_s1, n_s2

    if src_tick(i):
        words.append(u((pend << 15) | (tog << 14) | (ss << 13) | hold, MASK32))
    if dst_tick(i):
        words.append(u((dst_valid << 13) | dst_data, MASK32))
        words.append(u((ack_tog << 5) | (sync1 << 4) | (sync2 << 3) |
                       (ack_s1 << 2) | (ack_s2 << 1) | tk, MASK32))
    words.append(u(tx, CNT_W))
    words.append(u(rx, CNT_W))
    words.append(u(err, CNT_W))
    words.append(u(sticky, 1))
    words.append(u(out, 1))

words.append(BEATS)

if __name__ == "__main__":
    emit("ips_cdc_toggle_sync", words)
