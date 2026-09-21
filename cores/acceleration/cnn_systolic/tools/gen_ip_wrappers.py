#!/usr/bin/env python3
# Generate standardized proprietary IP wrappers for the CNN_FPGA modules that
# passed GW2A-18C board validation (16/16 selftest units, UART digest evidence
# in cores/acceleration/cnn_systolic/doc/board_uart_m{00ff,ff00}.txt).
#
# Wrapper conventions:
#   * module name  gw2a_cnn_<name>
#   * uniform ports first: clk, rst_n (active low), clk_en
#   * packed array ports are flattened to [N*W-1:0] vectors, element i at
#     bits [i*W +: W]  (same layout as SystemVerilog packed arrays)
#   * cores that have no rst_n/clk_en pin still get the uniform ports; the
#     manifest marks them "unused" so integration intent stays explicit.
#
# Output tree (under cores/acceleration/cnn_systolic/ip/):
#   <ip>/gw2a_cnn_<ip>.v      wrapper RTL (instantiates the validated core)
#   <ip>/ip_manifest.json     metadata: params, ports, digest, evidence
#   <ip>/README.md            port map + timing/usage notes
#   MANIFEST.md               index of all packaged IPs

import json
import os

PROJ = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))  # cores/acceleration/cnn_systolic
IP_ROOT = os.path.join(PROJ, "ip")

