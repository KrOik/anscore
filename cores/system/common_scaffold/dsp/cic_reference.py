"""Independent integer CIC checkpoints per logical input, without RTL timing assumptions.

Each stimulus row is offered until the real input handshake (invalid/reset rows
last one cycle). Matching golden rows give emit/value/last for that logical
sample. The testbench queues checkpoints only on actual handshakes and discards
in-flight checkpoints on reset. No guessed DUT ready or pipeline latency.
"""
import random


def fixtures(folder, rate, stages, width):
    rng = random.Random(0xC1C + rate * 19 + stages)
    integrators = [0] * stages
    delays = [0] * stages
    count = 0
    stimulus, expected = [], []
    accepted = checkpoints = resets = 0

    def wrap(value):
        return ((value + (1 << (width - 1))) % (1 << width)) - (1 << (width - 1))

    for cycle in range(3500):
        reset = cycle not in (0, 1, 307, 308, 1401)
        ce = int(rng.randrange(5) != 0) if cycle < 3400 else 1
        ready = int(rng.randrange(4) != 0) if cycle < 3400 else 1
        valid = int(cycle < 3200 and rng.randrange(4) != 0)
        data = [127, -128, 0, 1, -1, rng.randrange(-128, 128)][rng.randrange(6)]
        last = int(rng.randrange(19) == 0)
        # Directed short packets and RATE crossings, including signed extremes.
        if 2 <= cycle < 2 + 4 * (rate + 1):
            valid = 1
            data = [127, -128, 1, -1][cycle % 4]
            last = int((cycle - 2) % (rate + 1) == rate)
        stimulus.append(f"{ce} {valid} {data} {last} {ready} {int(reset)}\n")
        emit, result = 0, 0
        if not reset:
            integrators, delays = [0] * stages, [0] * stages
            count = 0
            resets += 1
        elif valid:
            accepted += 1
            value = data
            for index in range(stages):
                integrators[index] = wrap(integrators[index] + value)
                value = integrators[index]
            count += 1
            if count == rate or last:
                for index in range(stages):
                    old = value
                    value = wrap(value - delays[index])
                    delays[index] = old
                emit, result = 1, value
                count = 0
                checkpoints += 1
            if last:
                integrators, delays = [0] * stages, [0] * stages
                count = 0
        expected.append(f"{emit} {result} {last}\n")
    input_path, expected_path = folder / "input.txt", folder / "expected.txt"
    input_path.write_text("".join(stimulus), encoding="ascii")
    expected_path.write_text("".join(expected), encoding="ascii")
    return input_path, expected_path, {"accepted": accepted, "reference_checkpoints": checkpoints,
                                      "reset_records": resets, "stimulus_records": len(stimulus)}
