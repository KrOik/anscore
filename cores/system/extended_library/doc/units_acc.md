# wave2_ip_20k — Group H unit record (idx35..39, acceleration + reliability)

Agent H.  All digests produced by `tools/golden_acc.py` (independent Python
model, trap T1) — EXP constants in `src/st_*.v` were filled from its output
*before* any simulation comparison.  Verdicts use `===`/`!==` (T6); every
register is `clk_en` gated (T2); no multipliers anywhere (T4-safe).

## Verification evidence (iverilog -g2012, run from project root)

```
iverilog -g2012 -I src -o sim/tb_st_bnn_conv3x3.vvp -s tb_st_bnn_conv3x3 \
    sim/tb_st_bnn_conv3x3.v src/bnn_conv3x3.v src/st_bnn_conv3x3.v src/w2_img_stim.v
vvp sim/tb_st_bnn_conv3x3.vvp        -> W2TB BC3  PASS D=ce422c28 C=294
# (same pattern for the other four)
W2TB BDN  PASS D=8792e554 C=26
W2TB TMR  PASS D=dca39fbd C=35
W2TB WDT  PASS D=b93e6c10 C=47
W2TB LFSR PASS D=9867d947 C=82
```

`diff sim/dump_<unit>.txt sim/golden_<unit>.txt` — identical for all 5
(byte-for-byte output stream match, not just digest equality).

## Unit table

| idx | TAG | module | EXP digest | bytes | LUT-class | DFF | BSRAM | DSP |
|-----|-----|--------|-----------|-------|-----------|-----|-------|-----|
| 35 | BC3  | bnn_conv3x3 | CE422C28 | 256 | ~145 | 59 | 0 | 0 |
| 36 | BDN  | bnn_dense   | 8792E554 | 16  | ~362 | 165| 0 | 0 |
| 37 | TMR  | tmr_voter (+tmr_reg) | DCA39FBD | 18 | ~69 (~94 tmr_reg) | 29 (54) | 0 | 0 |
| 38 | WDT  | wdt_win     | B93E6C10 | 11  | ~148 | 47 | 0 | 0 |
| 39 | LFSR | lfsr_prng (+lfsr_scrambler/lfsr_descrambler) | 9867D947 | 112 | ~34 (~60 scr/dscr) | 32 (41) | 0 | 0 |

LUT-class = LUT1..4 + MUX2_LUT5 + ALU from `synth_gowin -top <unit>; stat`
(yosys 0.64+181, GW2A).  All far under the 1500 LUT4 / 0 DSP budget.

## Interfaces

