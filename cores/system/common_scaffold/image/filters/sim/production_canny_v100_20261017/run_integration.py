"""Recheck the exact integrated Canny source with the existing image group."""
from pathlib import Path
import hashlib
import json
import subprocess
import sys

HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[5]
IMAGE = ROOT / 'cores/system/common_scaffold/image'
sys.path.insert(0, str(ROOT / 'cores/signal_processing/dsp_isp_library/board/tang25k'))
import device_flow


def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def main():
    production = IMAGE / 'filters/rtl/img_edge_canny.v'
    candidate = ROOT / 'cores/system/common_scaffold/board/tang25k/build/image_canny_frame_selftest_25k_20261017_v100_gradpipe'
    assert production.read_bytes() == (candidate / 'rtl/img_edge_canny.v').read_bytes()
    assert sha(production) == '768e2cf8e2123c216c5c53f08e3bb34edb2677923033b1012f7816fe14fa27b0'
    before = set(IMAGE.glob('build_core_group_*'))
    command = [sys.executable, '-B', str(IMAGE / 'sim/run_image_core_group.py')]
    result = subprocess.run(command, cwd=ROOT, env=device_flow.tool_env(),
                            capture_output=True, text=True, timeout=180)
    generated = set(IMAGE.glob('build_core_group_*')) - before
    assert len(generated) == 1, generated
    group = generated.pop()
    evidence = json.loads((group / 'summary.json').read_text())
    status = result.returncode == 0 and evidence['compile_exit'] == 0 and evidence['simulation_exit'] == 0
    removed_bytes = 0
    # Remove only this invocation's disposable simulator image after PASS.
    # Pre-existing directories, sources, logs, summaries and images remain.
    if status:
        image = (group / 'core.vvp').resolve()
        assert image.parent == group.resolve() and image.is_relative_to(IMAGE.resolve())
        removed_bytes = image.stat().st_size
        image.unlink()
    assert production.read_bytes() == (candidate / 'rtl/img_edge_canny.v').read_bytes()
    summary = dict(status='PASS' if status else 'FAIL', command=command,
                   returncode=result.returncode, group_evidence=str(group.relative_to(ROOT)),
                   production_sha256=sha(production), candidate_rtl_byte_identical=True,
                   disposable_image_removed_bytes=removed_bytes, prior_images_preserved=True,
                   cases=evidence['cases'], pixels=evidence['pixels'], windows=evidence['windows'])
    (HERE / 'production_group_regression.json').write_text(json.dumps(summary, indent=2) + '\n')
    print(result.stdout + result.stderr)
    print(json.dumps(summary, indent=2))
    return 0 if status else 1


if __name__ == '__main__':
    raise SystemExit(main())