# ---------------------------------------------------------------------------
# spec table
# port tuple: (name, dir, width_expr, signed, dims, note)
#   dims = None            -> scalar / flat vector of width_expr
#   dims = (A,)            -> packed [A-1:0][W-1:0], flattened to A*W
#   dims = (A, B)          -> packed [A-1:0][B-1:0][W-1:0], flattened to A*B*W
# ---------------------------------------------------------------------------
IPS = [
    dict(
        name="pe", core="pe", src="src/pe.v", units="0 (PE) / 1 (PED, USE_DSP_PE=yes)",
        digest="B865EC67", board="m00ff",
        desc="Single MAC pipeline element: y_out <= D*W + y_in (2-stage).",
        params=[("DATA_WIDTH", "7"), ("WEIGHT_WIDTH", "8"),
                ("ADDER2_WIDTH", "18"), ("OUTPUT_WIDTH", "19"),
                ("USE_DSP_PE", '"no"', "set \"yes\" to use DSP mult (PED path)")],
        rstn=False,
        ports=[
            ("D", "input", "DATA_WIDTH", False, None, "unsigned pixel data"),
            ("W", "input", "WEIGHT_WIDTH", True, None, "signed weight"),
            ("y_in", "input", "ADDER2_WIDTH", True, None, "signed chain input"),
            ("y_out", "output", "OUTPUT_WIDTH", True, None, "signed chain output, latency 2"),
        ]),
    dict(
        name="pe_col", core="pe_col", src="src/pe_col.v", units="6 (COL)",
        digest="D149A670", board="m00ff",
        desc="Kernel-unrolled MAC chain: PE_ROW_NUM cascaded pe elements.",
        params=[("PE_ROW_NUM", "9"), ("DATA_WIDTH", "7"), ("WEIGHT_WIDTH", "8"),
                ("OUTPUT_WIDTH", "DATA_WIDTH + WEIGHT_WIDTH + $clog2(PE_ROW_NUM+1)"),
                ("USE_DSP_PE", '"no"')],
        rstn=False,
        ports=[
            ("D", "input", "DATA_WIDTH", False, ("PE_ROW_NUM",), "unrolled kernel data"),
            ("W", "input", "WEIGHT_WIDTH", True, ("PE_ROW_NUM",), "unrolled kernel weights"),
            ("y_out", "output", "OUTPUT_WIDTH", True, None, "dot-product result"),
        ]),
    dict(
        name="pe_page", core="pe_page", src="src/pe_page.v", units="7 (PAGE)",
        digest="C5BAB594", board="m00ff",
        desc="Output-channel-parallel page: PE_COL_NUM pe_col + weight ROM cycling.",
        params=[("PE_ROW_NUM", "9"), ("PE_COL_NUM", "2"), ("DATA_WIDTH", "7"),
                ("WEIGHT_WIDTH", "8"), ("CYCLE_PERIOD", "2"),
                ("OUTPUT_WIDTH", "DATA_WIDTH + WEIGHT_WIDTH + $clog2(PE_ROW_NUM+1)"),
                ("USE_DSP_PE", '"no"'),
                ("WEIGHT_FILE", '"pepage_weight.mem"', "$readmemb weight init")],
        rstn=False,
        ports=[
            ("new_line_1", "input", "1", False, None, "row-start pulse, 1 beat before first data"),
            ("data", "input", "DATA_WIDTH", False, ("PE_ROW_NUM",), "one input row beat"),
            ("y_out", "output", "OUTPUT_WIDTH", True, ("PE_COL_NUM",), "per-column results"),
        ]),
    dict(
        name="d_manager", core="d_manager", src="src/d_manager.v", units="2 (DM)",
        digest="783B6C25", board="m00ff",
        desc="Data skew/deskew manager: per-row staggered delay lines.",
        params=[("PE_ROW_NUM", "9"), ("DATA_WIDTH", "7")],
        rstn=False,
        ports=[
            ("data", "input", "DATA_WIDTH", False, ("PE_ROW_NUM",), "input stream"),
            ("D", "output", "DATA_WIDTH", False, ("PE_ROW_NUM",), "aligned output stream"),
        ]),
    dict(
        name="w_manager", core="w_manager", src="src/w_manager.v", units="3 (WM)",
        digest="6A9E1AC5", board="m00ff",
        desc="Weight sequencer: cyclic BSRAM/LUT-ROM readout, [col][row] layout.",
        params=[("PE_ROW_NUM", "9"), ("PE_COL_NUM", "2"), ("WEIGHT_WIDTH", "8"),
                ("CYCLE_PERIOD", "2"),
                ("WEIGHT_FILE", '"wm_test.mem"', "$readmemb weight init")],
        rstn=False,
        ports=[
            ("new_line_1", "input", "1", False, None, "restart weight sequence"),
            ("W_out", "output", "WEIGHT_WIDTH", True,
             ("PE_COL_NUM", "PE_ROW_NUM"), "weight matrix, [col][row] order"),
        ]),
    dict(
        name="sdp_ram", core="sdp_ram", src="src/sdp_ram.v", units="4 (RAM)",
        digest="2339D078", board="m00ff",
        desc="Simple dual-port RAM, sync write + sync read (ram_style=block).",
        params=[("WIDTH", "21"), ("DEPTH", "128"),
                ("AW", "(DEPTH > 1) ? $clog2(DEPTH) : 1", "address width")],
        rstn=False,
        ports=[
            ("we", "input", "1", False, None, "write enable (needs clk_en)"),
            ("waddr", "input", "AW", False, None, "write address"),
            ("wdata", "input", "WIDTH", False, None, "write data"),
            ("re", "input", "1", False, None, "read enable (needs clk_en)"),
            ("raddr", "input", "AW", False, None, "read address"),
            ("q", "output", "WIDTH", False, None, "registered read data"),
        ]),
    dict(
        name="my_fifo", core="my_fifo", src="src/my_fifo.v", units="5 (FIFO)",
        digest="D0C7C975", board="m00ff",
        desc="Async-clock FIFO with Gray-code pointers (rd_clk/wr_clk domains).",
        params=[("DATA_WIDTH", "8"), ("FIFO_DEPTH", "16")],
        rstn=False, fifo=True,
        ports=[
            ("rst", "input", "1", False, None, "async reset, ACTIVE HIGH"),
            ("wr_en", "input", "1", False, None, "write enable"),
            ("din", "input", "DATA_WIDTH", False, None, "write data"),
            ("rd_en", "input", "1", False, None, "read enable"),
            ("dout", "output", "DATA_WIDTH", False, None, "read data"),
            ("full", "output", "1", False, None, "wr domain"),
            ("empty", "output", "1", False, None, "rd domain"),
        ]),
    dict(
        name="max_pool2d", core="max_pool2d", src="src/max_pool2d.v", units="8 (POOL)",
        digest="35A02396", board="mff00",
        desc="Unsigned maximum over PE_ROW_NUM lanes, with two enabled pipeline stages.",
        reset_description="active-low asynchronous",
        params=[("PE_ROW_NUM", "9"), ("DATA_WIDTH", "7")],
        rstn=True,
        ports=[
            ("new_line_1", "input", "1", False, None, "row-start pulse"),
            ("input_valid", "input", "1", False, None, "data beat valid"),
            ("data", "input", "DATA_WIDTH", False, ("PE_ROW_NUM",), "page row data"),
            ("y_out", "output", "DATA_WIDTH", False, None, "pooled result"),
            ("new_line_out_1", "output", "1", False, None, "delayed row marker"),
            ("output_valid", "output", "1", False, None, "result valid"),
        ]),
    dict(
        name="activation_lut", core="activation_lut", src="src/activation_lut.v",
        units="9 (ALUT)", digest="830A5F5F", board="mff00",
        desc="Registered file-initialized lookup; shipped default table is unsigned saturation, not sigmoid.",
        params=[("INPUT_WIDTH", "13"), ("OUTPUT_WIDTH", "8"),
                ("CONV_POSITIVE", "1"),
                ("LUT_FILE", '"sigmoid_lut_8bit_to_8bit_h.mem"', "$readmemh init")],
        rstn=False, clken=False,
        ports=[
            ("in_valid", "input", "1", False, None, "input beat valid"),
            ("val_in", "input", "INPUT_WIDTH", False, None, "LUT address / value"),
            ("out_valid", "output", "1", False, None, "result valid (1-cycle latency)"),
            ("confidence_out", "output", "OUTPUT_WIDTH", False, None, "activation result"),
        ]),
    dict(
        name="input_layer", core="input_layer", src="src/input_layer.v",
        units="10 (IL)", digest="41C4C21F", board="mff00",
        desc="Ping-pong line buffers + pixel window assembler; emits KERNEL_ROW x KERNEL_COL sliding windows.",
        params=[("DATA_WIDTH", "8"), ("PE_PAGE_NUM", "2"), ("PE_ROW_NUM", "9"),
                ("CYCLE_PERIOD_IN", "1"), ("CYCLE_PERIOD_OUT", "2"),
                ("STEP_ROW", "1"), ("STEP_COL", "1"),
                ("KERNEL_ROW", "3"), ("KERNEL_COL", "3"),
                ("IMG_COL", "8"), ("IMG_ROW", "6")],
        rstn=True,
        ports=[
            ("new_line_input_1", "input", "1", False, None, "pulse before each input row"),
            ("data_input_valid", "input", "1", False, None, "pixel beat valid"),
            ("data_input", "input", "DATA_WIDTH", False, ("PE_PAGE_NUM",), "page lanes per beat"),
            ("data_out", "output", "DATA_WIDTH", False,
             ("PE_ROW_NUM", "PE_PAGE_NUM"), "conv window, [row][page]"),
            ("line_buf_full", "output", "1", False, None, "line buffer backpressure"),
            ("data_out_valid", "output", "1", False, None, "window valid"),
            ("new_line_out_1", "output", "1", False, None, "window row marker"),
        ]),
    dict(
        name="output_layer", core="output_layer", src="src/output_layer.v",
        units="11 (OL)", digest="46E9E19D", board="mff00",
        desc="Channel accumulate + bias + shift + ReLU quantize stage.",
        params=[("PE_PAGE_NUM", "2"), ("PE_COL_NUM", "2"), ("PE_ROW_NUM", "9"),
                ("PE_OUT_WIDTH", "20"), ("BIAS_WIDTH", "16"), ("ACC_WIDTH", "22"),
                ("SHIFT_KEY", "4"), ("OUT_WIDTH", "8"),
                ("CYCLE_PERIOD_OUT", "2"), ("CYCLE_PERIOD_IN", "1"),
                ("IMG_COL", "8"), ("WITH_RELU", "1"),
                ("BIAS_FILE", '"bias_test.mem"', "$readmemh bias init")],
        rstn=True,
        ports=[
            ("new_line_in", "input", "1", False, None, "row sync from input_layer"),
            ("page_y_out", "input", "PE_OUT_WIDTH", True,
             ("PE_PAGE_NUM", "PE_COL_NUM"), "partial sums [page][col]"),
            ("final_out", "output", "OUT_WIDTH", False, ("PE_COL_NUM",), "quantized output"),
            ("output_valid", "output", "1", False, None, "result valid"),
            ("new_line_out_1", "output", "1", False, None, "row marker"),
        ]),
    dict(
        name="conv_layer", core="lprnet_layer_direct", src="src/layer.v",
        units="12 (LAYR)", digest="9A9AEA61", board="mff00",
        desc="Full conv layer: input_layer + pe_page array + output_layer, streaming in/out.",
        params=[("PE_PAGE_NUM", "2"), ("PE_ROW_NUM", "9"), ("KERNEL_COL", "3"),
                ("KERNEL_ROW", "3"), ("PE_COL_NUM", "2"), ("MAX_POOL", "0"),
                ("WITH_RELU", "1"), ("DATA_WIDTH", "8"), ("WEIGHT_WIDTH", "9"),
                ("CYCLE_PERIOD_OUT", "2"), ("CYCLE_PERIOD_IN", "1"),
                ("IMG_COL", "8"), ("IMG_ROW", "6"),
                ("STEP_ROW", "1"), ("STEP_COL", "1"), ("USE_DSP_PE", '"no"'),
                ("SHIFT_KEY", "4"), ("BIAS_WIDTH", "16"), ("OUT_WIDTH", "8"),
                ("WEIGHT_FILE0", '"pepage_weight.mem"'), ("WEIGHT_FILE1", '"pepage_weight.mem"'),
                ("WEIGHT_FILE2", '"pepage_weight.mem"'), ("WEIGHT_FILE3", '"pepage_weight.mem"'),
                ("BIAS_FILE", '"bias_test.mem"')],
        rstn=True,
        ports=[
            ("new_line_input_1", "input", "1", False, None, "pulse before each input row"),
            ("data_input_valid", "input", "1", False, None, "pixel beat valid"),
            ("data_input", "input", "DATA_WIDTH", False, ("PE_PAGE_NUM",), "input lanes"),
            ("y_out", "output", "OUT_WIDTH", False, ("PE_COL_NUM",), "conv result"),
            ("new_line_out_1", "output", "1", False, None, "row marker"),
            ("output_valid", "output", "1", False, None, "result valid"),
        ]),
    dict(
        name="extrema_finder", core="extrema_finder", src="src/extrema_finder.v",
        units="13 (EXTR)", digest="931885AA", board="mff00",
        desc="Per-frame argmax/argmin over PE_COL_NUM x CYCLE_PERIOD_OUT channels.",
        params=[("DATA_WIDTH", "8"), ("PE_COL_NUM", "2"), ("CYCLE_PERIOD_OUT", "2"),
                ("CONV_POSITIVE", "1"),
                ("CHW", "$clog2(CYCLE_PERIOD_OUT*PE_COL_NUM)", "channel index width")],
        rstn=True,
        ports=[
            ("data_input_valid", "input", "1", False, None, "data beat valid"),
            ("new_line_1", "input", "1", False, None, "reset cycle counter per row"),
            ("data_in", "input", "DATA_WIDTH", True, ("PE_COL_NUM",), "signed samples"),
            ("val_out", "output", "DATA_WIDTH", True, None, "extremum value"),
            ("val_out_channel", "output", "CHW", False, None, "winning channel index"),
            ("val_valid", "output", "1", False, None, "result valid"),
        ]),
    dict(
        name="lprnet_spatial_sum", core="lprnet_spatial_sum", src="src/lprnet_spatial_sum.v",
        units="14 (SSUM)", digest="77330EC1", board="mff00",
        desc="Signed accumulation across image rows for each column/channel position (LPRNet head stage).",
        reset_description="active-low asynchronous",
        params=[("PE_COL_NUM", "2"), ("CYCLE_PERIOD_OUT", "2"),
                ("IMG_COL", "8"), ("IMG_ROW", "6"),
                ("DATA_WIDTH", "8"), ("ACC_WIDTH", "16")],
        rstn=True,
        ports=[
            ("new_line_input_1", "input", "1", False, None, "pulse before each row"),
            ("data_input_valid", "input", "1", False, None, "data beat valid"),
            ("data_input", "input", "DATA_WIDTH", True, ("PE_COL_NUM",), "signed samples"),
            ("y_out", "output", "ACC_WIDTH", True, ("PE_COL_NUM",), "row sums"),
            ("new_line_out_1", "output", "1", False, None, "row marker"),
            ("output_valid", "output", "1", False, None, "result valid"),
        ]),
    dict(
        name="lprnet_post_process", core="lprnet_post_process", src="src/lprnet_post_process.v",
        units="15 (CTC)", digest="ED74208A", board="mff00",
        desc="Spatial sum + argmax + CTC decode chain (LPRNet head).",
        params=[("PE_COL_NUM", "2"), ("CYCLE_PERIOD_OUT", "2"),
                ("IMG_COL", "8"), ("IMG_ROW", "6"),
                ("DATA_WIDTH", "8"), ("ACC_WIDTH", "16"),
                ("CONV_POSITIVE", "1"), ("BLANK_CHAR", "3"), ("VALID_CHAR_NUM", "4"),
                ("OCHW", "$clog2(CYCLE_PERIOD_OUT*PE_COL_NUM)", "char index width")],
        rstn=True,
        ports=[
            ("new_line_input_1", "input", "1", False, None, "pulse before each row"),
            ("data_input_valid", "input", "1", False, None, "data beat valid"),
            ("data_input", "input", "DATA_WIDTH", True, ("PE_COL_NUM",), "signed samples"),
            ("out_char", "output", "OCHW", False, None, "decoded channel index"),
            ("out_valid", "output", "1", False, None, "decoded char valid"),
            ("frame_start_out", "output", "1", False, None, "1 beat before out_valid"),
        ]),
]

