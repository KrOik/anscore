#!/usr/bin/env python3
# Generate standardized proprietary IP wrappers for the imgwin_20k streaming
# image kernels validated on GW2A-18C (6/6 selftest units, UART digest
# evidence in cores/image_processing/window/doc/board_uart_*.txt).
#
# Wrapper conventions (mirrors the cnn_systolic_20k package):
#   * module name  gw2a_img_<name>
#   * uniform ports first: clk, rst_n (active low), clk_en
#   * pixel-stream interface: pix + pix_valid + new_line in,
#     pix_out + out_valid + new_line_out (or win window bus) out
#   * the window-filter IPs embed win3x3_gen internally -- one shared
#     line-buffer/window generator, exactly as validated
#
# Output tree (under cores/image_processing/window/ip/):
#   <ip>/gw2a_img_<ip>.v      wrapper RTL
#   <ip>/ip_manifest.json     metadata: params, ports, digest, evidence
#   <ip>/README.md            port map + timing/usage notes
#   MANIFEST.md               index

import json
import os

PROJ = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
IP_ROOT = os.path.join(PROJ, "ip")

BORDER = ("edge replication (clamp): tap(r,c) = I[clamp(y+r-1,0,H-1)]"
          "[clamp(x+c-1,0,W-1)]; identical in tools/golden_model.py")

IPS = [
    dict(
        name="win3x3_gen", cores=["win3x3_gen", "line_buf_ram"],
        srcs=["src/win3x3_gen.v", "src/line_buf_ram.v"],
        units="0 (WIN)", digest="BD71944D",
        desc="Shared line-buffer + 3x3 window extractor: 2 BSRAM line "
             "buffers + column taps, emits one 9-tap window per output "
             "pixel in row-major order with edge-replication borders.",
        params=[("IMG_W", "16", "pixels per line (line-buffer depth)"),
                ("IMG_H", "16", "lines per frame")],
        ports=[
            ("pix", "input", "8", "gray pixel in"),
            ("pix_valid", "input", "1", "pixel beat valid"),
            ("new_line", "input", "1", "1-beat pulse before each input row"),
            ("win", "output", "72", "9 taps, win[i*8+:8] = tap(i), i=r*3+c"),
            ("win_valid", "output", "1", "window emitted this beat"),
            ("new_line_out", "output", "1", "first window of output row"),
            ("done", "output", "1", "frame flush complete"),
        ]),
    dict(
        name="gaussian3x3", cores=["gaussian3x3", "win3x3_gen", "line_buf_ram"],
        srcs=["src/gaussian3x3.v", "src/win3x3_gen.v", "src/line_buf_ram.v"],
        units="1 (GAUS)", digest="1C69D353",
        desc="3x3 Gaussian blur (1/16)*[[1,2,1],[2,4,2],[1,2,1]], shift-add "
             "only. Wraps win3x3_gen + gaussian3x3.",
        params=[("IMG_W", "16", ""), ("IMG_H", "16", "")],
        ports=[
            ("pix", "input", "8", "gray pixel in"),
            ("pix_valid", "input", "1", "pixel beat valid"),
            ("new_line", "input", "1", "1-beat pulse before each input row"),
            ("pix_out", "output", "8", "blurred pixel out"),
            ("out_valid", "output", "1", "output valid"),
            ("new_line_out", "output", "1", "first pixel of output row"),
            ("done", "output", "1", "frame flush complete"),
        ]),
    dict(
        name="sobel_edge", cores=["sobel_edge", "win3x3_gen", "line_buf_ram"],
        srcs=["src/sobel_edge.v", "src/win3x3_gen.v", "src/line_buf_ram.v"],
        units="2 (SOB)", digest="E1762120",
        desc="3x3 Sobel edge: |Gx|+|Gy| saturating 8-bit magnitude plus "
             "thresholded binary output. Wraps win3x3_gen + sobel_edge.",
        params=[("IMG_W", "16", ""), ("IMG_H", "16", ""),
                ("THRESH", "8'd96", "binary threshold on magnitude")],
        ports=[
            ("pix", "input", "8", "gray pixel in"),
            ("pix_valid", "input", "1", "pixel beat valid"),
            ("new_line", "input", "1", "1-beat pulse before each input row"),
            ("mag_out", "output", "8", "edge magnitude, saturating"),
            ("bin_out", "output", "8", "8'hFF/8'h00 thresholded edge"),
            ("out_valid", "output", "1", "output valid"),
            ("new_line_out", "output", "1", "first pixel of output row"),
            ("done", "output", "1", "frame flush complete"),
        ]),
    dict(
        name="median3x3", cores=["median3x3", "win3x3_gen", "line_buf_ram"],
        srcs=["src/median3x3.v", "src/win3x3_gen.v", "src/line_buf_ram.v"],
        units="3 (MED)", digest="A3A98A3C",
        desc="3x3 median via 7x sort3 row/col/diagonal network (verified "
             "exhaustively in golden model). Wraps win3x3_gen + median3x3.",
        params=[("IMG_W", "16", ""), ("IMG_H", "16", "")],
        ports=[
            ("pix", "input", "8", "gray pixel in"),
            ("pix_valid", "input", "1", "pixel beat valid"),
            ("new_line", "input", "1", "1-beat pulse before each input row"),
            ("pix_out", "output", "8", "median pixel out"),
            ("out_valid", "output", "1", "output valid"),
            ("new_line_out", "output", "1", "first pixel of output row"),
            ("done", "output", "1", "frame flush complete"),
        ]),
    dict(
        name="morph3x3", cores=["morph3x3", "win3x3_gen", "line_buf_ram"],
        srcs=["src/morph3x3.v", "src/win3x3_gen.v", "src/line_buf_ram.v"],
        units="4 (MRP)", digest="3E86450A",
        desc="3x3 binary morphology on a binary image (taps !=0 count as "
             "set): mode-selectable erode (AND tree) / dilate (OR tree). "
             "Wraps win3x3_gen + morph3x3.",
        params=[("IMG_W", "16", ""), ("IMG_H", "16", "")],
        ports=[
            ("pix", "input", "8", "binary pixel in (0 / nonzero)"),
            ("pix_valid", "input", "1", "pixel beat valid"),
            ("new_line", "input", "1", "1-beat pulse before each input row"),
            ("mode", "input", "1", "0 = erode, 1 = dilate"),
            ("pix_out", "output", "8", "8'hFF/8'h00 selected result"),
            ("erode_out", "output", "8", "raw erode result"),
            ("dilate_out", "output", "8", "raw dilate result"),
            ("out_valid", "output", "1", "output valid"),
            ("new_line_out", "output", "1", "first pixel of output row"),
            ("done", "output", "1", "frame flush complete"),
        ]),
    dict(
        name="threshold_bin", cores=["threshold_bin"],
        srcs=["src/threshold_bin.v"],
        units="5 (THR)", digest="9FFADFC0",
        desc="Fixed-threshold binarizer: pix>=THRESH -> 8'hFF else 8'h00. "
             "Passes the pixel-stream protocol through with 1-beat latency.",
        params=[("THRESH", "8'd128", "binarization threshold")],
        ports=[
            ("pix", "input", "8", "gray pixel in"),
            ("pix_valid", "input", "1", "pixel beat valid"),
            ("new_line", "input", "1", "row-start pulse (passed through)"),
            ("pix_out", "output", "8", "8'hFF/8'h00 out"),
            ("out_valid", "output", "1", "output valid"),
            ("new_line_out", "output", "1", "delayed row marker"),
        ]),
]

