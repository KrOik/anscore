# IP-09 motor control (development)

Work-order target: Clarke/Park,current/speed/position control,SVPWM,dead-time,
QEI and fault shutdown,with numerical plant step/disturbance tests before
optional real motor hardware. This project has only begun the protection path.

`rtl/pwm3_protection.v` accepts three synchronous raw PWM commands and emits
six complementary digital gates. For a raw transition sampled at edge t,
both gates turn off at t and the new gate turns on at t+D clock periods if
the command stays unchanged. dead_ticks D must be1..65535. A new transition
during the off interval restarts that interval; narrow pulses can disappear.
Initial enable also waits D ticks. Disabling immediately gates all outputs off.
Changing D affects newly detected transitions; use atomic controller settings
in the eventual integrated drive. No center-aligned carrier is implied.

Reset starts fault-latched. External active-low fault_n immediately gates all
outputs and asynchronously latches the fault,including a sub-clock pulse.
Release does not automatically restart. Explicit clear requires enable0 and
two sampled fault-release clocks; clear while enabled is ignored. Zero D
gates outputs immediately and latches config_error until disabled/nonzeroD
explicit clear. Raw/PWM/dead-time inputs are in the same clock domain.
External fault wiring,clock-domain release and real gate-driver timing require
board-specific review. This is a digital reference,not certified power-stage
protection or a measured asynchronous shutdown delay in hardware.

The test instantiates unchanged canonical wave2_ip_20k/src/pwm_gen.v at
period16,duties4/8/12. A cycle-level oracle checks exact D2/D3 timing and
mutual exclusion. A fault pulse between clock edges must suppress outputs
before the next clock; sticky fault,enabled-clear rejection,disabled-clear,
zeroD latch and recovery are asserted. No physical PWM/QEI/FOC pass follows.

```
. ./scripts/env.ps1
python cores/control/motor_foc/tools/test_pwm.py
```

Reuse audit located production_accel_25k acc_clarke_s12,acc_park_s12,
acc_inv_park_s12,acc_svpwm_sector and wave2 qei/pwm,plus dsp_20k pid_core.
The transform candidates use explicit GW5A MULT12X12 and specific packed
signed/Q-format conventions; assess their specs/numerics before integration.
`rtl/current_transform.v` now connects unchanged Clarke and Park kernels as
a two-stage elastic pipeline. Inputs are signed10 ia/ib/ic,Q10 theta8 index,
plausibility-enable/tolerance8 and sample_id32. Outputs are signed12 alpha,
beta,d,q,residual12,Park rangeflags4,sensor/arithmeticfault and aligned ID.
Angle and sensor metadata have matching ready/valid storage. Continuous II1
and stable output under stalls are checked. No inverse transform/regulator
or actual PWM coupling is present in this wrapper yet.

`python cores/control/motor_foc/tools/test_transform.py` independently generates
the Q10 trigonometric table from sin/cos and compares all256entries to the
canonical image. It computes Clarke by integer equations and Park by four
products (canonical uses three),then compares1024 full result records including
all256angles,balanced/unbalanced phase currents and179 plausibility faults.
First128samples assert II1,then seeded gaps/stalls exercise metadata alignment.
The canonical signed MULT12X12 simulation model is explicit in simulation
sources; it is not a synthesis replacement or new primitive certification.

Canonical files unchanged; the other candidates are not yet in a loop here.
Licensing/ownership audit remains open. No25K synthesis/PPA or board claim.

Remaining: canonical transform/controller integration,numerical plant,
current/speed/position modes,real SVPWM duty generation,atomic carrier update,
QEI/watchdog/fault counters,CSR/replay/host,golden closed-loop tests,25Kbuild,
LA/physical and release dependency evidence.

## dq current PI and numerical plant

