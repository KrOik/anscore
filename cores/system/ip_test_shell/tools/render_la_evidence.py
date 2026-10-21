"""Render an actual sample window, retaining measurement metadata on the image."""
import argparse
import json
from pathlib import Path
import matplotlib
matplotlib.use('Agg')
import matplotlib.pyplot as plt


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('capture', type=Path)
    args = ap.parse_args()
    report = json.loads((args.capture / 'summary.json').read_text())
    raw = (args.capture / 'capture.bin').read_bytes()
    first = report['fpga_tx_decoded'][0]['sample']
    begin, end = max(0, first - 30), first + 210
    x = [(i - first) / report['sample_rate'] * 1e6 for i in range(begin, end)]
    fig, axes = plt.subplots(4, 1, figsize=(11, 6), sharex=True)
    for axis, ch, label in zip(axes, [0, 1, 2, 5], ['CH0 FPGA RX (B3)', 'CH1 FPGA TX (C3)', 'CH2 RX event toggle', 'CH5 TX event toggle']):
        axis.step(x, [(b >> ch) & 1 for b in raw[begin:end]], where='post')
        axis.set_ylim(-.2, 1.2)
        axis.set_yticks([0, 1])
        axis.set_title(label, loc='left', fontsize=9, pad=3)
        axis.grid(alpha=.2)
    axes[-1].set_xlabel('Time relative to captured TX start (us)')
    fig.suptitle('Measured 8CH UART diagnostic: TX=0x55, RX high\n'
                 '2 MS/s | FPGA 50 MHz | 115200 baud 8N1 | registered probe delay 1 clock\n'
                 'bitstream SHA256 ' + report['bitstream_sha256'][:24], fontsize=11)
    fig.tight_layout(rect=(0, 0, 1, .88))
    fig.savefig(args.capture / 'waveform.png', dpi=160)
    plt.close(fig)


if __name__ == '__main__':
    main()
