"""Run DSP functional simulations; remove generated images on every exit."""
from pathlib import Path
import hashlib
import sys
import tempfile

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE.parent / "integration"))
from tooling import execute, evidence_dir, write_json
from cic_reference import fixtures
from iir_reference import fixture as iir_fixture
from cordic_reference import fixture as cordic_fixture
from resampler_reference import fixtures as resampler_fixtures
from fft_reference import fixtures as fft_fixtures


def main():
    evidence = evidence_dir("dsp_functional")
    sources = sorted(HERE.rglob("*.v")) + sorted(HERE.glob("*.py"))
    hashes = {p.relative_to(HERE).as_posix(): hashlib.sha256(p.read_bytes()).hexdigest()
              for p in sources}
    with tempfile.TemporaryDirectory(prefix="cip_dsp_") as temporary:
        image = Path(temporary) / "fir.vvp"
        execute([sys.executable,HERE/"generate_fft_twiddle.py","--check"],HERE,evidence/"fft_twiddle_check.log")
        execute(["iverilog", "-g2012", "-s", "tb_cip_dsp_fir", "-o", image,
                 HERE / "rtl/cip_dsp_fir.v", HERE / "sim/tb_cip_dsp_fir.v"],
                HERE, evidence / "compile.log")
        result = execute(["vvp", image], HERE, evidence / "simulation.log")
        if "PASS FIR checks=200" not in result:
            raise RuntimeError("Missing FIR success marker")
        write_json(evidence / "fir_summary.json", {"status": "PASS", "checks": 200,
                   "scope": "FIR signed 8-bit three-tap numeric/CE/backpressure/last/reset"})
        print(result.strip())
        cic_results = []
        for rate, stages, width in [(1, 1, 8), (2, 2, 10), (8, 3, 17), (5, 4, 20)]:
            label = f"cic_r{rate}_n{stages}"
            fixture_folder = Path(temporary) / label
            fixture_folder.mkdir()
            inp, expected, counts = fixtures(fixture_folder, rate, stages, width)
            execute(["iverilog", "-g2012", "-s", "tb_cip_dsp_cic_decimator",
                     f"-Ptb_cip_dsp_cic_decimator.RATE={rate}",
                     f"-Ptb_cip_dsp_cic_decimator.STAGES={stages}",
                     f"-Ptb_cip_dsp_cic_decimator.ACC_W={width}", "-o", image,
                     HERE / "rtl/cip_dsp_cic_decimator.v",
                     HERE / "sim/tb_cip_dsp_cic_decimator.v"],
                    HERE, evidence / f"{label}_compile.log")
            result = execute(["vvp", image, f"+input={inp}", f"+expected={expected}"],
                             HERE, evidence / f"{label}_simulation.log")
            if "PASS CIC" not in result:
                raise RuntimeError("Missing CIC success marker")
            cic_results.append({"rate": rate, "stages": stages, "width": width, **counts})
            print(result.strip())
        write_json(evidence / "cic_summary.json", {"status": "PASS", "cases": cic_results,
                   "scope": "integer modulo CIC, CE, stalls, resets, packet partial flush"})
        fixture, checks = iir_fixture(Path(temporary))
        execute(["iverilog", "-g2012", "-s", "tb_cip_dsp_iir_biquad", "-o", image,
                 HERE / "rtl/cip_dsp_iir_biquad.v", HERE / "sim/tb_cip_dsp_iir_biquad.v"],
                HERE, evidence / "iir_compile.log")
        result = execute(["vvp", image, f"+fixture={fixture}"], HERE, evidence / "iir_simulation.log")
        if f"PASS IIR checks={checks}" not in result:
            raise RuntimeError("Missing IIR success marker")
        write_json(evidence / "iir_summary.json", {"status": "PASS", "checks": checks,
                   "scope": "five coefficient sets, signed/saturation/feedback/CE/backpressure/last/reset"})
        print(result.strip())
        fixture, cordic_checks, cordic_error = cordic_fixture(Path(temporary))
        execute(["iverilog", "-g2012", "-s", "tb_cip_dsp_cordic", "-o", image,
                 HERE / "rtl/cip_dsp_cordic.v", HERE / "sim/tb_cip_dsp_cordic.v"],
                HERE, evidence / "cordic_compile.log")
        result = execute(["vvp", image, f"+fixture={fixture}"], HERE, evidence / "cordic_simulation.log")
        if f"PASS CORDIC checks={cordic_checks}" not in result:
            raise RuntimeError("Missing CORDIC success marker")
        print(result.strip())
        resampler_results=[]
        for up, down, taps in [(1,1,1),(3,2,11),(2,5,13),(5,1,7),(1,4,9),(4,6,17),(7,3,3)]:
            label=f"resampler_u{up}_d{down}_t{taps}"
            fixture_folder=Path(temporary)/label
            fixture_folder.mkdir()
            counts=resampler_fixtures(fixture_folder,up,down,taps)
            execute(["iverilog","-g2012","-s","tb_cip_dsp_resampler",
                     f"-Ptb_cip_dsp_resampler.UP={up}",f"-Ptb_cip_dsp_resampler.DOWN={down}",
                     f"-Ptb_cip_dsp_resampler.TAPS={taps}","-o",image,
                     HERE/"rtl/cip_dsp_resampler.v",HERE/"sim/tb_cip_dsp_resampler.v"],
                    HERE,evidence/f"{label}_compile.log")
            result=execute(["vvp",image,f"+folder={fixture_folder}"],HERE,evidence/f"{label}_simulation.log")
            if f"outputs={counts['outputs']}" not in result or "PASS RESAMPLER" not in result:
                raise RuntimeError("Missing resampler success marker")
            resampler_results.append({"up":up,"down":down,"taps":taps,**counts})
            print(result.strip())
        fft_results=[]
        for log_n,data_w in [(1,8),*[(n,16) for n in range(2,9)]]:
            label=f"fft_n{1<<log_n}"
            fixture_folder=Path(temporary)/label
            fixture_folder.mkdir()
            counts=fft_fixtures(fixture_folder,log_n,data_w)
            execute(["iverilog","-g2012","-s","tb_cip_dsp_fft",
                     f"-Ptb_cip_dsp_fft.LOG_N={log_n}",f"-Ptb_cip_dsp_fft.DATA_W={data_w}",
                     "-o",image,HERE/"rtl/cip_dsp_fft.v",HERE/"rtl/cip_dsp_fft_twiddle.v",
                     HERE/"sim/tb_cip_dsp_fft.v"],HERE,evidence/f"{label}_compile.log")
            result=execute(["vvp",image,f"+folder={fixture_folder}"],HERE,evidence/f"{label}_simulation.log")
            if "PASS FFT" not in result or f"outputs={counts['outputs']}" not in result:
                raise RuntimeError("Missing FFT success marker")
            fft_results.append(counts)
            print(result.strip())
        if any(hashlib.sha256(p.read_bytes()).hexdigest() != hashes[p.relative_to(HERE).as_posix()]
               for p in sources):
            raise RuntimeError("DSP source changed during simulation")
        write_json(evidence / "summary.json", {"status": "PASS", "rtl_and_test_sha256": hashes,
                   "fir_checks": 200, "cic_cases": cic_results, "iir_checks": checks,
                   "cordic_checks": cordic_checks, "cordic_float_max_xy_error": cordic_error,
                   "resampler_cases":resampler_results,
                   "fft_cases":fft_results,
                   "synthesis": "not_run", "board": "not_run"})
        print(evidence)


if __name__ == "__main__":
    main()
