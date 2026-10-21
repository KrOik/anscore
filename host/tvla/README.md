# TVLA Capture and Analysis Harness

This directory contains host-side tooling for fixed-vs-random TVLA capture
metadata and Welch t-test analysis around the hybrid lattice NTT board workflow.

This harness does not prove TVLA has passed by itself. A TVLA pass claim is not
supported until real fixed-vs-random traces are captured from the target setup,
analyzed, reviewed, and archived with the board bitstream and UART evidence.

## Offline Self-Test

Run the fixture self-test without hardware:

```powershell
python host\tvla\analyze_tvla.py --self-test
```

Expected result:

```text
SELFTEST PASS ...
```

## Capture

The capture script writes a JSONL manifest plus raw trace files. It can either
call an external acquisition command or generate explicit synthetic fixture
traces.

Synthetic harness check:

```powershell
python host\tvla\capture_tvla.py --synthetic-fixture --count 12 --manifest captures\tvla\fixture\manifest.jsonl --force
```

Capture counts must provide at least two fixed and two random traces.

Real acquisition command shape:

```powershell
python host\tvla\capture_tvla.py `
  --count 2000 `
  --manifest captures\tvla\run001\manifest.jsonl `
  --trace-command "python host\my_scope_capture.py --out {trace_path} --group {group} --index {sample_index}" `
  --uart-command "powershell -NoProfile -ExecutionPolicy Bypass -File scripts\read_hybrid_lattice_ntt_uart.ps1 -Seconds 3"
```

The trace command must create the file named by `{trace_path}`. Manifest sample
records include `sample_index`, `group`, `trigger_time_utc`, `uart_digest`,
`raw_trace_path`, and `raw_trace_sha256`.

Acquisition command templates are executed through the local shell because scope
and UART tools often need native command lines. Treat them as trusted operator
inputs, not as data from an untrusted manifest.

The repository wrapper exposes the common modes:

```powershell
.\scripts\run_hybrid_lattice_ntt_tvla.ps1 -Mode SelfTest
.\scripts\run_hybrid_lattice_ntt_tvla.ps1 -Mode Analyze -Manifest captures\tvla\run001\manifest.jsonl
```

## Analysis

Analyze a capture manifest and emit JSON/CSV summaries:

```powershell
python host\tvla\analyze_tvla.py captures\tvla\run001\manifest.jsonl `
  --json-out captures\tvla\run001\summary.json `
  --csv-out captures\tvla\run001\t_trace.csv
```

The analyzer exits with status 1 when `abs(t) >= 4.5` at any sample. For
instrument CSV files with multiple columns, pass `--trace-column <name>` so only
the amplitude column is analyzed.

## Board Workflow Notes

Program and UART helper scripts already exist:

```powershell
.\scripts\program_hybrid_lattice_ntt.ps1
.\scripts\read_hybrid_lattice_ntt_uart.ps1 -Seconds 3
```

The current validation log says there is no masking, randomized control-flow,
TVLA, or formal glitch evidence yet. Keep that claim boundary intact until
physical captures and analysis summaries exist.
