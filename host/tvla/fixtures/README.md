# TVLA Fixtures

`analyze_tvla.py --self-test` generates temporary fixed-vs-random fixtures at
runtime. The generated manifests use the same JSONL fields expected from real
capture runs:

- `sample_index`
- `group` as `fixed` or `random`
- `trigger_time_utc`
- `uart_digest`
- `raw_trace_path`

Trace files are plain text numeric samples, one sample per line. Real instrument
CSV traces are also supported; use `--trace-column` when the CSV has multiple
columns.

The generated fixtures are software-only tests for the harness. They are not
physical TVLA evidence and must not be cited as a board TVLA pass.
