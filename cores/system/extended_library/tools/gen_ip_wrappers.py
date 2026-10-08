#!/usr/bin/env python3
# ============================================================================
# gen_ip_wrappers.py -- generate standardized IP packages for wave2_ip_20k.
#
# Wave2 units have heterogeneous datapath interfaces; the validated artifact
# is the selftest cell st_<unit> (uniform contract: clk/clk_en/rst_n/start ->
# done/pass/digest/cycles).  Each package therefore wraps the st_ cell as
# gw2a_w2_<unit>; the manifest records the underlying core module, its
# sources, shared dependencies (auto-scanned), golden digest and evidence.
#
# Output tree (under cores/system/extended_library/ip/):
#   <unit>/gw2a_w2_<unit>.v   wrapper RTL
#   <unit>/ip_manifest.json   metadata
#   <unit>/README.md          usage notes
#   MANIFEST.md               index
# Run from cores/system/extended_library/ :  python tools/gen_ip_wrappers.py
# ============================================================================
import json
import os
import re

PROJ = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SRC = os.path.join(PROJ, "src")
IP_ROOT = os.path.join(PROJ, "ip")

# idx, unit (file base), tag, FNV-1a digest from unit selftest, description,
# known limitation note ("" if none)
UNITS = [
    (0,  "isp_dpc",       "DPC",  "660DE1FA", "ISP defect-pixel correction: 3x3 median replaces pixels failing a dead/hot threshold test.", ""),
    (1,  "isp_demosaic",  "DEM",  "43C5DA1F", "Bayer demosaic (RGGB) to RGB via neighbor averaging on a 3x3 window.", ""),
    (2,  "isp_awb",       "AWB",  "AF39F01C", "Auto white balance: gray-world frame statistics derive R/B gains applied to the next frame.", "First frame uses unity gain; NP must be a power of two."),
    (3,  "isp_gamma",     "GAM",  "61B5D82E", "Gamma correction via 256-entry LUT stored in BSRAM (DPX9B).", "Two-beat latency: registered BSRAM read plus output register."),
    (4,  "isp_csc",       "CSC",  "CE41D92D", "RGB<->YCbCr color-space conversion, fixed-point 8.8 coefficients.", ""),
    (5,  "isp_rgb2gray",  "GRY",  "9D413162", "RGB to grayscale: (77R+150G+29B)>>8 shift-add.", ""),
    (6,  "canny_grad",    "CGR",  "9764CD67", "Canny stage 1: Sobel gradient magnitude + 4-sector direction.", ""),
    (7,  "canny_nms",     "NMS",  "E28D6593", "Canny stage 2: non-maximum suppression along gradient direction.", "Frame-buffer/batch implementation, not a streaming stage."),
    (8,  "canny_dth",     "DTH",  "E2A5329F", "Canny stage 3: double threshold to strong/weak edge classes.", ""),
    (9,  "canny_hyst",    "HYS",  "6785454B", "Canny stage 4: hysteresis linking weak edges to strong ones.", "Single-pass local propagation, not iterative flood-fill."),
    (10, "feat_harris",   "HAR",  "AB859D8F", "Harris corner response from Ix/Iy window products.", ""),
    (11, "feat_fast",     "FST",  "E1DEB6B0", "FAST feature detector: serial doubled-ring scan (16 pixels) against center+/-threshold.", "Serial ring scan chosen for area over parallel comparators."),
    (12, "feat_lbp",      "LBP",  "45C677F3", "Local binary pattern: 8-neighbor threshold code per pixel.", ""),
    (13, "feat_hog",      "HOG",  "0AB2FBF5", "Histogram of oriented gradients over image cells.", ""),
    (14, "img_integral",  "INT",  "18ED7B54", "Integral (summed-area) image for O(1) box filters.", "18-bit row store; validated for the tested image range."),
    (15, "img_scaler",    "SCL",  "A34F3413", "Nearest/bilinear image scaler with configurable ratio.", ""),
    (16, "img_histogram", "HST",  "F14561DD", "256-bin image histogram with backpressured clear.", "Histogram clear introduces backpressure between frames."),
    (17, "hist_clahe",    "CLA",  "A267A0F3", "Contrast-limited adaptive histogram equalization.", "Simplified: 16-level bins, clip/renormalize, 3-bit interpolation fractions."),
    (18, "match_sad",     "SAD",  "A661F628", "Template matching by sum-of-absolute-differences search.", ""),
    (19, "img_crop",      "CRP",  "450E7855", "Axis-aligned region-of-interest crop on a pixel stream.", ""),
    (20, "frame_diff",    "FDIF", "6A760EBD", "Frame differencing: |cur-prev| > threshold motion mask.", ""),
    (21, "bg_model",      "BGS",  "17CD4105", "Running-average background model with foreground mask.", ""),
    (22, "mot_bbox",      "BBOX", "221B2F39", "Motion bounding box: min/max extents of a binary motion mask.", ""),
    (23, "ccl_bbox",      "CCL",  "84EA8E24", "Connected-component labeling with per-label bounding boxes (two-pass, union-find in w2_dpram banks).", ""),
    (24, "meas_proj",     "PRJ",  "1DBD11E7", "Row/column projection (histogram profile) of a binary image.", ""),
    (25, "can_ctrl",      "CAN",  "DC301204", "CAN 2.0 frame TX/RX controller with bit stuffing and CRC15.", "No bus arbitration/error frames; SOF hard synchronization only."),
    (26, "eth_mac_mii",   "MAC",  "7DC3E176", "Ethernet MAC, MII nibble interface, preamble/FCS handling.", "Half-duplex single-frame model; combinational tx_byte."),
    (27, "pwm_gen",       "PWM",  "89356055", "PWM generator with programmable period/duty.", ""),
    (28, "qei_dec",       "QEI",  "6E057083", "Quadrature encoder interface: 4x decode count + direction.", "Assumes synchronized external A/B inputs."),
    (29, "step_drv",      "STP",  "AAF87DCF", "Stepper motor driver: step/dir pulse generator with accel profile.", "Assumes tstart >= tmin."),
    (30, "dma_sg",        "DMA",  "92C91DF3", "Scatter-gather DMA: descriptor list walks src/dst/len transfers.", ""),
    (31, "ila_core",      "ILA",  "17852826", "Integrated logic analyzer: trigger + capture to BSRAM, UART readback.", "Pre-trigger depth is clamped to buffer capacity."),
    (32, "crc32_eth",     "CRC",  "CE9832E0", "Ethernet CRC32 (0xEDB88320) serial/byte engine.", ""),
    (33, "prbs31",        "PRBS", "DBA2F926", "PRBS31 generator/checker for link test.", ""),
    (34, "mem_bist",      "MBST", "C9D87DF5", "Memory BIST: march-style test over w2_dpram with fault injection hook.", ""),
    (35, "bnn_conv3x3",   "BC3",  "CE422C28", "Binarized 3x3 convolution: XNOR-popcount over window.", ""),
    (36, "bnn_dense",     "BDN",  "8792E554", "Binarized dense layer: XNOR-popcount dot products.", ""),
    (37, "tmr_voter",     "TMR",  "DCA39FBD", "Triple-modular-redundancy voter with per-input disagreement flags.", ""),
    (38, "wdt_win",       "WDT",  "B93E6C10", "Window watchdog: service only accepted inside an open window.", ""),
    (39, "lfsr_prng",     "LFSR", "9867D947", "LFSR/PRNG with programmable taps and seed.", ""),
]

