"""Deterministic real-time control kernels: motion, timing, arbitration, safety.

Each core here is an enabled-beat control step: one accepted (a,b,c) triple
advances one real-time algorithm by exactly one cycle at II=1, with the state
update, the limit check and the fault report all inside one combinational cone.
The sibling library's control cores are single-shot accounting units
(debounce_word, token_bucket, round_robin8, hysteresis, sticky_event,
event_counter, watermark, first_fault, stream_credit32, range_guard32); these six
are structurally different: multi-lane rate governors, per-channel windowed
supervision, credit-plus-fairness accounting and a signed phase/dither datapath.

State stays narrow on purpose: cores are packed 8 per board group under a
15000-LUT-class budget, so no core keeps more than 120 state bits and none uses a
multiplier or a divider; every programmed gain is an explicit shift.

Body vocabulary (declared by the template, reset each evaluation):
    r x                       result/aux registers, 32 bit
    f                         fault flag
    temp mask pa pb pc ph pl  32-bit unsigned temporaries
    ext                       33-bit unsigned (carry capture)
    wide wide2                64-bit unsigned
    swide swide2              64-bit signed
    sa sb sc                  $signed(a), $signed(b), $signed(c)
    data                      {a,b,c} as one 96-bit word
    i j idx lane sh           integers
    state_r state_n           256-bit state; only accepted beats commit it
"""
from random import Random

FAMILY = 'control'
MASK = (1 << 32) - 1

CORES = []


def core(name, spec, body, advantage, lanes, **kwargs):
    CORES.append(dict(name=name, family=FAMILY, spec=spec, body=body,
                      advantage=advantage, lanes=lanes, **kwargs))


# ---------------------------------------------------------------- 1 phase NCO
core('ctl_phase_nco32',
     'Direct digital synthesis phase step. state[31:0]=phase P, state[39:32]=W, a '
     'saturating count of wrap events. a[31:0]=tuning word (also the reload value). '
     'b[15:0]=signed two-complement phase dither, b[16]=1 steps P downwards, '
     'b[31:17] must be zero. c[31]=1 reloads P:=a and W:=0 and emits no step, c[30:0] '
     'must be zero. Otherwise P := (P + (b[16] ? -a : a) + dither) mod 2^32, free '
     'running with no overflow fault, and W := min(W + wrap events, 255) where each '
     'crossing of a 2^32 boundary is one event, up to two per beat. result=new P. '
     'aux[1:0]=quadrant P[31:30], aux[2]=wrapped upward, aux[3]=wrapped below zero, '
     'aux[4]=W saturated, aux[15:8]=W, aux[16]=reload applied. Any non-zero reserved '
     'bit is a malformed control word: f=1, the beat is rejected with P and W held, '
     'result=held P and aux[1:0] plus aux[15:8] echo the held quadrant and count. '
     'event_counter and token_bucket in the sibling library add a word to a scalar '
     'budget; this is a 32-bit signed-dither accumulator reporting quadrant and '
     'carry count in the same beat.',
     '''
if ((b[31:17] != 0) || (c[30:0] != 0)) begin
    f = 1'b1;
    r = state_r[31:0];
    x[1:0] = state_r[31:30];
    x[15:8] = state_r[39:32];
end
else if (c[31]) begin
    r = a;
    x[1:0] = a[31:30];
    x[16] = 1'b1;
    state_n[31:0] = a;
    state_n[39:32] = 8'd0;
end
else begin
    swide = $signed({1'b0, state_r[31:0]});
    if (b[16]) swide = swide - $signed({1'b0, a});
    else swide = swide + $signed({1'b0, a});
    swide = swide + {{48{b[15]}}, b[15:0]};
    r = swide[31:0];
    x[1:0] = swide[31:30];
    state_n[31:0] = swide[31:0];
    swide2 = swide >>> 32;
    if (swide2 < 0) begin swide2 = -swide2; x[3] = 1'b1; end
    else if (swide2 != 0) x[2] = 1'b1;
    pa = {24'd0, state_r[39:32]} + {28'd0, swide2[3:0]};
    if (pa[8]) begin temp = 32'd255; x[4] = 1'b1; end
    else temp = pa;
    state_n[39:32] = temp[7:0];
    x[15:8] = temp[7:0];
end
''',
     'A DDS or stepper axis must add a 32-bit tuning word, a signed dither and a '
     'wrap count every reference cycle; a software loop pays a branch and a '
     'multi-word fixup per step and jitters, this emits phase plus quadrant at II=1.',
     1, stateful=True)


# ------------------------------------------------------- 2 quadrature decoder
core('ctl_quadrature_decoder',
     'Eight-sample Gray quadrature walk. state[31:0]=position P (two-complement, '
     'free running modulo 2^32), state[33:32]=last AB state L, state[39:36]=illegal '
     'transition count E saturating at 15. a[1:0]=oldest sample through a[15:14]= '
     'newest, one pair per sample with A on the high bit; a[31:16] must be zero. The '
     'cycle order 00,01,11,10 is forward and adds 1, its reverse adds -1, and a '
     'transition where both bits change at once (00 to 11 or 11 to 00) is illegal: '
     'that sample adds no delta, raises f, marks the bitmap and bumps E. A repeated '
     'sample adds no delta. c[31]=1 zeroes P before the walk, c[30]=1 preloads P from '
     'b[31:0] and is ignored when c[31] is set, c[29:0] ignored. result=new P. '
     'aux[7:0]=per-sample reverse bitmap, aux[15:8]=per-sample changed bitmap, '
     'aux[23:16]=per-sample illegal bitmap, aux[25:24]=AB state after the walk, '
     'aux[26]=preload or reset applied, aux[27]=E saturated, aux[31:28]=E. Non-zero '
     'a[31:16] is malformed: f=1, the beat is rejected and result and aux echo the '
     'held P, L and E. sticky_event and event_counter in the sibling library see one '
     'word per beat; this walks eight edges per beat with a per-edge fault '
     'classification.',
     '''
if (a[31:16] != 0) begin
    f = 1'b1;
    r = state_r[31:0];
    x[25:24] = state_r[33:32];
    x[31:28] = state_r[39:36];
end
else begin
    if (c[31]) swide = 64'sd0;
    else if (c[30]) swide = $signed(b);
    else swide = $signed({{32{state_r[31]}}, state_r[31:0]});
    mask = state_r[33:32];
    pc = 0;
    for (i = 0; i < 8; i = i + 1) begin
        idx = a[2*i +: 2];
        if (idx != mask) begin
            x[i+8] = 1'b1;
            pb = mask ^ (mask >> 1);
            ph = idx ^ (idx >> 1);
            temp = (pb + 1) & 3;
            if (ph == temp) swide = swide + 1;
            else begin
                temp = (pb + 2) & 3;
                if (ph == temp) begin
                    x[i+16] = 1'b1;
                    f = 1'b1;
                    pc = pc + 1;
                end
                else begin
                    swide = swide - 1;
                    x[i] = 1'b1;
                end
            end
        end
        mask = idx;
    end
    r = swide[31:0];
    state_n[31:0] = swide[31:0];
    state_n[33:32] = mask[1:0];
    x[25:24] = mask[1:0];
    temp = {28'd0, state_r[39:36]} + {28'd0, pc[3:0]};
    if (temp > 32'd15) begin
        temp = 32'd15;
        x[27] = 1'b1;
    end
    state_n[39:36] = temp[3:0];
    x[31:28] = temp[3:0];
    x[26] = c[31] | c[30];
end
''',
     'Eight encoder edges are walked and fault-classified in one beat with an exact '
     'per-edge bitmap, so a servo loop cannot miss a glitch the way a polled '
     'software decoder does between two interrupts.', 8, stateful=True)


