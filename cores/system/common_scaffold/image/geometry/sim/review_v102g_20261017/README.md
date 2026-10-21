# v102g independent edge-operand review archive

This directory archives the 72,000-check mathematical probe already executed
by `/root/awb_board_candidate` in PowerShell from `D:\sipeedTANG20K` on
2026-10-17. The probe was **not rerun** to create this archive. It does not
modify the candidate or production RTL.

`probe_math.py` contains the Python stdin body of that completed invocation.
The actual shell invocation was the following here-string pipeline, preceded
by the read-only `rg` inspection shown below. `<Python body>` denotes the
literal contents now saved in `probe_math.py`, not a different algorithm:

```powershell
rg -n 'SETUP_DIV|pause_each_area_stage|reset|65535|left_x|right_x' cores/system/common_scaffold/board/tang25k/build/image_resample_frame_selftest_25k_20261017_v102g/tb_img_area_dst16_contract.sv
@'
<Python body>
'@ | python -B -
```

The completed tool output displayed `read_only_review: PASS`, 72,000 checks,
seed `0x1026`, and engine SHA256
`2de56577c9b42db3b63b9d6922c23e91d49d2ccd5a4eb3d1a6cf9c0c53b33d62`.
`original_stdout_json_transcribed.json` is the JSON section copied from that
tool output. The initial invocation did not persist a raw log file. Its
`exec_command` output text was forwarded without its process exit-code field;
the exact process exit code, wall-clock timestamp and original byte-level
newline encoding are therefore **not retained** here. This is an archival
transcription, not a newly generated execution log. No new PASS is claimed.

The sample checks compare integer operand widths and values for the old
expanded products versus the new registered-edge operands. The script uses
the same width for both coordinate axes; the static equivalence argument is
symmetric for Y. It does not execute, parse or compare RTL, and does not test
CE, reset, handshakes, cycles, synthesis, routing, hold timing or the board.
Those remain separate RTL tests and implementation evidence.

The static review found the following for legal configurations. Since
`ox < dw <= 65535` and `1 <= sw < 2^XW`, `(ox+1)*sw < 2^(XW+16)`.
Consequently the registered `right_x` loses no product bits, and
`right_x >= 1` prevents underflow in `right_x-1`. `DIV_W >= XEDGE_W` preserves
the operand when widened. The Y case follows the same argument. The added
`SETUP_DIV` state reads edges registered in the preceding CE-qualified
`SETUP` edge, before `DIV_START`. The inspected FSM and divider share CE and
reset. This adds one active CE cycle per destination pixel.

The existing g bench was inspected and calls
`pause_each_area_stage(ST_SETUP_DIV)`, preserving edge and numerator registers
while CE is low. This is a statement about reviewed source coverage, not a
claim that this mathematical probe ran that bench.