HEADER = """// ============================================================================
// gw2a_cnn_{name} -- proprietary IP wrapper (Cognition dev kit, GW2A-18C)
// Core: {core}  (adapted from CNN_FPGA rtl_pds, {src})
// Board-validated: unit(s) {units}, digest {digest}, bitstream {board}
// Port arrays are flattened: element i occupies bits [i*W +: W].
// ============================================================================
"""


def flat_width(p):
    w = p[2]
    dims = p[4]
    if dims:
        for d in dims:
            w = f"{d}*{w}"
    return w


def gen_rtl(ip):
    name = ip["name"]
    out = [HEADER.format(**ip)]
    out.append(f"module gw2a_cnn_{name} #(\n")
    plist = []
    for prm in ip["params"]:
        cmt = f"  // {prm[2]}" if len(prm) > 2 else ""
        plist.append(f"    parameter {prm[0]} = {prm[1]}{cmt}")
    out.append(",\n".join(plist))
    out.append("\n)(\n")

    pin = []
    if ip.get("fifo"):
        pin.append("    input  wire rd_clk,")
        pin.append("    input  wire wr_clk,")
    else:
        pin.append("    input  wire clk,")
    if ip.get("rstn"):
        pin.append("    input  wire rst_n,")
    if ip.get("clken", True) and not ip.get("fifo"):
        pin.append("    input  wire clk_en,")
    for p in ip["ports"]:
        _, d, w, s, dims, note = p
        fw = flat_width(p)
        dw = f"[{fw}-1:0]" if fw != "1" else ""
        sd = "signed " if s else ""
        pin.append(f"    {d}  wire {sd}{dw} {p[0]},  // {note}")
    if pin:
        # drop the separator comma on the last port (it sits before the comment)
        pin[-1] = pin[-1].replace(",  //", "   //", 1).rstrip().rstrip(",")
    out.append("\n".join(pin))
    out.append("\n);\n\n")

    # unflatten packed ports for the core connection
    conv = []
    for p in ip["ports"]:
        dims = p[4]
        if not dims:
            continue
        w = p[2]
        tot = "*".join(list(dims) + [w])
        s = "signed " if p[3] else ""
        decl = "".join(f"[{d}-1:0]" for d in dims)
        conv.append(f"    wire {s}{decl}[{w}-1:0] {p[0]}_pk;\n")
        conv.append(f"    assign {p[0]}_pk = {p[0]};\n" if p[1] == "input"
                    else f"    assign {p[0]} = {p[0]}_pk;\n")
    out.extend(conv)
    if conv:
        out.append("\n")

    # core instance (derived width helpers are wrapper-local, not forwarded)
    out.append(f"    {ip['core']} #(\n")
    out.append(",\n".join(f"        .{p[0]}({p[0]})" for p in ip["params"]
                         if p[0] not in ("AW", "CHW", "OCHW")))
    out.append(f"\n    ) u_core (\n")
    conns = []
    if ip.get("fifo"):
        conns += ["        .rd_clk(rd_clk)", "        .wr_clk(wr_clk)"]
    else:
        conns.append("        .clk(clk)")
    if ip.get("rstn"):
        conns.append("        .rst_n(rst_n)")
    if ip.get("clken", True) and not ip.get("fifo"):
        conns.append("        .clk_en(clk_en)")
    for p in ip["ports"]:
        tgt = f"{p[0]}_pk" if p[4] else p[0]
        conns.append(f"        .{p[0]}({tgt})")
    out.append(",\n".join(conns))
    out.append("\n    );\n\nendmodule\n")
    return "".join(out)


