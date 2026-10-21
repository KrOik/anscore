#!/usr/bin/env python3
# Cycle-level emulator of win3x3_gen + img_stim to test which hypothetical
# BSRAM behaviour reproduces the on-board digest DCD0334D.
# Latency model: lb read issued at beat T normally yields q at T+1
# (LAT=1, sim behaviour). LAT=2 means q reflects the address issued 2 beats
# ago (extra output register stage on silicon).
import sys

W = H = 16
LAT = int(sys.argv[1]) if len(sys.argv) > 1 else 1
WRITETHRU = len(sys.argv) > 2 and sys.argv[2] == "wt"

def stim_pixels():
    """return list of beats: ('nl',) or ('pix',v) -- one per ce beat"""
    beats = []
    for y in range(H):
        beats.append(('nl',))
        for x in range(W):
            base = (x + (x << 4)) ^ (y + (y << 3) + (y << 5)) ^ ((x & y) << 3)
            base &= 0xFF
            if 6 <= x <= 9 and 5 <= y <= 10:
                base = (base + 0x50) & 0xFF
            beats.append(('pix', base))
    return beats

def fnv(h, b):
    x = h ^ b
    return (x + (x << 1) + (x << 4) + (x << 7) + (x << 8) + (x << 24)) & 0xFFFFFFFF

def run():
    beats = stim_pixels()
    mem0 = [0] * W
    mem1 = [0] * W
    # read pipeline: list of (addr, mem_id) snapshots; depth LAT
    pipe0, pipe1 = [], []
    lb0_q = lb1_q = 0
    in_col = 0
    in_row = -1
    flushing = False
    fl_cnt = 0
    done = False
    sh_pend = False
    col_d = row_d = 0
    ph_d = sf_d = False
    pix_d = 0
    rt0 = rt1 = rt2 = [0, 0, 0]   # [oldest, mid, newest]
    windows = []
    bi = 0
    steps = 0
    while not done and steps < 20000:
        steps += 1
        beat = beats[bi] if bi < len(beats) else ('idle',)
        if beat[0] != 'idle':
            bi += 1
        pix = beat[1] if beat[0] == 'pix' else 0
        pix_valid = beat[0] == 'pix'
        new_line = beat[0] == 'nl'

        # ----- stage A source select (comb) -----
        take_pix = pix_valid and not flushing and not done and \
                   (in_col < W or (in_col == W + 1 and in_row < H - 1))
        cap_phant = (not flushing) and not done and in_col == W
        wait_nl = (not flushing) and not done and in_col == W + 1
        fl_issue = flushing and fl_cnt <= W
        cap_any = take_pix or cap_phant or fl_issue
        lb_re = take_pix or (fl_issue and fl_cnt < W)
        if flushing:
            lb_raddr = fl_cnt
        elif in_col == W + 1:
            lb_raddr = 0
        else:
            lb_raddr = in_col

        # ----- stage B comb -----
        do_shift = sh_pend
        tap_top = rt0[2] if ph_d else lb1_q
        tap_mid = rt1[2] if ph_d else lb0_q
        tap_bot = rt2[2] if ph_d else (lb0_q if sf_d else pix_d)
        emit_ok = do_shift and not done and 1 <= row_d <= H and \
                  (ph_d or col_d >= 1)
        emit_x = W - 1 if ph_d else col_d - 1
        lb_we = do_shift and not ph_d and not sf_d
        lb0_wd = pix_d
        lb1_wd = pix_d if row_d == 0 else lb0_q

        # ----- clock edge: RAM -----
        # read pipeline advance (LAT stages); head = q
        if lb_re:
            pipe0.append(lb_raddr)
            pipe1.append(lb_raddr)
        else:
            pipe0.append(None)
            pipe1.append(None)
        if len(pipe0) > LAT:
            a = pipe0.pop(0)
            if a is not None:
                lb0_q = mem0[a] if not (WRITETHRU and lb_we and col_d == a) \
                        else lb0_wd
            a = pipe1.pop(0)
            if a is not None:
                lb1_q = mem1[a] if not (WRITETHRU and lb_we and col_d == a) \
                        else lb1_wd
        # writes
        if lb_we:
            mem0[col_d] = lb0_wd
            mem1[col_d] = lb1_wd

        # ----- sequential A -----
        if take_pix:
            pix_d = pix; ph_d = False; sf_d = False
            if in_col >= W:
                col_d = 0; row_d = in_row + 1; in_col = 1
                if not new_line:
                    in_row += 1
            else:
                col_d = in_col; row_d = in_row; in_col += 1
        elif cap_phant:
            col_d = W; row_d = in_row; ph_d = True; sf_d = False
            in_col = W + 1
        elif fl_issue:
            col_d = W if fl_cnt == W else fl_cnt
            row_d = H; ph_d = (fl_cnt == W); sf_d = True
            fl_cnt += 1
        sh_pend = cap_any
        if new_line and not flushing and not done:
            in_col = 0; in_row += 1
        if wait_nl and in_row == H - 1:
            flushing = True; fl_cnt = 0
        if flushing and fl_cnt == W + 1:
            flushing = False
        if do_shift and ph_d and row_d == H:
            done = True

        # ----- sequential B -----
        if do_shift:
            rt0 = [rt0[1], rt0[2], tap_top]
            rt1 = [rt1[1], rt1[2], tap_mid]
            rt2 = [rt2[1], rt2[2], tap_bot]
            wn0 = [rt0[0], rt0[1], tap_top]   # post-shift view
            # window uses PRE-shift rt + new tap: replicate RTL exactly:
        if do_shift:
            # RTL computes wn* from PRE-edge rt then registers win
            pass
        if emit_ok:
            # reconstruct wn from pre-shift rt (we saved it below)
            pass

        # To keep it simple recompute window BEFORE updating rt:
        # (rerun comb with pre-edge rt)
        # -- handled inline above? do it explicitly:
        # (this loop section intentionally left; see run2 below)
        break  # placeholder
    return windows, done

