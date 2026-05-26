#!/usr/bin/env python3
# Copyright (c) Meta Platforms, Inc. and affiliates.
#
# This source code is licensed under the MIT license found in the
# LICENSE file in the root directory of this source tree.

# pyre-unsafe

import abc
import csv
import logging
import os
import signal
import subprocess
import sys
import threading


logger = logging.getLogger(__name__)
# Path to directory of benchpress_cli.py
BP_BASEPATH = os.path.dirname(os.path.abspath(sys.argv[0]))


class Monitor:
    def gen_path(self, filename):
        return BP_BASEPATH + f"/benchmark_metrics_{self.job_uuid}/{filename}"

    def __init__(self, interval, name, job_uuid):
        """Initialize some common parameters and storage variables"""
        self.name = name
        self.interval = interval
        # Reserved for result processing
        self.res = []
        # Reserved for original output of the monitoring process
        self.output = ""
        self.job_uuid = job_uuid
        self.logpath = self.gen_path(f"{name}.log")
        self.csvpath = self.gen_path(f"{name}.csv")
        self.logfile = open(self.logpath, "w", buffering=1)  # noqa: P201

    def __del__(self):
        self.logfile.close()

    def process_output(self, line):
        """Define custom ways to process each line of output"""
        pass

    def post_process(self):
        """Optional hook invoked after all monitors have terminated and
        written their primary CSVs. Subclasses may override this to emit
        derived metrics that need data from sibling monitors (e.g.,
        per-kI normalization using `instructions` from perfstat or
        PerfSpect3).
        """
        pass

    def output_catcher(self):
        """Catch output from the monitoring process line by line, and do the following:
        1) Append the line into self.output variable
        2) Write the line to the log file at /path/to/benchpress/benchmark_metrics_<uuid>/<name>.log
        3) Call process_output(line) to let subclasses customly process output lines
        """
        if not hasattr(self, "proc"):
            return
        if not isinstance(self.proc, subprocess.Popen):
            return
        if self.proc.stdout is None:
            return
        for line in iter(self.proc.stdout.readline, ""):
            if not line:
                continue
            self.output += line
            self.process_output(line)
            self.logfile.write(line)

    def stderr_catcher(self):
        """Catch stderr from the monitoring process and send error messages to log"""
        if not hasattr(self, "proc"):
            return
        if not isinstance(self.proc, subprocess.Popen):
            return
        if self.proc.stderr is None:
            return
        for line in iter(self.proc.stderr.readline, ""):
            if not line:
                continue
            logger.warning(line)

    @abc.abstractmethod
    def run(self):
        """
        Here the subclasses should implement how to start the monitoring process
        using subprocess.Popen. They should also set stdout and stderr to
        subprocess.PIPE in order to utilize Monitor's built-in stdout and stderr
        catcher. After doing Popen, the subclass's run method can super-call this
        run method to start the stdout and stderr catcher. The output and stderr
        catcher instances will be recorded as `oc` and `ec` members.
        """
        self.oc = threading.Thread(
            target=self.output_catcher, name=self.name + "-stdout", args=()
        )
        self.oc.start()
        self.ec = threading.Thread(
            target=self.stderr_catcher, name=self.name + "-stderr", args=()
        )
        self.ec.start()

    def terminate(self):
        """
        Kill the monitoring process using SIGINT signal and join the stdout
        and stderr catcher threads.
        """
        exitcode = -1
        if hasattr(self, "proc") and isinstance(self.proc, subprocess.Popen):
            os.kill(self.proc.pid, signal.SIGINT)
            exitcode = self.proc.wait()
        if hasattr(self, "oc") and isinstance(self.oc, threading.Thread):
            self.oc.join()
        if hasattr(self, "ec") and isinstance(self.ec, threading.Thread):
            self.ec.join()
        return exitcode

    def get_result(self):
        """Return the result array"""
        return self.res

    def gen_csv(self):
        if len(self.res) == 0:
            return ""

        csv_text = ""
        headers = sorted(self.res[0].keys() - {"timestamp"})
        csv_text += "index,timestamp," + ",".join(headers) + "\n"
        for i in range(len(self.res)):
            csv_text += f"{i},{self.res[i]['timestamp']},"
            for key in headers:
                csv_text += f"{self.res[i][key]},"
            csv_text += "\n"

        return csv_text

    def write_csv(self):
        csv_text = self.gen_csv()
        if len(csv_text.strip()) == 0:
            return
        with open(self.csvpath, "w") as f:
            f.write(csv_text)


