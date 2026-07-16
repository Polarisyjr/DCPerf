#!/usr/bin/env python3
# Copyright (c) Meta Platforms, Inc. and affiliates.
#
# This source code is licensed under the MIT license found in the
# LICENSE file in the root directory of this source tree.

# pyre-unsafe

import os
import re
import subprocess
import time

from . import derive_per_kI, load_instructions_per_interval_ts, logger, Monitor


# x86_64 syscall numbers grouped into four categories. The set is curated
# to cover the high-volume syscalls seen on server workloads; obscure or
# legacy syscalls are intentionally omitted. Numbers follow the Linux
# x86_64 ABI (arch/x86/entry/syscalls/syscall_64.tbl) and are vendor
# independent (same on AMD and Intel).
SYSCALLS = {
    "fs": [
        0, 1, 2, 3, 4, 5, 6, 8, 16, 17, 18, 19, 20, 21, 22, 32, 33, 40,
        72, 73, 74, 75, 76, 77, 78, 79, 80, 81, 82, 83, 84, 85, 86, 87,
        88, 89, 90, 91, 92, 93, 94, 95, 137, 138, 187, 213, 217, 232,
        233, 257, 258, 260, 262, 263, 264, 265, 266, 267, 268, 269, 285,
        290, 291, 292, 293, 294, 295, 296, 306, 316, 332, 437, 439,
    ],
    "mm": [
        9, 10, 11, 12, 25, 26, 27, 28, 149, 150, 151, 152, 216, 237, 238,
        239, 256, 279, 319, 324, 325,
    ],
    "thread": [
        13, 14, 15, 24, 35, 56, 57, 58, 59, 60, 61, 62, 200, 202, 203,
        204, 218, 230, 231, 234, 247, 273, 322, 435,
    ],
    "net": [
        41, 42, 43, 44, 45, 46, 47, 48, 49, 50, 51, 52, 53, 54, 55, 288,
        299, 307,
    ],
}

CAT_ID = {"fs": 1, "mm": 2, "thread": 3, "net": 4}
CAT_NAME = {v: k for k, v in CAT_ID.items()}
GROUP_TARGET = 1
GROUP_OTHER = 2
_SAFE_GROUP_NAME = re.compile(r"^[A-Za-z][A-Za-z0-9_]*$")


def _quote_bpftrace_string(value):
    return '"' + value.replace("\\", "\\\\").replace('"', '\\"') + '"'


def _cgroup_id_for_pid(pid):
    """Return the cgroup-v2 ID used by bpf_get_current_cgroup_id()."""
    with open(f"/proc/{int(pid)}/cgroup") as f:
        for line in f:
            _hierarchy, controllers, relative = line.rstrip("\n").split(":", 2)
            if controllers == "":
                # A unified-only host mounts cgroup2 at /sys/fs/cgroup; this
                # host uses hybrid mode and mounts it at
                # /sys/fs/cgroup/unified.  Try both conventional locations.
                for mountpoint in ("/sys/fs/cgroup", "/sys/fs/cgroup/unified"):
                    path = os.path.join(mountpoint, relative.lstrip("/"))
                    try:
                        return os.stat(path).st_ino
                    except FileNotFoundError:
                        continue
                raise ValueError(
                    f"PID {pid} cgroup-v2 path is not mounted: {relative}"
                )
    raise ValueError(f"PID {pid} has no cgroup-v2 membership")


