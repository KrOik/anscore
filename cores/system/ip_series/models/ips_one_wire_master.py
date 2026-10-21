"""Independent golden model for ips_one_wire_master.

Written from the contract in src/ips_one_wire_master.v, never from simulation
output (docs/IP_CORE_SOP.md trap T1).  The CRC is even derived the other way
round: the core clocks one bit through a reflected LFSR, this model does
polynomial long division by g(x) = x^8 + x^5 + x^4 + 1 in normal (MSB-first)
form over the bit-reversed byte stream and reflects the remainder back, which
is Maxim's CRC-8 arrived at from the opposite direction.

Core rules replayed here:
  * the engine moves on an enabled tick only; a beat with clk_en low or tick low
    freezes every register, so the tick-domain slot plan stays aligned;
  * commands are accepted in S_IDLE only.  2'd1 = reset/presence, 2'd2 = write
    byte (LSB first), 2'd3 = read byte, anything else = invalid opcode
    (bad_cmd_sticky + err_count).  cmd_valid while busy is a collision
    (busy_sticky + err_count) and the command is dropped;
  * reset phase, tick index tc: the line is pulled for tc < RST_LOW, presence is
    sampled at tc == PRE_SMP (line low = presence), a high line there is the
    no-presence error, and the phase closes at tc == PRE_END with done;
  * slot phase, one slot per bit, bit_idx 0..7 LSB first, slot ends at
    tc == SLOT_END, the 8th slot raises done and returns to S_IDLE.  A write slot
    pulls for tc < (bit ? W1_LOW : W0_LOW) and the pad level is never used as
    data; a read slot pulls for tc < RD_LOW and samples the pad at tc == RD_SMP
    (high = 1, low = 0), shifting it into rx_word;
  * with the command's crc_en latched, every completed byte steps the CRC
    accumulator, the transmitted byte for a write slot and the byte assembled
    from the sampled pad levels for a read slot.  crc_en also starts a block
    counter: the accumulator is cleared when the first crc_en byte of a block is
    launched (byte_count == 0) and the byte whose command carried crc_end closes
    the block.  A block must be exactly CRC_BYTES bytes long, otherwise
    len_sticky latches and err_count steps; with the right length the running CRC
    is the residue, 0x00 means good and anything else latches crc_sticky and
    steps crc_count.  byte_count restarts, so the residue stays readable.
  * all four counters hold at their saturating maximum 4'hF.

Stimulus contract shared with sim/tb_ips_one_wire_master.v: the plan is a list of
command entries.  Beat 0 of an entry presents cmd_valid, the following beats are
the phase ticks and the phase index p is the core's own tc (reset entries run
p = 0..PRE_END_TB, byte entries p = 0..SLOT*BITS-1, so bit slot j = p / SLOT and
q = p % SLOT).  Gap beats (tick low) and stall beats (clk_en low) are appended
inside an entry at a fixed phase index and repeat that phase beat's drive, so the
tick-domain plan stays aligned.  The slave is open drain: it pulls the presence
window PRE_ON..PRE_OFF of a reset entry that answers, and for read slot j of a
byte it pulls for the mode's window (M_WIDE SLV_ON..SLV_OFF, M_NARROW only the
single tick SLV_ON, M_DEAD never answers, and a returned 1 bit is never driven
low).  A write slot is silent.  pin = NOT(master pull-down OR slave pull-down).
Two 9-byte crc_en blocks (PD + CRCB, and the same block with bit 3 of PD[4]
corrupted to PDB4) plus one deliberately short 4-byte block are read, so the
model must produce a clean residue, a failed residue and a length error.

Folded word order per beat, all from the values observed after that beat's
enabled edge: w1 = (tc << 8) | (bit_idx << 5) | (state << 2) | (ow_oe << 1) |
done; w2 = (rx_word << 12) | (tx_word << 4) | byte_count; w3 = (nopre << 17) |
(crc_sticky << 16) | (len_sticky << 15) | (busy << 14) | (bad_cmd << 13) |
(presence << 12) | (rst_count << 8) | (crc_count << 4) | err_count; plus
(24'h0, crc) on every beat whose done is high.  Then nbeats, then
(state[2:0] << 12) | (rst_count << 8) | (crc_count << 4) | err_count for the
state left in the shared LCG generator.
"""

