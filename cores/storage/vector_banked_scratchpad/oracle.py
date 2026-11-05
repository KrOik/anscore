"""Original scalar reference. Not executed before a root-approved prepare stage.

The reference uses a flat Python word dictionary and increasing input lane
indices. It does not call RTL, model bank RAM response slots, or reproduce the
ISSUE/COLLECT state machine. Bank counts describe only the public round metric.
"""


class WordModel:
    def __init__(self, profile):
        self.profile = profile
        self.memory = {}

    def apply(self, vector):
        p = self.profile
        lanes, capacity = p["lanes"], p["banks"] * p["words"]
        data_mask = (1 << p["data_w"]) - 1
        mask = vector["mask"]
        invalid = sum(1 << i for i in range(lanes)
                      if mask & (1 << i) and not 0 <= vector["addresses"][i] < capacity)
        answer = {"status": 1 if invalid else 0, "mask": mask,
                  "error_mask": invalid, "data": [0] * lanes,
                  "known_mask": (1 << lanes) - 1, "tag": vector["tag"],
                  "accesses": 0, "rounds": 0}
        if invalid:
            return answer
        bank_loads = [0] * p["banks"]
        for lane in range(lanes):
            if not mask & (1 << lane):
                continue
            address = vector["addresses"][lane]
            answer["accesses"] += 1
            bank_loads[address % p["banks"]] += 1
            if vector["write"] & (1 << lane):
                self.memory[address] = vector["data"][lane] & data_mask
            elif address in self.memory:
                answer["data"][lane] = self.memory[address]
            else:
                # The contract deliberately leaves an unwritten RAM word
                # unspecified. Status/count/tag/held stability are still checked.
                answer["known_mask"] &= ~(1 << lane)
        answer["rounds"] = max(bank_loads)
        return answer

    def cancel(self, vector, kind):
        if kind == 1:  # asynchronous cancellation before preflight can run
            return
        if kind == 2:
            # This directed raw vector writes address zero on EVERY lane.
            # Reset follows exactly the first observed physical request, so
            # exactly lane zero's store has committed. No bank-FSM model is used.
            assert vector["mask"] == (1 << self.profile["lanes"]) - 1
            assert vector["write"] == vector["mask"]
            assert set(vector["addresses"]) == {0}
            self.memory[0] = vector["data"][0]
            return
        raise ValueError("unsupported cancellation kind")
