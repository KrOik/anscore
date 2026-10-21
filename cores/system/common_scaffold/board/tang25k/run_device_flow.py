#!/usr/bin/env python3
"""Build the isolated common_uart smoke harness for Tang Primer 25K.

This wrapper stages only the board harness and common_uart RTL into a local
build directory, then delegates synthesis, P&R, and packing to the established
cores/signal_processing/dsp_isp_library/board/tang25k/device_flow.py flow.
"""
import argparse
import shutil
import sys
from pathlib import Path


HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[3]
UART_RTL = ROOT / "projects" / "common_ip_scaffold" / "peripherals" / "rtl" / "common_uart.v"
FLOW_DIR = ROOT / "projects" / "dsp_isp_library" / "board" / "tang25k"


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--dest", type=Path, default=HERE / "build",
        help="staging/output directory (must remain under this tang25k directory)",
    )
    args = parser.parse_args()
    dest = args.dest.resolve()
    try:
        dest.relative_to(HERE.resolve())
    except ValueError as exc:
        raise SystemExit("--dest must be inside %s" % HERE) from exc
    if not UART_RTL.is_file():
        raise SystemExit("common_uart RTL not found: %s" % UART_RTL)
    flow_file = FLOW_DIR / "device_flow.py"
    if not flow_file.is_file():
        raise SystemExit("shared Tang 25K flow not found: %s" % flow_file)

    dest.mkdir(parents=True, exist_ok=True)
    shutil.copy2(HERE / "common_uart_smoke_25k.v", dest / "common_uart_smoke_25k.v")
    shutil.copy2(HERE / "tang25k.cst", dest / "tang25k.cst")
    shutil.copy2(UART_RTL, dest / "common_uart.v")

    sys.path.insert(0, str(FLOW_DIR))
    import device_flow

    summary = device_flow.build(
        dest,
        top="common_uart_smoke_25k",
        rtl=["common_uart.v", "common_uart_smoke_25k.v"],
        params={"CLK_HZ": 50000000, "BAUD": 115200, "TIMEOUT_CYCLES": 1000000},
        cst_name="tang25k.cst",
    )
    print("status=%s top=%s bitstream=%s" % (
        summary["status"], summary["top"], summary["bitstream"]
    ))
    print("This build result is not a board functional verification.")


if __name__ == "__main__":
    main()