# ---------------------------------------------------------- 3 slew limiter
core('ctl_slew_limiter_s16',
     'Two independent signed 16-bit slew limiters with asymmetric bounds. '
     'state[15:0]=lane0 output y0, state[31:16]=lane1 output y1, both two-complement. '
     'a[15:0]=lane0 target, a[31:16]=lane1 target. Lane0 rise limit R0=c[13:0] and '
     'fall limit F0=c[29:16]; lane1 rise limit R1=b[13:0] and fall limit F1=b[29:16]. '
     'All four are unsigned maximum steps per accepted beat; other bits of b and c '
     'are ignored except the command bits. c[31]=1 bypasses the limiter, so y:=target '
     'this beat with no clip fault. c[30]=1 freezes both outputs at their held '
     'values. Otherwise, per lane: if R and F are both zero the limit word is '
     'malformed, that lane holds and f=1 while the other lane still updates; else '
     'y := y+R when (target-y)>R, y := y-F when (target-y)<-F, otherwise y := target. '
     'A clipped lane always faults, and a clipped step never leaves the signed 16 '
     'range because the target is inside it. result=updated outputs with lane0 in '
     '[15:0]. aux[1:0]=lanes rise-clipped, aux[3:2]=lanes fall-clipped, aux[5:4]=lanes '
     'settled exactly on target, aux[6]=bypass applied, aux[7]=freeze applied, '
     'aux[9:8]=lanes with a malformed limit word, aux[31:10]=0. hysteresis32 and '
     'range_guard32 in the sibling library classify one unsigned word once; this is a '
     'per-beat dual-lane rate governor that owns its output state.',
     '''
for (lane = 0; lane < 2; lane = lane + 1) begin
    if (lane == 0) begin pa = c[13:0]; pb = c[29:16]; end
    else begin pa = b[13:0]; pb = b[29:16]; end
    if (c[31]) begin
        r[lane*16 +: 16] = a[lane*16 +: 16];
        state_n[lane*16 +: 16] = a[lane*16 +: 16];
        x[6] = 1'b1;
        x[4+lane] = 1'b1;
    end
    else if (c[30]) begin
        r[lane*16 +: 16] = state_r[lane*16 +: 16];
        state_n[lane*16 +: 16] = state_r[lane*16 +: 16];
        x[7] = 1'b1;
        x[4+lane] = (a[lane*16 +: 16] == state_r[lane*16 +: 16]);
    end
    else if ((pa == 0) && (pb == 0)) begin
        r[lane*16 +: 16] = state_r[lane*16 +: 16];
        state_n[lane*16 +: 16] = state_r[lane*16 +: 16];
        x[8+lane] = 1'b1;
        f = 1'b1;
    end
    else begin
        swide = $signed({{48{a[lane*16+15]}}, a[lane*16 +: 16]})
              - $signed({{48{state_r[lane*16+15]}}, state_r[lane*16 +: 16]});
        if (swide > $signed({32'd0, pa})) begin
            swide2 = $signed({{48{state_r[lane*16+15]}}, state_r[lane*16 +: 16]})
                   + $signed({32'd0, pa});
            r[lane*16 +: 16] = swide2[15:0];
            state_n[lane*16 +: 16] = swide2[15:0];
            x[lane] = 1'b1;
            f = 1'b1;
        end
        else if (swide < -$signed({32'd0, pb})) begin
            swide2 = $signed({{48{state_r[lane*16+15]}}, state_r[lane*16 +: 16]})
                   - $signed({32'd0, pb});
            r[lane*16 +: 16] = swide2[15:0];
            state_n[lane*16 +: 16] = swide2[15:0];
            x[2+lane] = 1'b1;
            f = 1'b1;
        end
        else begin
            r[lane*16 +: 16] = a[lane*16 +: 16];
            state_n[lane*16 +: 16] = a[lane*16 +: 16];
            x[4+lane] = 1'b1;
        end
    end
end
''',
     'Axis commands and drive setpoints must be rate limited every cycle with '
     'different up and down bounds; two lanes with their own clip flags land in one '
     'beat instead of a branchy clamp routine per axis.', 2, stateful=True)


# ------------------------------------------------------------- 4 PID form
core('ctl_pid_form_s16',
     'Two fixed-structure PID controllers, no multipliers. state[15:0]=previous error '
     'lane0, state[31:16]=previous error lane1 (signed 16), state[63:32]=integral '
     'accumulator lane0 and state[95:64]=integral accumulator lane1 (signed 32, '
     'clamped to plus or minus (2^23-1)). a[15:0]=error lane0, a[31:16]=error lane1. '
     'Shift gains, all arithmetic right shifts of two-complement values: b[3:0]=sP '
     'gives proportional term e>>>sP, b[7:4]=sI gives integral increment e>>>sI, '
     'b[11:8]=sD gives derivative term (e-e_prev)>>>sD, b[15:12]=sO is the output '
     'shift, b[18:16]=sK sets the derivative-kick threshold 1<<(15-sK). b[31:19] '
     'ignored. c[31]=1 restarts: the integral begins at zero before this beat '
     'increment, the derivative term is forced to zero and the stored error is '
     're-baselined. c[30]=1 freezes the integral accumulator. Other c bits ignored. '
     'Per lane acc := clamp(acc + (e>>>sI), -(2^23-1), 2^23-1) unless frozen or '
     'restarted, then u := (e>>>sP) + acc + ((e-e_prev)>>>sD), u := u>>>sO and '
     'finally u clamped to signed 16. result=u with lane0 in [15:0] and lane1 in '
     '[31:16]. aux[1:0]=lanes whose integral clamped, aux[3:2]=lanes whose output '
     'clamped, aux[5:4]=lanes with a derivative kick, aux[7:6]=lanes with a non-zero '
     'derivative term, aux[9:8]=lanes whose integral accumulator is negative, '
     'aux[10]=restart applied, aux[11]=integral frozen, aux[12]=both accumulators '
     'zero, aux[27:16]=b[15:4] gain config echo, other bits 0. fault=derivative kick '
     'on a restart beat, that is a lane whose absolute error change reached the '
     'threshold at the moment its derivative history was thrown away; saturation only '
     'sets aux flags. hysteresis32 and stream_credit32 in the sibling library are '
     'single-window compare or ledger cores; this is a two-lane controller form with '
     'windup accounting.',
     '''
for (lane = 0; lane < 2; lane = lane + 1) begin
    temp = a[lane*16 +: 16];
    mask = state_r[lane*16 +: 16];
    pa = {{16{temp[15]}}, temp[15:0]};
    pb = {{16{mask[15]}}, mask[15:0]};
    if (c[31]) begin
        swide2 = $signed(pa) - $signed(pb);
        if (swide2 < 0) swide2 = -swide2;
        if (swide2 >= (64'sd1 <<< (32'd15 - b[18:16]))) begin
            x[4+lane] = 1'b1;
            f = 1'b1;
        end
    end
    swide = $signed(pa) - $signed(pb);
    if (c[31]) swide = 0;
    sh = b[11:8];
    swide = swide >>> sh;
    swide2 = swide;
    if (swide != 0) x[6+lane] = 1'b1;
    if (c[31]) swide = 0;
    else swide = $signed(state_r[32 + 32*lane +: 32]);
    if (!c[30]) begin
        sh = b[7:4];
        swide = swide + ($signed(pa) >>> sh);
        if (swide > 64'sd8388607) begin
            swide = 64'sd8388607;
            x[lane] = 1'b1;
        end
        else if (swide < -64'sd8388607) begin
            swide = -64'sd8388607;
            x[lane] = 1'b1;
        end
    end
    state_n[32 + 32*lane +: 32] = swide[31:0];
    if (swide[31]) x[8+lane] = 1'b1;
    swide2 = swide2 + swide;
    sh = b[3:0];
    swide2 = swide2 + ($signed(pa) >>> sh);
    sh = b[15:12];
    swide2 = swide2 >>> sh;
    if (swide2 > 64'sd32767) begin
        swide2 = 64'sd32767;
        x[2+lane] = 1'b1;
    end
    else if (swide2 < -64'sd32768) begin
        swide2 = -64'sd32768;
        x[2+lane] = 1'b1;
    end
    r[lane*16 +: 16] = swide2[15:0];
    state_n[lane*16 +: 16] = temp[15:0];
end
x[10] = c[31];
x[11] = c[30];
x[27:16] = b[15:4];
if ((state_n[63:32] == 0) && (state_n[95:64] == 0)) x[12] = 1'b1;
''',
     'A dual-axis loop needs three shift-scaled terms, an anti-windup accumulator and '
     'a kick detector every cycle; the fabric adds them in one beat with no multiply '
     'and no sampling jitter.', 2, stateful=True)