# The inline approach above is error prone; implement cleanly:
def run2():
    beats = stim_pixels()
    mem0 = [0] * W
    mem1 = [0] * W
    pipe0, pipe1 = [], []
    lb0_q = lb1_q = 0
    in_col, in_row = 0, -1
    flushing, fl_cnt, done = False, 0, False
    sh_pend = False
    col_d = row_d = 0
    ph_d = sf_d = False
    pix_d = 0
    rt0 = [0, 0, 0]; rt1 = [0, 0, 0]; rt2 = [0, 0, 0]
    h = 0x811c9dc5
    nwin = 0
    bi = 0
    steps = 0
    while not done and steps < 40000:
        steps += 1
        beat = beats[bi] if bi < len(beats) else ('idle',)
        if beat[0] != 'idle':
            bi += 1
        pix = beat[1] if beat[0] == 'pix' else 0
        pix_valid = beat[0] == 'pix'
        new_line = beat[0] == 'nl'

        take_pix = pix_valid and not flushing and not done and \
                   (in_col < W or (in_col == W + 1 and in_row < H - 1))
        cap_phant = (not flushing) and not done and in_col == W
        wait_nl = (not flushing) and not done and in_col == W + 1
        fl_issue = flushing and fl_cnt <= W
        cap_any = take_pix or cap_phant or fl_issue
        lb_re = take_pix or (fl_issue and fl_cnt < W)
        if flushing:
            lb_raddr = fl_cnt
        elif in_col == W + 1:
            lb_raddr = 0
        else:
            lb_raddr = in_col

        do_shift = sh_pend
        tap_top = rt0[2] if ph_d else lb1_q
        tap_mid = rt1[2] if ph_d else lb0_q
        tap_bot = rt2[2] if ph_d else (lb0_q if sf_d else pix_d)
        wn0 = [rt0[1], rt0[2], tap_top]
        wn1 = [rt1[1], rt1[2], tap_mid]
        wn2 = [rt2[1], rt2[2], tap_bot]
        emit_ok = do_shift and not done and 1 <= row_d <= H and \
                  (ph_d or col_d >= 1)
        emit_x = W - 1 if ph_d else col_d - 1
        lb_we = do_shift and not ph_d and not sf_d
        lb0_wd = pix_d
        lb1_wd = pix_d if row_d == 0 else lb0_q

        # window taps (RTL: oldest=wn[0]? win[7:0]=oldest of top row etc)
        if emit_ok:
            if emit_x == 0:
                taps = [wn0[1], wn0[1], wn0[2],
                        wn1[1], wn1[1], wn1[2],
                        wn2[1], wn2[1], wn2[2]]
            else:
                taps = [wn0[0], wn0[1], wn0[2],
                        wn1[0], wn1[1], wn1[2],
                        wn2[0], wn2[1], wn2[2]]
            for t in taps:
                h = fnv(h, t)
            nwin += 1

        # RAM: advance read pipe, then writes
        pipe0.append(lb_raddr if lb_re else None)
        pipe1.append(lb_raddr if lb_re else None)
        if len(pipe0) > LAT:
            a = pipe0.pop(0)
            if a is not None:
                if WRITETHRU and lb_we and col_d == a:
                    lb0_q = lb0_wd
                else:
                    lb0_q = mem0[a]
            a = pipe1.pop(0)
            if a is not None:
                if WRITETHRU and lb_we and col_d == a:
                    lb1_q = lb1_wd
                else:
                    lb1_q = mem1[a]
        if lb_we:
            mem0[col_d] = lb0_wd & 0xFF
            mem1[col_d] = lb1_wd & 0xFF

        if take_pix:
            pix_d = pix; ph_d = False; sf_d = False
            if in_col >= W:
                col_d = 0; row_d = in_row + 1; in_col = 1
                if not new_line:
                    in_row += 1
            else:
                col_d = in_col; row_d = in_row; in_col += 1
        elif cap_phant:
            col_d = W; row_d = in_row; ph_d = True; sf_d = False
            in_col = W + 1
        elif fl_issue:
            col_d = W if fl_cnt == W else fl_cnt
            row_d = H; ph_d = (fl_cnt == W); sf_d = True
            fl_cnt += 1
        sh_pend = cap_any
        if new_line and not flushing and not done:
            in_col = 0; in_row += 1
        if wait_nl and in_row == H - 1:
            flushing = True; fl_cnt = 0
        if flushing and fl_cnt == W + 1:
            flushing = False
        if do_shift and ph_d and row_d == H:
            done = True
        if do_shift:
            rt0 = wn0; rt1 = wn1; rt2 = wn2
    return h, nwin, done

if __name__ == "__main__":
    h, nwin, done = run2()
    print(f"LAT={LAT} wt={WRITETHRU}: windows={nwin} done={done} "
          f"digest={h:08X}  (target BD71944D sim / DCD0334D hw)")