`rtl/dq_current_pi.v` reuses two unchanged acc_ipi_pid_s12 instances. One
atomic d/q sample includes signed12 references/measurements,kp/ki signed12,
shared shift4,restart,integrator-freeze and sampleID32. Reference-minus-current
is evaluated signed13 and explicitly clamped to signed12 with per-axis flags.
Derivative gain is0; actuator clamps to[-1024,1023]. The canonical conditional
integration,round-half-up requantisation and integral clamp[-2048,2047] remain
unchanged. Diagnostics expose per-axis canonical result flags,fault and
committed integrals. Both regulators consume/publish the same handshake;
no state advances without accepted input and outputs hold during backpressure.
This is a dq-domain current regulator,not a speed/position loop yet.

`python cores/control/motor_foc/tools/test_current_pi.py` runs the actual RTL
outputs into two numerical plants: `i += (u - 2*i + disturbance) >> 4`.
This normalized first-order RL surrogate has no physical units,rotor coupling,
back-EMF or inverter loss. The independent Python state model checks1024
references/currents/voltages/integrals/flags,including step,disturbance,reversal,
actuator saturation,integrator freeze/restart and recovery. A separate accepted
beat exercises signed error clipping at both endpoints. Random sink stalls
check held output. Settled windows must remain within3counts; observed0counts
in the current fixture,with23conditional-integration antiwindup samples.
This does not yet close phase-current transforms through inversePark/SVPWM,
nor connect the fault-protection module to the plant. No real motor claim.

## Inverse rotation and modulation

`rtl/voltage_modulator.v` reuses unchanged acc_inv_park_s12,then connects
`svpwm_duty.v`. The two-stage elastic pipeline carries period/sampleID and
rotation saturation flags with the same beat. Inputs d/q signed12 are clamped
by canonical inverse rotation to[-1024,1023],theta indexes Q10 sin/cos.
The modulation stage uses min/max common-mode space-vector injection:
u=alpha;v=round_up((-alpha*1024+beta*1774)/2048);
w=round_up((-alpha*1024-beta*1774)/2048),where1774 approximates sqrt3*1024.
Common offset=floor((max(u,v,w)+min(u,v,w))/2). Subtract offset,clamp each
phase to[-1024,1024],then duty=round_up((phase+1024)*period/2048).
This is common-mode SVPWM,not an explicit seven-segment switching sequencer;
the existing canonical sector decoder alone does not generate full duties.

Period4..65535 is legal; period<4 sets errorbit0 and zeroes all duties. Any
centered phase outside the linear modulation range sets errorbit1 while
returning clipped duties. Rotation flags separately expose canonical input
clipping/output range diagnostics. Duties lie within0..period; zero vector
gives rounded half-period duties. Reset discards pending beats. No PWM carrier,
gate dead-time or physical voltage claim is implied by these duty words.

`python cores/control/motor_foc/tools/test_modulator.py` verifies1024exact
duties/periods/errors/IDs/flags against independent four-product inverse
rotation and integer modulation,all256angles,extreme signed inputs,period
0/1/3/4/5/100/1024/65535,overmodulation and stalls. First128assertII1.
It also reconstructs average line voltages for non-overmodulated periods>=100
and compares with floating-point ideal rotation/inverseClarke,allowing
2048/period+4counts for PWM and fixed-point quantisation. This numerical
property does not include dead-time distortion or an actual switching load.

## Atomic PWM carrier and protection

`rtl/pwm3_atomic.v` accepts complete period,u/v/w duties,dead_ticks and sampleID
commands into one pending slot. Idle/unconfigured applies immediately; running
applies only after the old counter's period-1 beat. Period,duties,dead-time and
ID change together,starting the new counter at0. No update mixes phase values.
No input is accepted while pending; source must hold all fields under stall.
Comparator outputs use counter<duty,so0 is always low andperiod always high.
Carrier is edge-aligned,one system-clock tick per count. Disable resets counter
but retains valid active settings; pending commands may apply while disabled.