def port_decl_line(p):
    _, d, w, s, dims, note = p
    return dict(name=p[0], dir=d, width=flat_width(p), signed=bool(s),
                packed_dims=list(dims) if dims else None, note=note)


def gen_manifest(ip):
    return {
        "ip_name": f"gw2a_cnn_{ip['name']}",
        "core_module": ip["core"],
        "core_source": ip["src"],
        "description": ip["desc"],
        "clock_reset": {
            "clk": "single clock" if not ip.get("fifo") else "rd_clk/wr_clk async domains",
            "rst_n": ip.get("reset_description", "active-low synchronous") if ip.get("rstn") else "not present on core (uniform port omitted)",
            "clk_en": "step enable; tie 1 for full rate" if ip.get("clken", True) else "not present on core",
        },
        "status_protocol": "streaming valid/new_line; no start/done/error",
        "parameters": [{"name": p[0], "default": p[1],
                        **({"note": p[2]} if len(p) > 2 else {})}
                       for p in ip["params"]],
        "ports": [port_decl_line(p) for p in ip["ports"]],
        "validation": {
            "selftest_units": ip["units"],
            "golden_digest": ip["digest"],
            "sim": "iverilog PASS (full / mask A / mask B)",
            "board": {
                "board": "Sipeed Tang Primer 20K", "device": "GW2A-LV18PG256C8/I7",
                "bitstream_mask": ip["board"], "uart": "115200@COM24",
                "evidence": f"doc/board_uart_{ip['board']}.txt",
            },
        },
    }


