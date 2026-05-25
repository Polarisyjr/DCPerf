#!/usr/bin/env python3
# Copyright (c) Meta Platforms, Inc. and affiliates.
#
# This source code is licensed under the MIT license found in the
# LICENSE file in the root directory of this source tree.

# pyre-unsafe

import logging
import os
import sys
import traceback

from benchpress.lib.hook import Hook

from .perf_monitors import (
    cpufreq_cpuinfo,
    cpufreq_scaling,
    ctxsw,
    memstat,
    mpstat,
    netstat,
    perfstat,
    power,
    syscall_ebpf,
    topdown,
)

BP_BASEPATH = os.path.dirname(os.path.abspath(sys.argv[0]))

DEFAULT_OPTIONS = {
    "mpstat": {
        "interval": 5,
    },
    "cpufreq_scaling": {
        "interval": 5,
    },
    "cpufreq_cpuinfo": {
        "interval": 5,
    },
    "perfstat": {"interval": 5, "additional_events": []},
    "netstat": {"interval": 5, "additional_counters": []},
    "memstat": {"interval": 5, "additional_counters": []},
    "topdown": {},
    "power": {"interval": 1},
    "ctxsw": {"interval": 5},
    "syscall_ebpf": {"interval": 5},
}

AVAIL_MONITORS = {
    "mpstat": mpstat.MPStat,
    "cpufreq_scaling": cpufreq_scaling.CPUFreq,
    "cpufreq_cpuinfo": cpufreq_cpuinfo.CPUFreq,
    "perfstat": perfstat.PerfStat,
    "netstat": netstat.NetStat,
    "memstat": memstat.MemStat,
    "topdown": topdown.TopDown,
    "power": power.Power,
    "ctxsw": ctxsw.CtxSw,
    "syscall_ebpf": syscall_ebpf.SyscallEBPF,
}

logger = logging.getLogger(__name__)


class Perf(Hook):
    def before_job(self, opts, job):
        self.opts = DEFAULT_OPTIONS
        for key in DEFAULT_OPTIONS.keys():
            if not isinstance(opts, dict):
                break
            if key in opts:
                self.opts[key].update(opts[key])

        self.benchmark_metrics_dir = BP_BASEPATH + f"/benchmark_metrics_{job.uuid}"
        if not os.path.isdir(self.benchmark_metrics_dir):
            os.mkdir(self.benchmark_metrics_dir)

        should_run_perf_stat = True
        self.monitors = []
        for mon_name in AVAIL_MONITORS.keys():
            try:
                MonitorClass = AVAIL_MONITORS[mon_name]
                init_args = self.opts[mon_name]
                monitor = MonitorClass(job_uuid=job.uuid, **init_args)
                # We should disable PerfStat (and not run anything that uses PMU)
                # if IntelPerfSpect3 is enabled.
                if isinstance(monitor, topdown.IntelPerfSpect3) and monitor.supported:
                    logger.info(
                        "Disabling PerfStat to avoid conflict with IntelPerfSpect3"
                    )
                    should_run_perf_stat = False
                # The zen2 top-down collector already counts instructions+cycles
                # in its own groups; running PerfStat as a second perf session
                # only steals 2 PMCs and pushes the zen2 groups from 4 to ~6
                # multiplexing waves. Disable it (per-kI derivations fall back to
                # the AMD collector log via load_instructions_per_interval).
                if (
                    isinstance(monitor, topdown.AMDPerfUtil)
                    and getattr(monitor, "amd_gen", None) == "zen2"
                ):
                    logger.info(
                        "Disabling PerfStat: zen2 top-down collector already "
                        "counts instructions+cycles (frees 2 PMCs for its TMA groups)"
                    )
                    should_run_perf_stat = False
                self.monitors.append(monitor)
            except Exception as e:
                logger.warning(
                    f"Failed to load the perf monitor {mon_name} due to the following exception:"
                )
                logger.warning(traceback.print_exception(type(e), e, e.__traceback__))

        for monitor in self.monitors:
            try:
                if isinstance(monitor, perfstat.PerfStat) and not should_run_perf_stat:
                    continue
                monitor.run()
            except Exception as e:
                logger.warning(
                    f"Could not run perf monitor {mon_name} due to the following exception:"
                )
                logger.warning(traceback.print_exception(type(e), e, e.__traceback__))

    def after_job(self, opts, job):
        for monitor in self.monitors:
            monitor.terminate()
        for monitor in self.monitors:
            monitor.write_csv()
        # After every monitor has written its primary CSV, give each one
        # a chance to emit derived metrics that depend on sibling
        # monitors (e.g., ctxsw and syscall_ebpf reading `instructions`
        # from perfstat.csv or topdown-intel.sys.csv to compute per-kI).
        # Not all monitors inherit from the `Monitor` base class
        # (`AMDPerfUtil` and `DummyPerfUtil` in topdown.py do not), so
        # only invoke `post_process` when the attribute is actually
        # present and callable.
        for monitor in self.monitors:
            pp = getattr(monitor, "post_process", None)
            if not callable(pp):
                continue
            try:
                pp()
            except Exception as e:
                mon_name = getattr(monitor, "name", type(monitor).__name__)
                logger.warning(
                    f"Could not run post_process for {mon_name} due to "
                    "the following exception:"
                )
                logger.warning(traceback.print_exception(type(e), e, e.__traceback__))
