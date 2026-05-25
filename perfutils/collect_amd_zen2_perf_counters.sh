#!/bin/bash
# Copyright (c) Meta Platforms, Inc. and affiliates.
#
# This source code is licensed under the MIT license found in the
# LICENSE file in the root directory of this source tree.

# AMD Zen2 (Family 17h, e.g. EPYC "Rome") top-down + MPKI collector.
#
# This is a deliberately trimmed, core-PMU-only profile so it works on hosts
# that expose no uncore PMU (amd_l3 / amd_df), such as virtual machines. It
# collects exactly what the PROFILING.md metric list needs:
#   - Top-down L1 (frontend / backend / retiring / bad speculation)
#   - IPC, CPU utilization
#   - L1-D / L1-I / L2 (code+data) MPKI
#   - L1-ITLB / L1-DTLB / L2-TLB MPKI
#   - Branch-predictor (mispredict) and BTB MPKI
# LLC MPKI is intentionally omitted: it requires the amd_l3 uncore PMU, which is
# unavailable here.
#
# Events are packed into four <=6-event {} groups so each group co-schedules on
# the 6 general-purpose Zen2 PMCs with no intra-group multiplexing (ratios whose
# numerator and denominator share a group are therefore skew-free). With four
# groups rotating, each is enabled ~1/4 of the time.

