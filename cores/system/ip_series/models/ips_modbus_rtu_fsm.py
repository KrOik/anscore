"""Independent golden model for ips_modbus_rtu_fsm.

Written from the contract in src/ips_modbus_rtu_fsm.v, never from simulation
output (docs/IP_CORE_SOP.md trap T1).

Core rules replayed here:
  * a byte is consumed on any enabled beat with rx_valid high, unless a response
    is being sent (state S_ANS), and it always clears the silence counter; the
    first byte of a burst opens a frame, seeds the CRC with CRC_SEED and becomes
    rx_addr, the second byte becomes rx_func, rx_len counts the bytes of the ADU
    on the wire -- the two CRC bytes included -- and holds at 8'hFF;
  * on an enabled beat with no byte and tick high the silence counter increments
    and saturates at 8'hFF -- the close test uses the value *before* that
    increment, so a frame ends on the T35-th tick without a byte;  no tick and no
    byte freezes the timer;
  * evaluation order at the close is fixed: rx_len below MIN_LEN is short,
    otherwise a running CRC that did not fold to 16'h0000 is a CRC error,
    otherwise a foreign address is dropped, otherwise address 8'h00 is a
    broadcast without any response, otherwise the function is dispatched:
    FUNC_READ/FUNC_WRITE need exactly FUNC_LEN bytes, anything else is answered
    with EXC_FUNC, a supported function of the wrong length with EXC_DATA, and a
    supported function of the right length is acknowledged (frame_count);
  * the response is five bytes, one per enabled beat: resp_addr, resp_func,
    resp_code -- each folded into the reseeded CRC register -- then the low and
    high CRC bytes of that folded value;
  * counters saturate at 8'hFF; the tx pipe leaves tx_valid low on the beat that
    closes it and returns to S_IDLE in the same beat.

Stimulus contract shared with sim/tb_ips_modbus_rtu_fsm.v: the plan is a list of
slots, a slot is two beats, the first beat of a slot carries the tick and the
second one carries the byte (T_ONICK moves the byte onto the tick beat,
T_NOTICK withdraws the tick for the whole slot, T_STALL holds clk_en low for the
whole slot so the byte is lost).  Every counter, address change and frame length
below is the testbench plan, slot for slot.  Folded word order per beat: the four
error counters, exception/frame counters with rx_addr/rx_func, the tx pipe, then
crc_state/silence/rx_len; then nbeats.
"""

import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

from ips_model_common import emit, u

# Core defaults, exactly as declared in the ANSI header.
T35 = 40
MIN_LEN = 4
FUNC_LEN = 8
FUNC_READ = 0x03
FUNC_WRITE = 0x06
EXC_FUNC = 0x01
CRC_POLY = 0xA001
CRC_SEED = 0xFFFF

SIL_END = T35 - 1
TX_LAST = 4
EXC_DATA = 0x03
ACK_CODE = 0x00
CRC_GOOD = 0x0000

S_IDLE = 0
S_RX = 1
S_ANS = 2

# Testbench stimulus constants.
T_NONE = 0
T_NOTICK = 1
T_STALL = 2
T_ONICK = 3
TB_SEED = 0xFFFF

SLOTS = []
STATE = {'addr': 0x11, 'acc': TB_SEED}


def push(has, b, tag):
    SLOTS.append((1 if has else 0, b & 0xFF, tag, STATE['addr']))


def quiet(n):
    for _ in range(n):
        push(0, 0x00, T_NONE)


def quiet_t(n, tag):
    for _ in range(n):
        push(0, 0x00, tag)


def fbegin():
    STATE['acc'] = TB_SEED


def fbs(b, tag):
    push(1, b, tag)
    STATE['acc'] = crc_upd(STATE['acc'], b)


def fb(b):
    fbs(b, T_NONE)