def _build_script(
    interval,
    target_name="target",
    target_comms=(),
    target_tgids=(),
    target_cgroup_ids=(),
):
    split = bool(target_comms or target_tgids or target_cgroup_ids)
    parts = ["BEGIN {"]
    for cat, nrs in SYSCALLS.items():
        cid = CAT_ID[cat]
        for nr in nrs:
            parts.append(f"  @cat[{nr}] = {cid};")
    if split:
        parts.append(f'  printf("=GROUP= {target_name}\\n");')
    parts.append("}")
    parts.append("")
    parts.append("tracepoint:raw_syscalls:sys_enter {")
    parts.append("  $c = @cat[args->id];")
    if split:
        selectors = [f"comm == {_quote_bpftrace_string(v)}" for v in target_comms]
        selectors += [f"pid == {v}" for v in target_tgids]
        selectors += [f"cgroup == {v}" for v in target_cgroup_ids]
        predicate = " || ".join(selectors)
        parts.append("  if ($c > 0) {")
        parts.append(f"    $g = ({predicate}) ? {GROUP_TARGET} : {GROUP_OTHER};")
        parts.append("    @cnt[$g * 10 + $c] = count();")
        parts.append("  }")
    else:
        parts.append("  if ($c > 0) { @cnt[$c] = count(); }")
    parts.append("}")
    parts.append("")
    parts.append(f"interval:s:{interval} {{")
    parts.append('  printf("=TS= %u\\n", nsecs);')
    parts.append("  print(@cnt);")
    parts.append("  clear(@cnt);")
    parts.append("}")
    parts.append("")
    # Drop @cat at exit so it is not dumped to stdout. @cnt is intentionally
    # left alone so any trailing partial interval after SIGINT is captured.
    parts.append("END { clear(@cat); }")
    return "\n".join(parts)


