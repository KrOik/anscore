"""Freeze current production dependencies for repeat board tests; keep old evidence."""
from pathlib import Path
import subprocess
import sys

HERE = Path(__file__).resolve().parent
COMMON = HERE.parents[3]
REPLACEMENTS = [COMMON/'signal_video/rtl/cip_image_window_filter_frame.v',
                COMMON/'image/filters/rtl/img_filter_kernel3x3.v',
                COMMON/'image/filters/rtl/img_filter_median_sort3_segment.v']

if __name__ == '__main__':
    for name in ('mean_filter', 'gaussian_filter', 'sobel', 'prewitt', 'laplacian'):
        subprocess.run([sys.executable, '-B', str(HERE/'stage_harness.py'),
                        name+'_counts_v5', name+'_production_v6',
                        *map(str, REPLACEMENTS)], check=True)
