# Benchmarks

This directory holds the **benchmark contract** for the AMD hardware
intelligence layer (ADR-005). It contains no measurements yet, and that is
deliberate.

## Files

| File | Purpose |
|---|---|
| `benchmark.schema.json` | The versioned schema (`schema_version` 1) every result must satisfy. |
| `template.json` | The empty template: every measurement field is `null`. |
| `run-local-benchmark.py` | Runs the measurements against a **live** server and writes a result file. Stdlib only. |
| `results/<date>-<model>.json` | Real evidence entries. Each one names its hardware, runtime, model and what else the desktop was doing. |

## Running a measurement

Start the server first (the desktop window's **Start the AI**, `Chat.cmd`, or
`-Action Runtime -RuntimeAction start`), then:

```powershell
python benchmarks/run-local-benchmark.py                    # 3 runs, median reported
python benchmarks/run-local-benchmark.py --runs 5 --max-tokens 256 --dry-run
```

The runner reads `-Action State` for the runtime/model/hardware labels and the server's
`/props` endpoint for the slot count and context, so a number can never be labelled with a
setup it did not run on. It never starts or stops the server itself.

## First evidence entry

`results/2026-10-08-qwen3.5-9b.json` — Qwen3.5 9B (Q4_K_M) on an RX 9070 XT via
ROCm `rocm-7.2.1-b8407`, 64k context × 2 slots, 33/33 layers on the GPU: median **13.31
tokens/s**, median **235.2 ms** to first token, peak working set **10,053 MiB**, with the
three individual runs recorded (11.08 / 13.31 / 13.70 tok/s) and the windows that were open
at the time (Unreal Editor, Chrome, Discord, Firefox, Claude, Freebuff). Not a clean room,
and not rounded up.

## Rules

1. **No fabricated data.** A number may only appear here when a real run on
   real hardware produced it. Publisher claims, estimates and model-card figures
   never enter this directory; they stay labelled *unverified* in
   `docs/testing/benchmark-results.md`.
2. **Provenance required.** A populated result must record the runtime adapter
   (id + version/tag), the catalogue model id, and a UTC timestamp, so the
   number can be reproduced later.
3. **Versioned.** Results declare `schema_version`; a breaking change to the
   contract increments it and older results remain readable by consumers that
   ignore unknown fields (same rule as the state contract, ADR-003).

## Later

Result files validate against `benchmark.schema.json`; the test harness asserts the
contract itself (schema shape, template keys match the schema, every template measurement
field null). The harness still never asserts on measurement *values* — those are evidence,
not a test fixture, and re-running on different hardware must never fail CI.