SHARED = ["w2_dpram", "w2_win_rd", "w2_img_stim",
          "win3x3_gen", "line_buf_ram", "median3x3", "morph3x3",
          "sobel_edge", "threshold_bin", "gaussian3x3", "uart_tx"]
IMGWIN_DIR = "../imgwin_20k/src"

PROTO = ("unit selftest contract: pulse start (1 clk_en beat) after rst_n; "
         "cell runs its internal stimulus against the embedded DUT and "
         "raises done; pass==1 iff the FNV-1a digest equals the golden "
         "value and all output bytes matched the golden dump.  Verdicts "
         "use === so X cannot fake PASS.  Tie clk_en=1 for full rate.")


def scan_deps(unit):
    """Return (core_sources, shared_deps, uses_bsram) for unit's own files."""
    deps = set()
    bsram = False
    own = [f"src/{unit}.v", f"src/st_{unit}.v"]
    for rel in own:
        p = os.path.join(SRC, os.path.basename(rel))
        if not os.path.exists(p):
            continue
        txt = open(p).read()
        for m in SHARED:
            if re.search(r'\b' + m + r'\b', txt):
                deps.add(m)
        if re.search(r'\bDPX9B\b', txt):
            bsram = True
    srcs = [r for r in own if os.path.exists(os.path.join(SRC, os.path.basename(r)))]
    for d in sorted(deps):
        if d.startswith("w2_"):
            srcs.append(f"src/{d}.v")
        else:
            srcs.append(f"{IMGWIN_DIR}/{d}.v")
    return srcs, sorted(deps), bsram