HEADER = """// ============================================================================
// gw2a_img_{name} -- proprietary IP wrapper (Cognition dev kit, GW2A-18C)
// Cores: {cores}  ({srcs})
// Board-validated: selftest unit {units}, golden digest {digest},
//   bitstream cores/image_processing/window/build_oss/imgwin_20k.fs
// Border policy: {border}
// ============================================================================
"""

PROTO = ("input rows: dedicated 1-beat new_line then IMG_W pix_valid beats; "
         "output: IMG_H x IMG_W results in row-major order, out_valid per "
         "beat, new_line_out on first result of each row. All sequential "
         "logic gated by clk_en (tie 1 for full-rate operation).")


def gen_rtl(ip):
    n = ip["name"]
    out = [HEADER.format(name=n, cores="+".join(ip["cores"]),
                         srcs=", ".join(ip["srcs"]), units=ip["units"],
                         digest=ip["digest"], border=BORDER)]
    plines = []
    for i, p in enumerate(ip["params"]):
        c = "," if i < len(ip["params"]) - 1 else " "
        note = f"  // {p[2]}" if len(p) > 2 and p[2] else ""
        plines.append(f"    parameter {p[0]} = {p[1]}{c}{note}")
    out.append(f"module gw2a_img_{n} #(\n" + "\n".join(plines) + "\n)(\n")
    pins = [("input", "", "clk", "system clock"),
            ("input", "", "rst_n", "active-low async reset"),
            ("input", "", "clk_en", "step enable; tie 1 for full rate")]
    for p in ip["ports"]:
        w = "" if p[2] == "1" else f"[{int(p[2])-1}:0] "
        pins.append((p[1], w, p[0], p[3]))
    plines2 = []
    for i, (d, w, nm, note) in enumerate(pins):
        c = "," if i < len(pins) - 1 else " "
        plines2.append(f"    {d:<6} wire {w}{nm:<14}{c} // {note}")
    out.append("\n".join(plines2) + "\n);\n\n")

    if n == "win3x3_gen":
        out.append("""    win3x3_gen #(.IMG_W(IMG_W), .IMG_H(IMG_H)) u_core (
        .clk(clk), .clk_en(clk_en), .rst_n(rst_n),
        .pix(pix), .pix_valid(pix_valid), .new_line(new_line),
        .win(win), .win_valid(win_valid),
        .new_line_out(new_line_out), .done(done)
    );
endmodule
""")
    elif n == "threshold_bin":
        out.append("""    threshold_bin #(.THRESH(THRESH)) u_core (
        .clk(clk), .clk_en(clk_en), .rst_n(rst_n),
        .pix(pix), .pix_valid(pix_valid), .new_line(new_line),
        .pix_out(pix_out), .out_valid(out_valid),
        .new_line_out(new_line_out)
    );
endmodule
""")
    else:
        # window generator + filter
        filt = {"gaussian3x3": "gaussian3x3", "sobel_edge": "sobel_edge",
                "median3x3": "median3x3", "morph3x3": "morph3x3"}[n]
        out.append(f"""    wire [71:0] win_w;
    wire        wv_w, nlo_w;

    win3x3_gen #(.IMG_W(IMG_W), .IMG_H(IMG_H)) u_gen (
        .clk(clk), .clk_en(clk_en), .rst_n(rst_n),
        .pix(pix), .pix_valid(pix_valid), .new_line(new_line),
        .win(win_w), .win_valid(wv_w),
        .new_line_out(nlo_w), .done(done)
    );

""")
        if n == "gaussian3x3":
            out.append("""    gaussian3x3 u_f (
        .clk(clk), .clk_en(clk_en), .rst_n(rst_n),
        .win(win_w), .win_valid(wv_w), .new_line_out(nlo_w),
        .pix_out(pix_out), .out_valid(out_valid), .nl_out(new_line_out)
    );
endmodule
""")
        elif n == "sobel_edge":
            out.append("""    sobel_edge #(.THRESH(THRESH)) u_f (
        .clk(clk), .clk_en(clk_en), .rst_n(rst_n),
        .win(win_w), .win_valid(wv_w), .new_line_out(nlo_w),
        .mag_out(mag_out), .bin_out(bin_out),
        .out_valid(out_valid), .nl_out(new_line_out)
    );
endmodule
""")
        elif n == "median3x3":
            out.append("""    median3x3 u_f (
        .clk(clk), .clk_en(clk_en), .rst_n(rst_n),
        .win(win_w), .win_valid(wv_w), .new_line_out(nlo_w),
        .pix_out(pix_out), .out_valid(out_valid), .nl_out(new_line_out)
    );
endmodule
""")
        elif n == "morph3x3":
            out.append("""    morph3x3 u_f (
        .clk(clk), .clk_en(clk_en), .rst_n(rst_n),
        .win(win_w), .win_valid(wv_w), .new_line_out(nlo_w),
        .mode(mode),
        .pix_out(pix_out), .erode_out(erode_out),
        .dilate_out(dilate_out),
        .out_valid(out_valid), .nl_out(new_line_out)
    );
endmodule
""")
    return "".join(out)


