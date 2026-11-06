# B47 exact subpixel rectangle coverage delivery

**FINITE_RTL_PASS / HW_UNVERIFIED**,2026-11-06. The original source snapshot
and executed evidence are retained unchanged. This result document and
`QUALIFICATION.json` record the completed outcome of the reviewed source plan.

The new core generates exact positive pixel-cell areas from signed-Q8 runtime
rectangle edges clipped to a1..256 by1..256 viewport. The actual example
rendezvous with ordered destination pixels, applies exact RNE premultiplied
paint scaling, and uses unchanged production `rgba_porter_duff`. Command
ownership includes final composed-fragment retirement and completion retirement.
No framebuffer or texture memory is added.

The sole authorized gate `B47_SUBPIXEL_RECT_COVERAGE_ONCE_01` completed exactly
five standalone archived oracle preparations, two syntax children, five
compilations and five simulations. All17 children returned0 with confirmed
exit, complete output capture and no termination helper or active PID. The
largest recorded child took1.313s against the fixed20s deadline. The5s tree
termination and sole shared2s exit/drain path were not needed. There was no
retry and no project oracle import by the runner.

| Profile | Cases | Exact fixture fragments | Reset/recovery checks | Queued commands |
| --- | ---: | ---: | ---: | ---: |
| Core1x1, TAG1 |24|13|4|2|
| Core7x5, TAG8 |24|75|4|2|
| Core256x256, TAG32 |24|65825|4|2|
| Actual blend7x5, TAG8 |44|93|8|2|
| Actual sparse blend256x256, TAG32 |44|311|8|2|
| Total |160|66317|28|10|

Independent histogram fixtures verified negative/signed-extreme edges,
clipping, thin and fractional shapes, area1/full65536, empty/reversed geometry,
and exact conservation including65536 accepted pixels with area sum2^32.
Actual blend fixtures verified all13 modes, paint RNE ties and original-paint
error preservation when tiny coverage rounds to zero. The TB checked stalled
output/completion stability, destination source stability, command-field
poison, a real future command held during ownership, strict EOF, live reset
cancellation and fresh recovery. The tiny1x1 profile's partial-traversal reset
degenerates to a completed single pixel; larger profiles exercise real partial
traversal. Fragment totals above count file-backed oracle comparisons and
exclude the additional queue/recovery checks.

All16 canonical and archived source hashes,24 tool hashes, three controls,
34 raw streams,17 child records,10 vector/preparation artifacts and five
compiled/executed image hashes passed the metadata postcheck. Every simulation
launch persisted its prechecked image SHA256 before starting the process.
All five simulation stderr streams are empty and all contain normal `$finish`.
The blend syntax and compile streams retain the unchanged production module's
Icarus constant-select sensitivity notices; the tool completed successfully.

Original results:
`reports/20261106T153659_643183Z/results.json`, SHA256
`4bf96f5025fb408566effe288dc9d425854d426176f775afcf6392fc9a5cf9d9`.
Plan SHA256
`066cdae680211b00069a1dc8b24a2279cc0f4e7789ec1757876202abab2241bb`;
source seal SHA256
`97ca3123af34ab43ea5e3ba22ab64aeec0f2413ff6c3ead64c346e6ac268b566`;
review SHA256
`e4a7b0c7d5adc8545d12b2eb558b9f89f6b28c428af0e8049670b63524ef3442`.

The coverage core uses a registered area step with II2; the actual serial
blend accepts a new coverage/destination pair every9 clocks without stalls.
These are architectural schedules. Finite RTL evidence does not establish
universal correctness, measured dense-video throughput or physical fit.
No synthesis, PnR, STA, board or PPA execution was performed. Original README,
manifest and frozen plan retain their pre-execution status as sealed inputs.
