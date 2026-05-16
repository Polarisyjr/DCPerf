# Docker dispatcher: two-bug fix
**Date:** 2026-05-16

## Scope

Two bugs surfaced after refactoring `docker/{feedsim_autoscale,django_workload_default}/dcperf.sh` into a shared `docker/dcperf.sh` dispatcher (per-bench config in `docker/<bench>/start.sh`):

1. **AMD perf report fails inside container** with:
   ```
   sudo: PAM account management error: Authentication service cannot retrieve authentication info
   sudo: a password is required
   ```
2. **feedsim bench produces `metrics: null`** on the current host (`ccg-ubuntu`, AMD EPYC 9575F, 256 cores) even though `benchpress run` exits 0. Affects both `feedsim_default` and `feedsim_autoscale`. Pre-existing — all `benchmark_metrics_feedsim_*_timestamp:202605*` runs on this host had empty result files. NOT a general feedsim bug: `results/dcperf/feedsim_autoscale/895d8cb0/` shows a clean run on Intel Xeon 8480C / 96 cores / Azure VM (`spawned_instances: 1`, score 5.15) — the bug is **scale-dependent**.

## Bug 1: sudo / PAM

### Root cause
`quay.io/centos/centos:stream9` minimal image ships `/etc/pam.d/{system,password}-auth` as placeholder files that `include` modules requiring `systemd-logind` / `sssd`. In a container without those, PAM's `account` stage fails. `/etc/pam.d/sudo` includes `system-auth`, so every `sudo` invocation — even by `root` — dies before reaching sudoers policy. `generate_amd_perf_report.py` calls `sudo dmidecode -t 17`, exits 1, AMD perf report never generated.

`authselect` not installed in the base image, so the PAM stack was never wired up.

### Fix
Shim `sudo` as a transparent passthrough. The container runs as root by design, so `sudo cmd` is equivalent to `cmd`. Avoids dragging in `authselect` + profile.

```dockerfile
RUN printf '#!/bin/sh\nexec "$@"\n' > /usr/local/bin/sudo \
 && chmod +x /usr/local/bin/sudo
```

Applied to `docker/feedsim/Dockerfile` and `docker/djangobench/Dockerfile`. `/usr/local/bin` precedes `/usr/bin` in PATH so the shim wins. Does not affect host's `sudo` (different binary).