def gen_readme(ip):
    lines = [f"# gw2a_cnn_{ip['name']}\n\n{ip['desc']}\n"]
    lines.append(f"- Core: `{ip['core']}` (`{ip['src']}`)\n")
    lines.append(f"- Validated: selftest unit(s) {ip['units']}, digest `{ip['digest']}`, "
                 f"board bitstream `{ip['board']}`\n\n")
    lines.append("## Ports\n\n| port | dir | width | signed | note |\n|---|---|---|---|---|\n")
    if ip.get("fifo"):
        lines.append("| rd_clk / wr_clk | in | 1 | - | async FIFO clocks |\n")
        lines.append("| rst | in | 1 | - | **active-high** async reset |\n")
    else:
        lines.append("| clk | in | 1 | - | system clock |\n")
        if ip.get("rstn"):
            reset_note = ip.get("reset_description", "active-low sync")
            lines.append(f"| rst_n | in | 1 | - | {reset_note} reset |\n")
        if ip.get("clken", True):
            lines.append("| clk_en | in | 1 | - | step enable; tie 1 for full rate |\n")
    for p in ip["ports"]:
        lines.append(f"| {p[0]} | {p[1]} | {flat_width(p)} | "
                     f"{'yes' if p[3] else 'no'} | {p[5]} |\n")
    lines.append("\n## Parameters\n\n| name | default |\n|---|---|\n")
    for prm in ip["params"]:
        lines.append(f"| {prm[0]} | {prm[1]} |\n")
    lines.append("\nPacked array ports are flattened LSB-first: element `i` "
                 "occupies bits `[i*W +: W]`.\n")
    return "".join(lines)


