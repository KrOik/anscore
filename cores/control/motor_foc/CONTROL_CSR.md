# Motor controller CSR

`rtl/motor_control_csr.v` connects the actual motor_controller to a
transport-neutral one-outstanding-request CSR. No UART/hard-user-JTAG bridge
or physical transport acceptance is implied. Addresses are byte addresses,
32-bit aligned. Requests accept on req_valid&&req_ready; responses hold
valid/data/error until resp_ready. Writes require strobe0xF; unsupported,
unaligned,partial writes and disallowed lifecycle operations return error
without side effects. No automatic retry,ACK,clear or enable occurs.

| Address | Access | Meaning |
|---|---|---|
|00|R|Magic0x464F4331|
|04|R|bit0busy,1result occupied,2enabled,3clear held,4drive_fault_n,5PWMfault|
|08/0C|R|BUILD_ID low/high|
|10|W|One command value from list below|
|14|R|Live first cause|
|18|R|Lifetime fault count|
|1C/20|R|Live first fault timestamp low/high|
|24|R|Captured result serial, increments once per result|
|28/2C|R|Latest result capture timestamp low/high|
|40|RW|mode[1:0],restart[8],freeze_integral[9]|
|44/48/4C|RW|Ia/Ib/Ic signed low10|
|50|RW|Electrical theta low8|
|54|RW|Target position signed32|
|58|RW|Target speed signed low16,counts per sample interval|
|5C/60|RW|Direct d/q references signed low12|
|64/68|RW|Current PI Kp/Ki signed low12 (defaults8/4)|
|6C|RW|Current gain shift low4 (default4)|
|70/74|RW|Carrier period/dead ticks low16 (defaults256/2)|
|78|RW|Sample ID32|
|80|R|Result ID|
|84|R|Result error byte|
|88/8C|R|Captured encoder position/velocity signed32|
|90/94|R|Measured d/q sign-extended32|
|98/9C|R|Voltage d/q sign-extended32|
|A0/A4/A8|R|Applied U/V/W duties zero-extended32|
|AC|R|First cause at result capture|

Configuration stores full32 words but only specified low bits are consumed;
upper unused bits have no control meaning. Configuration writes are rejected
from submit until explicit result ACK. One whole command context is thereby
owned. Results80..AC are unreadable while empty; a completed result is copied
once,one extra clock after done is first observed so controller trips reach
the supervisor first-cause register. It remains stable even if a later live
fault changes14..20. Current/voltage/duty fields on failed commands may contain
previous values; interpret them only with the result error. Timestamp is in
system clocks and describes capture,not host read time.

Command10 values are exact,not combinable bit masks:

|Value|Action/condition|
|---|---|
|1|Submit when idle,clear released and controller ready|
|2|ACK only occupied result; releases controller ownership|
|4|Hold clear_fault high only idle and disabled|
|8|Release clear_fault only idle and disabled|
|16|Enable only idle,clear released,drive safe and PWMfault cleared|
|32|Disable immediately,including while busy; keeps ownership/result|

Startup: write initial direct mode,current samples,theta/PI/carrier/sampleID;
submit disabled and save/read/ACK result; assert clear4 while disabled and
wait for PWM release qualification plus watchdog monitor tick; release8;
verify status and enable16. Each subsequent sample is submit1,poll04 bit1,
read/save80..AC then ACK2. A held result does not kick watchdog: hardware
cadence must provide timely applied updates. Slow CSR access is not a
full-speed control scheduler; finite hardware replay owner is still required.
Fault recovery: disable32,finish/read/ACK owned result,remove raw fault,
assert clear4,wait qualified release and monitor tick,release8,verify status.
Clearing live fault diagnostics never rewrites a saved result.

`python cores/control/motor_foc/tools/test_csr.py` tests actual RTL/controller:
three independently calculated numerical snapshots (36words),one terminal
invalid-mode error with firstcause5/no PWM submission,held CSR responses,
busy/config/submit/clear rejection,empty ACK/read errors,unaligned/partial
requests,serial counts,later external fault with immutable result,explicit
lifecycle and recovery. PASS evidence:
`artifacts/motor_foc_25k/csr_20261020T213541429585Z`.
No synthesis,resource,physical transport or board result is claimed.
