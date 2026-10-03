# Diagnostic only: N=1 RMS lane from amplitude

This is not a general statistics implementation and must not be promoted.
For N=1, rounded mean power is exactly amplitude squared, so floor RMS equals
amplitude. The isolated core removes all root arithmetic and sends the correct
amplitude to the same 16-bit RMS result field. Other configuration lengths are
rejected by this leaf. The existing chain shell does not propagate leaf errors
outside its own configuration legality check; therefore only the original N=1
host-vector JSON may be used with this diagnostic image. Do not run the default
multi-length physical case matrix.

The purpose is to test the physical result RAM/UART RMS bit lane independently
of the root arithmetic cone. Every output field and flag is still checked by
the unchanged independent oracle. The production statistics RTL is untouched.
Statistics latency is one; production DCv3 plus this diagnostic totals three.