import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

from ips_model_common import emit, lcg32, u

# Core defaults, exactly as declared in the ANSI header.
RST_LOW = 6
PRE_SMP = 8
PRE_END = 12
RD_LOW = 2
RD_SMP = 3
W1_LOW = 2
W0_LOW = 6
SLOT_END = 5
CRC_POLY_REFLECTED = 0x8C     # the core's generator, for reference only
CRC_BYTES = 9

S_IDLE = 0
S_RST = 1
S_WBIT = 2
S_RBIT = 3
BIT_LAST = 7

# Testbench stimulus constants.
CMD_RST = 1
CMD_WR = 2
CMD_RD = 3
M_NONE = 0
M_WIDE = 1
M_NARROW = 2
M_DEAD = 3
SLOT = 6
BITS = 8
PRE_END_TB = 12
PRE_ON = 7
PRE_OFF = 8
SLV_ON = 3
SLV_OFF = 5
EXTRA_P = 20
GAP_N = 3
ST_N = 4

PD = [0x00, 0x00, 0x5A, 0xC3, 0x3C, 0x5A, 0x4C, 0x0F, 0x51]
CRCB = PD[8]
PDB4 = 0x34                   # PD[4] with bit 3 corrupted on the wire
SEED = 0x0BE512F5

BEATS = []                    # (tick, clk_en, slave_low, cmd_valid, cmd,
CHECKS = []                   #  wdata, crc_en, crc_end) triples per beat


def rev8(v):
    r = 0
    for i in range(8):
        r = u((r << 1) | ((v >> i) & 1), 8)
    return r


def crc_feed(acc, byte):
    """Normal-form (MSB first) division of the bit-reversed byte by
    g(x) = x^8 + x^5 + x^4 + 1, i.e. 0x31 without the leading x^8 term."""
    data = rev8(byte)
    for i in range(7, -1, -1):
        fb = ((acc >> 7) & 1) ^ ((data >> i) & 1)
        acc = u((acc << 1) & 0xFF, 8) ^ (0x31 if fb else 0)
        acc &= 0xFF
    return acc


def crc8(data):
    """Maxim / DS28EC01 CRC-8 of a byte list, by way of the normal-form
    generator: the remainder is reflected on the way out."""
    acc = 0
    for byte in data:
        acc = crc_feed(acc, byte)
    return rev8(acc)


def crc_step(crc, byte):
    """Advance a Maxim CRC-8 accumulator, kept in the reflected form the pad
    contract uses, by one whole byte.  The core does this one bit at a time with
    the reflected generator polynomial; doing it byte-wise through the
    normal-form generator is the same code checked from the other direction."""
    return rev8(crc_feed(rev8(crc), byte))


def check_stimulus():
    """The scratchpad block is built from the standard, so verify the standard."""
    assert crc8([ord(c) for c in '123456789']) == 0xA1
    assert crc8(PD[:8]) == CRCB
    assert crc8(PD) == 0x00                     # good block residue
    run = 0
    for byte in PD:
        run = crc_step(run, byte)
    assert run == crc8(PD)                      # byte-wise == whole-block
    bad = list(PD)
    bad[4] = PDB4
    assert crc8(bad) != 0x00                    # corrupted block residue


def slv_low(sd, j, q, md):
    """Does the slave pull the line down in phase (j, q) of a read byte?"""
    if (sd >> j) & 1:
        return 0                                # a 1 bit is never driven low
    if md == M_WIDE:
        return 1 if (SLV_ON <= q <= SLV_OFF) else 0
    if md == M_NARROW:
        return 1 if q == SLV_ON else 0
    return 0                                    # M_NONE / M_DEAD never answer


def beat(tick=1, en=1, slv=0, cv=0, cmd=0, dat=0, cren=0, cend=0):
    BEATS.append((tick, en, slv, cv, cmd, dat, cren, cend))


def repeat_last(count, **change):
    prev = BEATS[-1]
    for _ in range(count):
        beat(tick=change.get('tick', prev[0]), en=change.get('en', prev[1]),
             slv=prev[2], cv=prev[3], cmd=prev[4], dat=prev[5],
             cren=prev[6], cend=prev[7])