Valid period>=4,dead>=1,2*dead<period,duties<=period. Accepted invalid commands
increment rejected count,retain active settings and latch config_fault,which
asserts the protection fault input. A later valid command does not silently
clear that fault; disable and explicit clear are required. The integrated
pwm3_protection still requires reset/external faults to be explicitly cleared.
Direct fault_n gating,dead-time,sticky fault and release qualification are as
specified above. The applied pulse/ID and active settings expose actual boundary
ownership; raw PWM is diagnostic and is not a safe gate output during a fault.

The earlier canonical pwm_gen is retained unchanged and remains used in the
standalone protection test. Its separate sequential period/duty writes cannot
provide this complete-command boundary atomicity,so this carrier is a new narrow
implementation rather than a hidden change to the canonical peripheral.

`python cores/control/motor_foc/tools/test_atomic_pwm.py` checks18complete
carrier periods across three parameter sets and377sampled cycles,including
mid-period queued update,period16->20,dead2->3,duties0/period endpoints,
invalid command shutdown,asynchronous fault and explicit recovery. Python
independently counts high raw ticks per carrier and checks no mixed parameters;
RTL asserts gate nonoverlap/fault suppression. Modulator-to-carrier and full
FOC/plant coupling remain open. No physical gate timing or resource claim.

## Complete serialized current step

`rtl/foc_current_step.v` owns one phase-current sample through current_transform,
dq_current_pi,voltage_modulator and pwm3_atomic/protection. It snapshots angle,
references,gains,period,dead-time and ID at acceptance. Completion waits for the
matching applied_id pulse from the actual carrier,then holds ID,measured d/q,
voltage d/q,duties,error and diagnostics until done_ready. This serialized
control path deliberately has one outstanding sample; no whole-loop II1 claim.
The arithmetic blocks retain their standalone elastic contracts.

Error bits:0 invalid period/dead-time or modulation protocol;1 broken shunt
consistency/transform ID;2 clipped regulator error/ID;3 drive fault during
operation;4 overmodulated applied command (diagnostic,does not trip);7 bad FSM.
Fatal paths latch internal drive trip,flush/reset arithmetic (including PI
state),and return a held error. Drive fault during ownership also flushes.
Carrier configuration/gate fault latch is not silently reset. Disable and
explicit clear,then a fresh restart sample,are required for deterministic
recovery. A zero-error completion while disabled means settings applied,not
energized gates. Initial reset fault requires a disabled configuration step
and explicit fault-clear qualification before enable. A later live fault does
not rewrite an earlier held result; always inspect the separate live latch.

Diagnostics40: bits11:0 dPIflags,23:12 qPIflags,25:24 regulator error clipping,
29:26 Park range flags,33:30 inversePark range flags,35:34 canonical PI fault,
39:36 reserved0. Saturation/antiwindup is observable rather than silently
discarded. Shunt plausibility tolerance is2counts in this reference wrapper.

`python cores/control/motor_foc/tools/test_foc.py` closes512actual phase samples
through the entire RTL to applied PWM and back into a stationary alpha/beta
first-order numerical plant. Feedback uses averaged applied duty line-voltage,
not measured real motor currents or gate-loss physics. Phase ADC quantization,
canonical Clarke/Park/PI,inverse rotation,SVPWM,duties and diagnostics are
independently checked at every sample. Step,angle0->45->90degrees,disturbance,
reversal and restart settled windows require<=5counts; current observed maxima
0,1,0,0,0. Gate nonoverlap/fault suppression and held completion are asserted.
Tests additionally inject broken shunt consistency,external fault while owned,
fault clear/restart and invalid PWM configuration. No watchdog/timeout,outer
speed/position loop,QEI,CSR/replay or real motor acceptance is supplied yet.

## Encoder feedback

`rtl/encoder_feedback.v` synchronizes raw A/B/index through two stages,then
uses unchanged canonical qei_dec x4 decoder. Forward sequence00->10->11->01->00
increments; reverse decrements. The wrapper diagnoses two-bit Gray jumps with
a sticky encoder_error/count; canonical count remains unchanged for such jumps,
although its step_event can still pulse. Clear_errors resets diagnostics,
with a same-edge new violation taking precedence. Diagnostics are not yet
connected to the FOC drive trip input.