_PERFSPECT_INST_COLUMNS = (
    "instructions",
    "inst_retired.any",
    "inst_retired_any",
    "metric_instructions",
)


# Column headers (case-insensitive) that carry an elapsed-seconds timestamp,
# used to align the instruction stream to other monitors by time.
_TS_COLUMNS = ("timestamp_secs", "elapsed", "time", "timestamp", "seconds")


def _read_csv_instructions_column(path, candidates):
    """Read a CSV and return ``[(ts_elapsed_or_None, instructions), ...]`` using
    the first numeric column whose header matches one of `candidates`
    (case-insensitive, trimmed), and an elapsed-seconds timestamp from the first
    matching `_TS_COLUMNS` header when present. Returns None if no instructions
    column is found.
    """
    try:
        with open(path, newline="") as f:
            reader = csv.DictReader(f)
            if not reader.fieldnames:
                return None
            lowered = {c.strip().lower(): c for c in reader.fieldnames}
            target = None
            for cand in candidates:
                if cand in lowered:
                    target = lowered[cand]
                    break
            if target is None:
                return None
            ts_col = next((lowered[c] for c in _TS_COLUMNS if c in lowered), None)
            out = []
            for row in reader:
                try:
                    val = float(str(row.get(target, "")).strip())
                except (TypeError, ValueError):
                    val = 0.0
                ts = None
                if ts_col is not None:
                    try:
                        ts = float(str(row.get(ts_col, "")).strip())
                    except (TypeError, ValueError):
                        ts = None
                out.append((ts, val))
            return out
    except OSError:
        return None


def load_instructions_per_interval_ts(metrics_dir):
    """Load per-interval retired-instruction counts WITH timestamps, emitted by
    `PerfStat` (perf-stat.csv), `IntelPerfSpect3` (topdown-intel.sys.csv), or the
    AMD top-down collector. Returns ``[(ts_elapsed_or_None, instructions), ...]``
    in chronological order, or None if no source is available.

    Timestamps let callers normalize other monitors' per-interval counts to
    per-kilo-instruction by TIME rather than by sample index -- the collectors
    can sample at different or irregular cadences (the AMD collector in
    particular stretches/drops intervals under load), so positional pairing both
    truncates the shorter stream and misaligns the ratios.
    """
    pstat = os.path.join(metrics_dir, "perf-stat.csv")
    out = _read_csv_instructions_column(pstat, ("instructions",))
    if out:
        return out
    pspect = os.path.join(metrics_dir, "topdown-intel.sys.csv")
    out = _read_csv_instructions_column(pspect, _PERFSPECT_INST_COLUMNS)
    if out:
        return out
    out = _read_amd_collector_instructions(metrics_dir)
    if out:
        return out
    return None


def load_instructions_per_interval(metrics_dir):
    """Back-compat wrapper: instruction counts only (no timestamps), in
    chronological order, or None. Prefer load_instructions_per_interval_ts()."""
    pairs = load_instructions_per_interval_ts(metrics_dir)
    return [v for _, v in pairs] if pairs else None


