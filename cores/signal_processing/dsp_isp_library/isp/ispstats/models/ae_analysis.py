"""ISP-12 OFFLINE host-side AE/AWB analysis model.

**Scope**: this is a pure host-side analysis function consuming a statistics
record set produced by ``models/reference.py`` (or by the RTL readout port,
via ``unpack_record``).  It is **not** a control loop: it makes no camera
register writes, has no temporal state, and its suggestions are not fed back
into the statistics core.  goal.md ISP-12 requires exposure/gain *suggestion*
plus offline scene tests only; a real closed-loop AE claims camera-interface
evidence that this delivery deliberately does not provide.

Algorithm (deliberately simple, fully documented):

1. Frame brightness ``mean_lum``: total luma sum over all zones divided by
   total pixels.  For RGB the per-zone luma sum is
   ``(sum0 + 2*sum1 + sum2) / 4`` (same green-weighted luma as the
   gradient path); for gray it is ``sum0``.
2. ``scale = target_lum / mean_lum`` is the total illumination correction
   that would bring the measured mean to ``target_lum = target_frac * MPX``.
3. The suggestion splits ``scale`` into an exposure multiplier (clamped to
   ``exposure_bounds``) and a residual gain multiplier (clamped to
   ``gain_bounds``).  When both clamps engage the frame cannot be fully
   corrected; ``residual`` reports the leftover factor.
4. ``overexposed_frac`` (share of overexposed pixels) is reported for the
   host's own highlight-protection policy; when it exceeds
   ``oe_warn_frac`` the suggestion is forced to not increase exposure
   beyond 1.0 regardless of the mean (blown highlights are unrecoverable,
   mean matching would sacrifice them further).

All arithmetic is exact ``fractions.Fraction`` where ratios matter; returned
multipliers are floats for host convenience.
"""
from fractions import Fraction

# Sensible defaults for an 18%-grey-ish midtone target; hosts may override.
DEFAULT_TARGET_FRAC = Fraction(45, 100)          # 0.45 * MPX
DEFAULT_EXPOSURE_BOUNDS = (Fraction(1, 4), Fraction(4, 1))   # 0.25x .. 4x
DEFAULT_GAIN_BOUNDS = (Fraction(1, 1), Fraction(8, 1))       # 1x .. 8x
DEFAULT_OE_WARN_FRAC = Fraction(1, 20)           # >5% clipped: protect highs


def _clamp(v, lo, hi):
    return lo if v < lo else (hi if v > hi else v)


def frame_brightness(records, ch):
    """Exact (lum_sum, pixel_total, oe_total) over a record set."""
    lum = 0
    px = 0
    oe = 0
    for r in records:
        px += r['count']
        oe += r['oe']
        lum += (r['sum0'] + 2 * r['sum1'] + r['sum2']) if ch == 3 else r['sum0']
    # luma = (r + 2g + b)/4 per pixel, so divide the channel mix by 4
    if ch == 3:
        return Fraction(lum, 4), px, oe
    return Fraction(lum, 1), px, oe


def suggest_exposure_gain(records, bits, ch=3,
                          target_frac=DEFAULT_TARGET_FRAC,
                          exposure_bounds=DEFAULT_EXPOSURE_BOUNDS,
                          gain_bounds=DEFAULT_GAIN_BOUNDS,
                          oe_warn_frac=DEFAULT_OE_WARN_FRAC):
    """Consume a record list -> exposure/gain suggestion dict.

    ``records`` is a list of zone dicts as produced by
    ``reference.stats`` or ``reference.unpack_record``.  Returns::

        mean_lum        Fraction  measured mean luma (0..MPX)
        target_lum      Fraction  requested mean
        scale           Fraction  total correction needed (inf -> huge)
        exposure        float     suggested exposure multiplier
        gain            float     suggested analog/digital gain multiplier
        residual        float     uncorrected leftover factor after clamps
        overexposed_frac Fraction share of overexposed pixels
        highlight_limited bool    oe protection clamped the suggestion
        note            str       human-readable rationale
    """
    mpx = (1 << bits) - 1
    lum_sum, px, oe = frame_brightness(records, ch)
    if px <= 0:
        raise ValueError('empty record set')
    mean = lum_sum / px
    target = target_frac * mpx
    oe_frac = Fraction(oe, px)
    if mean == 0:
        scale = Fraction(1 << 62)      # black frame: maximum brightening
    else:
        scale = target / mean
    highlight_limited = False
    if oe_frac > oe_warn_frac and scale > 1:
        scale = Fraction(1)            # do not brighten a clipped scene
        highlight_limited = True
    exposure = _clamp(scale, *exposure_bounds)
    residual = scale / exposure
    gain = _clamp(residual, *gain_bounds)
    leftover = residual / gain
    if mean == 0:
        note = 'black frame: exposure+gain at maximum'
    elif highlight_limited:
        note = ('over %.1f%% pixels clipped; brightening suppressed'
                % (100 * float(oe_frac)))
    elif leftover != 1:
        note = 'correction clamped: residual %.3fx remains' % float(leftover)
    else:
        note = 'scale %.3fx fully covered by suggestion' % float(scale)
    return {
        'mean_lum': mean,
        'target_lum': target,
        'scale': scale,
        'exposure': float(exposure),
        'gain': float(gain),
        'residual': float(leftover),
        'overexposed_frac': oe_frac,
        'highlight_limited': highlight_limited,
        'note': note,
    }


def awb_channel_gains(records, bits=8, gray_world=True):
    """OFFLINE AWB aid: per-channel gain suggestion under the gray-world
    assumption.  Mean of each channel over the frame; suggested gain maps
    each channel mean to the green channel mean (common AWB reference).
    Returns {'r': gr, 'g': 1.0, 'b': gb} floats.  Gray mode is meaningless
    and raises.  Same not-a-control-loop scope as above."""
    s0 = s1 = s2 = n = 0
    for r in records:
        s0 += r['sum0']
        s1 += r['sum1']
        s2 += r['sum2']
        n += r['count']
    if n <= 0:
        raise ValueError('empty record set')
    mr, mg, mb = Fraction(s0, n), Fraction(s1, n), Fraction(s2, n)
    if mg == 0:
        raise ValueError('zero green mean: cannot form gray-world gains')
    return {'r': float(mg / mr) if mr else float('inf'),
            'g': 1.0,
            'b': float(mg / mb) if mb else float('inf')}


def focus_scores(records):
    """OFFLINE AF aid: per-record normalized focus energy = focus/count.
    Higher means stronger local gradients.  Returned as Fractions in zone
    push order."""
    return [Fraction(r['focus'], r['count']) for r in records]
