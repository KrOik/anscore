"""Run unchanged v95 AWB fixtures against the isolated count candidate."""
import importlib.util
from pathlib import Path

HERE = Path(__file__).resolve().parent
COMMON = HERE.parents[3]
original = COMMON / 'image/isp/evidence/production_awb_v95_20261017/run_production_awb_regression.py'
spec = importlib.util.spec_from_file_location('awb_original_regression', original)
runner = importlib.util.module_from_spec(spec)
spec.loader.exec_module(runner)
output = HERE / 'awb_counts_v4/reference_regression'
output.mkdir(exist_ok=True)
runner.STATS = HERE / 'awb_counts_v4/source/img_isp_awb_stats.v'
runner.EXPECTED_SHA['img_isp_awb_stats.v'] = runner.sha(runner.STATS)
runner.SUMMARY = output / 'summary.json'
original_run = runner.run
def run(command, log_path, cwd, env, timeout=180):
    return original_run(command, output / log_path.name, cwd, env, timeout)
runner.run = run
raise SystemExit(runner.main())
