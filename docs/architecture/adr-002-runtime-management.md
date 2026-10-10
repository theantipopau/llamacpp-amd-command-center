# ADR-002: Runtime management — one llama.cpp adapter, versioned installs, delegated managers deferred

- **Status:** Accepted, 2026-10-08 (Phase A)
- **Checklist:** §8 (runtime adapters), §9 (process supervisor)

## Context

Checklist §8 asks for a common adapter interface (capabilities, install, validate, start,
stop, health, logs, benchmark), a comparison of a direct adapter with a delegated
runtime-management approach (Lemonade), a router decision (llama-swap vs an
application-owned supervisor), and an experimental gate for Strata. The evidence record
(`docs/research/upstream-evidence.md`) verified only llama.cpp end to end on this
hardware; Lemonade, Strata and llama-swap were investigated but not validated locally.

## Decision

1. **Direct llama.cpp adapter first**, expressed as an interface *concept* in
   PowerShell: capability probe (`Test-LlamaServerSupports` runs `--help` against the
   installed build and checks for the literal flag), install
   (`Ensure-LlamaCppInstalled`), validate (`llama-server --list-devices`), start
   (`Start-ActiveServer`/generated launcher), stop (launcher-owned only), health
   (`/health` + real generation in `Test-LocalServer`), logs (`logs\`), benchmark
   (deferred to Phase E). Runtime-specific flags stay inside `Get-ServerArguments` —
   no other code may build llama.cpp flags.
2. **Versioned installs with rollback.** Runtime stages into `current\`, swaps with
   `current.bak`, restores the previous build on any failure, records
   `installation.json` (tag/asset/sha256/backend). A failed runtime upgrade never
   touches `models\` (checklist §8 acceptance). `ROCmLatest` (llama.cpp's own build)
   stays opt-in with a device-check rollback; AMD's ROCm 7.2.1 package remains the
   default backend for supported Radeon dGPUs; Vulkan is the portable fallback.
3. **No delegated runtime manager yet.** Lemonade (AMD-sponsored, Apache-2.0) and
   llama-swap are **deferred**: adopting either duplicates install/rollback behaviour
   this project already has, before any local validation exists. Re-evaluate in Phase E
   with a written ADR update; keep them out of the stable path until then.
4. **Strata stays experimental.** Publisher benchmarks are unverified; Strata may only
   be evaluated behind an explicit experimental gate that cannot replace the stable
   path silently (checklist §19 Phase E gate).
5. **Application-owned supervisor, no router yet.** Single-model supervisor with a
   defined lifecycle (`stopped → starting → ready → stopping → failed`) built on the
   existing status/health probes; PID-based ownership and port-conflict handling are
   Phase B/C work (see ADR-003 for the state contract they publish). llama-swap is not
   added while there is one model and one endpoint — avoid redundant supervisors.

## Consequences

- `Get-ServerArguments` remains the only place flags are constructed (existing rule,
  now an ADR-level contract).
- Experimental engines remain isolated: they may not write `active-model.json`,
  launchers, or editor integrations until validated.
- Acceptance for §8 ("a failed runtime upgrade can be rolled back without
  re-downloading model weights") is met by the `current`/`current.bak` swap and is
  regression-tested for the launcher/device logic; a live failed-upgrade drill is
  recorded in `docs/testing/validation-matrix.md` as not yet run.

## Revisit triggers

- A Lemonade/llama-swap evaluation with local evidence (Phase E).
- Multi-model concurrent serving (would justify a router and alias endpoint).
