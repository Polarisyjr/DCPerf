#!/usr/bin/env python3
"""Plot DCPerf profiling results collected per PROFILING.md.

Benchmark-agnostic: reads any DCPerf ``benchmark_metrics_*`` directory (Feedsim,
TaoBench, Mediawiki, DjangoBench, VideoTranscodeBench, ...) and renders the
common profiling figures described in PROFILING.md:

  1. top-down breakdown + IPC over time (PMU)
  2. MPKI panels: cache / TLB / branch  (PMU)
  3. CPU utilization + context switches per kilo-instruction
  4. system calls per kilo-instruction, by category (eBPF)

No pandas dependency -- stdlib csv + numpy + matplotlib only.

Usage::

    ./plot_profile.py [METRICS_DIR] [-o OUTDIR]

If METRICS_DIR is omitted the newest ``benchmark_metrics_*`` directory holding
profiling data is used. Figures are written as PNGs into OUTDIR
(default: ``<METRICS_DIR>/plots``). Missing inputs are skipped with a warning
rather than aborting the whole run.
"""
from __future__ import annotations

import argparse
import csv
import glob
import json
import os
import sys
from datetime import datetime

import matplotlib

matplotlib.use("Agg")
import matplotlib.pyplot as plt
import numpy as np

HERE = os.path.dirname(os.path.abspath(__file__))


# --------------------------------------------------------------------------- #
# discovery / loading helpers
# --------------------------------------------------------------------------- #
# files that mark a dir as holding profiling data we can plot
PROFILE_MARKERS = ("amd-zen2-perf-collector-timeseries.csv", "perf-stat.csv",
                   "topdown-intel.sys.csv", "syscall-ebpf.derived.csv",
                   "ctxsw.derived.csv")


def find_metrics_dir(explicit: str | None) -> str:
    if explicit:
        if not os.path.isdir(explicit):
            sys.exit(f"error: {explicit} is not a directory")
        return os.path.realpath(explicit)
    cands = []
    for d in glob.glob(os.path.join(HERE, "benchmark_metrics_*")):
        d = os.path.realpath(d)
        if any(os.path.isfile(os.path.join(d, m)) for m in PROFILE_MARKERS):
            cands.append(d)
    if not cands:
        sys.exit("error: no benchmark_metrics_* dir with profiling data found; "
                 "pass one explicitly")
    cands = sorted(set(cands), key=os.path.getmtime)
    return cands[-1]


def ensure_writable_dir(path: str):
    """Create ``path`` and make sure we can write to it.

    DCPerf's ``benchmark_metrics_*`` dirs are usually root-owned, so a plain
    mkdir fails. Fall back to sudo (mkdir + chown to the current user) so the
    figures still land next to the run that produced them.
    """
    try:
        os.makedirs(path, exist_ok=True)
        if os.access(path, os.W_OK):
            return
    except PermissionError:
        pass
    import subprocess
    uid, gid = os.getuid(), os.getgid()
    try:
        subprocess.run(["sudo", "-n", "mkdir", "-p", path], check=True)
        subprocess.run(["sudo", "-n", "chown", f"{uid}:{gid}", path], check=True)
        print(f"note: created {path} via sudo (metrics dir was root-owned)")
    except (subprocess.CalledProcessError, FileNotFoundError):
        sys.exit(f"error: cannot write to {path}; pass a writable -o/--outdir")


def read_csv(path: str) -> list[dict]:
    if not os.path.isfile(path):
        return []
    with open(path, newline="") as f:
        return list(csv.DictReader(f))


def col(rows: list[dict], name: str) -> np.ndarray:
    """Pull a numeric column, coercing blanks/garbage to NaN."""
    out = []
    for r in rows:
        v = r.get(name, "")
        try:
            out.append(float(v))
        except (TypeError, ValueError):
            out.append(np.nan)
    return np.asarray(out, dtype=float)


def clock_to_elapsed(rows: list[dict], key: str = "timestamp") -> np.ndarray:
    """Convert 'HH:MM:SS PM' stamps into seconds elapsed from the first row."""
    secs = []
    base = None
    for r in rows:
        t = (r.get(key) or "").strip()
        dt = None
        for fmt in ("%I:%M:%S %p", "%H:%M:%S"):
            try:
                dt = datetime.strptime(t, fmt)
                break
            except ValueError:
                continue
        if dt is None:
            secs.append(np.nan)
            continue
        if base is None:
            base = dt
        d = (dt - base).total_seconds()
        if d < 0:  # crossed midnight
            d += 24 * 3600
        secs.append(d)
    return np.asarray(secs, dtype=float)


