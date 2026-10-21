# Motor host API

`tools/motor_host.py` provides bounded,transport-neutral CSR control using
`bus.access(byte_address,value=None) -> unsigned32`. The adapter must raise on
CSR response errors and transport failure. No physical adapter is included
in this module; UART/hard-user-JTAG acceptance remains separate.

Example (after an application supplies its bus and persistent recorder):

```python
from motor_host import command,run_case
config=command(sample_id=17,ia=0,ib=0,ic=0,theta=0,d=80,q=-60,restart=True)
result=run_case(bus,config,loaded_build_id,save_capture,
                ack_after_save=False,seconds=2,max_polls=1000)
```

`save_capture(dict)` must persist a copy of its input before returning and
raise if persistence fails. It receives CONFIGURING,RUNNING,READING (incremental
raw words),SAVED and optionally ACKNOWLEDGED states,or FAIL with the reason.
Use a new artifact/run path; do not overwrite earlier evidence. A recorder
must serialize immediately rather than retaining mutable dict references.
The API defaults to retaining the occupied result. `ack_after_save=True` is
explicit permission to ACK this one successful sample after SAVED persists.
No failed result is automatically ACKed or retried. If ACK itself/its response
fails,read hardware ownership before any later action; never blindly retry.

The API checks exact magic/build ID,empty idle state with clear released,
canonical signed/range-checked configuration,expected sample ID,one serial
increment,nonzero timestamp,twice-read stable result words/serial,terminal
error,recorded/live fault and duty bounds. It captures raw unsigned words
without silently converting error data to successful measurements. Arbitrary
numerical results require their own model comparison; the generic runner does
not infer physical accuracy from error0 or duty limits.

It never enables the drive,clears protection,changes sampling rates or provides
real-time scheduling. Use CONTROL_CSR.md's explicit initialization and recovery
sequence. A single CSR sample is diagnostic transport work,not sustained
control-loop replay. Enabled loops must use an appropriate hardware scheduler
and watchdog cadence; Python polling is not a replacement for that scheduler.

Run fixture checks without hardware:

```powershell
python cores/control/motor_foc/tools/test_host.py
```

PASS evidence:`artifacts/motor_foc_25k/host_20261020T213751245977Z`.
The fixture is pinned to PASS actual CSR RTL evidence
`csr_20261020T213541429585Z` and refuses mismatched current source hashes.
All36 numerical words are checked against actual RTL log values for three
commands,including signed encoding and configuration write mapping. Serial,
timestamp,build identity and bus lifecycle are explicitly synthetic in this
host test; their RTL behavior was separately checked by test_csr.py.
Nineteen negative guards cover identity/build/stale ownership,transport,
poll bound,serial/timestamp,fault/torn/badword/wrongID/error/duty/persistence,
and five configuration range/type failures. No error case ACKs; default
successful capture also leaves ownership held. No physical link,board capture,
image SHA validation or real-time replay acceptance is claimed by this test.

## Updated synthesis-compatible protection fixtures

After protection async-process synthesis fixes,the current hosttest pins
`csr_20261020T213959144452Z`;all sourcehashes are rechecked. Host PASS:
`host_20261020T214024605885Z` (same3numericalfixtures/19negativeguards).
Earlier pinned paths above describe historical runs and are not current
source qualification. No physical adapter acceptance is added by repinning.
