#!/usr/bin/env python3
"""Build the bilateral-denoise board consistency target for Tang Primer 25K."""
import argparse
import shutil
import sys
from pathlib import Path

HERE=Path(__file__).resolve().parent
ROOT=HERE.parents[3]
FLOW_DIR=ROOT/"projects"/"dsp_isp_library"/"board"/"tang25k"
FILTER_RTL=ROOT/"projects"/"common_ip_scaffold"/"image"/"filters"/"rtl"
SOURCES={
    "image_bilateral_selftest_25k.v": HERE/"image_bilateral_selftest_25k.v",
    "img_filter_bilateral3x3.v": FILTER_RTL/"img_filter_bilateral3x3.v",
    "img_filter_exp_weight.v": FILTER_RTL/"img_filter_exp_weight.v",
}

def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--dest",type=Path,
                        default=HERE/"build"/"image_bilateral_selftest_25k",
                        help="output directory inside the Tang25K board folder")
    parser.add_argument("--uniform",action="store_true",
                        help="use an all-100 test window for arithmetic isolation")
    args=parser.parse_args()
    dest=args.dest.resolve()
    try:
        dest.relative_to(HERE.resolve())
    except ValueError as exc:
        raise SystemExit("--dest must remain inside %s"%HERE) from exc
    flow_file=FLOW_DIR/"device_flow.py"
    if not flow_file.is_file(): raise SystemExit("Tang25K device flow missing")
    for name,source in SOURCES.items():
        if not source.is_file(): raise SystemExit("RTL source missing: %s"%source)
    dest.mkdir(parents=True,exist_ok=True)
    for name,source in SOURCES.items(): shutil.copy2(source,dest/name)
    shutil.copy2(HERE/"tang25k.cst",dest/"tang25k.cst")
    sys.path.insert(0,str(FLOW_DIR))
    import device_flow
    summary=device_flow.build(
        dest,top="image_bilateral_selftest_25k",
        rtl=list(SOURCES),
        params={"CLK_HZ":50000000,"BAUD":115200,
                "TEST_MODE":int(args.uniform)},
        cst_name="tang25k.cst")
    print("status=%s top=%s bitstream=%s"%
          (summary["status"],summary["top"],summary.get("bitstream")))
    print("Build result is separate from board UART validation.")

if __name__=="__main__": main()
