# Product integration checks

Each generated package has exactly one functional RTL module and no vendor
primitive dependency. Include its manifest and SPEC with any downstream copy.

1. Select the exact core by its semantic contract, not just the family name.
2. Tie CE high for an ordinary single-clock ready/valid pipeline, or share CE
   consistently with both endpoints. Add appropriate CDC outside these cores.
3. Observe signedness, bit widths, reserved/ignored fields, restart commands,
   fault behavior, and pending-response cancellation on reset.
4. Re-run the independent model/unit test, then constrain and synthesize the
   actual integrated topology. Board groups measure test harness overhead;
   isolated core metrics measure a reusable core without that harness.
5. Use measured routed timing at the product frequency. Seven CE=1/16 board
   groups alone do not qualify an arbitrary full-speed integrated design.
6. Verify actual I/O protocol behavior in the application; packet micro-steps
   and checksum updates are not complete protocol controllers.
7. Register the exact RTL, model, manifest, constraints and bitstream hashes
   against the integration result. Preserve previous artifacts.
8. Resolve authorship/ownership/license and any application-specific standards
   or certification requirements with the owning project. No patentability or
   security claim is implied by the term IP core.

No core processes NTT coefficient memories or replaces the established lattice
engine. The series has no secret-share, masking, TRNG or constant-energy claim.
