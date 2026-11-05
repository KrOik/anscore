# Exact runtime GF(2) polynomial irreducibility

`gf2_polynomial_irreducibility` decides whether a caller-supplied monic binary
polynomial is irreducible. The caller supplies coefficients, never a factor,
Frobenius residue or precomputed classification. This provides the missing
modulus-domain check for configurable polynomial arithmetic.

All hardware is **HW_UNVERIFIED**. Only an actual successful `verification.json`
can qualify the explicitly frozen finite unit checks. No synthesis, PnR, STA,
formal, board, power or inherited regression is part of this package.

## Polynomial and result meaning

`DEGREE=D` defaults to16 and is legal from1 through64. `TAG_W` defaults to8
and is legal from1 through32. Input bit j is the coefficient of x^j; the
coefficient of x^D is implicitly one:

```text
P(x) = x^D + sum(s_poly[j]*x^j, j=0..D-1), over GF(2).
```

Every D-bit input pattern is legal. Low bits all zero mean P=x^D, not the zero
polynomial. A true zero polynomial, constants, arbitrary leading coefficients
and runtime degree changes have no encoding in this fixed-degree interface.
For D=1, both x and x+1 are irreducible, and x mod P equals the input constant
coefficient. The implementation does not assume bit one can fit a one-bit word.

Let C_i=(x^(2^i)+x) mod P. For each distinct prime q dividing D, Rabin's test
requires gcd(P,C_(D/q))=1; it also requires C_D=0. Checkpoint indices D/q are
visited in increasing order. D=1 has no GCD checkpoints. All arithmetic is
exact XOR polynomial arithmetic, without signed values, integer carries,
scaling, rounding, approximation, saturation or overflow status.

|kind|irreducible|check_index|delta|witness_gcd|
|---|---:|---:|---|---|
|0: PASS|1|D|0|1|
|1: GCD rejection|0|first failing checkpoint i|exact C_i|exact monic gcd(P,C_i), not1|
|2: final Frobenius rejection|0|D|exact nonzero C_D|canonical1; earlier checkpoints passed|

Kind3 is never emitted. `witness_gcd` has D+1 bits: when delta=0 its correct
value is the entire P. It is **not promised to be a proper factor**. On kind2,
the canonical1 field is not a claim about gcd(P,C_D). The kind/index/delta
tuple identifies an independently checkable failure of the stated criterion.
Irreducible does not mean primitive, and this is not a factorization service,
cryptographic validation standard or side-channel-hardened implementation.

## Ownership and handshake

One rising-edge clock, synchronous active-high reset, ordinary ready/valid,
no CE, frames, external memory or CDC. One acceptance latches all polynomial
bits and the tag. A source holds both fields and valid while stalled. Only an
IDLE edge with `s_valid && s_ready` accepts a command. Computing and pending
outputs block further acceptance. Sources may offer the next command early.

All valid output fields remain stable under backpressure. Output retirement
returns the core to IDLE; a new command can first be accepted on the following
edge, never on that same retirement edge. Invalid payload is unspecified.
Reset cancels the owner and pending output; both ready and valid are masked
while reset is high. A reset-high offer is not accepted. Control is reset,
but polynomial, arithmetic and output payload registers are not reset.

## Architecture and finite timing

One D-step shift/XOR modular-square engine reuses its registers for each
Frobenius round. A separate two-remainder Euclidean engine uses a leading-degree
comparison, swap or one shifted-XOR cancellation per clock. It does not compute
Bezout coefficients or an unused inverse. There is no RAM, runtime primality
engine, lookup of answers or external dependency. Checkpoint bits are elaboration
constants. See [COST.md](COST.md) for actual declarations, valid widths and proof.

From acceptance edge E, first valid appears after exactly the certificate's
number of compute clocks. With omega(D) distinct prime divisors of D:

```text
C <= D*(D+2) + omega(D)*(3*D+2)
```