# ------------------------------------------------------- 5 credit arbiter
core('ctl_credit_arb8',
     'Eight-port credit-based round-robin arbiter with fairness accounting. '
     'state[31:0]=credits, four bits per port (0 to 15, port k at state[4k+3:4k]); '
     'state[34:32]=round-robin pointer; state[36+3k+2:36+3k]=port k consecutive '
     'pass-over count, 0 to 7. a[7:0]=request vector, a[15:8]=credit deposits (+1 per '
     'set bit, saturating at 15), a[23:16]=credit withdrawals (-1 per set bit, floored '
     'at 0), a[31:24] ignored. b[7:0]=port enable mask, b[15:8]=starvation threshold '
     'T, b[31:16] ignored. c[31]=1 is an arm beat: port k credit becomes c[3k+2:3k], '
     'the pointer becomes c[26:24], every pass-over count clears, and no arbitration '
     'or ledger movement happens that beat. On any other beat the ledger is applied '
     'first (deposit, saturate at 15, then withdraw), a port is eligible when it '
     'requests, is enabled and holds a non-zero updated credit, and the grant is the '
     'first eligible port scanning upward from the pointer modulo 8, so the grant is '
     'exactly one-hot or none. The granted port pays one credit and the pointer '
     'becomes grant plus 1 modulo 8. A port that is enabled and requesting but holds '
     'zero credit raises f, and the beat still resolves for the other ports. '
     'result[7:0]=one-hot grant, result[15:8]=non-zero credit bitmap after the beat, '
     'result[23:16]=sum of remaining credits, result[31:24]=number of enabled '
     'requesters. aux[2:0]=next pointer, aux[5:3]=granted port index or 7 when none, '
     'aux[6]=grant issued, aux[7]=arm beat, aux[15:8]=eligible-but-skipped bitmap, '
     'aux[23:16]=starving bitmap (pass-over count non-zero and at least T), aux[24]= '
     'credit violation (same as fault), aux[25]=withdrawal against an empty credit, '
     'aux[26]=deposit saturated at 15, aux[27]=a pass-over count saturated at 7, '
     'aux[31:28]=0. round_robin8 in the sibling library issues one grant from a '
     'pointer with no ledger; this couples credits, per-port starvation counters and a '
     're-armable credit program.',
     '''
pb = 0;
pa = 0;
idx = 0;
pl = 0;
ph = 0;
if (c[31]) begin
    for (lane = 0; lane < 8; lane = lane + 1) begin
        pc = {29'd0, c[3*lane +: 3]};
        pb = pb | (pc << (4*lane));
        state_n[4*lane +: 4] = pc[3:0];
        state_n[36 + 3*lane +: 3] = 3'd0;
    end
    state_n[34:32] = c[26:24];
    x[2:0] = c[26:24];
    x[5:3] = 3'd7;
    x[7] = 1'b1;
end
else begin
    for (lane = 0; lane < 8; lane = lane + 1) begin
        pc = {28'd0, state_r[4*lane +: 4]};
        if (a[8+lane]) pc = pc + 32'd1;
        if (pc > 32'd15) begin
            pc = 32'd15;
            x[26] = 1'b1;
        end
        if (a[16+lane]) begin
            if (pc == 0) x[25] = 1'b1;
            else pc = pc - 32'd1;
        end
        pb = pb | (pc << (4*lane));
        state_n[4*lane +: 4] = pc[3:0];
        if (a[lane] && b[lane]) begin
            if (pc == 0) f = 1'b1;
            else pa = pa | (32'd1 << lane);
        end
    end
    pc = {29'd0, state_r[34:32]};
    x[2:0] = pc[2:0];
    for (i = 0; i < 8; i = i + 1) begin
        lane = (pc + i) & 32'h7;
        if ((!idx) && pa[lane]) begin
            idx = 1;
            pl = lane;
            ph = 32'd1 << lane;
        end
    end
    if (idx) begin
        r[7:0] = ph;
        x[6] = 1'b1;
        x[5:3] = pl[2:0];
        pc = (pl + 1) & 32'h7;
        x[2:0] = pc[2:0];
        state_n[34:32] = pc[2:0];
        temp = pb[4*pl +: 4] - 32'd1;
        pb = (pb & ~(32'hf << (4*pl))) | (temp << (4*pl));
        state_n[4*pl +: 4] = temp[3:0];
    end
    else x[5:3] = 3'd7;
    x[15:8] = pa & ~ph;
    for (lane = 0; lane < 8; lane = lane + 1) begin
        if (idx && (pl == lane)) temp = 0;
        else if (pa[lane]) begin
            temp = {29'd0, state_r[36 + 3*lane +: 3]} + 32'd1;
            if (temp > 32'd7) begin
                temp = 32'd7;
                x[27] = 1'b1;
            end
        end
        else if ((!a[lane]) || (!b[lane])) temp = 0;
        else temp = {29'd0, state_r[36 + 3*lane +: 3]};
        state_n[36 + 3*lane +: 3] = temp[2:0];
        if ((temp != 0) && (b[15:8] != 0) && (temp >= {24'd0, b[15:8]}))
            x[16+lane] = 1'b1;
    end
end
temp = 0;
mask = 0;
for (lane = 0; lane < 8; lane = lane + 1) begin
    pc = pb[4*lane +: 4];
    temp = temp + pc;
    if (pc != 0) mask = mask | (32'd1 << lane);
end
r[15:8] = mask;
r[23:16] = temp[7:0];
temp = 0;
for (lane = 0; lane < 8; lane = lane + 1)
    if (a[lane] && b[lane]) temp = temp + 32'd1;
r[31:24] = temp[7:0];
x[24] = f;
''',
     'Eight ports are credited, scanned, granted, aged and re-armed in one beat with '
     'an exact one-hot output, which a software arbiter can only approximate with a '
     'variable-latency priority loop.', 8, stateful=True)


# -------------------------------------------------------- 6 watchdog window
core('ctl_watchdog_window32',
     'Windowed supervision of four watchdog channels. state[3:0]=armed bitmap, '
     'state[7:4]=sticky early violations, state[11:8]=sticky late violations, '
     'state[15:12]=sticky strobe-while-disarmed hits, state[16+16k+15:16+16k]=last '
     'accepted timestamp of channel k, state[95:80]=latched minimum window, '
     'state[111:96]=latched maximum window, state[115:112]=stale beat count saturating '
     'at 15, state[119:116]=violation count saturating at 15. a[15:0]=free-running '
     'tick timestamp, a[19:16]=channel of a strobe, a[20]=strobe present, a[31:21] '
     'ignored. b[15:0]=maximum window bound and c[15:0]=minimum window bound, both '
     'latched only by an arm beat; c[31]=1 arms. An arm beat whose minimum exceeds its '
     'maximum is a malformed window: f=1, the beat is rejected and state holds. A '
     'valid arm beat sets every channel timestamp to the current tick, arms all four '
     'channels, clears both sticky maps, the disarmed-hit map, the stale count and the '
     'violation count, and consumes any strobe in that beat. On any other beat '
     'elapsed = (tick - last) modulo 2^16 for the strobed channel: a strobe on a '
     'disarmed channel sets that channel hit bit, a strobe with elapsed below the '
     'minimum is an early violation and one above the maximum is a late violation; '
     'each of those three raises f, marks its sticky map, disarms that channel until '
     'the next arm beat and counts one violation, and each still re-baselines that '
     'channel timestamp. An in-window strobe refreshes its channel, clears the stale '
     'count and raises no fault. After the strobe a timeout scan flags every '
     'still-armed channel whose elapsed against the current tick exceeds the maximum, '
     'as a late violation with the same handling. The stale count grows by one on '
     'every accepted beat without an in-window refresh. result[3:0]=armed, '
     'result[7:4]=early map, result[11:8]=late map, result[15:12]=disarmed-hit map, '
     'result[31:16]=tick echo. aux[3:0]=channels that violated this beat, aux[4]= '
     'in-window refresh accepted, aux[5]=arm beat, aux[6]=beat rejected, aux[7]=at '
     'least one channel armed, aux[11:8]=stale count, aux[15:12]=violation count, '
     'aux[27:24]=strobe channel echo, aux[28]=strobe present echo, aux[29]=violation '
     'count saturated, other bits 0. fault=first violation of the current window for '
     'any channel, and because a violating channel disarms itself one window cannot '
     'spam the fault line. first_fault32 and debounce_word in the sibling library '
     'latch one word with one run length; this tracks four independent time windows '
     'with sticky per-channel history.',
     '''
temp = a[15:0];
idx = a[19:16];
sa = {28'd0, state_r[115:112]};
sb = {28'd0, state_r[119:116]};
ph = 0;
pl = 0;
if (c[31] && (c[15:0] > b[15:0])) begin
    f = 1'b1;
    x[6] = 1'b1;
end
else if (c[31]) begin
    state_n[95:80] = c[15:0];
    state_n[111:96] = b[15:0];
    state_n[3:0] = 4'hf;
    state_n[7:4] = 4'h0;
    state_n[11:8] = 4'h0;
    state_n[15:12] = 4'h0;
    sa = 32'd0;
    sb = 32'd0;
    x[5] = 1'b1;
    for (lane = 0; lane < 4; lane = lane + 1)
        state_n[16 + 16*lane +: 16] = temp[15:0];
end
else if (a[20] && (idx > 4'd3)) begin
    f = 1'b1;
    x[6] = 1'b1;
end
else begin
    mask = 32'd0;
    if (a[20]) begin
        pa = (temp - state_r[16 + 16*idx +: 16]) & 16'hffff;
        if (!state_r[idx]) begin
            state_n[12+idx] = 1'b1;
            ph = ph | (32'd1 << idx);
            pl = pl + 32'd1;
            f = 1'b1;
        end
        else if (pa < state_r[95:80]) begin
            state_n[4+idx] = 1'b1;
            state_n[idx] = 1'b0;
            ph = ph | (32'd1 << idx);
            pl = pl + 32'd1;
            f = 1'b1;
        end
        else if (pa > state_r[111:96]) begin
            state_n[8+idx] = 1'b1;
            state_n[idx] = 1'b0;
            ph = ph | (32'd1 << idx);
            pl = pl + 32'd1;
            f = 1'b1;
        end
        else begin
            mask = 32'd1;
            x[4] = 1'b1;
        end
        state_n[16 + 16*idx +: 16] = temp[15:0];
    end
    for (lane = 0; lane < 4; lane = lane + 1) begin
        if (state_n[lane] &&
            (((temp - state_n[16 + 16*lane +: 16]) & 16'hffff)
             > state_n[111:96])) begin
            state_n[8+lane] = 1'b1;
            state_n[lane] = 1'b0;
            ph = ph | (32'd1 << lane);
            pl = pl + 32'd1;
            f = 1'b1;
        end
    end
    if (mask) sa = 32'd0;
    else begin
        sa = sa + 32'd1;
        if (sa > 32'd15) sa = 32'd15;
    end
    sb = sb + {28'd0, pl[3:0]};
    if (sb > 32'd15) begin
        sb = 32'd15;
        x[29] = 1'b1;
    end
    x[3:0] = ph;
end
state_n[115:112] = sa[3:0];
state_n[119:116] = sb[3:0];
r[3:0] = state_n[3:0];
r[7:4] = state_n[7:4];
r[11:8] = state_n[11:8];
r[15:12] = state_n[15:12];
r[31:16] = temp;
x[7] = (state_n[3:0] != 0);
x[11:8] = sa[3:0];
x[15:12] = sb[3:0];
x[27:24] = idx;
x[28] = a[20];
''',
     'Four refresh windows, sticky violation maps and a timeout scan resolve every '
     'beat in hard real time, where a polled software watchdog both misses the early '
     'edge and drifts with interrupt latency.', 4, stateful=True)