def derive_per_kI(bucket_rows, inst_ts, interval, cats, bucket_times=None):
    """Normalize per-interval category counts to per-kilo-instruction, aligning
    each bucket to the instruction stream BY TIMESTAMP when timestamps are
    available (else falling back to the legacy by-index pairing).

    bucket_rows : list of dicts, each with the category counts in `cats`
                  (and a 'timestamp' field, copied through to the output).
    inst_ts     : list of (elapsed_sec_or_None, instructions) in time order.
    interval    : nominal sampling interval (s) of `bucket_rows`.
    cats        : ordered category names.
    bucket_times: optional list of each bucket's own elapsed-seconds stamp. Pass
                  it for monitors whose cadence can drift (e.g. perf-stat based
                  ones); omit for steady monitors (e.g. bpftrace), where the
                  bucket time is taken as (i+1)*interval.

    Returns a list of dicts: index, timestamp, <cats>, instructions (the
    instruction count attributed to the bucket's interval), <cat>_per_kI.
    Covers every bucket -- not just min(len(buckets), len(inst_ts)).
    """
    times = [t for t, _ in inst_ts]
    insts = [v for _, v in inst_ts]
    have_ts = len(times) >= 1 and all(t is not None for t in times)

    # Instruction RATE (per second) at each inst sample, so a bucket landing in
    # a stretched/merged inst interval still gets the right denominator.
    rates = []
    if have_ts:
        for j in range(len(times)):
            dt = (times[j] - times[j - 1]) if j > 0 else (times[0] or interval)
            rates.append(insts[j] / dt if dt and dt > 0 else 0.0)

    def _ki_for_bucket(i, ptr):
        """Instructions attributed to bucket i's interval, and advanced ptr."""
        if have_ts:
            # bucket i's interval ends ~here (elapsed s): its own stamp if the
            # caller provided one, else the steady-cadence assumption.
            if bucket_times is not None and i < len(bucket_times) and bucket_times[i] is not None:
                te = bucket_times[i]
            else:
                te = (i + 1) * interval
            while ptr + 1 < len(times) and abs(times[ptr + 1] - te) <= abs(times[ptr] - te):
                ptr += 1
            return rates[ptr] * interval, ptr
        # legacy: pair by index
        return (insts[i] if i < len(insts) else 0.0), ptr

    out = []
    ptr = 0
    n = len(bucket_rows) if have_ts else min(len(bucket_rows), len(insts))
    for i in range(n):
        row = bucket_rows[i]
        ki, ptr = _ki_for_bucket(i, ptr)
        counts = [row.get(c, 0) for c in cats]
        ratios = [((c / ki) * 1000.0 if ki and ki > 0 else 0.0) for c in counts]
        rec = {"index": i, "timestamp": row.get("timestamp", ""),
               "instructions": ki}
        for c, cv, r in zip(cats, counts, ratios):
            rec[c] = cv
            rec[f"{c}_per_kI"] = r
        out.append(rec)
    return out


def _read_amd_collector_instructions(metrics_dir):
    """Per-interval instructions from a raw AMD top-down collector log
    (`amd-*perf-collector.log`, the per-socket `perf stat -x,` output).
    Sums the `instructions` event across sockets for each interval and
    returns ``[(elapsed_sec, instructions), ...]`` in chronological (file)
    order, or None if no such log/event is present.
    """
    try:
        names = [
            n
            for n in os.listdir(metrics_dir)
            if n.startswith("amd-") and n.endswith("perf-collector.log")
        ]
    except OSError:
        return None
    for name in sorted(names):
        per_ts = {}
        order = []
        try:
            with open(os.path.join(metrics_dir, name), newline="") as f:
                for row in csv.reader(f):
                    # cols: ts,socket,numcpus,value,unit,event,runtime,pct,...
                    if len(row) < 6 or row[5] != "instructions":
                        continue
                    ts = row[0]
                    try:
                        val = float(row[3])
                    except (TypeError, ValueError):
                        continue
                    if ts not in per_ts:
                        per_ts[ts] = 0.0
                        order.append(ts)
                    per_ts[ts] += val
        except OSError:
            continue
        if order:
            pairs = []
            for ts in order:
                try:
                    et = float(ts)
                except (TypeError, ValueError):
                    et = None
                pairs.append((et, per_ts[ts]))
            return pairs
    return None
