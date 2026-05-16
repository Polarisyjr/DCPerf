# DCPerf docker runner

Wraps the five benches we run (default settings only) behind one dispatcher.

## Quick start

```bash
./dcperf.sh <bench> all
```

This does `setup` → `install` → `bench` end-to-end. Each step is idempotent, so re-running after a failure resumes from where it stopped.

`<bench>` is one of:

| bench | benchpress job | approx wall time (install + run) |
|---|---|---|
| `taobench` | `tao_bench_standalone` | ~25–50 min install, ~55 min run |
| `mediawiki` | `oss_performance_mediawiki_mlp` | ~10–25 min install, ~15–20 min run |
| `videotranscode` | `video_transcode_bench_svt` | ~15–30 min install, tens of min run |
| `feedsim` | `feedsim_autoscale` | ~7–40 min install, ~30 min run |
| `djangobench` | `django_workload_default` | ~5–20 min install, ~35 min run |

Results land under `../benchmark_metrics_<job>_timestamp:<...>/` on the host (the repo is bind-mounted into the container at `/DCPerf`).

## Other subcommands

```bash
./dcperf.sh <bench> setup      # build image + start container only
./dcperf.sh <bench> install    # install bench inside container (add -f to wipe)
./dcperf.sh <bench> bench      # run the bench
./dcperf.sh <bench> shell      # interactive shell in container
./dcperf.sh <bench> stop       # stop container (keep image)
./dcperf.sh <bench> clean      # remove container + image
./dcperf.sh restore            # restore host perf_event_paranoid / kptr_restrict
```

`setup` relaxes `kernel.perf_event_paranoid` and `kernel.kptr_restrict` so in-container perf/bpftrace works; `bench` restores them on exit via an `EXIT` trap. If a run is killed before the trap fires, `./dcperf.sh restore` puts them back.

## Layout

- `dcperf.sh` — shared dispatcher (image build, container lifecycle, perf-gate save/restore, install/run flow).
- `<bench>/start.sh` — per-bench config: `BENCH_JOB`, install probe path, optional `BENCH_RUN_ARGS`, and hooks (`bench_patch_jobs_yml`, `bench_pre_install`, `bench_post_install`, `bench_force_cleanup`).
- `<bench>/Dockerfile` — per-bench image (all based on `quay.io/centos/centos:stream9`).
