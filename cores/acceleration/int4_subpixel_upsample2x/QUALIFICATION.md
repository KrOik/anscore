# Finite qualification with explicit timeout boundary

The completed simulations qualify the minimum profile, the odd9-input/3-output
profile, and the25 other original maximum-static-profile frames. They check3080
vector outputs,3237 inputs,77 vector frames,18 resets and15 known future frames.
The real resident matrix and quantizer are used. Twelve HDL children have10 PASS
and2 TIMEOUT; three simulations finish successfully. Hardware remains unverified.

The full1024-pixel,16-output-channel lower-row test is **NOT_QUALIFIED_TIMEOUT**.
The original complete maximum-profile run hit20seconds. An independently reviewed
follow-up split its26 frozen frame records into the other25 and intact maximum
row. Inputs/configuration/goldens stayed byte identical; only file-leading record
counts changed. Production RTL,original TB,model and old runner did not change.
The25-frame piece passed. The maximum row again timed out at20seconds,with progress
logged through327680 clocks,source x841,842 inputs and26936 retired checked outputs.
That progress does not establish final frame correctness or conclusively identify
the timeout cause. No further split,rerun or extended deadline was attempted.

The separate copied TB differs only in its top name and progress display/flush
statements. Both original failure receipts,source archives,vectors,logs and images
remain. There were3 original integer preparations and1 literal-record preparation,
zero planning or repair oracle calls. Original successful profiles were not rerun.
All4 unique images remain outside Git. One follow-up image was used by both its
successful25-frame and timed-out maximum-row simulation and must be preserved.
QUALIFICATION.json and B42_DELIVERY.json bind the exact plans,receipts and hashes.