### Verified
End-to-end on freshly built images (no injection):
- `which sudo` → `/usr/local/bin/sudo` (Dockerfile-baked shim active)
- `sudo dmidecode -t 17` → returns real SMBIOS memory device data, exit 0
- `generate_amd_perf_report.py -s timeseries.csv -f csv --arch zen5 amd-zen5-perf-collector.log` (the same invocation DCPerf's perf hook uses in `benchpress/plugins/hooks/perf_monitors/topdown.py:366`) → exit 0, writes 827 lines of timeseries CSV with full zen5 microarchitectural counters (Frontend/Backend Bound %, L1/L2/L3 fills, TLB miss, Branch Retired, etc.)

## Bug 2: feedsim `metrics: null`

### Root cause
`packages/feedsim/run.sh:210` starts LeafNodeRank in background then `sleep 90` before launching `search_qps.sh`. The script even self-documents: `FIXME(cltorres) Remove sleep, expose an endpoint or print a message to notify service is ready`.

On Intel-96 / Azure VM, autoscale rounds 96 → 1 instance; single-instance warmup fits in 90 s and the bench runs cleanly (`results/dcperf/feedsim_autoscale/895d8cb0/`, score 5.15). On the 256-core AMD EPYC 9575F box, autoscale rounds 256 → 3 instances; each instance does `--graph_scale=21 --graph_subset=2000000` graph build + `--min_icache_iterations=1600000` icache warmup. With 3 instances competing for CPU and each using ~89 ranking threads, warmup blows past 90 s. Manual smoke test: LeafNodeRank starts listening on its port immediately but is still doing "Build Time: ~7s" iterations after 2 minutes.

`packages/feedsim/third_party/src/scripts/search_qps.sh:215` compounds the problem with `load_test_retries=3`. Each retry launches DriverNodeRank, sleeps 7 s, checks if alive. Three retries × 7 s = ~21 s window — not enough to cover Leaf's remaining warmup, so the load test never starts. `feedsim_results*.txt` end up header-only, and `run-feedsim-multi.sh:152` divides by `successful_insts == 0` → bc "Divide by zero" → empty `avg_latency` → emitted JSON has `"average_latency_msec":` (invalid JSON) → benchpress parser bails → `metrics: null`.

### Fix
Two minimal patches to the upstream templates:

1. **`packages/feedsim/run.sh`**: replace `sleep 90` with `LEAF_WAIT="${DCPERF_LEAF_WAIT:-300}"; sleep "$LEAF_WAIT"`. Env-overridable per host (e.g. `DCPERF_LEAF_WAIT=120` on a small Intel-96 box).
2. **`packages/feedsim/third_party/src/scripts/search_qps.sh`**: bump `load_test_retries 3 → 20`. Gives a ~140-second retry window for Leaf to settle, robust to jitter.

These templates are `cp`'d to `benchmarks/feedsim/{run.sh,src/scripts/search_qps.sh}` by `install_feedsim.sh`, so committing the upstream-template change is what makes the fix durable across `install --force` cycles.

### Verified
End-to-end on the 256-core AMD box after a clean rebuild (`./dcperf.sh feedsim clean && setup && install --force`):

```json
"benchmark_name": "feedsim_default",
"run_id": "35eee634",
"metrics": {
    "target_percentile": "95p",
    "target_latency_msec": 500.0,
    "final_requested_qps": 336.71,
    "final_achieved_qps": 338.28,
    "final_latency_msec": 404.28,
    "score": 5.93
}
```

Search converged in 7 binary-search iters (warmup → peak 478 qps → converge to 336 qps with p95 = 404 ms ≤ 500 ms target). This is the **first non-empty feedsim run on the AMD-256 host**; all prior `benchmark_metrics_feedsim_*_timestamp:202605*` directories had empty result files.

## Files Modified

| File | Change |
|---|---|
| `docker/dcperf.sh` (new) | Shared dispatcher: bench lifecycle, container privileged-flags template, perf-gate save/restore with `EXIT` trap, install probe + jobs.yml patch hooks |
| `docker/feedsim/start.sh` (new) | Per-bench: `BENCH_JOB=feedsim_autoscale`, `bench_patch_jobs_yml` swaps cpu-mpstat → perf hook, `bench_force_cleanup` invokes `cleanup_feedsim.sh` |
| `docker/djangobench/start.sh` (new) | Per-bench: `BENCH_JOB=django_workload_default`, `BENCH_RUN_ARGS=(-r standalone)`, custom force-cleanup skipping `pkill` under `--pid=host` |
| `docker/feedsim/Dockerfile` | + sudo shim |
| `docker/djangobench/Dockerfile` | + sudo shim |
| `docker/TASK_REPORT.md` (new) | This document |
| `packages/feedsim/run.sh` | `sleep 90` → `DCPERF_LEAF_WAIT` (default 300) |
| `packages/feedsim/third_party/src/scripts/search_qps.sh` | `load_test_retries 3 → 20` |

Directory renames: `docker/feedsim_autoscale/` → `docker/feedsim/`, `docker/django_workload_default/` → `docker/djangobench/`.

## Final Container State
After validation + cleanup, the two relevant containers are the rebuilt ones (Dockerfile-baked shim):
- `dcperf-feedsim` (image `dcperf-feedsim:centos9`, ~1.84 GB)
- `dcperf-djangobench` (image `dcperf-djangobench:centos9`, ~2.47 GB)

Legacy containers/images removed: `dcperf-{feedsim_autoscale,django_workload_default}{,:centos9}` (~4.3 GB freed). No leftover `/tmp/dcperf-*.perf_gates_orig` snapshots. Host `kernel.perf_event_paranoid=-1`, `kernel.kptr_restrict=0` (unchanged from session start — we hit the `already relaxed` branch and never persisted a restore snapshot).

## Notes / Open Items
- The `--arch` flag of `generate_amd_perf_report.py` defaults to `zen3`. DCPerf's perf hook (`topdown.py:366`) correctly passes `--arch zen5` when running under the perf monitor on a zen5 host. If you ever invoke the script manually, remember to pass `--arch zen5` and supply the **raw** `amd-zen5-perf-collector.log` (not the summary CSV) as the positional input.
- `sleep "$LEAF_WAIT"` is a fixed-duration wait, not a polling probe. On smaller hosts (e.g. Intel-96 where 90 s sufficed historically) it now wastes time — set `DCPERF_LEAF_WAIT=120` or similar via env. A polling version would need a Leaf readiness signal that the upstream binary doesn't currently expose.