# ------------------------------------------------------------ integer model
def s16(value):
    value &= 0xffff
    return value - (1 << 16) if value >> 15 else value


def s32(value):
    value &= MASK
    return value - (1 << 32) if value >> 31 else value


def pack2(values):
    return (values[0] & 0xffff) | ((values[1] & 0xffff) << 16)


def pack8(samples):
    value = 0
    for k, sample in enumerate(samples):
        value |= (sample & 3) << 2*k
    return value


def limits(rise, fall):
    return (rise & 0x3fff) | ((fall & 0x3fff) << 16)


def hit(tick, channel):
    """A watchdog strobe word: tick in [15:0], channel in [19:16], present in [20]."""
    return (tick & 0xffff) | ((channel & 0xf) << 16) | (1 << 20)


def _nco(a, b, c, state):
    phase = state & MASK
    stored = (state >> 32) & 0xff
    dither = s16(b & 0xffff)
    if (b >> 17) or (c & 0x7fffffff):
        return phase, (stored << 8) | (phase >> 30), 1, state
    if c >> 31:
        return a, (1 << 16) | (a >> 30), 0, a
    total = phase + dither - a if (b >> 16) & 1 else phase + dither + a
    events = total >> 32                        # floor division by 2^32
    crossings = events if events >= 0 else -events
    aux = (total & MASK) >> 30
    if events > 0:
        aux |= 1 << 2
    if events < 0:
        aux |= 1 << 3
    count = stored + crossings
    if count > 255:
        count = 255
        aux |= 1 << 4
    aux |= (count & 0xff) << 8
    return total & MASK, aux, 0, (total & MASK) | (count << 32)


CYCLE = (0, 1, 3, 2)                            # legal Gray quadrature order


def _quadrature(a, b, c, state):
    position = state & MASK
    tracked = (state >> 32) & 3
    errors = (state >> 36) & 15
    if a >> 16:
        return position, (tracked << 24) | (errors << 28), 1, state
    walk = 0 if c >> 31 else (s32(b) if (c >> 30) & 1 else s32(position))
    reverse = changed = illegal = faults = 0
    for index in range(8):
        sample = (a >> 2*index) & 3
        if sample == tracked:
            continue
        changed |= 1 << index
        offset = (CYCLE.index(sample) - CYCLE.index(tracked)) & 3
        if offset == 1:
            walk += 1
        elif offset == 3:
            walk -= 1
            reverse |= 1 << index
        else:
            illegal |= 1 << index
            faults += 1
        tracked = sample
    count = errors + faults
    aux = reverse | (changed << 8) | (illegal << 16) | (tracked << 24)
    if (c >> 31) or ((c >> 30) & 1):
        aux |= 1 << 26
    if count > 15:
        count = 15
        aux |= 1 << 27
    aux |= (count & 15) << 28
    result = walk & MASK
    return result, aux, 1 if illegal else 0, result | (tracked << 32) | (count << 36)


def _slew(a, b, c, state):
    held = [s16((state >> 16*k) & 0xffff) for k in range(2)]
    target = [s16((a >> 16*k) & 0xffff) for k in range(2)]
    rise = [c & 0x3fff, b & 0x3fff]
    fall = [(c >> 16) & 0x3fff, (b >> 16) & 0x3fff]
    out = list(held)
    aux = f = 0
    if c >> 31:
        out = list(target)
        aux = (1 << 6) | (1 << 4) | (1 << 5)
    elif (c >> 30) & 1:
        aux = 1 << 7
        for k in range(2):
            if target[k] == held[k]:
                aux |= 1 << (4 + k)
    else:
        for k in range(2):
            gap = target[k] - held[k]
            if rise[k] == 0 and fall[k] == 0:
                aux |= 1 << (8 + k)
                f = 1
            elif gap > rise[k]:
                out[k] = held[k] + rise[k]
                aux |= 1 << k
                f = 1
            elif gap < -fall[k]:
                out[k] = held[k] - fall[k]
                aux |= 1 << (2 + k)
                f = 1
            else:
                out[k] = target[k]
                aux |= 1 << (4 + k)
    packed = pack2(out)
    return packed, aux, f, packed


ACC_LIMIT = (1 << 23) - 1


def _pid(a, b, c, state):
    shift = [(b >> 4*k) & 0xf for k in range(4)]           # sP sI sD sO
    threshold = 1 << (15 - ((b >> 16) & 7))
    restart = bool(c >> 31)
    frozen = bool((c >> 30) & 1)
    aux = f = result = 0
    integrals = []
    for k in range(2):
        error = s16((a >> 16*k) & 0xffff)
        previous = s16((state >> 16*k) & 0xffff)
        integral = s32((state >> (32 + 32*k)) & MASK)
        if restart and abs(error - previous) >= threshold:
            aux |= 1 << (4 + k)
            f = 1
        derivative = 0 if restart else (error - previous) >> shift[2]
        if derivative:
            aux |= 1 << (6 + k)
        if restart:
            integral = 0
        if not frozen:
            integral += error >> shift[1]
            if integral > ACC_LIMIT:
                integral = ACC_LIMIT
                aux |= 1 << k
            elif integral < -ACC_LIMIT:
                integral = -ACC_LIMIT
                aux |= 1 << k
        if integral < 0:
            aux |= 1 << (8 + k)
        integrals.append(integral)
        effort = (error >> shift[0]) + integral + derivative
        effort >>= shift[3]
        if effort > 32767:
            effort = 32767
            aux |= 1 << (2 + k)
        elif effort < -32768:
            effort = -32768
            aux |= 1 << (2 + k)
        result |= (effort & 0xffff) << 16*k
    if restart:
        aux |= 1 << 10
    if frozen:
        aux |= 1 << 11
    if not any(integrals):
        aux |= 1 << 12
    aux |= ((b >> 4) & 0xfff) << 16
    new_state = 0
    for k in range(2):
        new_state |= ((a >> 16*k) & 0xffff) << 16*k
        new_state |= (integrals[k] & MASK) << (32 + 32*k)
    return result, aux, f, new_state


