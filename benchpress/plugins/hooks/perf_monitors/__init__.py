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


def _read_csv_instructions_column(path, candidates):
    """Read a CSV and return the first numeric column whose header
    matches one of `candidates` (case-insensitive, trimmed). Returns a
    list of floats, or None if no matching column is found.
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
            out = []
            for row in reader:
                v = row.get(target, "")
                try:
                    out.append(float(str(v).strip()))
                except (TypeError, ValueError):
                    out.append(0.0)
            return out
    except OSError:
        return None


def load_instructions_per_interval(metrics_dir):
    """Load per-interval retired-instruction counts emitted by either
    `PerfStat` (perfstat.csv) or `IntelPerfSpect3`
    (topdown-intel.sys.csv). Returns a list of floats aligned by row
    order, or None if neither source is available.

    PerfStat is preferred since its format is fixed and the column name
    is exactly `instructions`. PerfSpect3 is used as a fallback; its
    column naming is best-effort.
    """
    pstat = os.path.join(metrics_dir, "perf-stat.csv")
    out = _read_csv_instructions_column(pstat, ("instructions",))
    if out:
        return out
    pspect = os.path.join(metrics_dir, "topdown-intel.sys.csv")
    out = _read_csv_instructions_column(pspect, _PERFSPECT_INST_COLUMNS)
    if out:
        return out
    # AMD fallback: when PerfStat is disabled (e.g. the zen2 collector
    # already counts instructions+cycles), recover per-interval
    # instructions from the AMD collector's raw per-socket log.
    out = _read_amd_collector_instructions(metrics_dir)
    if out:
        return out
    return None


def _read_amd_collector_instructions(metrics_dir):
    """Per-interval instructions from a raw AMD top-down collector log
    (`amd-*perf-collector.log`, the per-socket `perf stat -x,` output).
    Sums the `instructions` event across sockets for each interval and
    returns one value per interval in chronological (file) order, or
    None if no such log/event is present.
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
            return [per_ts[ts] for ts in order]
    return None