Default16: C<=338. Degree64: C<=4418. A conservative bound over the complete
legal degree envelope is4806. Early GCD rejection can finish sooner. First
retirement is E+C+1 with an always-ready consumer, and continuous-source II
is C+2 because the retirement edge does not accept the next owner. Arbitrary
consumer stalls add unbounded retirement/acceptance delay, not compute work.

Invalid parameters instantiate the deliberately missing named module
`gf2_polynomial_irreducibility_invalid_parameters__see_README`.

## Frozen finite verification

The independent primary oracle builds the Frobenius matrix Q on the basis
1,x,...,x^(D-1). Its columns are x^(2*j) mod P, **not** x^(2^j). Irreducibility
requires squarefreeness gcd(P,P')=1 and nullity(Q-I)=1. The separate derivative
test prevents a power of a single irreducible from being falsely accepted.
This is not Rabin's repeated-residue classification. A second implementation
forms complete unreduced squares and scans full polynomial remainders, with
whole Euclidean divisions. All candidate monic factors are enumerated as a
third check at D<=8. No external math library is imported or executed.

Eight fixed (D,TAG_W) profiles are (1,1),(2,2),(3,3),(8,8),(16,8),(30,3),
(63,32),(64,32). The first four exhaust every input pattern:270 commands.
The larger profiles each have16 structural and32 fixed-seed commands:192.
The explicit preseal revision replaces one degree64 structural coefficient
with0x1b, independently classified before any HDL. Degree64 fresh recovery
uses that independently verified PASS polynomial, with a different tag.
Thus462 immutable main commands run in continuous and output-stalled modes.
There are155 frozen reset probes, with per-profile counts7,20,20,21,21,23,22,21.
Every retired witness and exact first-valid time is compared, with full raw
REC records retained. Main square/cancellation/swap/termination counters are
also independently summed from whole-division certificates.

Reset owner selection uses the first match in a fixed input pool before HDL:
the main cases plus256 fixed-seed candidates for wider profiles, plus one
explicit algebraic whole-P owner at each of degrees63 and64. Seven distinct
degree9 and eight distinct degree8 irreducible factors, respectively, make
those products squarefree divisors of the checkpoint Frobenius polynomial.
The factor sets come from complete fixed512/256-element monic domains, not
an adaptive candidate search. CONSTRUCTION_CERTIFICATES retains their two
independent classifications. This auxiliary
analysis only selects actual registered-state predicates; it is not the numeric
oracle. Every selected probe seals full u/v or round/countdown predicates,
the complete canceled owner and a complete independently certified fresh command.
The plan declares aliases, exhaustive-domain impossibilities and any missing
fixed-pool coverage; it never changes cases in response to a DUT result.
PRESEAL_RECORD preserves the original plan/fixture identities. The complete
first source/fixture generation and its pure preparation receipt were archived
before the specifically root-authorized revision; neither generation ran HDL.
One probe presents an actual different next offer during a held output before
reset. Three reset-high offers per probe must not transfer. Fresh commands
then complete with the same exact arithmetic, witness, latency and stall checks.

`TEST_PLAN.json` contains every child argv/cwd and every immutable fixture hash.
There are9 legal compiles (including the default wrapper),4 named parameter
rejections and24 simulations:37 children. Each child has a hard20-second limit.
The first error stops the matrix and leaves all later children NOT_RUN. A
timeout is terminal. The source seal is reviewed by root before the sole
authorized `--execute --approved-seal SHA` invocation. No automatic retry,
timeout increase, adaptive split or golden/tolerance repair is implemented.
Any failure archives all sealed sources, seal, original receipt and raw artifacts.

Preparation and seal commands, before root approves any HDL:

```text
python -B prepare.py
python -B run_tests.py --seal
```

`python -B run_tests.py --check` only reads hashes and successful receipt
structure; it never imports the oracle or starts HDL. The minimal wrapper is
`example/gf2_irred16.sv`; both source lists are relative to this package root.