def rqt(a, f, n):
    """n bytes on the wire: address, function, n-4 data bytes, then the CRC."""
    fbegin()
    fb(a)
    if n > 1:
        fb(f)
    d = 0x40
    for _ in range(2, n - 2):
        fb(d)
        d = (d + 3) & 0xFF
    fend()


def fend():
    push(1, STATE['acc'] & 0xFF, T_NONE)
    push(1, (STATE['acc'] >> 8) & 0xFF, T_NONE)


def fend_bad(cw):
    push(1, cw & 0xFF, T_NONE)
    push(1, (cw >> 8) & 0xFF, T_NONE)


def set_addr(a):
    STATE['addr'] = a & 0xFF


def crc_upd(c, d):
    x = u(c ^ d, 16)
    for _ in range(8):
        if x & 1:
            x = u((x >> 1) ^ CRC_POLY, 16)
        else:
            x = x >> 1
    return x


def build_plan():
    del SLOTS[:]
    STATE['addr'] = 0x11
    fbegin()

    quiet(260)

    rqt(0x11, 0x03, 8); quiet(45)
    rqt(0x11, 0x06, 8); quiet(45)
    rqt(0x11, 0x10, 8); quiet(45)
    rqt(0x11, 0x04, 8); quiet(45)
    rqt(0x11, 0x03, 9); quiet(45)
    rqt(0x11, 0x03, 7); quiet(45)
    rqt(0x11, 0x03, 4); quiet(45)
    # truncated frame: address, function and only the low CRC byte
    fbegin()
    fb(0x11); fb(0x03)
    push(1, STATE['acc'] & 0xFF, T_NONE)
    quiet(45)
    rqt(0x00, 0x03, 8); quiet(45)
    rqt(0x22, 0x03, 8); quiet(45)

    set_addr(0x12)
    rqt(0x11, 0x03, 8); quiet(45)
    rqt(0x12, 0x06, 8); quiet(45)
    set_addr(0x11)

    fbegin()
    fb(0x11); fb(0x03); fb(0x40); fb(0x43)
    fend_bad(0xBEEF)
    quiet(45)

    # one frame split across 50 tick-free slots: 6 payload bytes + CRC = 8 wire
    # bytes, so the merged frame is a well-formed acknowledged read
    fbegin()
    fb(0x11); fb(0x03); fb(0x40); fb(0x43)
    quiet_t(50, T_NOTICK)
    fb(0x46); fb(0x49)
    fend()
    quiet(45)

    # one byte slot the core never sees because clk_en is low for it
    fbegin()
    fb(0x11); fb(0x03); fb(0x40)
    fbs(0x43, T_STALL)
    fb(0x46)
    fend()
    quiet(45)

    rqt(0x11, 0x03, 8)
    quiet(40)
    rqt(0x11, 0x03, 8)
    quiet(45)

    rqt(0x11, 0x03, 8)
    quiet(39)
    fbs(0x5A, T_ONICK)
    quiet(45)

    rqt(0x11, 0x03, 260); quiet(45)

    rqt(0x11, 0x06, 8); quiet(45)
    quiet(20)


def expand():
    """Turn the slot plan into per-beat (tick, rx_valid, clk_en, byte, addr)."""
    beats = []
    for has, b, tag, sa in SLOTS:
        en = 0 if tag == T_STALL else 1
        tk = 0 if tag == T_NOTICK else 1
        beats.append((tk, 1 if (has and tag == T_ONICK) else 0, en, b, sa))
        beats.append((0, 1 if (has and tag != T_ONICK) else 0, en, b, sa))
    return beats


def bump(st, key):
    if st[key] != 0xFF:
        st[key] = u(st[key] + 1, 8)


