"""Run the v73 arithmetic benches against the production single-file core."""
from pathlib import Path
import datetime
import hashlib
import json
import os
import shutil
import subprocess
import tempfile

HERE = Path(__file__).resolve().parent
CORE = HERE.parent / "img_dh_guided_refine.v"
CASES = (
    ("tb_addsub64_prefix", "tb_addsub64_prefix.sv", "PREFIX64_TEST PASS cases=148232"),
    ("tb_mul64x16_byte", "tb_mul64x16_byte.sv", "MUL64X16_BYTE_TEST PASS cases=321"),
    ("tb_img_dh_iter_div_signed64", "tb_img_dh_iter_div_signed64.v", "DIVIDER_BYTE_TEST PASS cases=272"),
    ("tb_img_dh_solve_pipeline", "tb_img_dh_solve_pipeline.sv", "SOLVE_PIPELINE_TEST PASS cases=786"),
)


def main():
    evidence = HERE.parent / "evidence" / "production_v73_20261017"
    out = evidence / ("arithmetic_" + datetime.datetime.now().strftime("%Y%m%d_%H%M%S_%f"))
    out.mkdir(parents=True)
    native = [shutil.which("iverilog"), shutil.which("vvp")]
    if not all(native) or any(subprocess.run([t, "-V"], capture_output=True).returncode for t in native):
        native = None
    wsl = (shutil.which("wsl.exe") or shutil.which("wsl")) if os.name == "nt" else None
    if not native and not wsl:
        raise RuntimeError("Icarus Verilog is required, native or in Ubuntu WSL")

    def translate(path):
        if native:
            return str(path)
        result = subprocess.run([wsl, "-d", "Ubuntu", "--", "wslpath", "-a", path.as_posix()],
                                capture_output=True, text=True, check=True, timeout=30)
        return result.stdout.strip()

    results = []
    with tempfile.TemporaryDirectory(prefix="dehaze_production_v73_") as temp:
        for top, filename, marker in CASES:
            image = translate(Path(temp) / (top + ".vvp"))
            commands = (
                [native[0], "-g2012", "-Wall", "-s", top, "-o", image, str(CORE), str(HERE / filename)]
                if native else
                [wsl, "-d", "Ubuntu", "--", "iverilog", "-g2012", "-Wall", "-s", top,
                 "-o", image, translate(CORE), translate(HERE / filename)],
                [native[1], image] if native else [wsl, "-d", "Ubuntu", "--", "vvp", image],
            )
            for phase, command in zip(("compile", "simulation"), commands):
                result = subprocess.run(command, capture_output=True, text=True, timeout=180)
                (out / (top + "_" + phase + ".log")).write_text(result.stdout + result.stderr, encoding="utf-8")
                if result.returncode:
                    raise RuntimeError(f"{top} {phase} failed: {result.stdout}{result.stderr}")
                if phase == "simulation" and marker not in result.stdout:
                    raise RuntimeError(f"{top} missing expected result: {result.stdout}")
            results.append({"top": top, "status": "PASS", "marker": marker})
            print(top + " PASS", flush=True)
    summary = dict(status="PASS", backend="native" if native else "Ubuntu WSL",
                   production_source_sha256=hashlib.sha256(CORE.read_bytes()).hexdigest(),
                   cases=results, temporary_images_removed=True)
    (out / "summary.json").write_text(json.dumps(summary, indent=2) + "\n", encoding="utf-8")
    print("evidence=" + str(out))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