def gen_rtl(unit, tag, digest):
    return f"""// ============================================================================
// gw2a_w2_{unit} -- wave2 selftest IP wrapper (GW2A-18C, Tang Primer 20K)
// Wraps st_{unit}: internal stimulus + DUT + golden-digest comparison.
// Validated: selftest unit {tag}, FNV-1a digest {digest},
//   iverilog unit sim + aggregate (full/lo/hi UNIT_EN masks) PASS.
// ============================================================================
module gw2a_w2_{unit} (
    input  wire        clk,
    input  wire        rst_n,    // active-low async reset
    input  wire        clk_en,   // step enable; tie 1 for full rate
    input  wire        start,    // 1-beat start pulse (clk_en domain)
    output wire        done,
    output wire        pass,
    output wire [31:0] digest,
    output wire [15:0] cycles
);
    st_{unit} u_cell (
        .clk(clk), .clk_en(clk_en), .rst_n(rst_n), .start(start),
        .done(done), .pass(pass), .digest(digest), .cycles(cycles)
    );
endmodule
"""


def gen_manifest(idx, unit, tag, digest, desc, note, srcs, deps, bsram):
    return {
        "ip_name": f"gw2a_w2_{unit}",
        "wrapper_module": f"gw2a_w2_{unit}",
        "selftest_cell": f"st_{unit}",
        "core_module": unit,
        "core_sources": srcs,
        "shared_dependencies": deps,
        "sim_aux_sources": (["sim/gowin_bsram_sim.v"] if bsram else []),
        "sim_note": ("core instantiates the Gowin DPX9B BSRAM primitive "
                     "directly; include sim/gowin_bsram_sim.v in iverilog "
                     "compiles for its behavioral model." if bsram else ""),
        "description": desc,
        "limitations": note,
        "clock_reset": {
            "clk": "single clock",
            "rst_n": "active-low async reset",
            "clk_en": "step enable on sequential logic; tie 1 for full rate",
        },
        "selftest_protocol": PROTO,
        "ports": [
            {"name": "clk", "dir": "input", "width": 1},
            {"name": "rst_n", "dir": "input", "width": 1},
            {"name": "clk_en", "dir": "input", "width": 1},
            {"name": "start", "dir": "input", "width": 1},
            {"name": "done", "dir": "output", "width": 1},
            {"name": "pass", "dir": "output", "width": 1},
            {"name": "digest", "dir": "output", "width": 32},
            {"name": "cycles", "dir": "output", "width": 16},
        ],
        "validation": {
            "selftest_unit_index": idx,
            "selftest_tag": tag,
            "golden_digest_fnv1a": digest,
            "golden_model": "tools/golden_*.py (independent Python model)",
            "sim": ("iverilog unit sim PASS (byte-exact golden dump) + "
                    "w2_selftest aggregate PASS (masks FFFFFFFFFF / "
                    "00000FFFFF / FFFFF00000)"),
            "board": ("PASS on Tang Primer 20K (GW2A-LV18PG256C8/I7) via "
                      "grouped -noalu bitstreams, UART report verified -- "
                      "see doc/VALIDATION_LOG.md. NOTE: board images MUST be "
                      "built with synth_gowin -noalu; GW2A ALU cells produce "
                      "wrong results for some input patterns on silicon."),
        },
    }