### bnn_conv3x3 #(IMG_W=16, IMG_H=16, NCH=2)
```
clk, clk_en, rst_n
pix, pix_valid, new_line            // 1-bit imgwin-contract stream
wcfg[NCH*9-1:0], thcfg[NCH*4-1:0]   // packed per-channel weights/thresholds
out[NCH-1:0], out_valid, out_nl, done
```
Internal 1-bit line buffers (2xIMG_W shift regs) + 3-tap column regs;
edge-replication borders identical to win3x3_gen (phantom column + flush
row).  Per output window: `out[ch] = popcount(~(win9 ^ w9_ch)) >= thr_ch`.
win9[i] = tap(r,c), i = r*3+c.  Output byte folded = {6'b0, out1, out0}.
st_ config: ch0 w9=9'b101100101 thr=5, ch1 w9=9'b011010011 thr=4;
stimulus = w2_img_stim 16x16x1 binarised (pix > 128).  Single frame per
reset.

### bnn_dense #(NIN=32, N=4)
```
clk, clk_en, rst_n
w_en, w_addr, w_data[31:0]          // weight write port (per neuron)
b_en, b_addr, b_data[7:0] signed    // bias write port
in_valid, in_vec[31:0] -> out_valid, out[N-1:0]   // 1-beat latency
```
`out[n] = (popcount(~(in_vec ^ w[n])) + bias[n]) >= 0`, bias signed.
st_: xorshift32 stream (seed 9E3779B9) supplies 4 weights, 4 signed-6-bit
biases, then 16 input vectors; folds {4'b0, out} per output beat.

### tmr_voter #(W=8) / tmr_reg #(W=8)
```
voter: in_valid, a,b,c[W-1:0] -> out_valid, y, mism_a/b/c, err,
       err_cnt[15:0] (sticky saturating), clr_cnt
tmr_reg: wr, din, fa/fb/fc (XOR fault masks), clr_cnt ->
       y, y_valid, mism_a/b/c, err, err_cnt   (triplicated regs voted 1
       beat after each write)
```
st_: 8 writes, single-bit fault on replica (i mod 3), bit i; write 7 clean.
Per vote folds {y, flags}; then err_cnt lo/hi (=7).  Internal checks:
y === din on every write, err_cnt==7, 8 votes.

### wdt_win #(WMIN=4, WMAX=9)
```
clk, clk_en, rst_n, en, kick, clr ->
reset_req (sticky), ev_good/ev_early/ev_late/ev_tout strobes,
cnt_good/cnt_early/cnt_late/cnt_tout[7:0] (saturating)
```
Kick classified by beats since last restart: <WMIN early, WMIN..WMAX good,
expired (cnt>WMAX) late; reaching WMAX+1 without kick = timeout + reset_req.
st_ schedule: kicks at t=7 (good), 10 (early), 16 (good); timeout at t=26;
late kick t=29; good kick t=35.  Folds event bytes (01/E1/1A/70) then the
four counters + reset_req.  Internal checks: counts == (3,1,1,1), rr==1.

### lfsr_prng / lfsr_scrambler / lfsr_descrambler
```
lfsr_prng:      seed_wr, seed[31:0], step -> state[31:0]
                Galois right-shift, taps {32,22,2,1}, mask 32'h8020_0003
scrambler:      seed_wr, seed, in_valid, din -> out_valid, dout
                c = din ^ k(s), s <= {s[23:0], c}
descrambler:    same but s <= {s[23:0], din} (shifts ciphertext in)
k(s) = s[7:0]^s[15:8]^s[23:16]^s[31:24]
```
Self-synchronous: descrambler state is fully determined by the last 4
ciphertext bytes — resyncs after 4 bytes from any seed.  st_: 16 PRNG
steps folded (state LSB-first, 64B); 16-byte plaintext (i*17+0x55)
scrambled -> folded; descrambled with correct seed -> folded (exact
round-trip checked); descrambler reseeded wrong (0BADF00D), ciphertext
replayed -> folded, bytes 4..15 checked == pt (self-sync demo).

## Known limits

- bnn_conv3x3: single frame per reset (done latches); IMG_W/IMG_H bounded
  by shift-register cost (no RAM used).  Extra input rows after IMG_H are
  ignored.
- bnn_dense: weights/bias live in DFF registers (N x 40 bits); for large N
  a RAM-backed variant would be needed.
- wdt_win: counters saturate at 8'hFF; `clr` clears counters+reset_req;
  `!en` disarms (cnt=0) but reset_req stays until clr/rst.
- lfsr scrambler pair: keystream = XOR-fold of state bytes (prototype-grade
  mixing, documented for test — not a security primitive).
- st_ cells expose `dbg_data[31:0]`/`dbg_cnt[2:0]` mirrors of every folded
  byte for TB dumping (`sim/dump_<unit>.txt`).

## Commands

```bash
export PATH="<repo>/tools/oss-cad-suite/oss-cad-suite/bin:.../lib:$PATH"
cd cores/system/extended_library
python tools/golden_acc.py                       # digests + golden_*.txt
iverilog -g2012 -I src -o sim/tb_st_<u>.vvp -s tb_st_<u> \
    sim/tb_st_<u>.v src/<u>.v src/st_<u>.v [src/w2_img_stim.v]
vvp sim/tb_st_<u>.vvp
diff sim/dump_<u>.txt sim/golden_<u>.txt
yosys -p "read_verilog -sv src/<u>.v; synth_gowin -top <u>; stat"
```
