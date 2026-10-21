#!/usr/bin/env python3
"""Build the isolated Tang 25K auto-stitch functional self-test image."""
import argparse
import collections
import datetime
import hashlib
import json
import re
import shutil
import sys
from pathlib import Path


HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[3]
BUILD_ROOT = HERE / "build"
FLOW_DIR = ROOT / "projects" / "dsp_isp_library" / "board" / "tang25k"
MULTIFRAME_DIR = ROOT / "projects" / "common_ip_scaffold" / "image" / "multiframe"
SOURCES = {
    "img_mf_auto_stitch_selftest_25k.v": HERE / "img_mf_auto_stitch_selftest_25k.v",
    "img_mf_auto_stitch.v": MULTIFRAME_DIR / "img_mf_auto_stitch.v",
    "img_mf_dual_frame_store.v": MULTIFRAME_DIR / "img_mf_dual_frame_store.v",
    "img_mf_translation_sad.v": MULTIFRAME_DIR / "img_mf_translation_sad.v",
}


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--dest", type=Path,
        help="new output directory under board/tang25k/build (must not contain prior logs)",
    )
    parser.add_argument("--synth-timeout", type=int, default=900)
    parser.add_argument("--pnr-timeout", type=int, default=900)
    parser.add_argument("--no-abc9", action="store_true",
                        help="use the classic ABC mapper for a comparative timing attempt")
    parser.add_argument("--retime", action="store_true",
                        help="enable Yosys/ABC register retiming for a comparative build")
    parser.add_argument("--route-freq", type=float, default=50.0,
                        help="nextpnr target in MHz; timing is always checked against the 50 MHz board clock")
    args = parser.parse_args()

    if args.dest is None:
        stamp = datetime.datetime.now(datetime.timezone.utc).strftime("%Y%m%dT%H%M%SZ")
        dest = BUILD_ROOT / ("img_mf_auto_stitch_selftest_25k_" + stamp)
    else:
        dest = args.dest
    dest = dest.resolve()
    try:
        dest.relative_to(BUILD_ROOT.resolve())
    except ValueError as exc:
        raise SystemExit("--dest must be inside %s" % BUILD_ROOT) from exc
    if dest.exists() and any(dest.iterdir()):
        raise SystemExit("refusing to overwrite an existing build/log directory: %s" % dest)
    if not (FLOW_DIR / "device_flow.py").is_file():
        raise SystemExit("shared Tang Primer 25K device flow is missing")
    for target_name, source in SOURCES.items():
        if not source.is_file():
            raise SystemExit("required RTL source is missing: %s" % source)

    dest.mkdir(parents=True, exist_ok=True)
    for target_name, source in SOURCES.items():
        shutil.copy2(source, dest / target_name)
    shutil.copy2(HERE / "tang25k.cst", dest / "tang25k.cst")
    sys.path.insert(0, str(FLOW_DIR))
    import device_flow

    # This harness uses two small synchronous frame stores. The default GW5A
    # script maps these into distributed RAM16SDP4 cells, which the available
    # nextpnr GW5A architecture cannot place. Keep the board build self
    # contained and request the supported block-RAM/FF mapping explicitly.
    top = "img_mf_auto_stitch_selftest_25k"
    rtl = [
        "img_mf_dual_frame_store.v",
        "img_mf_translation_sad.v",
        "img_mf_auto_stitch.v",
        "img_mf_auto_stitch_selftest_25k.v",
    ]
    ys = ["read_verilog -sv -I. " + " ".join(rtl)]
    lib = device_flow.cells_xtra_lib()
    if lib:
        ys.append("read_verilog -lib %s" % str(lib).replace("\\", "/"))
    synth_flags = ["-noalu", "-nolutram"]
    if args.no_abc9:
        synth_flags.append("-noabc9")
    if args.retime:
        synth_flags.append("-retime")
    ys.extend([
        "chparam -set CLK_HZ 25000000 %s" % top,
        "chparam -set BAUD 115200 %s" % top,
        "chparam -set POR_CYCLES 32768 %s" % top,
        "synth_gowin %s -family %s -top %s -json top25k.json"
        % (" ".join(synth_flags), device_flow.YOSYS_FAMILY, top),
        "stat",
    ])
    (dest / "build25k.ys").write_text("\n".join(ys) + "\n", encoding="utf-8")
    device_flow.run(dest, ["yosys", "-s", "build25k.ys"], "synthesis_25k.log",
                    timeout=args.synth_timeout)

    net = json.loads((dest / "top25k.json").read_text())
    top_wires = net["modules"][top].get("netnames", {})
    if "functional_clk" not in top_wires:
        raise RuntimeError("synthesis dropped the functional_clk net needed by the 25 MHz SDC")
    counts = collections.Counter(c["type"]
                                 for c in net["modules"][top]["cells"].values())
    synth_lut = sum(v for k, v in counts.items()
                    if re.fullmatch(r"LUT[1-4]|ALU", k))
    synth_dsp = sum(v for k, v in counts.items()
                    if k.startswith(("MULT", "PADD", "ALU54")))

    # E2 stays constrained at 50 MHz; the internal, registered divide-by-two
    # clock is separately constrained at its actual 25 MHz functional rate.
    (dest / "auto_stitch_clocks.sdc").write_text(
        "create_clock -name board_clk50 -period 20.000 [get_ports {clk}]\n"
        "create_clock -name functional_clk25 -period 40.000 [get_nets {functional_clk}]\n",
        encoding="utf-8",
    )
    device_flow.run(
        dest,
        ["nextpnr-himbaechel", "--json", "top25k.json", "--write", "pnr25k.json",
         "--device", device_flow.DEVICE, "--vopt", "family=%s" % device_flow.FAMILY,
         "--vopt", "cst=tang25k.cst", "--vopt", "sspi_as_gpio",
         "--freq", str(args.route_freq), "--sdc", "auto_stitch_clocks.sdc",
         "--seed", "1", "--log", "nextpnr_25k.log"],
        "pnr_console_25k.log", timeout=args.pnr_timeout,
    )
    pnr_log = (dest / "nextpnr_25k.log").read_text(errors="replace")
    util = {}
    for name, key in (("LUT4", "lut4"), ("DFF", "dff"), ("BSRAM", "bsram"),
                      ("MULT12X12", "mult12")):
        match = re.search(r"%s:\s+(\d+)/\s*\d+" % name, pnr_log)
        util[key] = int(match.group(1)) if match else None
    if (not util.get("lut4") or "Nothing was placed" in pnr_log
            or "Program finished normally" not in pnr_log
            or re.search(r"^ERROR", pnr_log, re.M)):
        raise RuntimeError("route failed or utilisation unparsed; %s" % dest)
    clocks = re.findall(r"Max frequency for clock[^\n]*?:\s*([\d.]+)\s*MHz", pnr_log)
    if not clocks:
        raise RuntimeError("no post-route frequency data; %s" % dest)

    pack_python = device_flow.CAD / "lib" / "python3.exe"
    if not pack_python.exists():
        pack_python = device_flow.CAD / "bin" / "python.exe"
    image_name = "img_mf_auto_stitch_selftest_25k.fs"
    device_flow.run(
        dest,
        [str(pack_python), str(device_flow.CAD / "bin" / "gowin_pack-script.py"),
         "-d", device_flow.FAMILY, "--sspi_as_gpio", "-o", image_name, "pnr25k.json"],
        "pack_25k.log",
    )
    gates = dict(
        lut4=util["lut4"] <= device_flow.GATE["lut4"],
        dff=(util["dff"] or 0) <= device_flow.GATE["dff"],
        bsram=(util["bsram"] or 0) <= device_flow.GATE["bsram"],
        mult12=(util["mult12"] or 0) <= device_flow.GATE["mult12"],
        timing=min(map(float, clocks)) >= device_flow.CLK_MHZ,
    )
    summary = dict(
        status="BUILD_PASS_NOT_BOARD" if all(gates.values()) else "BUILD_GATE_FAIL",
        device=device_flow.DEVICE, family=device_flow.FAMILY,
        clk_mhz=device_flow.CLK_MHZ, route_freq_mhz=args.route_freq, top=top,
        params={"CLK_HZ": 25000000, "BAUD": 115200, "POR_CYCLES": 32768},
        noalu=True, nolutram=True, noabc9=args.no_abc9, retime=args.retime,
        synth_lut=synth_lut, synth_dsp=synth_dsp,
        util=util, ceiling=device_flow.CEILING, gate=device_flow.GATE,
        fmax_mhz=sorted(map(float, clocks)), gates=gates,
        bitstream=image_name, bitstream_bytes=(dest / image_name).stat().st_size,
        bitstream_sha256=hashlib.sha256((dest / image_name).read_bytes()).hexdigest(),
        built_at=datetime.datetime.now(datetime.timezone.utc)
        .strftime("%Y-%m-%dT%H:%M:%SZ"),
    )
    (dest / "build_25k_summary.json").write_text(
        json.dumps(summary, indent=2) + "\n", encoding="utf-8")
    if not all(gates.values()):
        raise RuntimeError("25K resource/timing gate: %s; see %s" % (gates, dest))
    print("status=%s top=%s bitstream=%s" % (
        summary["status"], summary["top"], dest / summary["bitstream"]
    ))
    print("resource counts: %s" % summary["util"])
    print("bitstream sha256: %s" % summary["bitstream_sha256"])
    print("Build artifact is not board programming or UART validation.")


if __name__ == "__main__":
    main()
