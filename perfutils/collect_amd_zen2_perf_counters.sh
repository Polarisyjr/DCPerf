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
# This script ships TWO event-group layouts and picks one at runtime:
#
#   * 6-PMC layout (LAYOUT_6PMC): four <=6-event {} groups, the original packing
#     for bare-metal Zen2, which exposes 6 general-purpose PMCs. Each group fills
#     the 6 PMCs with no intra-group multiplexing; with four groups rotating each
#     is enabled ~1/4 of the time.
#
#   * 4-PMC layout (LAYOUT_4PMC): six <=4-event {} groups, for virtualized hosts
#     (e.g. Azure / Hyper-V) that expose only 4 GP PMCs. A {} group is scheduled
#     atomically, so a 6-event group on a 4-PMC host is dropped wholesale and perf
#     reports every member as "<not counted>". Capping each group at 4 events keeps
#     it schedulable; with six groups rotating each is enabled ~1/6 of the time.
#
# Selection: $ZEN2_PMC_LAYOUT (=6 or =4) forces a layout; otherwise pick_event_set()
# probes whether a 6-event group co-schedules and falls back to the 4-PMC layout if
# not. Either way perf scales each group's counts to a full-interval estimate, so
# cross-group ratios stay accurate for steady-state workloads.
#
# Co-scheduling rule honored by both layouts: a ratio is skew-free only if BOTH its
# operands live in the same group, so operand *pairs that are both bursty* are kept
# together (IPC = instr/cycles; the four top-down terms; L2 miss%; branch-mispredict%),
# while every MPKI divides by `instructions`, which -- being smooth -- lives in exactly
# one group and cross-extrapolates. NOTE: the post-processor groups rows by event
# *name*, so each event name must appear in exactly ONE group per layout (no duplicating
# `instructions`/`cycles` across groups, or get_group() would concatenate them).

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

# Event encodings (unchanged from the 6-PMC profile) -------------------------
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
L1_DC_MISSES_EV='cpu/event=0x41,umask=0x1f,name=l1_dc_misses/'
L1_IC_MISSES_EV='cpu/event=0x64,umask=0x07,name=l1_ic_misses/'
ITLB_MISSES_EV='cpu/event=0x84,umask=0,name=itlb_misses/'
DTLB_MISSES_EV='cpu/event=0x45,umask=0x0f,name=dtlb_misses/'
L2_IC_REQUESTS_G1_EV='cpu/event=0x60,umask=0x10,name=l2_ic_requests_g1/'
L2_IC_REQUESTS_G2_EV='cpu/event=0x61,umask=0x18,name=l2_ic_requests_g2/'
L2_IC_HITS_EV='cpu/event=0x64,umask=0x06,name=l2_ic_hits/'
L2_DC_REQUESTS_EV='cpu/event=0x60,umask=0xc8,name=l2_dc_requests/'
L2_DC_HITS_EV='cpu/event=0x64,umask=0x70,name=l2_dc_hits/'
L2_ITLB_MISSES_EV='cpu/event=0x85,umask=0x07,name=l2_itlb_misses/'
RETIRED_BRANCH_MISPRED_EV='cpu/event=0xc3,umask=0,name=retired_branch_mispred/'
RETIRED_BRANCH_INSTRUCTIONS_EV='cpu/event=0xc2,umask=0,name=retired_branch_instructions/'
BP_L2_BTB_CORRECT_EV='cpu/event=0x8b,umask=0,name=bp_l2_btb_correct/'
L2_DTLB_MISSES_EV='cpu/event=0x45,umask=0xf0,name=l2_dtlb_misses/'

# =========================== 6-PMC layout (bare metal) ========================
# Four <=6-event groups; each fills all 6 GP PMCs with no intra-group multiplexing.
# top-down level-1: all six TMA inputs co-scheduled => the slot decomposition sums
# to ~100% by construction (skew-free).
PMC6_TOPDOWN_GROUP="{${TD_CYCLES_EV},${TD_RETIRED_OPS_EV},${TD_DISPATCHED_OPS_EV},${TD_OP_QUEUE_EMPTY_EV},${TD_TOKEN_STALL_PART1_EV},${TD_TOKEN_STALL_PART2_EV}}"
# IPC + the single instr/cycles MPKI denominator + L1 + L1-TLB.
PMC6_CORE_GROUP="{cycles,instructions,${L1_DC_MISSES_EV},${L1_IC_MISSES_EV},${ITLB_MISSES_EV},${DTLB_MISSES_EV}}"
# L2 code + data + L2-iTLB.
PMC6_L2_GROUP="{${L2_IC_REQUESTS_G1_EV},${L2_IC_REQUESTS_G2_EV},${L2_IC_HITS_EV},${L2_DC_REQUESTS_EV},${L2_DC_HITS_EV},${L2_ITLB_MISSES_EV}}"
# branch predictor + BTB + L2-dTLB; mispred & branch instructions co-scheduled.
PMC6_BRANCH_GROUP="{${RETIRED_BRANCH_MISPRED_EV},${RETIRED_BRANCH_INSTRUCTIONS_EV},${BP_L2_BTB_CORRECT_EV},${L2_DTLB_MISSES_EV}}"
LAYOUT_6PMC="${PMC6_TOPDOWN_GROUP},${PMC6_CORE_GROUP},${PMC6_L2_GROUP},${PMC6_BRANCH_GROUP}"