sample_tick captures coherent signed position32,delta velocity32,timestamp64
and monotonically incremented sequence32. Velocity is counts per caller-defined
sample interval,not RPM; use a constant interval and supply encoder scaling in
the controller. Each sample sees decoder state from the preceding clock edge
because both blocks are registered. Snapshot_valid pulses; its data and
velocity_valid hold until the next sample. The first baseline sample has
velocity_valid0. Position arithmetic wraps modulo2^32; signed delta assumes
motion strictly within half the count range per sample.

Rising index latches the prior decoder count. With index_reset0 a coincident
legal step is counted; with index_reset1 count clears and that step is dropped,
matching canonical RTL (the broad header comment is less precise). The reset
choice is delayed alongside index_event for snapshot rebasing. After a count
reset,the partial speed interval is invalidated and a fresh sample baseline
is required,preventing an index-induced velocity spike. Neither synchronization
nor a Gray diagnostic guarantees lossless counting if edges outrun sampling.
Reset assumes quadrature state00; a different initial phase can count an initial
transition or diagnose a jump. Home/index before using absolute position.

`python cores/control/motor_foc/tools/test_encoder.py` independently models
the synchronizers,Gray state machine,index priority and coherent snapshots.
It checks1000clocks/91snapshots,forward/reverse,index-with/without-reset,
signed wrap,invalid jumps and diagnostic clear. No physical encoder rate,
metastability MTBF,LA or integrated outer-loop acceptance is claimed.

## Current/speed/position command modes

`rtl/motor_outer_loop.v` is a serialized command source for the current loop.
Mode0 passes d reference and clamps direct q to+/-CURRENT_LIMIT(default256).
Mode1 uses target_speed;mode2 forms `(target_position-position)>>>POSITION_SHIFT`
(default3). Both speed targets clamp to+/-SPEED_LIMIT(default32 counts/window).
Position subtraction is signed33,so extreme opposite signed32 endpoints do
not silently wrap. Speed error is signed33 then clamped16 with clippedbit0;
speed-target limiting sets bit2,direct-q limiting bit3,bit1 reserved0.

The speed PI reuses unchanged zero-DSP pid_core with Kp4,Ki1/4,Kd0,
integral clamp+/-2047 and output clamp+/-CURRENT_LIMIT. It uses the canonical
integral clamping law,not conditional integration of the inner current PI.
Entering speed/position from a different mode or asserting restart resets
its integral via a registered reset state. integrator_restarted reports an
actual outer-PI restart; current mode bypasses that PI,and returning later
forces a restart before use. No state advances on result backpressure.
Mode3 returns error1;speed/position with invalid velocity baseline returns
error2 and no PI state update. Output commands/ID/errors hold to m_ready.
Mode-dependent loop/sample rates and physical unit conversion are still the
owning integrated controller's responsibility.

`python cores/control/motor_foc/tools/test_outer.py` verifies1024actual commands
against independent mode/PID state and a normalized mechanical surrogate:
`velocity_q8 += (q_command*256 - 4*velocity_q8 - load_q8)>>5`,then position
integrates velocity. Feedback velocity is delta quantized position per sample.
It covers direct current,speed +/-steps,load disturbance,position +/-steps,
mode changes/restart,held output,invalid mode/velocity and extreme speed error.
Current observed settled errors: speed1,reversal1,position6,position reverse1,
restart0counts against fixed limits2/2/10/10/2. InitialKi1/8 failed the speed
window at3counts;the actual RTL gain changed to1/4 and the original thresholds
were retained. This is not yet QEI->outer->phaseFOC/mechanical joint integration.

## First-fault and applied-update watchdog supervisor

