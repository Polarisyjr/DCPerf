// Copyright (c) Meta Platforms, Inc. and affiliates.
//
// This source code is licensed under the MIT license found in the
// LICENSE file in the root directory of this source tree.
//
// Microbenchmarks that each drive a distinct Zen2 top-down (TMA) bucket, used by
// validate_zen2_tma.py to regression-test the Zen2 L1 decomposition in
// ../../generate_amd_perf_report.py. Mode is selected by argv[1].
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#define ITERS 2000000000ULL

// retire: 4 independent ALU reductions, predictable, no memory -> Retiring-heavy.
static uint64_t bench_retire(void) {
    uint64_t a = 1, b = 2, c = 3, d = 4;
    for (uint64_t i = 0; i < ITERS; i++) { a += i; b ^= a; c += b; d ^= c; }
    return a ^ b ^ c ^ d;
}

// aluchain: one long loop-carried multiply dependency chain -> Backend(latency).
static uint64_t bench_aluchain(void) {
    uint64_t a = 0xdeadbeef, d = 2654435761ULL;
    for (uint64_t i = 1; i < ITERS / 2; i++) { a += (a * 2654435761ULL + i) ^ (d | 1); d += i; }
    return a;
}

// ucode: same chain but with an integer divide each iter. div retires ops that
// 0xAA (decoder+opcache) never counts -> proves why dispatched must be 0xAB.
static uint64_t bench_ucode(void) {
    uint64_t a = 0xdeadbeef, d = 2654435761ULL;
    for (uint64_t i = 1; i < ITERS / 2; i++) { a += (a * 2654435761ULL + i) / (d | 1); d += i; }
    return a;
}

// membound: dependent pointer-chase over a buffer >> LLC -> Backend(memory).
static uint64_t bench_membound(void) {
    size_t n = 1 << 26; // 64M * 8B = 512MB
    size_t *arr = malloc(n * sizeof(size_t));
    for (size_t i = 0; i < n; i++) arr[i] = i;
    for (size_t i = n - 1; i > 0; i--) {
        size_t j = ((uint64_t)rand() * rand()) % (i + 1);
        size_t t = arr[i]; arr[i] = arr[j]; arr[j] = t;
    }
    size_t idx = 0; uint64_t acc = 0;
    for (uint64_t i = 0; i < ITERS / 20; i++) { idx = arr[idx]; acc += idx; }
    free(arr);
    return acc;
}

// badspec: data-dependent unpredictable branch -> Bad Speculation + FE resteers.
static uint64_t bench_badspec(void) {
    size_t n = 1 << 22; unsigned char *b = malloc(n);
    for (size_t i = 0; i < n; i++) b[i] = rand() & 1;
    uint64_t acc = 0;
    for (uint64_t i = 0; i < ITERS / 2; i++) { if (b[i & (n - 1)]) acc += 3; else acc ^= 7; }
    free(b);
    return acc;
}

int main(int argc, char **argv) {
    if (argc < 2) { fprintf(stderr, "usage: %s <retire|aluchain|ucode|membound|badspec>\n", argv[0]); return 2; }
    uint64_t r = 0;
    const char *m = argv[1];
    if (!strcmp(m, "retire")) r = bench_retire();
    else if (!strcmp(m, "aluchain")) r = bench_aluchain();
    else if (!strcmp(m, "ucode")) r = bench_ucode();
    else if (!strcmp(m, "membound")) r = bench_membound();
    else if (!strcmp(m, "badspec")) r = bench_badspec();
    else { fprintf(stderr, "unknown mode: %s\n", m); return 2; }
    printf("%llu\n", (unsigned long long)r);
    return 0;
}
