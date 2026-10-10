# Benchmark results

Last updated: 2026-10-09 (Phase C).

## Status: first measured numbers exist, and they contradict an old claim

Phase C ran the first real measurements with `benchmarks/run-local-benchmark.py` against a
live server, and recorded them at
[benchmarks/results/2026-10-08-qwen3.5-9b.json](../../benchmarks/results/2026-10-08-qwen3.5-9b.json)
(schema `benchmarks/benchmark.schema.json`, `schema_version` 1).

| Measurement | Value | Notes |
|---|---|---|
| Time to first token (median of 3) | **235.2 ms** | 264.7 / 235.2 / 191.5 ms |
| Generation throughput (median of 3) | **13.31 tokens/s** | 11.08 / 13.31 / 13.70 tok/s |
| Peak working set | **10,052.8 MiB** | `llama-server` peak since start, so it includes loading |
| Setup | Qwen3.5 9B (Q4_K_M, alias `qwen3.5:9b`), 64k context × 2 slots, 33/33 layers on the GPU | `/props` + `-Action State` |
| Runtime | ROCm `rocm-7.2.1-b8407` | `-Action State` |
| Hardware | RX 9070 XT (15.8 GiB dedicated VRAM), Ryzen 7 9800X3D, 31.2 GiB RAM | typed hardware profile |
| Desktop during the runs | Unreal Editor, Chrome, Discord, Firefox, Claude, Freebuff | not a clean room |

The earlier "~45–90 tokens/s" figure in this table **was not reproduced**: 13.31 tok/s is
the measured median on this machine, with a loaded desktop. It is recorded here as the
honest floor, not replaced by a nicer number. Re-measuring on an idle desktop is Phase D
work; until then treat 45–90 t/s as unverified.

**Phase A ran no llama-bench or llama-server throughput measurements.** Numbers from
before Phase C below are still prior-session or publisher figures, never re-verified.

## Figures recorded elsewhere, with provenance

| Figure | Source | Label |
|---|---|---|
| Qwen3.5 9B Q4_K_M on RX 9070 XT: ~45–90 tokens/s generation, 64k context, fully VRAM-resident | README model table; detailed run notes in `notes/chatlog.md` | **Prior-session local observation, not re-run in Phase A — unverified for this release** |
| Prompt processing ~3,160 t/s; generation ~71 t/s (one prior session) | `notes/chatlog.md` | Prior-session, single run, unverified |
| Qwen3.8 27B on 16 GB card: ~4–7 tokens/s (spills to RAM) | README, `notes/reddit-post.md` | Prior-session, unverified |
| Strata v0.1.40.3 performance claims | Strata publisher README | **Publisher-reported, unverified — never measured here** |
| Lemonade, KTransformers, GAIA performance | Project homepages | Publisher-reported, unverified |
| AMD ROCm package "validated" for llama.cpp | AMD docs | AMD's claim; local evidence is limited to device enumeration + prior-session runs on b8407 |

## What would make a number admissible here

1. Command line exactly as run (llama-bench or `/v1/chat/completions` payload, context
   size, `--parallel`, slots).
2. Engine build (tag + commit), backend (ROCm/Vulkan/CPU), driver version, device.
3. Date, power state (games closed, GPU idle), and the raw output log path.
4. Multiple runs with the spread reported — no single-run headlines.

## Planned benchmark work (Phase E, not started)

- Reproducible prompt/generation benchmark for the recommended model per hardware
  profile, stored here with raw logs under `notes/` (gitignored) and summaries here.
- Idle-unload (`--sleep-idle-seconds`) VRAM reclamation measured before/after.
- iGPU/APU/NPU experiments (§14) only with before/after measurements; default remains
  "dedicated Radeon only" regardless of results unless a benefit is demonstrated.