def main():
    os.makedirs(IP_ROOT, exist_ok=True)
    index = ["# GW2A-18C validated CNN IP package\n\n",
             "Source: `external/CNN_FPGA` rtl_pds, adapted for Tang Primer 20K.\n",
             "Every IP below passed RTL sim (iverilog) and on-board UART digest "
             "validation on GW2A-LV18PG256C8/I7 (27 MHz, COM24 115200).\n",
             "Evidence: `../doc/board_uart_m00ff.txt`, `../doc/board_uart_mff00.txt`,\n",
             "`../doc/utilization_ab.txt`.\n\n",
             "| IP | core | selftest unit | digest | board mask |\n",
             "|---|---|---|---|---|\n"]
    for ip in IPS:
        d = os.path.join(IP_ROOT, ip["name"])
        os.makedirs(d, exist_ok=True)
        open(os.path.join(d, f"gw2a_cnn_{ip['name']}.v"), "w").write(gen_rtl(ip))
        open(os.path.join(d, "ip_manifest.json"), "w").write(
            json.dumps(gen_manifest(ip), indent=2, ensure_ascii=False))
        open(os.path.join(d, "README.md"), "w").write(gen_readme(ip))
        index.append(f"| `gw2a_cnn_{ip['name']}` | `{ip['core']}` | {ip['units']} "
                     f"| {ip['digest']} | {ip['board']} |\n")
    open(os.path.join(IP_ROOT, "MANIFEST.md"), "w").write("".join(index))
    print(f"wrote {len(IPS)} IP packages under {IP_ROOT}")


if __name__ == "__main__":
    main()