`rtl/motor_safety.v` wraps unchanged canonical `wdt_win`. Applied PWM events
are retained until monitor_tick, so a narrow update is not lost between beats.
External fault capture is asynchronous; encoder/control errors and watchdog
reset/early/late states also inhibit drive_fault_n. First cause (1 external,
2 encoder,3 timeout,4 early/late,5 control),64-bit timestamp and lifetime fault
count are retained. Clearing is permitted only while disabled with live
external/encoder/control faults absent. A pending one-clock clear is carried
to the next watchdog tick; stale watchdog causes cannot re-latch during that
wait. Raw watchdog state still inhibits gates until actually cleared. PWM
protection has separate release qualification and must also be explicitly
cleared before enabling. No certified power-stage safety claim is made.

`python cores/control/motor_foc/tools/test_safety.py` connects the actual
supervisor to pwm3_atomic/protection. Six fault episodes cover timeout,
encoder,subclock external,early heartbeat,control error and a second timeout
with single-clock disabled clear between monitor beats. Checks include first
cause preservation,enabled-clear rejection,live encoder blocking clear,
heartbeat aggregation,gate suppression and explicit recovery. Latest PASS:
artifacts/motor_foc_25k/safety_20261020T212621936223Z. The added pulse-clear
regression fails pre-fix RTL (pre_fix_expected_failure.log) and passes fixed
RTL. This is simulation evidence,not physical shutdown latency qualification.

## Integrated sample ownership

`rtl/motor_controller.v` connects encoder_feedback,motor_outer_loop,
foc_current_step and motor_safety. Exactly one accepted command is owned
through QEI snapshot,outer-loop response,FOC applied-PWM response and held
result. All command context is captured at valid/ready acceptance; changing
live mode/ID afterwards cannot alter the owned transaction. Encoder position
and velocity are coherently sampled at that acceptance. The first sample has
no valid velocity baseline: use a disabled direct-current initialization
sample before speed/position operation. Electrical theta remains explicitly
supplied; encoder counts are not silently treated as electrical angle.
Velocity units are counts per accepted-sample interval; callers must provide
constant cadence or apply explicit unit conversion. No free-running sample
queue or automatic timing scheduler is provided by this module.

The inner loop exports applied_update from the actual atomic PWM carrier;
this signal feeds the canonical watchdog,not result acknowledgements. A held
result cannot manufacture heartbeats. WMIN/WMAX and monitor_tick must be
chosen for the specified sampling cadence. The caller controls enable and
must keep it stable for an owned command. Initialization and explicit clear
are performed disabled; hold clear long enough for the PWM release qualifier
and watchdog monitor tick before enabling. QEI error clear is disabled-only.

Outer errors/ID mismatch return error0x20 with sticky control fault and no
PWM submission. FOC ID mismatch returns0x40; inner errors retain their byte
encoding (0x10 overmodulation diagnostic is nonfatal). Fatal inner errors
latch control fault; clearing a result by m_ready does not clear protection.
External,encoder and watchdog trips also inhibit the actual carrier. The
monitor records first cause/time/lifetime count. Measured dq/voltage/duty
outputs are valid with held m_valid after a successful FOC operation; after
an outer error they retain the previous FOC values and must not be interpreted
as a new successful control update.

`python cores/control/motor_foc/tools/test_controller.py` PASS evidence:
artifacts/motor_foc_25k/controller_20261020T212857193310Z. It tests all three
modes,legal QEI Gray cycle/coherent delta,command snapshot despite live-input
changes,held result/backpressure,exact applied-event count,illegal Gray
shutdown,invalid outer mode without PWM submission,subclock external fault
and disabled recovery. Initial test used opposite Gray direction and failed
its expected +4 count; the stimulus was reversed,not the canonical decoder
or expected positive displacement. Failure evidence is retained. Existing
512-state phase-plant oracle also passes after exposing applied_update:
artifacts/motor_foc_25k/foc_20261020T212843443207Z.
This integrated test is protocol/fault evidence; joint mechanical-plant
numerics,CSR/replay/host,synthesis and25K hardware acceptance remain open.

## Integrated averaged electrical/mechanical/QEI numerical acceptance