def _arbiter(a, b, c, state):
    credit = [(state >> 4*k) & 0xf for k in range(8)]
    pointer = (state >> 32) & 7
    passed = [(state >> (36 + 3*k)) & 7 for k in range(8)]
    request, deposit, withdraw = a & 0xff, (a >> 8) & 0xff, (a >> 16) & 0xff
    enable, threshold = b & 0xff, (b >> 8) & 0xff
    aux = f = 0
    if c >> 31:
        credit = [(c >> 3*k) & 7 for k in range(8)]
        pointer = (c >> 24) & 7
        passed = [0]*8
        aux = (1 << 7) | (pointer & 7) | (7 << 3)
    else:
        eligible = 0
        for port in range(8):
            value = credit[port]
            if (deposit >> port) & 1:
                value += 1
            if value > 15:
                value = 15
                aux |= 1 << 26
            if (withdraw >> port) & 1:
                if value == 0:
                    aux |= 1 << 25
                else:
                    value -= 1
            credit[port] = value
            if (request >> port) & 1 and (enable >> port) & 1:
                if value == 0:
                    f = 1
                else:
                    eligible |= 1 << port
        granted = 8
        for scan in range(8):
            port = (pointer + scan) & 7
            if (eligible >> port) & 1:
                granted = port
                break
        if granted < 8:
            credit[granted] -= 1
            pointer = (granted + 1) & 7
            aux |= (1 << 6) | (granted << 3) | (pointer & 7)
            aux |= (eligible & ~(1 << granted)) << 8
        else:
            aux |= (pointer & 7) | (7 << 3)
            aux |= eligible << 8
        for port in range(8):
            if port == granted:
                value = 0
            elif (eligible >> port) & 1:
                value = passed[port] + 1
                if value > 7:
                    value = 7
                    aux |= 1 << 27
            elif not ((request >> port) & 1 and (enable >> port) & 1):
                value = 0
            else:
                value = passed[port]
            passed[port] = value
            if value and threshold and value >= threshold:
                aux |= 1 << (16 + port)
    aux |= f << 24
    total = bitmap = requesters = 0
    for port in range(8):
        total += credit[port]
        if credit[port]:
            bitmap |= 1 << port
        if (request >> port) & 1 and (enable >> port) & 1:
            requesters += 1
    result = ((bitmap << 8) | ((total & 0xff) << 16) | (requesters << 24))
    if c >> 31:
        result |= 0
    else:
        result |= 1 << granted if granted < 8 else 0
    new_state = (pointer & 7) << 32
    for port in range(8):
        new_state |= credit[port] << 4*port
        new_state |= passed[port] << (36 + 3*port)
    return result, aux, f, new_state


def _watchdog(a, b, c, state):
    tick = a & 0xffff
    channel = (a >> 16) & 0xf
    strobe = (a >> 20) & 1
    minimum = (state >> 80) & 0xffff
    maximum = (state >> 96) & 0xffff
    armed = [(state >> k) & 1 for k in range(4)]
    early = (state >> 4) & 0xf
    late = (state >> 8) & 0xf
    masked = (state >> 12) & 0xf
    last = [(state >> (16 + 16*k)) & 0xffff for k in range(4)]
    stale = (state >> 112) & 0xf
    violations = (state >> 116) & 0xf
    aux = f = 0
    if (c >> 31) and ((c & 0xffff) > (b & 0xffff)):
        f, aux = 1, 1 << 6                          # malformed window, beat rejected
    elif c >> 31:
        minimum, maximum = c & 0xffff, b & 0xffff
        armed = [1]*4
        early = late = masked = 0
        last = [tick]*4
        stale = violations = 0
        aux = 1 << 5
    elif strobe and channel > 3:
        f, aux = 1, 1 << 6                          # malformed channel, beat rejected
    else:
        hits = violated = 0
        refreshed = False
        if strobe:
            elapsed = (tick - last[channel]) & 0xffff
            if not armed[channel]:
                masked |= 1 << channel
                violated |= 1 << channel
                hits += 1
                f = 1
            elif elapsed < minimum:
                early |= 1 << channel
                armed[channel] = 0
                violated |= 1 << channel
                hits += 1
                f = 1
            elif elapsed > maximum:
                late |= 1 << channel
                armed[channel] = 0
                violated |= 1 << channel
                hits += 1
                f = 1
            else:
                refreshed = True
                aux = 1 << 4
            last[channel] = tick
        for k in range(4):
            if armed[k] and ((tick - last[k]) & 0xffff) > maximum:
                late |= 1 << k
                armed[k] = 0
                violated |= 1 << k
                hits += 1
                f = 1
        stale = 0 if refreshed else min(stale + 1, 15)
        violations += hits
        if violations > 15:
            violations = 15
            aux |= 1 << 29
        aux |= violated & 0xf
    aux |= (1 if any(armed) else 0) << 7
    aux |= (stale & 0xf) << 8
    aux |= (violations & 0xf) << 12
    aux |= channel << 24
    aux |= strobe << 28
    result = (tick << 16) | (masked << 12) | (late << 8) | (early << 4)
    new_state = (minimum << 80) | (maximum << 96) | ((stale & 0xf) << 112) \
        | ((violations & 0xf) << 116) | (early << 4) | (late << 8) | (masked << 12)
    for k in range(4):
        result |= armed[k] << k
        new_state |= armed[k] << k
        new_state |= last[k] << (16 + 16*k)
    return result, aux, f, new_state


MODEL = {'ctl_phase_nco32': _nco, 'ctl_quadrature_decoder': _quadrature,
         'ctl_slew_limiter_s16': _slew, 'ctl_pid_form_s16': _pid,
         'ctl_credit_arb8': _arbiter, 'ctl_watchdog_window32': _watchdog}


def step(name, a, b, c, state=0):
    try:
        return MODEL[name](a, b, c, state)
    except KeyError:
        raise ValueError(name)