def gen_manifest(ip):
    return {
        "ip_name": f"gw2a_img_{ip['name']}",
        "core_modules": ip["cores"],
        "core_sources": ip["srcs"],
        "sim_aux_sources": (["sim/gowin_bsram_sim.v"]
                            if "line_buf_ram" in ip["cores"] else []),
        "sim_note": ("line_buf_ram instantiates the Gowin DPX9B BSRAM "
                     "primitive directly (18-bit mode, addrbe-encoded "
                     "addresses); include sim/gowin_bsram_sim.v in iverilog "
                     "compiles for its behavioral model."
                     if "line_buf_ram" in ip["cores"] else ""),
        "description": ip["desc"],
        "clock_reset": {
            "clk": "single clock",
            "rst_n": "active-low async reset",
            "clk_en": "step enable on every sequential element; tie 1 for full rate",
        },
        "stream_protocol": PROTO,
        "border_policy": BORDER,
        "parameters": [{"name": p[0], "default": p[1],
                        **({"note": p[2]} if len(p) > 2 and p[2] else {})}
                       for p in ip["params"]],
        "ports": [{"name": p[0], "dir": p[1], "width": int(p[2]),
                   "signed": False, "note": p[3]} for p in ip["ports"]],
        "signedness": "all data ports unsigned 8-bit",
        "mem_files": "none (no $readmemh dependencies)",
        "dsp_usage": "0 (shift-add only)",
        "validation": {
            "selftest_unit": ip["units"],
            "golden_digest_fnv1a_16x16": ip["digest"],
            "sim": "iverilog PASS (full 3F / mask 0F / mask 30) + UART report",
            "board": {
                "board": "Sipeed Tang Primer 20K", "device": "GW2A-LV18PG256C8/I7",
                "bitstream": "build_oss/imgwin_20k.fs", "uart": "115200@COM24",
                "evidence": "doc/board_uart_full.txt",
            },
        },
    }


