#!/usr/bin/env python3
"""Build the board-visible grayscale opening consistency test for GW5A-25."""
import argparse
import shutil
import sys
from pathlib import Path


HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[3]
FLOW_DIR = ROOT / "projects" / "dsp_isp_library" / "board" / "tang25k"
RTL_DIR = ROOT / "projects" / "common_ip_scaffold" / "image" / "filters" / "rtl"
SOURCES = {
    "image_filter_selftest_25k.v": HERE / "image_filter_selftest_25k.v",
    "img_filter_frame_engine.v": RTL_DIR / "img_filter_frame_engine.v",
    "img_filter_exp_weight.v": RTL_DIR / "img_filter_exp_weight.v",
}


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--dest", type=Path,
        default=HERE / "build" / "image_filter_selftest_25k",
        help="staging/output directory (must remain under this tang25k directory)",
    )
    args = parser.parse_args()
    dest = args.dest.resolve()
    try:
        dest.relative_to(HERE.resolve())
    except ValueError as exc:
        raise SystemExit("--dest must be inside %s" % HERE) from exc
    if not (FLOW_DIR / "device_flow.py").is_file():
        raise SystemExit("shared Tang Primer 25K device flow is missing")
    for target_name, source in SOURCES.items():
        if not source.is_file():
            raise SystemExit("required RTL source is missing: %s" % source)

    dest.mkdir(parents=True, exist_ok=True)
    for target_name, source in SOURCES.items():
        shutil.copy2(source, dest / target_name)
    sys.path.insert(0, str(FLOW_DIR))
    import device_flow

    summary = device_flow.build(
        dest,
        top="image_filter_selftest_25k",
        rtl=[
            "img_filter_exp_weight.v",
            "img_filter_frame_engine.v",
            "image_filter_selftest_25k.v",
        ],
        params={"CLK_HZ": 50000000, "BAUD": 115200},
    )
    print("status=%s top=%s bitstream=%s" % (
        summary["status"], summary["top"], summary["bitstream"]
    ))
    print("resource counts: %s" % summary["util"])
    print("bitstream sha256: %s" % summary["bitstream_sha256"])
    print("Build evidence is not board validation; load and UART-check separately.")


if __name__ == "__main__":
    main()