def step(st, tick, rv, b, sa):
    if rv and (st['state'] != S_ANS):
        if st['state'] == S_IDLE:
            st['state'] = S_RX
            st['rx_len'] = 1
            st['rx_addr'] = b
            st['crc_state'] = crc_upd(CRC_SEED, b)
        else:
            ln = st['rx_len']
            st['crc_state'] = crc_upd(st['crc_state'], b)
            if ln != 0xFF:
                st['rx_len'] = u(ln + 1, 8)
            if ln == 1:
                st['rx_func'] = b
        st['silence'] = 0
    elif st['state'] == S_ANS:
        idx = st['tx_idx']
        st['tx_valid'] = 1
        if idx == 0:
            st['tx_byte'] = st['resp_addr']
            st['crc_state'] = crc_upd(st['crc_state'], st['resp_addr'])
        elif idx == 1:
            st['tx_byte'] = st['resp_func']
            st['crc_state'] = crc_upd(st['crc_state'], st['resp_func'])
        elif idx == 2:
            st['tx_byte'] = st['resp_code']
            st['crc_state'] = crc_upd(st['crc_state'], st['resp_code'])
        elif idx == 3:
            st['tx_byte'] = st['crc_state'] & 0xFF
        elif idx == 4:
            st['tx_byte'] = (st['crc_state'] >> 8) & 0xFF
        if idx == TX_LAST:
            st['tx_idx'] = 0
            st['tx_valid'] = 0
            st['state'] = S_IDLE
            st['silence'] = 0
        else:
            st['tx_idx'] = u(idx + 1, 3)
    elif tick:
        sl = st['silence']
        if sl != 0xFF:
            st['silence'] = u(sl + 1, 8)
        if (st['state'] == S_RX) and (sl == SIL_END):
            st['state'] = S_IDLE
            if st['rx_len'] < MIN_LEN:
                bump(st, 'short_count')
            elif st['crc_state'] != CRC_GOOD:
                bump(st, 'crc_err_count')
            elif (st['rx_addr'] != sa) and (st['rx_addr'] != 0):
                bump(st, 'not_addr_count')
            elif st['rx_addr'] == 0:
                bump(st, 'broadcast_count')
            else:
                st['resp_addr'] = st['rx_addr']
                st['tx_idx'] = 0
                st['state'] = S_ANS
                st['crc_state'] = CRC_SEED
                if (st['rx_func'] != FUNC_READ) and (st['rx_func'] != FUNC_WRITE):
                    st['resp_func'] = u(st['rx_func'] | 0x80, 8)
                    st['resp_code'] = EXC_FUNC
                    bump(st, 'exc_count')
                elif st['rx_len'] != FUNC_LEN:
                    st['resp_func'] = u(st['rx_func'] | 0x80, 8)
                    st['resp_code'] = EXC_DATA
                    bump(st, 'exc_count')
                else:
                    st['resp_func'] = st['rx_func']
                    st['resp_code'] = ACK_CODE
                    bump(st, 'frame_count')


def fold(st):
    w1 = ((st['crc_err_count'] << 24) | (st['short_count'] << 16) |
          (st['not_addr_count'] << 8) | st['broadcast_count'])
    w2 = ((st['exc_count'] << 24) | (st['frame_count'] << 16) |
          (st['rx_addr'] << 8) | st['rx_func'])
    w3 = ((st['tx_valid'] << 14) | (st['tx_byte'] << 6) |
          (st['tx_idx'] << 3) | st['state'])
    w4 = ((st['crc_state'] << 16) | (st['silence'] << 8) | st['rx_len'])
    return w1, w2, w3, w4


def main():
    build_plan()
    beats = expand()
    st = dict(rx_addr=0, rx_func=0, rx_len=0, crc_state=0, silence=0,
              state=S_IDLE, tx_valid=0, tx_byte=0, tx_idx=0,
              crc_err_count=0, short_count=0, not_addr_count=0,
              broadcast_count=0, exc_count=0, frame_count=0,
              resp_addr=0, resp_func=0, resp_code=0)
    words = []
    for tick, rv, en, b, sa in beats:
        if en:
            step(st, tick, rv, b, sa)
        for w in fold(st):
            words.append(u(w, 32))
    words.append(len(beats))
    emit('ips_modbus_rtu_fsm', words)


if __name__ == '__main__':
    main()