SOURCE="${BASH_SOURCE[0]}"
while [ -h "$SOURCE" ]; do
  DIR="$( cd -P "$( dirname "$SOURCE" )" && pwd )"
  SOURCE="$(readlink "$SOURCE")"
  [[ $SOURCE != /* ]] && SOURCE="$DIR/$SOURCE"
done
DIR="$( cd -P "$( dirname "$SOURCE" )" && pwd )"
ME="$(basename "$0")"
INTERVAL_SECS=5

# Disable NMI watchdog so it does not steal a PMC.
sysctl kernel.nmi_watchdog=0 >/dev/null

# --- Group 1: top-down level-1 (TMA). Exactly 6 events => no multiplexing. ----
# token-stall uses umask=0xff (full resource mask); do NOT use Zen5's 0x57/0x27
# masks -- on Zen2 those drop the memory-related backend stalls.
# dispatched-ops MUST be 0xab (all ops dispatched), NOT 0xaa/de_dis_uops_from_decoder:
# 0xaa only counts decoder+opcache sources and omits microcode-sequencer ops, so it
# undercounts vs retired (0xc1) on microcoded code (e.g. integer div) -- making
# BadSpec = (dispatched - retired) go negative. 0xab is the complete dispatched-op
# counter (Zen2 analog of Zen5 de_src_op_disp.all): a clean superset of retired ops
# and >retired under misspeculation. (0xab is undocumented in perf's json; verified
# empirically -- cross-check AMD Family 17h PPR PMCx0AB before relying further.)
TD_CYCLES_EV='cpu/event=0x76,umask=0,name=td_cycles/'
TD_RETIRED_OPS_EV='cpu/event=0xc1,umask=0,name=td_retired_ops/'
TD_DISPATCHED_OPS_EV='cpu/event=0xab,umask=0xff,name=td_dispatched_ops/'
TD_OP_QUEUE_EMPTY_EV='cpu/event=0xa9,umask=0,name=td_op_queue_empty/'
TD_TOKEN_STALL_PART1_EV='cpu/event=0xae,umask=0xff,name=td_token_stall_part1/'
TD_TOKEN_STALL_PART2_EV='cpu/event=0xaf,umask=0xff,name=td_token_stall_part2/'
TOPDOWN_L1_GROUP="{${TD_CYCLES_EV},${TD_RETIRED_OPS_EV},${TD_DISPATCHED_OPS_EV},${TD_OP_QUEUE_EMPTY_EV},${TD_TOKEN_STALL_PART1_EV},${TD_TOKEN_STALL_PART2_EV}}"

# --- Group 2: IPC + shared instr/cycles denominators + L1 + L1-TLB ------------
# cycles/instructions live here once and are the shared denominator for every
# MPKI (their cross-group extrapolation is accurate because they are smooth).
L1_DC_MISSES_EV='cpu/event=0x41,umask=0x1f,name=l1_dc_misses/'
L1_IC_MISSES_EV='cpu/event=0x64,umask=0x07,name=l1_ic_misses/'
ITLB_MISSES_EV='cpu/event=0x84,umask=0,name=itlb_misses/'
DTLB_MISSES_EV='cpu/event=0x45,umask=0x0f,name=dtlb_misses/'
CORE_BASE_GROUP="{cycles,instructions,${L1_DC_MISSES_EV},${L1_IC_MISSES_EV},${ITLB_MISSES_EV},${DTLB_MISSES_EV}}"

# --- Group 3: L2 (code + data) + L2-ITLB --------------------------------------
L2_IC_REQUESTS_G1_EV='cpu/event=0x60,umask=0x10,name=l2_ic_requests_g1/'
L2_IC_REQUESTS_G2_EV='cpu/event=0x61,umask=0x18,name=l2_ic_requests_g2/'
L2_IC_HITS_EV='cpu/event=0x64,umask=0x06,name=l2_ic_hits/'
L2_DC_REQUESTS_EV='cpu/event=0x60,umask=0xc8,name=l2_dc_requests/'
L2_DC_HITS_EV='cpu/event=0x64,umask=0x70,name=l2_dc_hits/'
L2_ITLB_MISSES_EV='cpu/event=0x85,umask=0x07,name=l2_itlb_misses/'
L2_GROUP="{${L2_IC_REQUESTS_G1_EV},${L2_IC_REQUESTS_G2_EV},${L2_IC_HITS_EV},${L2_DC_REQUESTS_EV},${L2_DC_HITS_EV},${L2_ITLB_MISSES_EV}}"

# --- Group 4: branch predictor + BTB + L2-DTLB --------------------------------
# branch_mispred and branch_instructions share this group so the mispredict rate
# is computed from co-scheduled counters.
RETIRED_BRANCH_MISPRED_EV='cpu/event=0xc3,umask=0,name=retired_branch_mispred/'
RETIRED_BRANCH_INSTRUCTIONS_EV='cpu/event=0xc2,umask=0,name=retired_branch_instructions/'
BP_L2_BTB_CORRECT_EV='cpu/event=0x8b,umask=0,name=bp_l2_btb_correct/'
L2_DTLB_MISSES_EV='cpu/event=0x45,umask=0xf0,name=l2_dtlb_misses/'
BRANCH_GROUP="{${RETIRED_BRANCH_MISPRED_EV},${RETIRED_BRANCH_INSTRUCTIONS_EV},${BP_L2_BTB_CORRECT_EV},${L2_DTLB_MISSES_EV}}"

PERF_PID=
wrapup() {
  kill -INT "$PERF_PID"
}

trap wrapup SIGINT SIGTERM

perf_stat() {
  local ev="$1"
  local interval_ms="$2"
  perf stat -e "$ev" -x, -I "${interval_ms}" --per-socket -a --log-fd 1 &
  PERF_PID="$!"
  wait "$PERF_PID"
}

collect_counters() {
  local interval="$1"
  if [[ -n "$1" ]] && [[ "$1" -gt 0 ]]; then
    interval="$1"
  else
    interval="$INTERVAL_SECS"
  fi
  interval_ms="$((interval * 1000))"

  events="${TOPDOWN_L1_GROUP},${CORE_BASE_GROUP},${L2_GROUP},${BRANCH_GROUP}"

  # CPU utilization = mperf/tsc. These live on the free-running msr PMU, so they
  # do not contend with the core PMCs above. Only request them if present.
  if [[ -f /sys/bus/event_source/devices/msr/events/mperf ]]; then
    events="${events},msr/mperf,name=mperf/,msr/tsc,name=tsc/"
  fi

  perf_stat "${events}" "${interval_ms}"
}

collect_counters "$1" 2>/tmp/${ME}.err