# ------------------------------------------------------------------- vectors
def vectors(name, count=320):
    """Board set first: rows 0..127 are structured, exhaustive and edge driven.

    Every stateful core puts a c[31]=1 reload inside the board set and every fault
    rule is reached there, so the hardware run cannot pass by luck.
    """
    rows = []
    if name == 'ctl_phase_nco32':
        for k in range(16):                       # sixteen tuning words, five dithers
            for dither in (-2, -1, 0, 1, 2):
                rows.append(((1 << 28)*k, dither & 0xffff, 0))
        for k in range(16):                       # reload sweep over all quadrants
            rows.append(((k << 28) | 0x0000ABCD, 0, 1 << 31))
        for k in range(16):                       # reverse stepping
            rows.append((0x10000000 + k, 1 << 16, 0))
        for k in range(8):                        # reserved b bits: rejected beats
            rows.append((0x01010101*k, 1 << (17 + k), 0))
        for k in range(8):                        # reserved c bits: rejected beats
            rows.append((0x02020202*k, 0, 1 << k))
        for value in (0, 1, 0x7fff, 0x8000, 0xffff):
            rows.append((MASK, value, 0))
            rows.append((MASK, value | (1 << 16), 0))
    elif name == 'ctl_quadrature_decoder':
        forward, reverse = (1, 3, 2, 0, 1, 3, 2, 0), (2, 3, 1, 0, 2, 3, 1, 0)
        glitch, stuck = (3, 3, 3, 3, 3, 3, 3, 3), (2, 2, 2, 2, 2, 2, 2, 2)
        mixed = [(0, 1, 1, 3, 2, 2, 0, 1), (2, 3, 1, 0, 1, 3, 2, 0),
                 (0, 1, 3, 3, 2, 1, 0, 2), (1, 2, 1, 2, 1, 2, 1, 2),
                 (0, 3, 1, 2, 0, 3, 1, 2), (0, 0, 1, 1, 3, 3, 2, 2)]
        table = (forward, reverse, glitch, stuck) + tuple(mixed)
        for pattern in table:
            rows.append((pack8(pattern), 0, 0))
        for k in range(8):                        # reset beats inside the board set
            rows.append((pack8(table[k]), 0, 1 << 31))
        for k in range(8):                        # malformed sample word
            rows.append(((k + 1) << 16, k, 0))
        for k in range(16):                       # preload sweep, distinct bases
            rows.append((pack8(table[k % 10]), 0x40000000 + 0x01000010*k, 1 << 30))
        for value in range(64):                   # exhaustive over samples 0..2
            rows.append((value, 0, 0))
        for value in range(32):                   # exhaustive over samples 3..4
            rows.append((value << 6, 0, 0))
    elif name == 'ctl_slew_limiter_s16':
        programs = [(7, 3, 7, 3), (1, 1, 1, 1), (0, 0, 0, 0), (16383, 16383, 1, 1),
                    (100, 1, 5, 5), (1, 100, 100, 1), (255, 254, 0, 9),
                    (0, 5, 9, 0), (3, 4095, 4095, 3)]
        targets = [(32767, -32768), (-32768, 32767), (4095, -4096), (7, -8)]
        for rise0, fall0, rise1, fall1 in programs:
            for low, high in targets:
                rows.append((pack2([low, high]), limits(rise1, fall1),
                             limits(rise0, fall0)))
        for k in range(48):                       # rising ramp resolution sweep
            rows.append((pack2([1000, -1000]), limits(2*k, 4095 - k),
                         limits(k, 8 + k)))
        for k in range(12):                       # falling ramp resolution sweep
            rows.append((pack2([-1000, -1000]), limits(1, 10 + k),
                         limits(2, 3 + k)))
        for k in range(24):                       # bypass sweep, distinct targets
            rows.append((pack2([k*250 - 1500, 32767 - k]), limits(1, 1),
                         (1 << 31) | limits(9, 4)))
        for k in range(4):                        # freeze holds both lanes
            rows.append((pack2([0, 0]), limits(2, 3), (1 << 30) | limits(2, 3)))
        for k in range(8):                        # one malformed lane at a time
            rows.append((pack2([500, -500]), 0 if k % 2 else limits(8, 2),
                         limits(8, 2) if k % 2 else 0))
    elif name == 'ctl_pid_form_s16':
        errors = [(32767, -32768), (1000, -1000), (0, 0), (1, -1), (127, 128),
                  (8192, -8193), (-32768, 32767), (255, -255)]
        for k in range(8):                        # restart kicks at each threshold
            for delta in (32767, 8192, 100):
                rows.append((pack2([delta, -delta]),
                             k | (8 << 4) | (15 << 8) | (2 << 12) | (k << 16),
                             1 << 31))
        for k in range(8):                        # frozen integral sweep
            rows.append((pack2([4000*k, -4000*k]),
                         (15 - k) | (0 << 4) | (k << 8) | (3 << 12), 1 << 30))
        for shift_p in range(8):                  # gain cross, distinct echo words
            for shift_i in range(8):
                low, high = errors[(shift_p + shift_i) % 8]
                rows.append((pack2([low, high]),
                             shift_p | (shift_i << 4) | (15 << 8) | (2 << 12), 0))
        for shift_d, shift_o, shift_k in ((0, 0, 0), (4, 6, 5), (9, 1, 3), (12, 11, 7),
                                          (2, 15, 1), (7, 3, 6)):
            for low, high in errors[:4]:
                word = (15 | (8 << 4) | (shift_d << 8) | (shift_o << 12)
                        | (shift_k << 16))
                rows.append((pack2([low, high]), word, 0))
                rows.append((pack2([high, low]), word, 0))
    elif name == 'ctl_credit_arb8':
        for k in range(56):                       # arm beats with distinct ledgers
            program = ((k * 2654435761) >> 7) & 0xFFFFFF
            rows.append(((k & 0xFF) | (((k >> 3) & 0x1F) << 8),
                         (0xFF - (k & 0x0F)) | (((k % 9) + 1) << 8),
                         (1 << 31) | program | ((k & 7) << 24)))
        for k in range(8):                        # one credit, then ask all eight
            rows.append((0, 0xFF | (8 << 8),
                         (1 << 31) | (1 << (3*k)) | (k << 24)))
            rows.append((0xFF | (k << 8), 0xFF | (8 << 8), 0))
        for k in range(24):                       # deposits drive the grants
            request = (k * 37) & 0xFF
            deposit = (k * 11 + 1) & 0xFF
            rows.append((request | (deposit << 8), 0xFF | (((k % 8) + 1) << 8), 0))
        for k in range(12):                       # withdrawals against empty ports
            rows.append((0xFF | ((k & 0x0F) << 16), 0xFF | ((k + 1) << 8), 0))
        for k in range(12):                       # disabled ports and idle beats
            rows.append((0x0F | (0xF0 if k % 2 else 0), (0xF0 if k % 2 else 0x0F)
                         | ((k & 7) << 8), 0))
    elif name == 'ctl_watchdog_window32':
        rows.append((1000, 20, (1 << 31) | 10))           # arm, window 10..20
        rows.append((1000, 20, (1 << 31) | 500))          # malformed window
        rows.append((1000, 9, (1 << 31) | 10))            # malformed window
        rows.append((1001, 20, (1 << 31) | 10))           # re-arm
        for k in range(24):                               # too-early strobes
            rows.append((hit(1005 + k, k % 4), 20, 0))
        for k in range(24):                               # in-window refresh sweep
            rows.append((hit(1100 + 12*k, k % 4), 30, 0))
        for k in range(24):                               # late and timeout beats
            rows.append((hit(2000 + 97*k, k % 4), 30, 0))
        for k in range(16):                               # idle aging
            rows.append((5000 + k, 30, 0))
        for k in range(8):                        # strobe on a reserved channel
            rows.append((hit(6000 + k, 4 + k), 30, 0))
        for k in range(16):                       # re-arms with fresh windows
            rows.append((7000 + k, 4000 + k, (1 << 31) | (200 + k)))
        for k in range(8):                        # arm beats with minimum above max
            rows.append((8000 + k, k, (1 << 31) | (30 + k)))
        for k in range(8):                        # long stale windows
            rows.append((hit(9000 + k, k % 4), 4 + k, 0))
    else:
        raise ValueError(name)

    rng = Random(0xC0A71A00 + sum(name.encode()))
    while len(rows) < count:
        rows.append(_tail(name, rng))
    return rows[:count]


def _tail(name, rng):
    """Randomised padding past the board set: legal and malformed words mixed."""
    if name == 'ctl_phase_nco32':
        return (rng.getrandbits(32),
                rng.choice([rng.getrandbits(17), rng.getrandbits(17) | (1 << 16),
                            rng.getrandbits(32), 0]),
                rng.choice([0, 0, 0, 1 << 31, rng.getrandbits(31)]))
    if name == 'ctl_quadrature_decoder':
        return (pack8([rng.getrandbits(2) for _ in range(8)]), rng.getrandbits(32),
                rng.choice([0, 0, 0, 1 << 31, 1 << 30, rng.getrandbits(30)]))
    if name == 'ctl_slew_limiter_s16':
        return (pack2([rng.getrandbits(16), rng.getrandbits(16)]),
                limits(rng.getrandbits(14), rng.getrandbits(14)),
                rng.choice([limits(rng.getrandbits(14), rng.getrandbits(14)),
                            (1 << 31) | limits(rng.getrandbits(14),
                                                rng.getrandbits(14)),
                            (1 << 30) | limits(rng.getrandbits(14),
                                               rng.getrandbits(14)), 0]))
    if name == 'ctl_pid_form_s16':
        return (pack2([rng.getrandbits(16), rng.getrandbits(16)]),
                rng.getrandbits(19),
                rng.choice([0, 0, 1 << 31, 1 << 30, (1 << 31) | (1 << 30)]))
    if name == 'ctl_credit_arb8':
        return (rng.getrandbits(24), rng.getrandbits(16),
                rng.choice([0, 0, (1 << 31) | rng.getrandbits(27),
                            rng.getrandbits(31)]))
    return (rng.choice([hit(rng.getrandbits(16), rng.getrandbits(4)),
                        rng.getrandbits(16),
                        rng.getrandbits(16) | (rng.getrandbits(4) << 16)]),
            rng.getrandbits(16),
            rng.choice([0, 0, (1 << 31) | rng.getrandbits(16), rng.getrandbits(16)]))


