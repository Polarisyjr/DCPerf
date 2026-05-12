#!/usr/bin/env python3
# Copyright (c) Meta Platforms, Inc. and affiliates.
#
# This source code is licensed under the MIT license found in the
# LICENSE file in the root directory of this source tree.

# pyre-unsafe

import os
import subprocess
import time

from . import load_instructions_per_interval, logger, Monitor


class CtxSw(Monitor):
    """Capture system-wide context switches per interval.

    Uses `perf stat -a -e context-switches` only. `context-switches` is a
    kernel software event (`PERF_TYPE_SOFTWARE`), so this monitor does
    not occupy any PMU counter and is safe to run alongside `PerfStat`,
    `IntelPerfSpect3`, or any topdown collection.

    Per-kI normalization is deferred to `post_process()`, which reads
    `instructions` from the `perf-stat.csv` (preferred) or
    `topdown-intel.sys.csv` (PerfSpect3) emitted in the same job
    directory.
    """

    def __init__(self, interval, job_uuid, delim=","):
        super(CtxSw, self).__init__(interval, "ctxsw", job_uuid)
        self.delim = delim

    def _process_output(self, line):
        parts = line.rstrip("\n").split(self.delim)
        if len(parts) < 4:
            return
        try:
            interval = float(parts[0])
        except ValueError:
            return
        event = parts[3].strip()
        if event != "context-switches":
            return
        count_str = parts[1].strip()
        if not count_str:
            return
        try:
            count = float(count_str)
        except ValueError:
            return
        self.res.append(
            {
                "interval": interval,
                "timestamp": time.strftime("%I:%M:%S %p"),
                "context_switches": count,
            }
        )

    def process_output(self, line):
        try:
            self._process_output(line)
        except Exception as e:
            logger.warning(
                "CtxSw encountered an exception while processing output: " + str(e)
            )

    def run(self):
        args = [
            "perf",
            "stat",
            "-a",
            "-e",
            "context-switches",
            "-I",
            f"{self.interval * 1000}",
            "-x",
            self.delim,
            "--log-fd",
            "1",
        ]
        self.proc = subprocess.Popen(args, stdout=subprocess.PIPE, encoding="utf-8")
        super(CtxSw, self).run()

    def post_process(self):
        inst = load_instructions_per_interval(os.path.dirname(self.csvpath))
        if not inst:
            logger.info(
                "ctxsw: no instructions source found (need perf-stat.csv or "
                "topdown-intel.sys.csv); skipping per-kI derivation"
            )
            return
        derived_path = self.gen_path("ctxsw.derived.csv")
        n = min(len(self.res), len(inst))
        with open(derived_path, "w") as f:
            f.write("index,timestamp,context_switches,instructions,ctxsw_per_kI\n")
            for i in range(n):
                cs = self.res[i].get("context_switches", 0.0)
                ki = inst[i]
                try:
                    ratio = (cs / ki) * 1000.0 if ki > 0 else 0.0
                except (TypeError, ZeroDivisionError):
                    ratio = 0.0
                f.write(
                    f"{i},{self.res[i]['timestamp']},{cs},{ki},{ratio}\n"
                )
