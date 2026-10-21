import json
from pathlib import Path
import sys

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE.parent / "integration"))
from tooling import evidence_dir, sim, write_json


def main():
    evidence = evidence_dir("cdc")
    sources = [*sorted((HERE / "rtl").glob("*.v")), HERE / "sim/tb_cip_cdc.sv"]
    sim("tb_cip_cdc", sources, evidence, "CDC PASS")
    write_json(evidence / "result.json", {"status": "PASS", "board": "not_run", "physical_cdc": "not_verified"})
    print(f"evidence={evidence}")


if __name__ == "__main__":
    main()
