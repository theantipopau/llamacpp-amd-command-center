# ADR-005: AMD Hardware Intelligence Layer — recommendations, adapters, diagnostics, benchmarks

- **Status:** Accepted, 2026-10-08 (Phase B, defined before implementation)
- **Checklist:** §3 (typed commands), §4 (catalogue-driven recommendations),
  §9 (runtime abstraction), §16 (versioned state), §17 (diagnostics/benchmarks)
- **Builds on:** ADR-001 (shell), ADR-002 (runtime management), ADR-003 (state
  contract), ADR-004 (versioned catalogue)

## Context

Phase A established the truth layer: a typed state contract, snapshots, a typed
hardware profile, and a versioned catalogue loaded at runtime. The project is
still, at heart, a launcher: recommendation logic lives in three places
(`Get-ModelAssessment`, `Get-ModelForUseCase`, `Get-HardwareRecommendation`),
every code path assumes llama.cpp, "diagnostics" is a human screen with string
output, and there is no contract for recording measurements later.

The goal for Phase B is to become an AMD-aware local AI platform that
recommends, validates, installs and optimises workloads — with a trustworthy,
machine-readable intelligence layer. No UI work until all of the below exists.

## Decision

### 1. Recommendation engine (Task 1)

- **`Get-WorkloadRecommendations -Hardware [-Runtime] [-DetectionConfidence]`**
  is the single engine. Input: the typed hardware profile, the planned/installed
  runtime, and the hardware-detection confidence. Output (all derived from
  `catalog/*.json` + detection, **no hardcoded GPU names anywhere**):

```json
{
  "schema_version": 1,
  "recommended": {
    "fast":     { "tier": "fast", "model_id": "...", "model_name": "...",
                  "status": "...", "confidence": "...", "reason": "...",
                  "gpu_resident": true, "blockers": [] },
    "balanced": { ... },
    "maximum":  { ... }
  },
  "blockers": []
}
```

- **`status` distinguishes exactly four values:**
  - `unsupported` — the planned runtime cannot load the model
    (`Get-ModelRuntimeBlocker`) or it does not fit the memory budget
    (assessment `Recommended = false`).
  - `experimental` — the catalogue marks the model `Experimental`
    (ornith's own `COMMUNITY / EXPERIMENTAL` tag; the flag lives in
    `models.json`, not in code) and it is otherwise runnable.
  - `recommended` — fits the budget **and** is fully GPU-resident.
  - `supported` — fits the budget but spills into system RAM (runs, slower).
- **Tier selection** (blockers filtered first; if nothing is runnable the tier
  reports the top candidate with `status: unsupported` and its blocker):
  - `fast` — smallest tool-capable model (ties: catalogue order); fallback
    smallest model overall.
  - `balanced` — the existing default: highest-ranked GPU-resident tool model,
    else highest-ranked recommended model (identical to `Get-RecommendedModel`).
  - `maximum` — highest-ranked runnable model (catalogue `Rank` order).
- **`confidence`** (how sure we are of this recommendation, derived only from
  detection provenance and status): `low` when detection confidence is `low`
  or the status is `unsupported`; `high` when detection is `high` and status is
  `recommended`; `medium` otherwise. `reason` is assembled from measured
  quantities already in the assessment (headroom, budget, residency) — never
  invented numbers.
- Exposed as **`-Action Recommend`**: one JSON document, read-only, exits 0,
  `schema_version` 1; hardware-scan failure degrades to `hardware_error` +
  `recommended: null` (same rule as `-Action State`).
- `Get-HardwareRecommendation` (single backend/model pick) stays as the
  hardware-profile summary; the engine is the tiered superset.

### 2. Runtime abstraction layer (Task 2)

- Adapter **descriptors** come from `catalog/runtimes.json` → `adapters[]`
  (`id`, `display_name`, `status: active|stub`, `description`, `unknowns[]`) —
  data, not code. `Get-RuntimeAdapter [-Id]` returns one; `Get-RuntimeAdapters`
  returns all.
