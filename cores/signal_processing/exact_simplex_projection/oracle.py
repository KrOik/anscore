"""Independent exact sorted-prefix oracle; never imports RTL/control-walk code.

No function in this file was executed while authoring the package.
"""
from fractions import Fraction


def certificate(values, mass, tag):
    """Sort descending, select the largest strict admissible prefix (Condat Alg.1)."""
    values = list(values)
    n = len(values)
    assert n >= 1 and mass >= 0
    if mass == 0:
        return dict(values=values, mass=mass, tag=tag, denominator=1,
                    numerators=[0]*n, threshold_numerator=0,
                    certificate=dict(nonnegative=True, exact_mass=True,
                                     kkt=True, zero_mass_unique_feasible=True))
    ordered = sorted(values, reverse=True)
    prefix = 0
    selected = None
    for count, value in enumerate(ordered, 1):
        prefix += value
        if count*value > prefix-mass:
            selected = count, prefix-mass
    assert selected is not None
    count, threshold = selected
    nums = [max(count*value-threshold, 0) for value in values]
    positive = sum(value > 0 for value in nums)
    assert positive == count
    assert sum(nums) == mass*count
    # Fraction independently checks the exact primal/dual KKT certificate.
    tau = Fraction(threshold, count)
    projected = [Fraction(value, count) for value in nums]
    assert all(value >= 0 for value in projected)
    assert sum(projected) == mass
    for value, result in zip(values, projected, strict=True):
        if result > 0:
            assert value-result == tau
        else:
            assert Fraction(value) <= tau
    return dict(values=values, mass=mass, tag=tag, denominator=count,
                numerators=nums, threshold_numerator=threshold,
                certificate=dict(nonnegative=True, exact_mass=True, kkt=True,
                                 positive_count=positive,
                                 sum_numerators=sum(nums), mass_times_k=mass*count))


def small_support_crosscheck(result):
    """For N<=3, independently enumerate every nonempty positive support.

    This enumerates mathematical subsets, not deletion rounds or sorted prefixes.
    Strict positivity excludes threshold ties from the denominator.
    """
    x, mass = result['values'], result['mass']
    assert len(x) <= 3
    if mass == 0:
        assert result['denominator'] == 1 and not any(result['numerators'])
        return
    witnesses = []
    for mask in range(1, 1 << len(x)):
        support = [i for i in range(len(x)) if mask & (1 << i)]
        k = len(support)
        t = sum(x[i] for i in support)-mass
        if all(k*x[i] > t if i in support else k*x[i] <= t for i in range(len(x))):
            witnesses.append((k, [max(k*v-t, 0) for v in x]))
    assert witnesses == [(result['denominator'], result['numerators'])]