`python cores/control/motor_foc/tools/test_plant.py` now closes the connected
controller around an averaged numerical plant,using actual applied PWM duty
results rather than the outer current command as torque. Each accepted sample
is exactly1024 clocks apart. Fixed supplied electrical theta0 makes d/q axes
stationary; this test is not a rotating PMSM/back-EMF/inverter switching model.
It emits physical Gray A/B transitions (six clocks per edge) through the actual
two-stage synchronizer and canonical QEI,then checks the sampled count/delta.
The first disabled initialization and explicit protection clear precede enable.

Equations (integer shifts arithmetic; divisions truncate toward zero):
Va=(2*Du-Dv-Dw)*2048/(3*256),
Vb=(Dv-Dw)*2048*1024/(1774*256);
Ia += (Va-2*Ia)>>4; Ibeta += (Vb-2*Ibeta)>>4;
velocity_q8 += (Ibeta*256-4*velocity_q8-load_q8)>>7;
position_q8 += velocity_q8. Shunt samples are Ia,
Ib=(-Ia*1024+Ibeta*1774+1024)>>11,Ic=-Ia-Ib.
The numerical torque uses resulting phase current,not requested q current.
Average ideal duty voltage excludes deadtime voltage loss,switching losses,
back-EMF and physical motor parameters; gate nonoverlap/inhibit assertions
remain active and dedicated PWM/deadtime tests cover the digital waveforms.

The original integrated speed Ki1/4 caused sustained position oscillation.
plant_20261020T213043032303Z preserves FAIL despite2048exact golden states
(position error743>10). Parameter SPEED_KI_SHIFT is now exposed by the outer
module (standalone default2 unchanged) and controller (integrated default6).
Kp4,Ki1/64 is the actual integrated RTL setting; position shift3 and all error
thresholds remain unchanged. This setting is for the documented normalized
plant/cadence; physical control gains require separate plant qualification.
No simulation expectation was changed to excuse the oscillation.

PASS evidence:artifacts/motor_foc_25k/plant_20261020T213232350599Z.
2048exact full states include mode,position,velocity,target,phase currents,
measured dq,voltage dq,applied duties,mechanical states and applied-event count.
Speed step/load/reverse max errors2/2/2counts/window (limits2),position/reverse
2/7counts (limits10),restart0(limit2). Also verifies one applied update per
sample,zero supervisor faults,no deadline overrun,and QEI count equality.
Independent Python oracle hashes its arithmetic helpers,tables,RTL and TB.
Standalone outer regression remains PASS1024states at original Ki1/4:
outer_20261020T213247545973Z;integrated protocol/fault regression PASS at
controller_20261020T213247554189Z. This supersedes the earlier missing-joint-
numerical-test note for this averaged stationary-axis model only. CSR/replay,
host,synthesis/placement,25K/LA and physical motor gates remain open.

## Transport-neutral command/result CSR

`rtl/motor_control_csr.v` and CONTROL_CSR.md define a one-command-owned CSR
front end with immutable result capture,explicit result ACK and explicit
hold/release-clear/enable/disable lifecycle. Configuration cannot change while
busy; firstcause capture allows the controller trip to propagate before
snapshot. Actual motor_controller is instantiated,not a response stub.
`python cores/control/motor_foc/tools/test_csr.py` PASS evidence
csr_20261020T213541429585Z:three numerical snapshots and invalid-mode terminal
fault,backpressure,negative accesses,live fault with stable results,recovery.
CSR is transport-neutral; finite full-clock replay,UARThost/hardJTAG and25K
synthesis/board acceptance remain open. CONTROL_CSR.md is the register map.

## Host result capture API

`tools/motor_host.py` adds canonical command range/encoding checks,bounded
polling,identity/build validation,immutable result verification and incremental
capture through a caller-provided persistent recorder. ACK is explicit and
only after successful SAVED persistence; failures preserve hardware ownership.
No enable,clear or retries are implicit. HOST.md specifies the bus/recorder
contract and the distinct missing physical transport/full-clock replay gates.
`python cores/control/motor_foc/tools/test_host.py` PASS evidence
host_20261020T213751245977Z:three source-hash-pinned actual RTL numerical
fixtures (36fields),19 negative guards,save-before-ACK/default-held behavior.
Host lifecycle metadata is synthetic and explicitly separate from actual
CSR RTL evidence; no live UART/JTAG/25K acceptance is inferred.