- The interface (PowerShell functions taking `-AdapterId`, mirroring the
  required names):
  - **`Get-RuntimeCapabilities`** — for llama.cpp: probes the installed
    `llama-server.exe --help` **once** against the catalogue-declared flag list
    (`llamacpp_capabilities[]`, each with `required` + `purpose`); returns
    `{ adapter, available, confidence, capabilities: [{flag, required, purpose,
    supported}] }` where `supported` is `true`/`false`/`null` (unknown when the
    exe is missing). Stubs return `available: false`, `confidence: "none"`.
  - **`Test-RuntimeAdapter`** (validate) — `{ adapter, ok, status:
    validated|degraded|blocked|not_implemented, confidence, warnings[],
    blockers[], unknowns[] }`. llama.cpp blockers: exe missing, hardware
    unsupported, a `required` capability absent. Stubs: `status:
    not_implemented`, `ok: false`, `blockers` naming the stub, `unknowns`
    copied from the catalogue — **never a fabricated verdict**.
  - **`Start-Runtime`** — llama.cpp delegates to the existing
    `Start-ActiveServer` (the proven start path) and converts its outcome to a
    typed result; stubs return `status: not_implemented` without side effects.
  - **`Stop-Runtime`** — contract encodes CLAUDE.md: no `llama-server`
    process → `not_running`; process present without `-Force` →
    `requires_confirmation` (it never kills); with `-Force` it performs the
    same process stop the window's fallback uses. The `-Force` kill was
    originally left unexercised (a name-based kill could take down the user's
    live server). It is now covered safely: the harness spawns a harmless
    stand-in process named `llama-server.exe` (a copy of `ping.exe`), forces
    the stop, asserts the process is gone, and **skips** if any real
    `llama-server` is already running so it can never touch a server it did not
    start (see the ADR-006 follow-up for the live run through the desktop).
  - **`Get-RuntimeHealth`** — llama.cpp: live `{ state: stopped|loading|
    running, port, base_url, process_ids, ok, confidence }` from the existing
    server probe; stubs: `{ state: "unknown", ok: false, confidence: "none",
    reason }`.
- Consumers migrate to adapters incrementally; `-Action State`'s `server`
  section stays frozen (ADR-003 contract). The application must stop caring
  which runtime is underneath: everything above the adapter layer speaks only
  the interface.

### 3. Diagnostics framework (Task 3)

- **`Get-DiagnosticReport`** builds one typed document, exposed as
  **`-Action Diagnose`** (read-only early exit, prints JSON, exit 0, no GUI,
  no string parsing):

```json
{ "schema_version": 1, "generated_at": "...", "command_center_version": "...",
  "runtime_health":  { "adapter", "state", "ok", "validation_status",
                       "capabilities_available", "confidence",
                       "warnings": [], "blockers": [] },
  "hardware_health": { "level", "confidence", "reasons": [],
                       "backend", "recommended_model", "error" },
  "model_health":    { "id", "present", "fit", "blocker", "confidence",
                       "warnings": [], "blockers": [] },
  "editor_health":   { "vscode": {...}, "continue": {...},
                       "llama_vscode": {...}, "confidence" },
  "warnings": [], "blockers": [],
  "overall": { "status": "ok|degraded|broken", "confidence" } }
```

- Every section carries validation status + confidence; aggregates roll up:
  any blocker → `broken`, else any warning → `degraded`, else `ok`.
- Never throws: a failed section degrades to `null` + `error` (ADR-003 rule).
- Blockers include: llama.cpp not installed, required capability missing,
  unsupported hardware, active model blocked by the runtime or missing on
  disk. Warnings include: support-level warnings (iGPU-only, Vulkan loader
  missing), process up but unhealthy, no active model, VS Code connected to a
  different model. A stopped server is **not** a problem (neutral state).

### 4. Benchmark framework (Task 4)

- New `benchmarks/` directory with a **stable, versioned contract only** —
  no numbers are recorded in this phase:
  - `benchmark.schema.json` — JSON-Schema-style description, `schema_version`
    1, nullable numeric fields (`ttft_ms`, `tokens_per_second`,
    `memory_peak_mb`), nullable context fields (`runtime`, `model`,
    `timestamp`).
  - `template.json` — the all-null template; every measurement field is
    `null`. **No fabricated data, ever.**
  - `README.md` — provenance rules: results may only be populated by a real
    measurement run, which must record runtime adapter, model id, catalogue
    revisions and timestamp.
- Later benchmark work writes result files that validate against this schema;
  the harness asserts the contract itself (existence, shape, all-null
  template).

## Non-goals (this phase)

- No React/Tauri/dashboard/visual hardware display/theme work (explicit stop
  conditions).
- No second runtime implemented — Lemonade and Strata stay structured stubs;
  their `unknowns` are documented, not guessed.
- No benchmark numbers, no fabricated measurements.
- `-Action State` schema unchanged (additive only, and nothing added this
  phase goes into it).

## Consequences

- One engine answers "what should this PC run?", one interface answers "what
  runtime is underneath?", one document answers "is this install healthy?",
  one schema answers "how do we record speed later?".
- Tests prove the no-hardcoded-GPU-names rule behaviourally (identical
  recommendations for machines differing only in GPU name), prove stubs never
  fabricate verdicts, and drive `-Action Diagnose`/`-Action Recommend` through
  subprocess JSON parsing.
- `Stop-Runtime -Force` killing a process is now exercised by the harness with
  a stand-in `llama-server.exe`, guarded to skip whenever a real server is
  running; the desktop's opt-in live test (`cargo test -- --ignored
  live_start_stop`) additionally drives the same path against a server it
  started itself. Recorded in the validation matrix as a pass.