def gen_readme(unit, tag, digest, desc, note, srcs, bsram):
    s = f"# gw2a_w2_{unit}\n\n{desc}\n\n"
    s += f"- Wraps `st_{unit}` (selftest cell; core `{unit}`)\n"
    s += f"- Sources: `{', '.join(srcs)}`\n"
    s += f"- Golden digest (FNV-1a): `{digest}`\n"
    if note:
        s += f"- Limitation: {note}\n"
    if bsram:
        s += ("- Simulation: add `../../sim/gowin_bsram_sim.v` to iverilog "
              "compiles (core uses the DPX9B primitive directly).\n")
    s += f"\n## Protocol\n\n{PROTO}\n"
    s += ("\n## Ports\n\n| port | dir | width | note |\n|---|---|---|---|\n"
          "| clk | in | 1 | system clock |\n"
          "| rst_n | in | 1 | active-low async reset |\n"
          "| clk_en | in | 1 | step enable; tie 1 |\n"
          "| start | in | 1 | 1-beat run pulse |\n"
          "| done | out | 1 | selftest finished |\n"
          "| pass | out | 1 | digest + dump matched golden (=== checked) |\n"
          "| digest | out | 32 | FNV-1a of DUT output stream |\n"
          "| cycles | out | 16 | elapsed clk_en beats |\n")
    return s


def main():
    os.makedirs(IP_ROOT, exist_ok=True)
    idx_lines = ["# GW2A-18C wave2 IP package (40 units)\n\n",
                 "Vision / communication / system / reliability / BNN "
                 "selftest IPs for Tang Primer 20K "
                 "(GW2A-LV18PG256C8/I7, 27 MHz).  Each package wraps the "
                 "validated `st_<unit>` selftest cell; golden digests come "
                 "from independent Python models in `../tools/`.\n\n",
                 "Evidence: `../doc/VALIDATION_LOG.md`, unit dumps in "
                 "`../sim/`.\n\n",
                 "| # | IP | tag | digest | description |\n",
                 "|---|---|---|---|---|\n"]
    for (i, unit, tag, dg, desc, note) in UNITS:
        srcs, deps, bsram = scan_deps(unit)
        d = os.path.join(IP_ROOT, unit)
        os.makedirs(d, exist_ok=True)
        open(os.path.join(d, f"gw2a_w2_{unit}.v"), "w",
             newline="\n").write(gen_rtl(unit, tag, dg))
        open(os.path.join(d, "ip_manifest.json"), "w",
             newline="\n").write(json.dumps(
                 gen_manifest(i, unit, tag, dg, desc, note, srcs, deps, bsram),
                 indent=2, ensure_ascii=False))
        open(os.path.join(d, "README.md"), "w",
             newline="\n").write(gen_readme(unit, tag, dg, desc, note,
                                            srcs, bsram))
        idx_lines.append(f"| {i} | `gw2a_w2_{unit}` | {tag} | `{dg}` "
                         f"| {desc.split(':')[0].split('.')[0]} |\n")
    open(os.path.join(IP_ROOT, "MANIFEST.md"), "w",
         newline="\n").write("".join(idx_lines))
    print(f"wrote {len(UNITS)} IP packages under {IP_ROOT}")


if __name__ == "__main__":
    main()