def gen_readme(ip):
    n = ip["name"]
    lines = [f"# gw2a_img_{n}\n\n{ip['desc']}\n\n"]
    lines.append(f"- Cores: `{', '.join(ip['cores'])}` (`{', '.join(ip['srcs'])}`)\n")
    lines.append(f"- Validated: selftest unit {ip['units']}, golden digest "
                 f"`{ip['digest']}` (16x16 formula image, FNV-1a)\n")
    lines.append(f"- Board evidence: `../../doc/board_uart_full.txt`\n")
    if "line_buf_ram" in ip["cores"]:
        lines.append("- Simulation: include `../../sim/gowin_bsram_sim.v` in "
                     "iverilog compiles (line_buf_ram instantiates the "
                     "Gowin DPX9B primitive directly; the file provides its "
                     "behavioral model).\n")
    lines.append("\n")
    lines.append("## Ports\n\n| port | dir | width | note |\n|---|---|---|---|\n")
    lines.append("| clk | in | 1 | system clock |\n")
    lines.append("| rst_n | in | 1 | active-low async reset |\n")
    lines.append("| clk_en | in | 1 | step enable; tie 1 for full rate |\n")
    for p in ip["ports"]:
        lines.append(f"| {p[0]} | {p[1]} | {p[2]} | {p[3]} |\n")
    lines.append("\n## Parameters\n\n| name | default | note |\n|---|---|---|\n")
    for p in ip["params"]:
        lines.append(f"| {p[0]} | {p[1]} | {p[2] if len(p)>2 else ''} |\n")
    lines.append(f"\n## Stream protocol\n\n{PROTO}\n")
    lines.append(f"\n## Border policy\n\n{BORDER}\n")
    return "".join(lines)


def main():
    os.makedirs(IP_ROOT, exist_ok=True)
    index = ["# GW2A-18C validated imgwin IP package\n\n",
             "Streaming image-processing kernels for Tang Primer 20K "
             "(GW2A-LV18PG256C8/I7, 27 MHz). Every IP passed RTL sim "
             "(iverilog, 3 UNIT_EN masks) and on-board UART digest "
             "validation.\n",
             "Evidence: `../doc/board_uart_full.txt`, "
             "`../doc/VALIDATION_LOG.md`.\n\n",
             "| IP | cores | selftest unit | digest |\n|---|---|---|---|\n"]
    for ip in IPS:
        d = os.path.join(IP_ROOT, ip["name"])
        os.makedirs(d, exist_ok=True)
        open(os.path.join(d, f"gw2a_img_{ip['name']}.v"), "w").write(gen_rtl(ip))
        open(os.path.join(d, "ip_manifest.json"), "w").write(
            json.dumps(gen_manifest(ip), indent=2, ensure_ascii=False))
        open(os.path.join(d, "README.md"), "w").write(gen_readme(ip))
        index.append(f"| `gw2a_img_{ip['name']}` | `{'+'.join(ip['cores'])}` "
                     f"| {ip['units']} | {ip['digest']} |\n")
    open(os.path.join(IP_ROOT, "MANIFEST.md"), "w").write("".join(index))
    print(f"wrote {len(IPS)} IP packages under {IP_ROOT}")


if __name__ == "__main__":
    main()