def group_by_timestamp(rows: list[dict], tcol: str, cols: list[str]):
    """Average rows that share a Timestamp_Secs value (collector emits one row
    per core-group); returns (sorted_times, {col: mean_array})."""
    buckets: dict[float, list[dict]] = {}
    for r in rows:
        try:
            t = round(float(r[tcol]), 3)
        except (KeyError, TypeError, ValueError):
            continue
        buckets.setdefault(t, []).append(r)
    times = sorted(buckets)
    out = {c: [] for c in cols}
    for t in times:
        grp = buckets[t]
        for c in cols:
            vals = [float(g[c]) for g in grp
                    if g.get(c) not in (None, "") and _isnum(g[c])]
            out[c].append(np.mean(vals) if vals else np.nan)
    return np.asarray(times), {c: np.asarray(v, float) for c, v in out.items()}


def _isnum(v) -> bool:
    try:
        float(v)
        return True
    except (TypeError, ValueError):
        return False


def load_bench_name(metrics_dir: str) -> str:
    """Best-effort human-readable benchmark name for figure titles."""
    for p in glob.glob(os.path.join(metrics_dir, "*metrics_*_iter_*.json")):
        try:
            d = json.load(open(p))
            name = d.get("benchmark_name")
            if name:
                return name
        except (json.JSONDecodeError, OSError):
            pass
    # fall back to the run-id suffix of the dir name
    return os.path.basename(metrics_dir.rstrip("/"))


# --------------------------------------------------------------------------- #
# figures
# --------------------------------------------------------------------------- #
def fig_topdown(times, data, out: str, bench: str):
    keys = ["Retiring %", "Bad Speculation %", "Frontend Bound %", "Backend Bound %"]
    if any(np.all(np.isnan(data.get(k, np.array([np.nan])))) for k in keys):
        print("  skip topdown: missing columns")
        return
    colors = {"Retiring %": "#55a868", "Bad Speculation %": "#c44e52",
              "Frontend Bound %": "#dd8452", "Backend Bound %": "#4c72b0"}
    fig, ax = plt.subplots(figsize=(10, 5.5))
    stacks = [np.nan_to_num(data[k]) for k in keys]
    ax.stackplot(times, *stacks, labels=keys,
                 colors=[colors[k] for k in keys], alpha=0.85)
    ax.set_xlabel("Elapsed time (s)")
    ax.set_ylabel("Top-down breakdown (%)")
    ax.set_ylim(0, 100)
    ax.set_xlim(times.min(), times.max())
    ax.set_title(f"{bench}: CPU top-down breakdown + IPC over time")

    ax2 = ax.twinx()
    ax2.plot(times, data["Avg. IPC"], color="black", lw=1.6, label="IPC")
    ax2.set_ylabel("IPC")
    ax2.set_ylim(0, max(1.0, np.nanmax(data["Avg. IPC"]) * 1.2))

    h1, l1 = ax.get_legend_handles_labels()
    h2, l2 = ax2.get_legend_handles_labels()
    ax.legend(h1 + h2, l1 + l2, fontsize=8, loc="upper right", ncol=3)
    _save(fig, out, "fig1_topdown_ipc.png")


def fig_mpki(times, data, out: str, bench: str):
    groups = [
        ("Cache MPKI", [
            ("L1 DCache MPKI (w/ prefetches)", "L1-D"),
            ("L1 ICache MPKI (w/ prefetches)", "L1-I"),
            ("L2 Code MPKI", "L2-code"),
            ("L2 Data MPKI", "L2-data"),
        ]),
        ("TLB MPKI", [
            ("iTLB MPKI", "iTLB"),
            ("dTLB MPKI", "dTLB"),
            ("L2 iTLB MPKI", "L2-iTLB"),
            ("L2 dTLB MPKI", "L2-dTLB"),
        ]),
        ("Branch prediction", [
            ("Branch Mispred MPKI", "mispred MPKI"),
            ("BTB Correction MPKI", "BTB corr MPKI"),
        ]),
    ]
    fig, axes = plt.subplots(3, 1, figsize=(10, 11), sharex=True)
    any_plotted = False
    for ax, (title, series) in zip(axes, groups):
        for cname, label in series:
            y = data.get(cname)
            if y is None or np.all(np.isnan(y)):
                continue
            ax.plot(times, y, lw=1.4, label=label)
            any_plotted = True
        ax.set_ylabel("MPKI")
        ax.set_title(title)
        ax.grid(True, alpha=0.3)
        ax.legend(fontsize=8, ncol=2)
        ax.set_xlim(times.min(), times.max())
    axes[-1].set_xlabel("Elapsed time (s)")
    if not any_plotted:
        plt.close(fig)
        print("  skip mpki: no columns")
        return
    fig.suptitle(f"{bench}: cache / TLB / branch MPKIs over time", y=0.995)
    _save(fig, out, "fig2_mpki.png")


