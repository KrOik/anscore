# B39 segmented qualification status

LINT_PASS / UNIT_SIM_PASS / INTEGRATION_CANDIDATE / HW_UNVERIFIED.

Primary six-child repair receipt PASS, three successful simulations:
`repair_reports/20261106T055649817455Z/results.json`, SHA256
`a8b72d4c88976cb95ee8323de19ac511abac237ad41a7fa6bca95daa6abf6b55`.
Prior receipt remains FAIL: six passed children, one watchdog failure, one
successful simulation. Root-approved TB-only repair corrected a cancellation
driver/backpressure deadlock; production RTL, oracle, original plan/runner,
vectors and original raw streams were unchanged. No passed syntax/minimum
profile rerun, no automatic repair/retry, no second oracle import/preparation.
Combined evidence has12 passed children, four successful simulations and one
historical HDL failure; it is not a first-attempt suite pass.32768 output records
were checked. Full metadata is in QUALIFICATION.json and B39_DELIVERY.json.
The first failed image is permanently retained per FAILURE_ARCHIVE.json.
Shared sources are unchanged. Legacy window storage is register-based;
default risk LOW/MEDIUM, maximum HIGH; the actual chain has two windows.
No synthesis/PnR/STA/board, PPA search, maximum frame simulation or old regression.
