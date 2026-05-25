# DCPerf Profiling Plan

## Benchmarks under profile

- Mediawiki
- Feedsim
- TaoBench
- DjangoBench
- VideoTranscodeBench

## Methodology

### perf — hardware counters

PMU-based (require hardware performance counters):

- **Topdown breakdown**: frontend / backend / retiring / bad speculation
- **IPC**
- **Cache / TLB / Branch MPKIs**
  - L1-D, L1-I, L2
  <!-- - LLC -->
  - L1-DTLB, L1-ITLB, L2-TLB
  - BP (branch predictor), BTB

Software events (no PMU required):

- **CPU utilization**
- **Context switches per kilo instructions** — `ctxsw` monitor counts
  context switches (software event); per-kI is derived from
  `perfstat` or PerfSpect3 instructions in post-processing.

<!-- - **Power**
- **Memory bandwidth utilization** -->

### eBPF — OS-level behavior

- Distribution of system calls per kilo instructions, broken down by category:
  - File system
  - Memory management
  - Thread management
  - Networking operations
- Collected by the `syscall_ebpf` monitor (bpftrace on
  `raw_syscalls:sys_enter`, x86_64). The monitor emits per-interval raw
  counts. Per-kI normalization is produced in `syscall-ebpf.derived.csv`
  by post-processing, which reads `instructions` from `perf-stat.csv` or
  `topdown-intel.sys.csv` and joins by row index.
