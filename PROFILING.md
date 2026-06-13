# DCPerf Profiling Plan

## Benchmarks under profile

- Mediawiki
- Feedsim
- TaoBench
- DjangoBench
- VideoTranscodeBench

## Platform note (current host)

This host is an **AMD EPYC 7V12 (Zen2 / "Rome", family 17h) Azure VM**. The
AMD top-down path is [`perfutils/collect_amd_zen2_perf_counters.sh`](perfutils/collect_amd_zen2_perf_counters.sh).
Two hardware limits of this VM shape what is collectable:

- **No uncore PMU.** `/sys/bus/event_source/devices/` exposes only `cpu` and
  `msr` — there is no `amd_l3` or `amd_df`. So **LLC MPKI** and **memory
  bandwidth** cannot be measured here (both need uncore counters), and the Zen2
  collector is deliberately core-PMU-only.
- **No power telemetry.** All `/sys/class/hwmon` sensors are `nvme` (disk temp);
  there is no power sensor, no RAPL (`/sys/class/powercap` is empty), and no
  energy PMU. So **Power** collects nothing on this VM.
- **6 usable GP PMCs after disabling the NMI watchdog.** The watchdog steals a
  PMC; the collector runs `sysctl kernel.nmi_watchdog=0` at startup, after which
  all 6 Zen2 counters are available and the 6-event `{}` groups co-schedule with
  no multiplexing. (Measured with the watchdog *on* it looks like only 4 are
  free — that is the watchdog's PMC plus measurement noise, not a real limit.)

## Methodology

### perf — hardware counters

PMU-based (require hardware performance counters):

- **Topdown breakdown**: frontend / backend / retiring / bad speculation — ✅
- **IPC** — ✅
- **Cache / TLB / Branch MPKIs**
  - L1-D, L1-I, L2 — ✅
  - LLC — ❌ on this host (needs `amd_l3` uncore PMU)
  - L1-DTLB, L1-ITLB, L2-TLB — ✅
  - BP (branch predictor), BTB — ✅

Software events (no PMU required):

- **CPU utilization** — ✅ (`mpstat`, plus `msr/mperf,tsc`)
- **Context switches per kilo instructions** — ✅ `ctxsw` monitor counts
  context switches (software event); per-kI is derived from
  `perfstat` or PerfSpect3 instructions in post-processing.

Not collectable on this host (hardware limits, not software gaps):

- **Power** — ❌ no power sensor / RAPL / energy PMU on this VM (`power` monitor).
- **Memory bandwidth utilization** — ❌ needs the `amd_df` uncore PMU, absent on
  this VM. (Collected by the `topdown` monitor where an uncore PMU exists.)

### eBPF — OS-level behavior

- Distribution of system calls per kilo instructions, broken down by category — ✅:
  - File system
  - Memory management
  - Thread management
  - Networking operations
- Collected by the `syscall_ebpf` monitor (bpftrace on
  `raw_syscalls:sys_enter`, x86_64). The monitor emits per-interval raw
  counts. Per-kI normalization is produced in `syscall-ebpf.derived.csv`
  by post-processing, which reads `instructions` from `perf-stat.csv` or
  `topdown-intel.sys.csv` and joins by row index.
- Requires `bpftrace`. This host has the distro build (Ubuntu 20.04, v0.9.4),
  which predates the `-q` flag; the monitor probes for `-q` support and omits it
  when unavailable (the suppressed "Attaching N probes…" banner goes to stderr
  and is ignored by the stdout parser regardless).