# =========================== 4-PMC layout (VM / Hyper-V) ======================
# --- Group 1: top-down occupancy (Retiring / BadSpec / no-dispatch slots) ------
# {td_cycles,td_retired_ops,td_dispatched_ops} co-scheduled => Retiring = ret/(6*cyc),
# BadSpec = (disp-ret)/(6*cyc) and the no_dispatch slot deficit (6*cyc-disp) are all
# skew-free. l1_dc_misses rides the free 4th slot (its MPKI cross-extrapolates).
TD_OCCUPANCY_GROUP="{${TD_CYCLES_EV},${TD_RETIRED_OPS_EV},${TD_DISPATCHED_OPS_EV},${L1_DC_MISSES_EV}}"

# --- Group 2: top-down stall split (Frontend vs Backend share) -----------------
# {op_queue_empty,token_stall_1,token_stall_2} co-scheduled => the FE/BE apportioning
# ratio opq/(opq+tok) is skew-free; it multiplies the G1 no_dispatch fraction (two
# smooth ratios, accurate across groups). l1_ic_misses rides the free 4th slot.
TD_STALL_GROUP="{${TD_OP_QUEUE_EMPTY_EV},${TD_TOKEN_STALL_PART1_EV},${TD_TOKEN_STALL_PART2_EV},${L1_IC_MISSES_EV}}"

# --- Group 3: IPC + the single instructions/cycles denominator + L1-TLB --------
# cycles/instructions live here once (IPC is skew-free) and are THE shared MPKI
# denominator. itlb/dtlb sit here too, so iTLB/dTLB MPKI are additionally skew-free.
CORE_BASE_GROUP="{cycles,instructions,${ITLB_MISSES_EV},${DTLB_MISSES_EV}}"

# --- Group 4: L2 code (instruction side) + L2-ITLB -----------------------------
# {l2_ic_requests_g1,l2_ic_requests_g2,l2_ic_hits} co-scheduled => L2 code miss%
# (misses=(g1+g2)-hits over accesses=g1+g2) is skew-free.
L2_CODE_GROUP="{${L2_IC_REQUESTS_G1_EV},${L2_IC_REQUESTS_G2_EV},${L2_IC_HITS_EV},${L2_ITLB_MISSES_EV}}"

# --- Group 5: L2 data side + L2-DTLB -------------------------------------------
# {l2_dc_requests,l2_dc_hits} co-scheduled => L2 data miss% is skew-free.
L2_DATA_GROUP="{${L2_DC_REQUESTS_EV},${L2_DC_HITS_EV},${L2_DTLB_MISSES_EV}}"

# --- Group 6: branch predictor + BTB -------------------------------------------
# {retired_branch_mispred,retired_branch_instructions} co-scheduled => mispredict
# rate is skew-free. Mispred/BTB MPKI divide by instructions (G3, cross-extrapolated).
BRANCH_GROUP="{${RETIRED_BRANCH_MISPRED_EV},${RETIRED_BRANCH_INSTRUCTIONS_EV},${BP_L2_BTB_CORRECT_EV}}"
LAYOUT_4PMC="${TD_OCCUPANCY_GROUP},${TD_STALL_GROUP},${CORE_BASE_GROUP},${L2_CODE_GROUP},${L2_DATA_GROUP},${BRANCH_GROUP}"

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

# Echo the event string for whichever layout this host can actually schedule.
# $ZEN2_PMC_LAYOUT (6|4) forces the choice; otherwise probe a 6-event {} group
# against a short CPU-bound burst (an idle or too-short window also yields
# "<not counted>", so we must keep a core busy during the probe) and fall back
# to the 4-PMC layout when the group is dropped.
pick_event_set() {
  case "${ZEN2_PMC_LAYOUT:-}" in
    6) echo "$LAYOUT_6PMC"; return ;;
    4) echo "$LAYOUT_4PMC"; return ;;
  esac
  local probe="${PMC6_CORE_GROUP}"
  local out
  out="$(perf stat -e "$probe" -a -- \
         bash -c 'n=0; while ((n<30000000)); do ((n++)); done' 2>&1)"
  if echo "$out" | grep -q "not counted"; then
    echo "$LAYOUT_4PMC"
  else
    echo "$LAYOUT_6PMC"
  fi
}

collect_counters() {
  local interval="$1"
  if [[ -n "$1" ]] && [[ "$1" -gt 0 ]]; then
    interval="$1"
  else
    interval="$INTERVAL_SECS"
  fi
  interval_ms="$((interval * 1000))"

  events="$(pick_event_set)"

  # CPU utilization = mperf/tsc. These live on the free-running msr PMU, so they
  # do not contend with the core PMCs above. Only request them if present.
  if [[ -f /sys/bus/event_source/devices/msr/events/mperf ]]; then
    events="${events},msr/mperf,name=mperf/,msr/tsc,name=tsc/"
  fi

  perf_stat "${events}" "${interval_ms}"
}

collect_counters "$1" 2>/tmp/${ME}.err