def rst_ent(pre, gapf, stf):
    beat(cv=1, cmd=CMD_RST)
    for p in range(PRE_END_TB + 1):
        beat(slv=1 if (pre and PRE_ON <= p <= PRE_OFF) else 0)
        if gapf and p == PRE_ON:
            repeat_last(GAP_N, tick=0)
        if stf and p == 9:
            repeat_last(ST_N, en=0)


def byte_ent(cm, dt, sd, md, ce, cd, coll, gapf, stf, kind):
    beat(cv=1, cmd=cm, dat=dt, cren=ce, cend=cd)
    for p in range(SLOT * BITS):
        j = p // SLOT
        q = p % SLOT
        cv = 1 if (coll and p == EXTRA_P) else 0
        slv = slv_low(sd, j, q, md) if cm == CMD_RD else 0
        beat(cv=cv, cmd=CMD_WR if cv else 0, slv=slv)
        if gapf and p == SLOT + SLV_ON:
            repeat_last(GAP_N, tick=0)
        if stf and p == 3 * SLOT + 1:
            repeat_last(ST_N, en=0)
    if kind:
        CHECKS.append((len(BEATS) - 1, kind))


def bad_ent():
    beat(cv=1, cmd=0, dat=0xA5)


def build_plan():
    del BEATS[:]
    del CHECKS[:]
    state = SEED
    rst_ent(1, 0, 0)                            # presence detected
    byte_ent(CMD_WR, 0xF3, 0, M_NONE, 0, 0, 0, 0, 0, 0)
    for k in range(9):                          # good scratchpad block
        byte_ent(CMD_RD, 0, PD[k], M_WIDE, 1, k == 8, 0, k == 4, k == 1,
                 1 if k == 8 else 0)
    rst_ent(0, 1, 0)                            # no presence -> error path
    rst_ent(1, 0, 1)
    state = lcg32(state)
    byte_ent(CMD_WR, state & 0xFF, 0, M_NONE, 0, 0, 1, 0, 0, 0)
    state = lcg32(state)
    byte_ent(CMD_RD, 0, state & 0xFF, M_DEAD, 0, 0, 0, 0, 0, 0)
    bad_ent()
    for k in range(9):                          # corrupted block -> CRC flag
        byte_ent(CMD_RD, 0, PDB4 if k == 4 else PD[k], M_WIDE, 1, k == 8, 0, 0,
                 k == 6, 2 if k == 8 else 0)
    state = lcg32(state)
    byte_ent(CMD_RD, 0, 0x5A, M_NARROW, 0, 0, 0, 1, 0, 0)
    state = lcg32(state)
    byte_ent(CMD_RD, 0, 0x0F, M_NARROW, 0, 0, 0, 0, 1, 0)
    rst_ent((state >> 20) & 1, 0, 0)            # LCG-selected presence
    for k in range(4):                          # short block -> length flag
        state = lcg32(state)
        byte_ent(CMD_RD, 0, state & 0xFF, M_WIDE, 1, k == 3, 0, 0, 0,
                 3 if k == 3 else 0)
    state = lcg32(state)
    byte_ent(CMD_WR, (state >> 8) & 0xFF, 0, M_NONE, 1, 0, 0, 0, 0, 0)
    state = lcg32(state)
    byte_ent(CMD_RD, 0, state & 0xFF, M_NARROW, 1, 0, 0, 0, 0, 0)
    rst_ent(1, 0, 0)
    return state


def drive(st):
    """ow_oe: the pad pulls low while the master is inside its low window."""
    if st['state'] == S_RST:
        return 1 if st['tc'] < RST_LOW else 0
    if st['state'] == S_WBIT:
        low = W1_LOW if (st['tx'] & 1) else W0_LOW
    elif st['state'] == S_RBIT:
        low = RD_LOW
    else:
        return 0
    return 1 if st['tc'] < low else 0


def bump_err(st):
    if st['err'] != 0xF:
        st['err'] = u(st['err'] + 1, 4)


