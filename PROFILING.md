# DCPerf Profiling Plan

## Benchmarks under profile

- Mediawiki
- Feedsim
- TaoBench
- DjangoBench
- VideoTranscodeBench

## Methodology

### perf — hardware counters

- **Topdown breakdown**: frontend / backend / retiring / bad speculation
- **IPC**
- **CPU utilization**
- **Power**
- **Memory bandwidth utilization**
- **Cache / TLB / Branch MPKIs**
  - L1-D, L1-I, L2, LLC
  - L1-DTLB, L1-ITLB, L2-TLB
  - BP (branch predictor), BTB
- **Context switches per kilo instructions**

### eBPF — OS-level behavior

- Distribution of system calls per kilo instructions, broken down by category:
  - File system
  - Memory management
  - Thread management
  - Networking operations