def fig_cpu_ctxsw(times, data, metrics_dir: str, out: str, bench: str):
    fig, ax = plt.subplots(figsize=(10, 5.5))
    plotted = False
    if "CPU Utilization %" in data and not np.all(np.isnan(data["CPU Utilization %"])):
        ax.plot(times, data["CPU Utilization %"], color="#4c72b0", lw=1.6,
                label="CPU utilization %")
        plotted = True
    ax.set_xlabel("Elapsed time (s)")
    ax.set_ylabel("CPU utilization (%)", color="#4c72b0")
    ax.set_ylim(0, 100)
    ax.grid(True, alpha=0.3)

    ctx = read_csv(os.path.join(metrics_dir, "ctxsw.derived.csv"))
    if ctx:
        t = clock_to_elapsed(ctx)
        y = col(ctx, "ctxsw_per_kI")
        ax2 = ax.twinx()
        ax2.plot(t, y, color="#c44e52", lw=1.4, label="ctxsw / kilo-instr")
        ax2.set_ylabel("context switches per kI", color="#c44e52")
        h1, l1 = ax.get_legend_handles_labels()
        h2, l2 = ax2.get_legend_handles_labels()
        ax.legend(h1 + h2, l1 + l2, fontsize=8, loc="upper right")
        plotted = True
    else:
        ax.legend(fontsize=8)
    if not plotted:
        plt.close(fig)
        print("  skip cpu/ctxsw: no data")
        return
    ax.set_title(f"{bench}: CPU utilization and context switches per kI")
    _save(fig, out, "fig3_cpu_ctxsw.png")


def fig_syscalls(metrics_dir: str, out: str, bench: str):
    rows = read_csv(os.path.join(metrics_dir, "syscall-ebpf.derived.csv"))
    if not rows:
        print("  skip syscalls: no syscall-ebpf.derived.csv")
        return
    t = clock_to_elapsed(rows)
    cats = [("fs_per_kI", "filesystem", "#4c72b0"),
            ("mm_per_kI", "memory mgmt", "#dd8452"),
            ("thread_per_kI", "thread mgmt", "#55a868"),
            ("net_per_kI", "networking", "#c44e52")]
    stacks, labels, colors = [], [], []
    for cname, label, color in cats:
        y = col(rows, cname)
        if np.all(np.isnan(y)):
            continue
        stacks.append(np.nan_to_num(y))
        labels.append(label)
        colors.append(color)
    if not stacks:
        print("  skip syscalls: no per-kI columns")
        return
    fig, ax = plt.subplots(figsize=(10, 5.5))
    ax.stackplot(t, *stacks, labels=labels, colors=colors, alpha=0.85)
    ax.set_xlabel("Elapsed time (s)")
    ax.set_ylabel("syscalls per kilo-instruction")
    ax.set_title(f"{bench}: system calls per kI, by category (eBPF)")
    ax.set_xlim(np.nanmin(t), np.nanmax(t))
    ax.grid(True, alpha=0.3)
    ax.legend(fontsize=8, loc="upper right")
    _save(fig, out, "fig4_syscalls_per_kI.png")


def _save(fig, out: str, name: str):
    fig.tight_layout()
    path = os.path.join(out, name)
    fig.savefig(path, dpi=130, bbox_inches="tight")
    plt.close(fig)
    print(f"  wrote {os.path.relpath(path, HERE)}")


# --------------------------------------------------------------------------- #
def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("metrics_dir", nargs="?", help="benchmark_metrics_* directory")
    ap.add_argument("-o", "--outdir", help="output dir (default: <metrics_dir>/plots)")
    args = ap.parse_args()

    mdir = find_metrics_dir(args.metrics_dir)
    out = args.outdir or os.path.join(mdir, "plots")
    ensure_writable_dir(out)
    print(f"metrics dir : {mdir}")
    print(f"output dir  : {out}")

    bench = load_bench_name(mdir)
    print(f"benchmark   : {bench}")

    # PMU time series (AMD Zen2 collector; one row per core-group -> average)
    ts_path = None
    for cand in ("amd-zen2-perf-collector-timeseries.csv",
                 "perf-stat.csv", "topdown-intel.sys.csv"):
        p = os.path.join(mdir, cand)
        if os.path.isfile(p):
            ts_path = p
            break
    times, data = np.array([]), {}
    if ts_path:
        rows = read_csv(ts_path)
        wanted = ["Avg. IPC", "CPU Utilization %", "Frontend Bound %",
                  "Backend Bound %", "Retiring %", "Bad Speculation %",
                  "L1 DCache MPKI (w/ prefetches)", "L1 ICache MPKI (w/ prefetches)",
                  "L2 Code MPKI", "L2 Data MPKI", "iTLB MPKI", "dTLB MPKI",
                  "L2 iTLB MPKI", "L2 dTLB MPKI", "Branch Mispred MPKI",
                  "BTB Correction MPKI"]
        present = [c for c in wanted if c in rows[0]] if rows else []
        times, data = group_by_timestamp(rows, "Timestamp_Secs", present)
        print(f"PMU series  : {os.path.basename(ts_path)} "
              f"({len(times)} samples)")
    else:
        print("PMU series  : none found")

    print("rendering figures:")
    if len(times):
        fig_topdown(times, data, out, bench)
        fig_mpki(times, data, out, bench)
        fig_cpu_ctxsw(times, data, mdir, out, bench)
    fig_syscalls(mdir, out, bench)
    print("done.")


if __name__ == "__main__":
    main()
