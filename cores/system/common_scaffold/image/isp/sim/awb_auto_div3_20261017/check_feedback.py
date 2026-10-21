#!/usr/bin/env python3
"""Transaction-level independent integer AWB oracle for captured edge events.

No divider recurrence, prefix adder, pipeline multiplier stages or fixed solver
completion schedule is reproduced. Mathematical results are queued from the
real accepted raw-pixel/stats transactions. Configuration is checked against
the specified latest-mailbox / accepted-gain-input-SOF commit contract.
"""
from __future__ import annotations

import collections
import csv
from pathlib import Path

NEUTRAL = (256, 256, 256, 0)


def gains_for(stats: tuple[int, ...], minimum: int, maximum: int) -> tuple[int, ...]:
    r, g, b, count, _lines, frame, overflow = stats
    error = int(count == 0) | (int(bool(overflow)) << 1) | (int(minimum > maximum) << 2)
    if error or r+g+b == 0:
        return 256, 256, 256, frame, error
    target = (r+g+b)//3
    gains = []
    for channel in (r, g, b):
        if channel == 0:
            error |= 8
            gains.append(maximum)
        else:
            gains.append(min(max((target*256)//channel, minimum), maximum))
    return *gains, frame, error


def pixel_for(pixel: int, gains: tuple[int, ...]) -> int:
    result = 0
    for shift, gain in zip((16, 8, 0), gains[:3]):
        channel = (pixel >> shift) & 255
        result = (result << 8) | min(255, (channel*gain+128)//256)
    return result


class FeedbackOracle:
    def __init__(self, width: int):
        self.width = width
        self.maximum = (1 << width)-1
        self.rows = 0
        self.epoch = -1
        self.was_reset = False
        self.cover = collections.Counter()
        self.phase_cover: dict[int, collections.Counter] = collections.defaultdict(collections.Counter)
        self.frame_ids: set[int] = set()
        self.applied_ids: set[int] = set()
        self.transitions: list[dict[str, object]] = []
        self.latencies: list[int] = []
        self.previous = None
        self.ce_clock = 0
        self.reset()

    def reset(self) -> None:
        if getattr(self, "pixels", None):
            self.cover["reset_discarded_gain_pixels"] += len(self.pixels)
        if getattr(self, "bypass", None):
            self.cover["reset_discarded_bypass_pixels"] += 1
        if getattr(self, "solver", None):
            self.cover["reset_cancelled_solver"] += len(self.solver)
        if getattr(self, "stats_pending", None):
            self.cover["reset_cancelled_stats"] += 1
        if getattr(self, "pending", False) or getattr(self, "latest", None):
            self.cover["reset_cancelled_gain_update"] += 1
        self.open = False
        self.sums = [0, 0, 0]
        self.count = self.lines = self.frame = self.overflow = self.protocol = 0
        self.bypass = None
        self.pixels = collections.deque()
        self.stats_pending = None
        self.solver = collections.deque()
        self.active = NEUTRAL
        self.latest = None
        self.latest_payload = NEUTRAL
        self.staged = NEUTRAL
        self.pending = False
        self.error = 0

    def require(self, condition: bool, message: str, row: dict[str, int]) -> None:
        if not condition:
            raise AssertionError(f"WIDTH={self.width} cycle={row['cycle']} phase={row['phase']} epoch={self.epoch}: {message}")

    def statistics(self) -> tuple[int, ...]:
        return *self.sums, self.count, self.lines, self.frame, self.overflow

    def publish(self, row: dict[str, int], tag: str) -> None:
        self.require(self.stats_pending is None, "statistics overwrite without free slot", row)
        self.stats_pending = self.statistics()
        self.cover[tag] += 1
        self.frame = (self.frame+1) & 0xFFFFFFFF

    def post_status(self, row: dict[str, int]) -> None:
        self.require((row["ar"], row["ag"], row["ab"], row["af"]) == self.active,
                     f"applied gains/frame differ got={tuple(row[k] for k in ('ar','ag','ab','af'))} expected={self.active}", row)
        self.require(row["error"] == self.error, f"sticky error differs got={row['error']:02x} expected={self.error:02x}", row)
        self.require(row["postpending"] == int(self.pending), "gain configuration pending differs", row)
        self.require(row["latestv"] == int(self.latest is not None), "latest-valid differs", row)
        self.require(tuple(row[k] for k in ("latestr", "latestg", "latestb", "latestframe")) == self.latest_payload,
                     "latest payload/frame differs", row)
        self.require(tuple(row[k] for k in ("stagedr", "stagedg", "stagedb", "stagedframe")) == self.staged,
                     "staged payload/frame differs", row)
        self.require(row["update"] == int(self.pending or self.latest is not None), "update_pending differs", row)

    def consume(self, row: dict[str, int]) -> None:
        self.rows += 1
        self.phase_cover[row["phase"]]["rows"] += 1
        if not row["rst"]:
            if not self.was_reset:
                self.epoch += 1
                self.cover["reset_epochs"] += 1
            self.reset()
            self.was_reset = True
            self.post_status(row)
            self.require(row["postmv"] == 0, "output survives async reset", row)
            if not row["ce"]:
                self.cover["async_reset_ce0_rows"] += 1
            self.previous = row
            return
        self.was_reset = False
        if row["seed"]:
            self.require(not self.open and self.stats_pending is None and not self.solver and
                         not self.pending and self.latest is None and not self.pixels and self.bypass is None,
                         "counter seed not quiescent", row)
            self.frame = row["seedvalue"]
            self.cover["explicit_frame_counter_seeds"] += 1

        self.require(row["statv"] == int(self.bypass is not None), "statistics RGB bypass valid differs", row)
        if self.bypass is not None:
            self.require(tuple(row[k] for k in ("statdata", "statsof", "stateol")) == self.bypass,
                         "statistics RGB bypass payload/SOF/EOL differs", row)
        self.require(row["statsv"] == int(self.stats_pending is not None), "stats publication valid differs", row)
        if self.stats_pending is not None:
            actual = tuple(row[k] for k in ("sumr", "sumg", "sumb", "count", "lines", "sframe", "overflow"))
            self.require(actual == self.stats_pending, f"raw statistics differ got={actual} expected={self.stats_pending}", row)
        self.require(row["protocol"] == self.protocol, "statistics protocol flag differs", row)
        stats_free = self.stats_pending is None or bool(row["statsr"])
        boundary_blocked = row["sv"] and row["ssof"] and self.open and not stats_free
        expected_ready = int(bool(row["ce"] and (self.bypass is None or row["statr"]) and not boundary_blocked))
        expected_flush_ready = int(bool(row["ce"] and self.open and not row["sv"] and stats_free))
        self.require(row["sready"] == expected_ready, "raw input readiness violates statistics slot/bypass contract", row)
        self.require(row["flushready"] == expected_flush_ready, "flush readiness differs", row)
        self.require(row["pending"] == int(self.pending), "pre-edge pending differs", row)
        self.require(row["cfgready"] == int(bool(row["ce"] and not self.pending)), "configuration readiness differs", row)
        apply_update = bool(self.latest is not None and row["ce"] and not self.pending)
        self.require(row["apply"] == int(apply_update), "latest-to-shadow dispatch differs", row)
        expected_gain_ready = int(bool(row["ce"] and (len(self.pixels) < 3 or row["mready"])))
        self.require(row["statr"] == expected_gain_ready, "three-slot gain pipeline readiness differs", row)

        # Check output whenever VALID, including all backpressured edges.
        if row["mv"]:
            self.require(bool(self.pixels), "output without accepted gain-input pixel", row)
            expected = self.pixels[0]
            self.require(tuple(row[k] for k in ("mdata", "msof", "meol")) == expected[:3],
                         f"output pixel/sideband differs got={tuple(row[k] for k in ('mdata','msof','meol'))} expected={expected}", row)
        if self.previous and self.previous["rst"]:
            # Previous blocked output must be exactly the current pre-edge output.
            old = self.previous
            if old["mv"] and (not old["ce"] or not old["mready"]):
                self.require(row["mv"] == 1 and tuple(row[k] for k in ("mdata", "msof", "meol")) ==
                             tuple(old[k] for k in ("mdata", "msof", "meol")), "output changed while stalled", row)
        if not row["ce"]:
            self.cover["ce_disabled_rows"] += 1
            if row["mv"]:
                self.cover["output_valid_ce_pause"] += 1
            self.require(tuple(row[k] for k in ("postmv", "postmdata", "postmsof", "postmeol")) ==
                         tuple(row[k] for k in ("mv", "mdata", "msof", "meol")), "output advanced while CE disabled", row)
            self.post_status(row)
            self.previous = row
            return

        self.ce_clock += 1
        if self.solver and self.previous and tuple(row[k] for k in ("minimum", "maximum")) != \
                tuple(self.previous[k] for k in ("minimum", "maximum")):
            self.cover["live_bounds_changed_while_solver_busy"] += 1
        if boundary_blocked:
            self.cover["statistics_boundary_backpressure"] += 1
        if row["mv"] and not row["mready"]:
            self.cover["output_backpressure_rows"] += 1
        if row["statv"] and row["statsof"] and not row["statr"] and self.pending:
            self.cover["pending_sof_blocked_by_output"] += 1
        if row["flush"] and not row["flushready"]:
            self.cover["ignored_flush_rows"] += 1
            if row["sv"]:
                self.cover["flush_deferred_by_source_valid"] += 1

        old_latest = self.latest
        old_staged = self.staged
        old_pending = self.pending
        commit = bool(old_pending and row["statv"] and row["statr"] and row["statsof"])
        if self.protocol:
            self.error |= 16
        if row["mv"] and row["mready"]:
            self.pixels.popleft()
            self.cover["output_pixels_checked"] += 1
            self.phase_cover[row["phase"]]["output_pixels"] += 1
        if row["statv"] and row["statr"]:
            raw, sof, eol = self.bypass
            self.bypass = None
            selected = old_staged if commit else self.active
            self.pixels.append((pixel_for(raw, selected), sof, eol, self.epoch, selected[3]))
            self.cover["gain_input_pixels"] += 1
            self.require(len(self.pixels) <= 3, "gain elastic capacity exceeded", row)
        if commit:
            self.active = old_staged
            self.pending = False
            self.applied_ids.add(old_staged[3])
            self.cover["sof_gain_commits"] += 1
            self.phase_cover[row["phase"]]["commits"] += 1
            self.transitions.append({"cycle": row["cycle"], "phase": row["phase"], "epoch": self.epoch,
                                     "event": "SOF_COMMIT", "gains": list(self.active[:3]), "source_frame": self.active[3]})
        if apply_update:
            self.staged = old_latest
            self.pending = True
            self.latest = None
            self.cover["gain_shadow_stages"] += 1
            if row["statv"] and row["statr"] and row["statsof"]:
                self.cover["shadow_stage_same_edge_as_sof_no_old_pending"] += 1

        if row["resultv"]:
            self.require(bool(self.solver), "solver returned an unrequested/duplicate result", row)
            expected, accepted_ce, _source_stats = self.solver.popleft()
            actual = tuple(row[k] for k in ("resultr", "resultg", "resultb", "rframe", "rerror"))
            self.require(actual == expected, f"solver integer result/frame differs got={actual} expected={expected}", row)
            latency = self.ce_clock-accepted_ce+1
            self.require(1 <= latency <= 801, "solver CE watchdog exceeded", row)
            self.latencies.append(latency)
            self.cover["solver_results_checked"] += 1
            self.error |= expected[4]
            self.frame_ids.add(expected[3])
            self.transitions.append({"cycle": row["cycle"], "phase": row["phase"], "epoch": self.epoch,
                                     "event": "RESULT", "gains": list(expected[:3]), "source_frame": expected[3], "error": expected[4]})
            if expected[4] & 0xF7:
                self.cover["invalid_results_rejected"] += 1
                if self.active[:3] != (256, 256, 256):
                    self.cover["invalid_result_preserved_non_neutral_active_gain"] += 1
                self.phase_cover[row["phase"]]["invalid_results"] += 1
                if expected[4] & 2:
                    self.cover["overflow_results_rejected"] += 1
                if expected[4] & 4:
                    self.cover["invalid_config_results_rejected"] += 1
            else:
                if old_latest is not None and not apply_update:
                    self.cover["latest_mailbox_overwrites"] += 1
                    self.phase_cover[row["phase"]]["mailbox_overwrites"] += 1
                if apply_update:
                    self.cover["same_edge_old_latest_staged_new_result_retained"] += 1
                if expected[4] & 8:
                    self.cover["zero_channel_diagnostic_results_accepted"] += 1
                self.latest = expected[:4]
                self.latest_payload = expected[:4]
        if row["statsv"] and row["statsr"]:
            self.require(self.stats_pending is not None, "solver accepted absent statistics", row)
            self.require(not self.solver, "multiple uncompleted solver transactions", row)
            captured = self.stats_pending
            self.stats_pending = None
            self.solver.append((gains_for(captured, row["minimum"], row["maximum"]), self.ce_clock, captured))
            self.cover["stats_handshakes"] += 1
        if row["flush"] and row["flushready"]:
            self.publish(row, "flush_publications")
            self.open = False
        if row["sv"] and row["sready"]:
            raw = row["sdata"]
            self.require(self.bypass is None, "raw bypass overrun", row)
            self.bypass = (raw, row["ssof"], row["seol"])
            self.cover["raw_pixels_accepted"] += 1
            if row["ssof"]:
                if self.open:
                    self.publish(row, "sof_publications")
                self.open = True
                self.sums = [(raw >> shift) & 255 for shift in (16, 8, 0)]
                self.count, self.lines, self.overflow = 1, row["seol"], 0
            elif self.open:
                components = [(raw >> shift) & 255 for shift in (16, 8, 0)]
                unbounded = [a+b for a, b in zip(self.sums, components)]
                self.overflow |= int(any(value > self.maximum for value in unbounded) or self.count == 0xFFFFFFFF or
                                     (row["seol"] and self.lines == 0xFFFFFFFF))
                self.sums = [min(self.maximum, value) for value in unbounded]
                self.count = min(0xFFFFFFFF, self.count+1)
                self.lines = min(0xFFFFFFFF, self.lines+row["seol"])
            else:
                self.protocol = 1
                self.cover["stray_non_sof_pixels"] += 1
        self.post_status(row)
        self.previous = row

    def finish(self) -> dict[str, object]:
        if self.bypass or self.pixels or self.stats_pending or self.solver:
            raise AssertionError("test ended with unchecked pixel/statistics/solver transactions")
        mandatory = ("raw_pixels_accepted", "output_pixels_checked", "sof_publications", "flush_publications",
                     "statistics_boundary_backpressure", "output_backpressure_rows", "ce_disabled_rows",
                     "output_valid_ce_pause", "async_reset_ce0_rows", "sof_gain_commits",
                     "latest_mailbox_overwrites", "pending_sof_blocked_by_output",
                     "invalid_config_results_rejected", "zero_channel_diagnostic_results_accepted",
                     "invalid_result_preserved_non_neutral_active_gain", "live_bounds_changed_while_solver_busy",
                     "same_edge_old_latest_staged_new_result_retained",
                     "reset_cancelled_solver", "reset_discarded_gain_pixels", "reset_cancelled_gain_update",
                     "stray_non_sof_pixels", "flush_deferred_by_source_valid", "explicit_frame_counter_seeds")
        missing = [key for key in mandatory if self.cover[key] == 0]
        if self.width == 8 and not self.cover["overflow_results_rejected"]:
            missing.append("overflow_results_rejected_at_width8")
        if missing:
            raise AssertionError(f"required coverage absent WIDTH={self.width}: {missing}")
        if not {0xFFFF, 0x10000, 0x7FFFFFFF, 0x80000000, 0xFFFFFFFF, 0, 1}.issubset(self.frame_ids):
            raise AssertionError("full-width solver frame id/carry/wrap coverage absent")
        if not {0xFFFF, 0x10000, 0x7FFFFFFF, 0x80000000, 0xFFFFFFFF, 0}.issubset(self.applied_ids):
            raise AssertionError("full-width applied source-frame association absent")
        return {"status": "PASS", "sum_width": self.width, "rows": self.rows,
                "coverage": dict(self.cover), "phase_coverage": {str(k): dict(v) for k, v in self.phase_cover.items()},
                "frame_ids_checked": [f"{frame:08X}" for frame in sorted(self.frame_ids)],
                "applied_source_frames_checked": [f"{frame:08X}" for frame in sorted(self.applied_ids)],
                "result_latency_ce_observation": {"minimum": min(self.latencies), "maximum": max(self.latencies),
                    "definition": "inclusive CE edge count from stats acceptance through result-valid observed before its consumption edge"},
                "transitions": self.transitions,
                "final_pending_gain_update_is_allowed_without_another_sof": self.pending or self.latest is not None}


def check_trace(path: Path, width: int) -> dict[str, object]:
    oracle = FeedbackOracle(width)
    with path.open(newline="", encoding="ascii") as stream:
        for raw in csv.DictReader(stream):
            if None in raw:
                raise AssertionError("malformed trace fields")
            if any(value is None or any(char in value.lower() for char in "xz") for value in raw.values()):
                raise AssertionError(f"unknown/truncated trace row: {raw}")
            oracle.consume({key: int(value, 16) for key, value in raw.items()})
    return oracle.finish()