# ------------------------------------------------------------------ selftest
def selftest():
    """Hand-derived expectations, computed here rather than by the model."""
    checks = 0

    # --- phase NCO: four increments of half scale is one full turn per two beats
    state = 0
    seen = []
    for _ in range(4):
        r, x, f, state = step('ctl_phase_nco32', 0x80000000, 0, 0, state)
        seen.append((r, x, f))
    assert seen[0] == (0x80000000, 0x002, 0)
    assert seen[1] == (0x00000000, 0x104, 0)
    assert seen[2] == (0x80000000, 0x102, 0)
    assert seen[3] == (0x00000000, 0x204, 0)
    checks += 4
    # k increments of a fixed step: phase is k times step modulo 2^32 and the wrap
    # count is the exact number of 2^32 boundaries crossed, saturated at 255
    for tuning, beats in ((0x20000000, 16), (0x0000FFFF, 40), (0x00000001, 60),
                          (0xF0000000, 30)):
        state = 0
        for k in range(1, beats + 1):
            r, x, f, state = step('ctl_phase_nco32', tuning, 0, 0, state)
            advance = k * tuning
            assert r == advance & MASK
            assert (x >> 8) & 0xff == min(255, advance >> 32)
            assert x & 3 == (r >> 30)
            assert f == 0
            checks += 1
    # dither and direction: phase 0x10 minus 0x20 wraps below zero once
    r, x, f, state = step('ctl_phase_nco32', 0x20, 1 << 16, 0, 0x10)
    assert (r, x, f) == (0xfffffff0, (1 << 8) | (1 << 3) | 3, 0)
    assert state == 0xfffffff0 | (1 << 32)
    # the same beat forward instead adds 0x20 plus dither zero
    r, x, f, _ = step('ctl_phase_nco32', 0x20, 0, 0, 0x10)
    assert (r, x, f) == (0x30, 0, 0)
    checks += 2
    # reload wins over accumulation, clears the wrap count and stamps aux[16]
    r, x, f, state = step('ctl_phase_nco32', 0x12345678, 0, 1 << 31, state)
    assert (r, x, f, state) == (0x12345678, (1 << 16) | 0, 0, 0x12345678)
    checks += 1
    # reserved bits reject the beat and echo the held accumulator instead
    held = 0xDEADBEEF | (7 << 32)
    r, x, f, new = step('ctl_phase_nco32', 0, 1 << 20, 0, held)
    assert (r, x, f, new) == (0xDEADBEEF, (7 << 8) | 3, 1, held)
    r, x, f, new = step('ctl_phase_nco32', 0, 0, 4, held)
    assert (r, x, f, new) == (0xDEADBEEF, (7 << 8) | 3, 1, held)
    checks += 2

    # --- quadrature: hand-written forward, reverse and illegal walks
    forward = pack8((1, 3, 2, 0, 1, 3, 2, 0))
    reverse = pack8((2, 3, 1, 0, 2, 3, 1, 0))
    jump = pack8((3, 3, 3, 3, 3, 3, 3, 3))
    assert forward == 0x2D2D and reverse == 0x1E1E and jump == 0xFFFF
    r, x, f, _ = step('ctl_quadrature_decoder', forward, 0, 0)
    assert (r, x, f) == (8, 0x0000FF00, 0)
    r, x, f, _ = step('ctl_quadrature_decoder', reverse, 0, 0)
    assert (r, x, f) == (0xfffffff8, 0x0000FFFF, 0)
    # one 00 -> 11 jump: a single illegal edge, then the state holds
    r, x, f, state = step('ctl_quadrature_decoder', jump, 0, 0)
    assert (r, x, f) == (0, 0x13010100, 1)
    # a legal forward step measured against the glitched state
    r, x, f, state = step('ctl_quadrature_decoder', pack8((2,)*8), 0, 0, state)
    assert (r, x, f) == (1, 0x12000100, 0)
    checks += 4
    # one edge forward then the same edge back
    r, x, f, state = step('ctl_quadrature_decoder', pack8((1,)*8), 0, 0)
    assert (r, x, f) == (1, 0x01000100, 0)
    r, x, f, state = step('ctl_quadrature_decoder', 0, 0, 0, state)
    assert (r, x, f) == (0, 0x00000101, 0)
    checks += 2
    # reset and preload paths
    r, x, f, _ = step('ctl_quadrature_decoder', forward, 0, 1 << 31, 0x555)
    assert (r, (x >> 26) & 7, f) == (8, 1, 0)
    r, x, f, _ = step('ctl_quadrature_decoder', forward, 0x7ffffff8, 1 << 30)
    assert (r, x, f) == (0x80000000, (1 << 26) | 0x0000FF00, 0)
    r, x, f, _ = step('ctl_quadrature_decoder', reverse, 0x00000008, 1 << 30)
    assert (r, f) == (0, 0)
    checks += 3
    # the other simultaneous transition, 11 to 00
    r, x, f, _ = step('ctl_quadrature_decoder', 0, 0, 0, 3 << 32)
    assert (r, x, f) == (0, 0x10010100, 1)
    checks += 1
    # eight illegal jumps on top of an almost-full error count saturate it at 15
    r, x, f, state = step('ctl_quadrature_decoder', pack8((3, 0, 3, 0, 3, 0, 3, 0)),
                          0, 0, 8 << 36)
    assert (r, x, f) == (0, 0xF8FFFF00, 1)
    assert ((state >> 36) & 15) == 15 and (x >> 27) & 1 == 1
    checks += 2
    # malformed sample word rejects and echoes the whole position count
    r, x, f, new = step('ctl_quadrature_decoder', 0x00010000, 0, 0, forward | (2 << 32))
    assert (r, x, f, new) == (forward, 2 << 24, 1, forward | (2 << 32))
    checks += 1

    # --- slew limiter against a hand-computed ramp
    state = 0
    ramp = []
    for _ in range(5):
        r, x, f, state = step('ctl_slew_limiter_s16', pack2([1000, 0]),
                              limits(7, 3), limits(7, 3), state)
        ramp.append((r, x, f))
    assert [row[0] for row in ramp] == [7, 14, 21, 28, 35]
    assert ramp[0] == (7, 0x21, 1)
    assert all(row[2] == 1 for row in ramp)
    checks += 3
    # the falling edge uses the asymmetric bound
    r, x, f, state = step('ctl_slew_limiter_s16', pack2([-1000, 0]), limits(7, 3),
                          limits(7, 3), state)
    assert (r, x, f) == (32, 0x24, 1)
    checks += 1
    # a generous limit settles both lanes in one beat and raises no fault
    r, x, f, _ = step('ctl_slew_limiter_s16', pack2([500, -500]), limits(16383, 16383),
                      limits(16383, 16383), 0)
    assert (r, x, f) == (pack2([500, -500]), 0x30, 0)
    checks += 1
    # bypass then one malformed lane: the healthy lane keeps moving
    r, x, f, state = step('ctl_slew_limiter_s16', pack2([1000, -32768]), 0,
                          (1 << 31) | limits(9, 4))
    assert (r, x, f) == (pack2([1000, -32768]), 0x70, 0)
    r, x, f, state = step('ctl_slew_limiter_s16', pack2([1500, 2000]), 0,
                          limits(7, 3), state)
    assert (r, x, f) == (pack2([1007, -32768]), 0x01 | 0x200, 1)
    checks += 2
    # freeze holds both outputs and reports only the lane that already agrees
    r, x, f, state = step('ctl_slew_limiter_s16', pack2([1007, 5]), limits(2, 3),
                          (1 << 30) | limits(2, 3), state)
    assert (r, x, f) == (pack2([1007, -32768]), 0x80 | 0x10, 0)
    checks += 1
    # rise of 65535 with a limit of 16383 from -32768 lands on -16385
    r, x, f, _ = step('ctl_slew_limiter_s16', pack2([32767, 0]), limits(1, 1),
                      limits(16383, 1), 1 << 15)
    assert (r & 0xffff) == (-16385 & 0xffff) and (x & 1) == 1
    checks += 1

    # --- PID: anti-windup clamp on a computed step response
    gains = 15 | (8 << 4) | (15 << 8) | (2 << 12) | (2 << 16)
    # stored history: lane0 sat at 32767 with an integral 127 below the bound,
    # lane1 at zero error with the mirrored negative integral
    seed = pack2([32767, 0]) | ((8388480 & MASK) << 32) | ((-8388480 & MASK) << 64)
    r, x, f, state = step('ctl_pid_form_s16', pack2([32767, -32768]), gains, 0, seed)
    assert r == 0x80007fff                       # both lanes saturate the output
    assert x & 0xff == 0x8e                      # lane1 windup, both output clamps,
    #                                            lane1 non-zero derivative
    assert ((state >> 32) & MASK) == 8388607     # lane0 lands exactly on the bound
    assert s32((state >> 64) & MASK) == -8388607  # lane1 clamps here
    assert (x >> 9) & 1 == 1 and (x >> 8) & 1 == 0
    checks += 4
    r, x, f, state = step('ctl_pid_form_s16', pack2([32767, 0]), gains, 0, state)
    assert x & 1 == 1                             # one step past the bound clamps
    assert ((state >> 32) & MASK) == 8388607
    assert (x >> 16) & 0xfff == (gains >> 4) & 0xfff
    checks += 3
    # restart: integral cleared before this beat, derivative suppressed, kick seen
    r, x, f, state = step('ctl_pid_form_s16', pack2([30000, 30000]), gains, 1 << 31,
                          (500000 << 32) | (500000 << 64))
    assert (r, f) == (29 | (29 << 16), 1)
    assert x & 0x30 == 0x30 and x & 0xC0 == 0 and x & 0x400 == 0x400
    assert ((state >> 32) & MASK) == 117 and ((state >> 64) & MASK) == 117
    checks += 3
    # with the threshold exponent at zero the same jump is legal
    r, x, f, _ = step('ctl_pid_form_s16', pack2([30000, 30000]),
                      15 | (8 << 4) | (15 << 8) | (2 << 12), 1 << 31,
                      (500000 << 32) | (500000 << 64))
    assert f == 0 and x & 0x30 == 0 and x & (1 << 10)
    checks += 1
    # a frozen integral keeps its value and reports the freeze
    r, x, f, state = step('ctl_pid_form_s16', pack2([1000, 1000]), gains, 1 << 30,
                          (1000 << 32) | (1000 << 64))
    assert ((state >> 32) & MASK) == 1000 and x & (1 << 11) and x & 3 == 0
    assert r == 250 | (250 << 16)
    checks += 2
    # a fresh controller reports both accumulators zero
    r, x, f, _ = step('ctl_pid_form_s16', 0, 0, 0, 0)
    assert (r, x & ((1 << 12) | (1 << 13)), f) == (0, 0x1000, 0)
    checks += 1

    # --- credit arbiter: arm, one-hot round robin, no starvation, exact ledger
    arm = (1 << 31) | sum(7 << 3*port for port in range(8))
    r, x, f, state = step('ctl_credit_arb8', 0, 0xFF | (8 << 8), arm)
    assert (r, x, f) == (0x0038FF00, (1 << 7) | (7 << 3), 0)
    assert (state & 0xffffffff) == 0x77777777 and (state >> 32) & 7 == 0
    checks += 2
    ports = []
    for _ in range(16):
        r, x, f, state = step('ctl_credit_arb8', 0xFF, 0xFF | (8 << 8), 0, state)
        grant = r & 0xff
        assert grant and grant & (grant - 1) == 0            # exactly one hot
        ports.append(grant.bit_length() - 1)
        assert (x >> 6) & 1 == 1 and f == 0
        checks += 1
    assert ports == [k % 8 for k in range(16)]
    assert (r >> 16) & 0xff == 40 and (r >> 8) & 0xff == 0xFF
    assert (r >> 24) & 0xff == 8 and (x >> 16) & 0xff == 0
    checks += 4
    # a threshold of one now reports every passed-over port
    r, x, f, state = step('ctl_credit_arb8', 0xFF, 0xFF | (1 << 8), 0, state)
    assert bin((x >> 16) & 0xff).count('1') == 7
    assert bin((x >> 8) & 0xff).count('1') == 7
    assert (r & 0xff) == 1
    checks += 3
    # one credit on one port: the rest fault but the grant is still exact
    r, x, f, state = step('ctl_credit_arb8', 0xFF, 0xFF | (8 << 8), (1 << 31) | 1)
    assert (r, x, f) == (0x08010100, (1 << 7) | (7 << 3), 0)
    r, x, f, state = step('ctl_credit_arb8', 0xFF, 0xFF, 0, state)
    assert (r & 0xff) == 1 and f == 1 and (x >> 24) & 1 == 1
    assert (x & 7) == 1 and ((x >> 3) & 7) == 0 and ((x >> 8) & 0xff) == 0
    r, x, f, state = step('ctl_credit_arb8', 0xFF, 0xFF, 0, state)
    assert (r & 0xff) == 0 and f == 1 and ((x >> 3) & 7) == 7 and (x & 7) == 1
    checks += 3
    # ledger arithmetic: deposit, saturate at 15, withdraw, floor at zero
    r, x, f, state = step('ctl_credit_arb8', (1 << 2) | (1 << (8 + 2)), 0, 0, 3 << 8)
    assert ((state >> 8) & 0xf) == 4 and (x >> 26) & 1 == 0 and f == 0
    r, x, f, state = step('ctl_credit_arb8', 1 << (8 + 0), 0, 0, 0xF)
    assert (state & 0xf) == 15 and (x >> 26) & 1 == 1
    r, x, f, state = step('ctl_credit_arb8', (1 << 3) | (1 << (16 + 3)), 0, 0,
                          0xF << 12)
    assert ((state >> 12) & 0xf) == 14 and (x >> 25) & 1 == 0
    r, x, f, state = step('ctl_credit_arb8', 1 << (16 + 3), 0, 0, 0)
    assert (x >> 25) & 1 == 1 and ((state >> 12) & 0xf) == 0
    checks += 4

    # --- windowed watchdog: hand-derived early, late, timeout and re-arm
    state = 0
    r, x, f, state = step('ctl_watchdog_window32', 1000, 20, (1 << 31) | 10, state)
    assert (r, x, f) == ((1000 << 16) | 0x0F, (1 << 5) | (1 << 7), 0)
    checks += 1
    r, x, f, state = step('ctl_watchdog_window32', hit(1005, 1), 20, 0, state)
    assert (r, x, f) == ((1005 << 16) | (2 << 4) | 0x0D,
                         0x2 | (1 << 7) | (1 << 8) | (1 << 12) | (1 << 24) | (1 << 28),
                         1)
    checks += 1
    r, x, f, state = step('ctl_watchdog_window32', hit(1006, 1), 20, 0, state)
    assert (r >> 12) & 0xf == 2 and x & 0xf == 2 and f == 1
    assert (x >> 8) & 0xf == 2 and (x >> 12) & 0xf == 2
    checks += 1
    r, x, f, state = step('ctl_watchdog_window32', hit(1015, 2), 20, 0, state)
    assert (r, x, f) == ((1015 << 16) | (2 << 12) | (2 << 4) | 0x0D,
                         (1 << 4) | (1 << 7) | (2 << 12) | (2 << 24) | (1 << 28), 0)
    checks += 1
    r, x, f, state = step('ctl_watchdog_window32', hit(1040, 3), 20, 0, state)
    assert (r, x, f) == ((1040 << 16) | (2 << 12) | (0x0D << 8) | (2 << 4),
                         0xD | (1 << 8) | (5 << 12) | (3 << 24) | (1 << 28), 1)
    assert (x >> 7) & 1 == 0                     # nothing armed any more
    assert ((state >> 80) & 0xffff) == 10 and ((state >> 96) & 0xffff) == 20
    checks += 2
    r, x, f, state = step('ctl_watchdog_window32', 1041, 20, (1 << 31) | 10, state)
    assert (r, x, f) == ((1041 << 16) | 0x0F, (1 << 5) | (1 << 7), 0)
    checks += 1
    held = state
    r, x, f, new = step('ctl_watchdog_window32', 1042, 20, (1 << 31) | 30, held)
    assert f == 1 and x & (1 << 6) and new == held
    r, x, f, new = step('ctl_watchdog_window32', hit(1043, 5), 20, 0, held)
    assert f == 1 and x & (1 << 6) and new == held
    checks += 2
    # a window of 1..2 times out on the third beat for all four channels at once
    state = step('ctl_watchdog_window32', 0, 2, (1 << 31) | 1)[3]
    for k in (1, 2):
        r, x, f, state = step('ctl_watchdog_window32', k, 2, 0, state)
        assert f == 0 and (x >> 8) & 0xf == k and (x >> 12) & 0xf == 0
        checks += 1
    r, x, f, state = step('ctl_watchdog_window32', 3, 2, 0, state)
    assert f == 1 and x & 0xf == 0xF and (x >> 12) & 0xf == 4
    assert (x >> 7) & 1 == 0 and (x >> 8) & 0xf == 3
    checks += 1
    # violation count saturates at 15 and flags: one window that times out all four
    # channels at once, then strobes landing on channels that supervision dropped
    state = step('ctl_watchdog_window32', 0, 2, (1 << 31) | 1)[3]
    r, x, f, state = step('ctl_watchdog_window32', 3, 2, 0, state)
    assert (r, x, f) == ((3 << 16) | (0xF << 8), 0x0F | (1 << 8) | (4 << 12), 1)
    for k in range(4, 16):
        r, x, f, state = step('ctl_watchdog_window32', hit(k, k % 4), 2, 0, state)
        assert f == 1 and (x >> 28) & 1 == 1        # every one is a strobe
        checks += 1
    assert (x >> 12) & 0xf == 15 and (x >> 29) & 1 == 1
    assert ((state >> 116) & 0xf) == 15 and (x >> 7) & 1 == 0
    checks += 3
    return checks
