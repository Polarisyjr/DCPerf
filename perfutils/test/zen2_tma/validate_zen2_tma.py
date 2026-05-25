#!/usr/bin/env python3
# Copyright (c) Meta Platforms, Inc. and affiliates.
#
# This source code is licensed under the MIT license found in the
# LICENSE file in the root directory of this source tree.
#
# Regression test for the Zen2 (Family 17h) top-down L1 decomposition in
# perfutils/generate_amd_perf_report.py. For each microbenchmark it measures the
# real TOPDOWN_L1_GROUP counters, feeds them through the *actual* report
# functions, and asserts the invariants the methodology must hold:
#   * the four buckets sum to ~100% (weighted slot-deficit closure), and
#   * Bad Speculation is non-negative (depends on dispatched=0xAB, not 0xAA).
#
# REQUIRES real Zen2 hardware (the event codes are Family 17h specific) and perf
# with access to raw core PMCs. As non-root, /proc/sys/kernel/perf_event_paranoid
# must allow per-process counting (the events are pinned to :u). This is a
# hardware test -- it is skipped (exit 77) on non-Zen2 / no-perf machines.
#
# Caveat: dispatched-ops uses raw 0xAB, which is undocumented in perf's json;
# its definition was confirmed empirically, not against the AMD Family 17h PPR.
import os
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
PERFUTILS = os.path.normpath(os.path.join(HERE, "..", ".."))
sys.path.insert(0, PERFUTILS)

SKIP = 77
W = 6  # Zen2 dispatch width

MODES = ["retire", "aluchain", "ucode", "membound", "badspec"]

# Same event codes as collect_amd_zen2_perf_counters.sh TOPDOWN_L1_GROUP, named
# to match the groups generate_amd_perf_report.py looks up. :u = user-only so the
# test runs without root (microbenchmarks are ~entirely user-space anyway).
GROUP = (
    "{cpu/event=0x76,umask=0,name=td_cycles/u,"
    "cpu/event=0xc1,umask=0,name=td_retired_ops/u,"
    "cpu/event=0xab,umask=0xff,name=td_dispatched_ops/u,"
    "cpu/event=0xa9,umask=0,name=td_op_queue_empty/u,"
    "cpu/event=0xae,umask=0xff,name=td_token_stall_part1/u,"
    "cpu/event=0xaf,umask=0xff,name=td_token_stall_part2/u}"
)
EVENTS = [
    "td_cycles",
    "td_retired_ops",
    "td_dispatched_ops",
    "td_op_queue_empty",
    "td_token_stall_part1",
    "td_token_stall_part2",
]


def is_zen2():
    try:
        info = open("/proc/cpuinfo").read()
    except OSError:
        return False
    return "AuthenticAMD" in info and "cpu family\t: 23" in info


def have_perf():
    return (
        subprocess.run(
            ["perf", "--version"], capture_output=True
        ).returncode
        == 0
    )


def build():
    src = os.path.join(HERE, "bench.c")
    out = os.path.join(HERE, "bench")
    subprocess.run(
        ["gcc", "-O2", "-fno-tree-vectorize", "-o", out, src], check=True
    )
    return out


def measure(binpath, mode):
    """Run one mode under perf and return {event_name: counter_value}."""
    out = subprocess.run(
        ["perf", "stat", "-x,", "-e", GROUP, binpath, mode],
        capture_output=True,
        text=True,
    ).stderr
    vals = {}
    for line in out.splitlines():
        f = line.split(",")
        if len(f) >= 3 and f[2] in EVENTS:
            try:
                vals[f[2]] = float(f[0])
            except ValueError:
                pass  # <not counted> -> missing, caught below
    return vals


def to_grouped_df(vals):
    """Build a 1-row-per-event frame in read_csv()'s schema, grouped by name."""
    import pandas as pd

    cols = [
        "timestamp", "socket", "numcpus", "counter_value", "counter_unit",
        "event_name", "counter_runtime", "mux", "optional_metric_value",
        "optional_metric_unit", "1", "2",
    ]
    rows = [
        [1.0, 0, 96, v, "", k, v, 100.0, "", "", "", ""] for k, v in vals.items()
    ]
    return pd.DataFrame(rows, columns=cols).groupby("event_name")


def main():
    if not is_zen2():
        print("SKIP: not an AMD Zen2 (Family 17h) machine")
        return SKIP
    if not have_perf():
        print("SKIP: perf not available")
        return SKIP

    import generate_amd_perf_report as g

    binpath = build()
    print(
        f"{'workload':<10} {'Retire%':>8} {'BadSpec%':>9} {'FE%':>7} "
        f"{'BE%':>7} {'SUM%':>8}  result"
    )
    print("-" * 62)

    failures = []
    for mode in MODES:
        vals = measure(binpath, mode)
        missing = [e for e in EVENTS if e not in vals]
        if missing:
            print(f"{mode:<10}  (events not counted: {missing})")
            failures.append((mode, f"missing events {missing}"))
            continue
        gdf = to_grouped_df(vals)
        R = g.zen2_retiring_pct(gdf)["series"].iloc[0]
        B = g.zen2_bad_speculation_pct(gdf)["series"].iloc[0]
        FE = g.zen2_frontend_bound_pct(gdf)["series"].iloc[0]
        BE = g.zen2_backend_bound_pct(gdf)["series"].iloc[0]
        s = R + B + FE + BE

        problems = []
        if abs(s - 100.0) > 0.5:
            problems.append(f"sum={s:.1f} (expect ~100)")
        if B < -0.5:
            problems.append(f"BadSpec={B:.1f} (negative)")
        verdict = "ok" if not problems else "FAIL: " + "; ".join(problems)
        if problems:
            failures.append((mode, "; ".join(problems)))
        print(
            f"{mode:<10} {R:8.1f} {B:9.1f} {FE:7.1f} {BE:7.1f} {s:8.1f}  {verdict}"
        )

    if failures:
        print(f"\n{len(failures)} failure(s):")
        for mode, why in failures:
            print(f"  {mode}: {why}")
        return 1
    print("\nall workloads: four buckets sum to ~100%, BadSpec >= 0")
    return 0


if __name__ == "__main__":
    sys.exit(main())