def step(st, tick, slv, cv, cmd, dat, cren, cend):
    if not tick:
        return                                  # the whole engine freezes
    pin = 0 if (drive(st) or slv) else 1        # open drain, pre-edge drive
    st['done'] = 0
    if cv and st['state'] != S_IDLE:
        st['busy'] = 1
        bump_err(st)
    if st['state'] == S_IDLE:
        if cv:
            st['tc'] = 0
            st['bit_idx'] = 0
            st['cren_q'] = cren
            st['cend_q'] = cend
            if cren and st['byte_count'] == 0:
                st['crc'] = 0
            if cmd == CMD_RST:
                st['state'] = S_RST
            elif cmd == CMD_WR:
                st['state'] = S_WBIT
                st['tx'] = dat
                st['tx_byte'] = dat
            elif cmd == CMD_RD:
                st['state'] = S_RBIT
            else:
                st['bad_cmd'] = 1
                bump_err(st)
    elif st['state'] == S_RST:
        if st['tc'] == PRE_SMP:
            st['presence'] = 1 - pin
            if pin:
                st['nopre'] = 1
                bump_err(st)
        if st['tc'] == PRE_END:
            st['state'] = S_IDLE
            st['done'] = 1
            if st['rst_c'] != 0xF:
                st['rst_c'] = u(st['rst_c'] + 1, 4)
        else:
            st['tc'] = u(st['tc'] + 1, 6)
    else:
        if st['tc'] == RD_SMP and st['state'] == S_RBIT:
            st['rx'] = u((pin << 7) | (st['rx'] >> 1), 8)
        if st['tc'] == SLOT_END:
            if st['state'] == S_WBIT:
                st['tx'] = st['tx'] >> 1
            if st['bit_idx'] == BIT_LAST:
                was_read = st['state'] == S_RBIT
                st['state'] = S_IDLE
                st['done'] = 1
                if st['cren_q']:
                    # the eight bits of this byte are complete here: the ones
                    # sampled off the pad for a read slot, the byte presented on
                    # wdata for a write slot
                    st['crc'] = crc_step(st['crc'],
                                         st['rx'] if was_read else st['tx_byte'])
                if st['cend_q']:
                    blk = u(st['byte_count'] + 1, 4) if st['cren_q'] \
                        else st['byte_count']
                    if blk != CRC_BYTES:
                        st['len_st'] = 1
                        bump_err(st)
                    elif st['crc'] != 0:
                        st['crc_st'] = 1
                        if st['crc_c'] != 0xF:
                            st['crc_c'] = u(st['crc_c'] + 1, 4)
                    st['byte_count'] = 0
                elif st['cren_q']:
                    st['byte_count'] = u(st['byte_count'] + 1, 4)
            else:
                st['bit_idx'] = u(st['bit_idx'] + 1, 3)
                st['tc'] = 0
        else:
            st['tc'] = u(st['tc'] + 1, 6)


def fold(st):
    w1 = u((st['tc'] << 8) | (st['bit_idx'] << 5) | (st['state'] << 2) |
           (drive(st) << 1) | st['done'], 32)
    w2 = u((st['rx'] << 12) | (st['tx'] << 4) | st['byte_count'], 32)
    w3 = u((st['nopre'] << 17) | (st['crc_st'] << 16) | (st['len_st'] << 15) |
           (st['busy'] << 14) | (st['bad_cmd'] << 13) | (st['presence'] << 12) |
           (st['rst_c'] << 8) | (st['crc_c'] << 4) | st['err'], 32)
    return w1, w2, w3


def main():
    check_stimulus()
    state = build_plan()
    st = dict(state=S_IDLE, tc=0, bit_idx=0, rx=0, tx=0, tx_byte=0, crc=0,
              byte_count=0, presence=0, nopre=0, crc_st=0, len_st=0, busy=0,
              bad_cmd=0, rst_c=0, crc_c=0, err=0, cren_q=0, cend_q=0, done=0)
    words = []
    for tick, en, slv, cv, cmd, dat, cren, cend in BEATS:
        if en:
            step(st, tick, slv, cv, cmd, dat, cren, cend)
        for w in fold(st):
            words.append(w)
        if st['done']:
            words.append(u(st['crc'], 32))
    words.append(u(len(BEATS), 32))
    words.append(u(((state & 7) << 12) | (st['rst_c'] << 8) |
                   (st['crc_c'] << 4) | st['err'], 32))
    emit('ips_one_wire_master', words)


if __name__ == '__main__':
    main()
