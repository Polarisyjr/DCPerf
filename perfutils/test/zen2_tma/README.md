# Zen2 top-down (TMA) regression test

Validates the Zen2 (Family 17h) top-down L1 decomposition implemented in
[`perfutils/generate_amd_perf_report.py`](../../generate_amd_perf_report.py).

`validate_zen2_tma.py` builds a set of microbenchmarks (`bench.c`), each crafted
to dominate one TMA bucket, measures the real `TOPDOWN_L1_GROUP` counters, feeds
them through the **actual report functions**, and asserts the two invariants the
methodology must hold:

1. the four buckets (Retiring / Bad Speculation / Frontend / Backend) sum to
   **~100%**, and
2. **Bad Speculation is non-negative**.

## Why these two invariants

Both guard against regressions in two non-obvious event choices:

- **Bad Speculation ≥ 0** depends on `td_dispatched_ops` being event **`0xAB`**
  (all dispatched ops, incl. microcode-sequencer ops), *not* `0xAA`
  (`de_dis_uops_from_decoder`, decoder+opcache only). `0xAA` undercounts on
  microcoded code (e.g. integer `div`) and drives Bad Speculation negative — the
  `ucode` / `membound` microbenchmarks exercise exactly this.
- **Sum ≈ 100%** depends on Frontend/Backend being the *weighted slot-deficit*
  form (apportioning `W*cycles - dispatched` by the op-queue-empty : token-stall
  ratio), not raw cycle fractions. Raw cycle fractions undershoot on
  partial-issue workloads (`badspec`) and overshoot on latency-bound ones
  (`ucode`); the weighted form closes both.

## Running

```sh
python3 validate_zen2_tma.py
```

Exit codes: `0` pass, `1` an invariant failed, `77` skipped (not Zen2 / no perf).

## Requirements & caveats

- **Real Zen2 (Family 17h) hardware** — the event codes are family-specific. On
  anything else the test skips (exit 77).
- **perf access to core PMCs.** As non-root, `/proc/sys/kernel/perf_event_paranoid`
  must permit per-process counting; the events are pinned to `:u` so user-space
  measurement is enough.
- **`0xAB` is undocumented in perf's event json.** Its definition (complete
  dispatched-ops counter, the Zen2 analog of Zen5 `de_src_op_disp.all`) was
  confirmed empirically, not against the AMD Family 17h PPR. Cross-check
  `PMCx0AB` in the PPR before relying on this further.