## Synthesis-compatible protection capture

The first actual GW5A synthesis rejected the original multi-asynchronous-edge
processes even though digital simulations passed. PWM fault/reset now combine
into one asynchronous assertion net for fault_latched and release_sync.
The external supervisor capture has one asynchronous external-fault set pin;
system reset clears that capture synchronously at clk when raw external fault
is released. Raw external fault wins over system reset for that capture and
continues to gate drive_fault_n directly. Other supervisor registers retain
asynchronous system reset. Hold system reset through at least one clock before
use. Release qualification and disabled-only clear remain explicit; this is
not a physical reset-release/MTBF or certified power-stage qualification.

After this change the dedicated subclock-fault/deadtime/protection regression
PASS pwm_protection_20261020T214020945531Z;atomiccarrier PASS
atomic_pwm_20261020T214022856141Z;sixfault safety PASS
safety_20261020T213957256532Z;connectedcontroller PASS
controller_20261020T214023711832Z;CSR PASS csr_20261020T213959144452Z;
hostfixture repinned to that source-hashed CSR evidence and PASS
host_20261020T214024605885Z. The older hostfixture/sourcehash references above
are historical evidence; current test_host.py pins the new CSR run.

`tools/synth_core.py` freezes sources/tables and synthesizes motor_control_csr
for GW5A with no IO pads. It excludes behavioral MULT12X12 simulation model,
retaining explicit vendor primitives. This is core-only resource evidence;
board route,IO/effective Fmax and bitstream are separate acceptance gates.

### First core synthesis result

`synth_20261020T214131951101Z` PASS for motor_control_csr,GW5A target:
5833 LUT1..4 (28/1315/2288/2202),1809 ALU,2509 DFF,
14 MULT12X12 primitives,0 BSRAM/PLL/IOB. PPA_25K.csv records this core-only
measurement. Primitive count is not a claim about final physical DSP packing.
No IO pads are emitted,no timing/placement/route/image/board qualification.
Source/table/script snapshots and netlist SHA256 are in the evidence summary.
Initial synth_20261020T213924873254Z failed on multi-async-event inference;
synth_20261020T213958280835Z mapped successfully but its report remained FAIL
because the script mistook19 nonfunctional $scopeinfo metadata cells for
unmapped logic. Both preserved;classifier permits only that metadata and
continues to reject other unmapped internal cell types. Current frozen rebuild
and check -assert pass. No claim that this image fits/runs on current20K.

## First25K board-bound offline implementation

Added examples/25k/motor_top.v,motor.cst with supplementary canonical UART
transport and isolated registered8probe outputs. RawQEI tied0/externalfault
inactive for this diagnostic binding;no physicalmotor interface claim.
`test_uart.py` PASS uart_20261020T214527771634Z checks three complete commands
and36numericalwords through bit-serial UART/actualCSR/controller. Simulation
baud shortened;not physicalUART evidence. `build_board.py` freezes inputs,
synthesizes/routes/packs GW5A-LV25MG121NES. PASS
board_20261020T214445572169Z:79.038887MHz target50MHz,final7328LUT4,
1850ALU,2563DFF,14MULT12X12,0BSRAM/PLL,11IOB. PPA_25K.csv and
INTEGRATION.md recordfingerprint/imageSHA andscope. No download occurred.
`motor_host.validate_build` verifiescurrent/frozensources/fingerprint/image;
run_uart.py provides one disabled-drive diagnostic,with durablefile capture
before optionalACK. Help/hostfixturechecks pass;physicaladapterunused.
Finitehardware replay,externalmotor/QEI binding,runtimehardJTAG,25K/LA
measurement,licensing/release remainopen;this is not completeIP09acceptance.