class SyscallEBPF(Monitor):
    """Capture syscall rates by category using bpftrace (x86_64).

    Attaches to `tracepoint:raw_syscalls:sys_enter` system-wide and emits
    per-interval counts for four categories: file system (`fs`), memory
    management (`mm`), thread/process management (`thread`), and
    networking (`net`).

    Per-kI normalization is computed in `post_process()`, which reads
    `instructions` from `perf-stat.csv` (PerfStat monitor) or
    `topdown-intel.sys.csv` (IntelPerfSpect3) in the same job directory,
    and emits `syscall-ebpf.derived.csv` alongside the raw counts.
    """

    def __init__(
        self,
        interval,
        job_uuid,
        target_name="target",
        target_comms=None,
        target_tgids=None,
        target_cgroup_ids=None,
        target_cgroup_pids=None,
    ):
        """Create the monitor, optionally splitting one target from the host.

        Selectors are ORed. ``target_cgroup_pids`` is a convenience option that
        resolves each PID's cgroup-v2 ID at monitor construction time.  A
        cgroup selector is preferred for containers because it includes every
        subprocess and thread, even when their ``comm`` names differ.
        """
        super(SyscallEBPF, self).__init__(interval, "syscall-ebpf", job_uuid)
        if not _SAFE_GROUP_NAME.fullmatch(target_name):
            raise ValueError(
                "target_name must start with a letter and contain only "
                "letters, digits, and underscores"
            )
        self.target_name = target_name
        self.target_comms = tuple(str(v) for v in (target_comms or ()))
        self.target_tgids = tuple(sorted({int(v) for v in (target_tgids or ())}))
        cgroup_ids = {int(v) for v in (target_cgroup_ids or ())}
        for pid in target_cgroup_pids or ():
            cgroup_ids.add(_cgroup_id_for_pid(pid))
        self.target_cgroup_ids = tuple(sorted(cgroup_ids))
        self.split_enabled = bool(
            self.target_comms or self.target_tgids or self.target_cgroup_ids
        )

    def _close_current(self):
        if self._current is not None:
            self.res.append(self._current)
            self._current = None

    def _open_bucket(self):
        self._close_current()
        self._current = {
            "interval": self._idx,
            "timestamp": time.strftime("%I:%M:%S %p"),
            "fs": 0,
            "mm": 0,
            "thread": 0,
            "net": 0,
        }
        if getattr(self, "split_enabled", False):
            target_name = getattr(self, "target_name", "target")
            for cat in CAT_ID:
                self._current[f"{target_name}_{cat}"] = 0
                self._current[f"other_{cat}"] = 0
        self._idx += 1

    def _process_output(self, line):
        s = line.rstrip("\n").strip()
        if not s:
            return
        if s.startswith("=TS="):
            self._open_bucket()
            return
        if s.startswith("=GROUP="):
            target_name = s[len("=GROUP=") :].strip()
            if _SAFE_GROUP_NAME.fullmatch(target_name):
                self.target_name = target_name
                self.split_enabled = True
            return
        if s.startswith("@cnt["):
            try:
                rb = s.index("]")
                cid = int(s[5:rb])
                colon = s.index(":", rb)
                cnt = int(s[colon + 1 :].strip())
            except (ValueError, IndexError):
                return
            group = None
            if cid >= 10:
                group, cid = divmod(cid, 10)
            name = CAT_NAME.get(cid)
            if not name:
                return
            if self._current is None:
                self._open_bucket()
            if group == GROUP_TARGET:
                target_name = getattr(self, "target_name", "target")
                self._current[f"{target_name}_{name}"] = cnt
                self._current[name] = cnt + self._current[f"other_{name}"]
            elif group == GROUP_OTHER:
                target_name = getattr(self, "target_name", "target")
                self._current[f"other_{name}"] = cnt
                self._current[name] = cnt + self._current[f"{target_name}_{name}"]
            elif group is None:
                self._current[name] = cnt

    def process_output(self, line):
        try:
            self._process_output(line)
        except Exception as e:
            logger.warning(
                "SyscallEBPF encountered an exception while processing output: "
                + str(e)
            )

    @staticmethod
    def _bpftrace_supports_quiet():
        """Whether the installed bpftrace accepts -q (quiet).

        -q was added after the v0.9.x series shipped by older distros (e.g.
        Ubuntu 20.04's bpftrace 0.9.4 rejects it with "invalid option -- 'q'").
        It only suppresses the "Attaching N probes..." banner, which bpftrace
        writes to stderr (captured separately below) and which the stdout parser
        ignores anyway -- so when -q is unavailable we simply omit it.
        """
        try:
            help_out = subprocess.run(
                ["bpftrace", "--help"],
                capture_output=True,
                encoding="utf-8",
            )
            return "-q" in (help_out.stdout + help_out.stderr)
        except OSError:
            return False

    def run(self):
        self._idx = 0
        self._current = None
        script = _build_script(
            self.interval,
            self.target_name,
            self.target_comms,
            self.target_tgids,
            self.target_cgroup_ids,
        )
        args = ["bpftrace"]
        if self._bpftrace_supports_quiet():
            args.append("-q")
        args += ["-e", script]
        self.proc = subprocess.Popen(
            args,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            encoding="utf-8",
        )
        super(SyscallEBPF, self).run()

    def terminate(self):
        rc = super(SyscallEBPF, self).terminate()
        self._close_current()
        return rc

    def post_process(self):
        inst_ts = load_instructions_per_interval_ts(os.path.dirname(self.csvpath))
        if not inst_ts:
            logger.info(
                "syscall_ebpf: no instructions source found (need "
                "perf-stat.csv or topdown-intel.sys.csv); skipping per-kI "
                "derivation"
            )
            return
        cats = list(CAT_ID)
        if self.split_enabled:
            cats += [f"{self.target_name}_{cat}" for cat in CAT_ID]
            cats += [f"other_{cat}" for cat in CAT_ID]
        cats = tuple(cats)
        # Align by timestamp (not sample index) so the derived series spans the
        # whole run even when the instruction collector sampled at a different /
        # irregular cadence than this 5s-steady eBPF monitor.
        rows = derive_per_kI(self.res, inst_ts, self.interval, cats)
        derived_path = self.gen_path("syscall-ebpf.derived.csv")
        with open(derived_path, "w") as f:
            f.write(
                "index,timestamp,"
                + ",".join(cats)
                + ",instructions,"
                + ",".join(f"{c}_per_kI" for c in cats)
                + "\n"
            )
            for r in rows:
                f.write(
                    f"{r['index']},{r['timestamp']},"
                    + ",".join(str(r[c]) for c in cats)
                    + f",{r['instructions']},"
                    + ",".join(str(r[f"{c}_per_kI"]) for c in cats)
                    + "\n"
                )
