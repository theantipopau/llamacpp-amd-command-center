# Implementation status

Living progress record for the AMD Local AI Master Agent Checklist work in this
checkout. Updated after each slice (checklist §20). States: **not started**,
**in progress**, **implemented**, **validated**, **blocked**, **deferred**.

Last updated: 2026-10-10 (Phase D, slices D-1 settings + D-2 model library + the
settings VRAM-effect line + the runtime-update action and the capture gate).

## Status table

| Task | Phase | What | State |
|---|---|---|---|
| D-3 | D | Settings screen VRAM effect: `gpu_vram_gib`/`active_model_gib` in the Settings document, `describeIdleVramEffect` wording (0.9 × VRAM − model, the engine's own rule) | validated |
| D-4 | D | Responsive window layout: fluid type/spacing, two-column model library on wide windows, stacked fact rows below 640 px; verified at 780 px and 1560 px by the capture tool | validated |
| D-5 | D | Repeatable window capture: `Capture-DesktopScreenshot.ps1` (PrintWindow, no SendKeys) + harness gate that re-verifies the artifact every run, honest SKIP without a window | validated |
| D-6 | D | Runtime update: `-RuntimeAction update` adapter entry (requires_confirmation → single-source updater) + desktop "Update llama.cpp" button | validated — both paths ran live (2026-10-10): AMD package re-verified in place; ROCmLatest downloaded b11429/ROCm 10.0, SHA-256 passed, GPU-visibility guard declined it correctly (needs AMD ROCm runtime libs installed separately) and restored b8407 with every model intact |
| A-1 | A | Upstream evidence record (checklist §1) | validated |
| A-2 | A | Baseline audit + feature-preservation matrix (§2) | validated |
| A-3 | A | Architecture decisions (§3): shell, runtime, state contract | validated |
| A-4 | A | Validation matrix and benchmark provenance (§17) | validated |
| A-5 | A | Confirmed-bug fix: Gemma 4 Q4_K_M catalog entry | validated |
| A-6 | A | Smallest complete slice: typed state contract `-Action State` (ADR-003) | validated |
| A-7 | A | One authoritative source: core state, status line as projection, window typed | validated |
| A-8 | A | State snapshotting (auto-capture + `-Action Snapshot`) | validated |
| A-9 | A | Typed hardware profile: cpu/memory/detection + support/confidence/recommendation | validated |
| A-10 | A | Versioned catalogue `catalog/*.json` loaded at runtime (ADR-004) | validated |
| B-1 | B | Architecture decision: hardware intelligence layer (ADR-005) | validated |
| B-2 | B | Recommendation engine: catalogue-driven workload tiers (`-Action Recommend`) | validated |
| B-3 | B | Runtime abstraction: llama.cpp active, Lemonade/Strata structured stubs | validated |
| B-4 | B | Diagnostics framework: typed health document (`-Action Diagnose`) | validated |
| B-5 | B | Benchmark contract: `benchmarks/` schema, no fabricated data | validated |
| C-1 | C | Desktop vertical slice: install/run/stop through the GUI | validated |
| D-1 | D | Settings surface: backend document + desktop screen (idle unload, use case) | validated |
| D-2 | D | Model library screen: backend Library document + download/activate/remove | validated |

## Entries

### A-1 — Upstream evidence record (checklist §1)
**State: validated** (2026-10-08)

- Changed files: `docs/research/upstream-evidence.md`, `tests/fixtures/catalog-evidence.json`
  (new), `.NOTES` re-verification block in `Install-LlamaCpp-AMD.ps1`.
- Verified: AMD ROCm 7.2.1 package still newest (565,651,083 bytes matches
  `$script:AmdRocmPackageSize`); llama.cpp stable v0.6.0 publishes only
  `nightly-tag.txt` so the script's fallback is correct; nightly b11481 asset
  names match the script's regexes; installed b8407 build supports every flag the
  script uses; all 9 catalog GGUF files exist at pinned Hugging Face revisions
  with Git LFS SHA-256 (recorded in the fixture); editor-integration schemas
  confirmed; research leads (Qwen3.8-Flash-Next, Liquid d1, Reflection Beam) and
  alternative engines (Strata, Lemonade, llama-swap, KTransformers, GAIA)
  verdicts recorded.
- Tests: the harness section "Catalog matches the recorded upstream evidence"
  asserts the fixture against the catalog (part of the 177 → 225 growth).
- Evidence: `docs/research/upstream-evidence.md`.
- Blockers: **no git metadata in this checkout** (not a git working tree), so
  §1's "confirm default branch/commit" cannot be satisfied — recorded as an
  evidence gap, not silently skipped.

### A-2 — Baseline audit + feature-preservation matrix (checklist §2)
**State: validated** (2026-10-08)

- Changed files: `docs/engineering/baseline-audit.md` (new).
- Contents: system inventory, feature map, file-ownership table (user-owned vs
  app-owned), security/robustness audit, baseline test capture, and the
  feature-preservation matrix (~16 behaviours with source location, risk,
  replacement component, migration test, status) plus the Phase A
  deliberate-change table.
- Evidence: baseline harness run **177 PASS / 0 FAIL** before any Phase A
  change.

### A-3 — Architecture decisions (checklist §3)
**State: validated** (2026-10-08)

- Changed files: `docs/architecture/adr-001-desktop-shell.md`,
  `adr-002-runtime-management.md`, `adr-003-state-contract.md` (new).
- ADR-001: keep PowerShell 5.1 + WPF near-term; Tauri deferred with revisit
  triggers. ADR-002: direct llama.cpp adapter first, versioned installs with
  `current`/`current.bak` rollback, other engines deferred/gated. ADR-003:
  typed, versioned application-state contract (`schema_version`, starts at 1,
  additive evolution, consumers ignore unknown fields; hardware failure degrades
  to `null` + `hardware_error`).
- ADR-003 is implemented by task A-6.

### A-4 — Validation matrix and benchmark provenance (checklist §17)
**State: validated** (2026-10-08)

- Changed files: `docs/testing/validation-matrix.md`,
  `docs/testing/benchmark-results.md` (new).
- The validation matrix labels every claim Simulated / Local / Untested and
  records release-gate requirements. The benchmark file explicitly states
  **no benchmarks were run in Phase A**; every throughput figure in the README
  (45–90 t/s, 3160 t/s prompt, 4–7 t/s) is labelled *prior-session, unverified*,
  and publisher figures (Strata, Lemonade) are labelled unverified third-party
  claims.

### A-5 — Gemma 4 catalog fix (confirmed bug)
**State: validated** (2026-10-08)

- Problem: the catalog referenced `gemma-4-12B-it-Q4_K_M.gguf`, which
  `ggml-org/gemma-4-12B-it-GGUF` does not publish (HTTP 404; only
  BF16/Q4_0/Q8_0 exist) — a guaranteed download failure for users.
- Changed files: `Install-LlamaCpp-AMD.ps1` (file + `ApproxGiB` 6.87), `README.md`
  and `docs/index.html` (7.5 GB → 6.9 GB, Q4_0 quant), fixture pinning the real
  file.
- Tests: evidence-fixture assertions in the harness; all catalog download URLs
  verified live at pinned revisions during A-1.

### A-6 — Typed state contract: `-Action State` (ADR-003's smallest complete slice)
**State: validated** (2026-10-08)

- Behaviour: `powershell -File Install-LlamaCpp-AMD.ps1 -Action State` prints
  exactly one JSON document and exits 0, before run logging, so asking for state
  can never write a log. Top-level fields: `schema_version` (1), `generated_at`,
  `command_center_version`, `install_root`, `runtime`, `model`, `server`,
  `models[]`, `settings`, `editors.vscode`, `desktop_shortcuts`, `hardware`,
  `hardware_error`.
- Changed files:
  - `Install-LlamaCpp-AMD.ps1`: `'State'` added to the `-Action` ValidateSet;
    new shared helpers `Get-ServerState`, `Get-VsCodeChatState`,
    `Get-DesktopShortcutState`, `Get-InstalledModelStates`,
    `Get-StateProperty`; new `Get-ApplicationState`; early-exit branch next to
    `Status`. `Get-CommandCenterStatus` and `Get-InstalledModelList` now consume
    the same helpers, so the string contracts and the JSON contract cannot
    drift — their output format is unchanged (7-field status line,
    `number|id|name|state` list lines).
  - `tests/Test-CommandCenter.ps1`: 35 new checks — a seeded deterministic
    install state, schema/typed-field assertions, JSON round-trip
    (arrays stay arrays, nulls stay null), status-line ↔ state-document drift
    checks, a simulated hardware-scan failure proving `hardware` degrades to
    `null` + `hardware_error` instead of throwing, and a subprocess run of
    `-Action State` against an empty temp install root asserting exit 0, one
    parseable JSON document, `schema_version` 1, and that the install folder is
    left completely untouched (read-only proof).
  - `README.md`: `State` row in the action table (docs/index.html has no action
    table; its Gemma row was already synced in A-5).
- Tests: `powershell.exe -NoProfile -ExecutionPolicy Bypass -File
  .\tests\Test-CommandCenter.ps1` → **260 PASS, 0 FAIL, exit 0** (log excerpt:
  the "Application state" and "-Action State subprocess" sections, all green).
  Live verification on this machine: empty temp install root (nulls, empty
  arrays) and the real install (`rocm-7.2.1-b8407`, Qwen3.5 9B active,
  Ornith blocked, 3 downloaded models) both produced valid documents parsed by
  an independent JSON reader.
- Evidence: ADR-003 (`docs/architecture/adr-003-state-contract.md`), the
  harness sections named above.
- Implementation note: PowerShell 5.1 semantics were measured, not assumed —
  `return ,$items` double-wraps when the caller uses `@(...)`
  (`[[]]` in JSON), so `Get-InstalledModelStates` uses a plain return with all
  callers wrapping in `@(...)`.
- Blockers: none.

### A-7 — One authoritative state source (migrate status-line consumers)
**State: validated** (2026-10-08)

- Behaviour: the state is built once in `Get-CoreApplicationState` (hardware-free,
  adds `idle_minutes`); `Get-ApplicationState` = core + schema/hardware with fields
  copied straight across; `Get-CommandCenterStatus` is a pure projection of the core
  (the 7-field line remains cmd.exe's serialization, which cannot parse JSON);
  `Get-GuiState` reads the typed core — the window no longer splits the status line.
  Duplicate parsing (`-split '\|'`, re-reading `active-model.json`/`installation.json`)
  is gone from every PowerShell consumer.
- Changed files: `Install-LlamaCpp-AMD.ps1`, `tests/Test-CommandCenter.ps1`.
- Tests: 7 new checks — state document is a superset of the core, `idle_minutes`
  matches the validator, line and window values equal the core verbatim, window mode
  still resolves `setup` without an exe; the pre-existing 7-field contract test still
  passes. Harness **298 PASS / 0 FAIL / exit 0**.
- Evidence: ADR-003 Amendment 1; harness section "Core state: the status line and the
  window are projections of one source".
- Blockers: none. The batch menu deliberately keeps the line (`read_status` contract,
  CLAUDE.md); it is a serialization of the same object, not a second source.

### A-8 — State snapshotting
**State: validated** (2026-10-08)

- Behaviour: `Save-StateSnapshot` writes the state document plus `snapshot_reason` to
  `<install>/state-history/state-<UTC>.json` (UTF-8, no BOM), keeps the newest
  `$script:StateSnapshotKeep` (40), and never throws. Auto-captured before
  `Activate`/`Install`/`Update`/`Uninstall`/`RemoveModel`/`Easy` (reason
  `before-<action>`); `-Action Snapshot` takes one manually and prints the path.
  `-Action State` stays strictly read-only.
- Changed files: `Install-LlamaCpp-AMD.ps1` (functions + ValidateSet + early exit +
  auto-capture before `Start-RunLogging`), `tests/Test-CommandCenter.ps1`, README
  `Snapshot` row, CLAUDE.md ownership rules.
- Tests: 10 new checks — retention prune (keep 3 of 5), newest-first listing with
  reasons, JSON round trip incl. arrays, every stored snapshot parses, subprocess
  manual snapshot (exit 0, path printed, full document with hardware), and a
  subprocess `Activate` on an empty root that fails *after* writing
  `before-Activate` (proves capture-before-change).
- Evidence: harness sections "State snapshots: history for diagnostics and rollback"
  and "-Action Snapshot: a manual write and an auto-capture before a change".
- Known limitation: a successful full `Uninstall` deletes `state-history` with the
  install folder; snapshots exist to diagnose what happened, and there is nothing left
  to diagnose after a clean removal.

### A-9 — Typed hardware profile
**State: validated** (2026-10-08)

- Behaviour: `Get-HardwareProfile` now also returns typed sections — `cpu`
  (name/cores/threads/vendor_amd), `memory.ram_gib`, `detection`
  (`gpu_source ∈ {dxgi, registry, wmi, mixed}`, `confidence ∈ {high, medium, low}`),
  `support` (`level ∈ {supported, warning, unsupported}`, `confidence`, `reasons[]`)
  via `Resolve-HardwareSupport`, `recommendation` (`backend ∈ {ROCm, Vulkan}`,
  `model_id`, `confidence`, `reason`) via `Get-HardwareRecommendation`,
  `HasDiscreteAmdGpu`, and per-GPU `Source`/`VramConfidence` (DXGI = high,
  registry = medium, WMI `AdapterRAM` = low — the uint32 4 GiB cap is why). All
  additive: no existing field renamed, `schema_version` stays 1.
- Support rules mirror existing enforcement instead of inventing policy: no Radeon →
  `unsupported` (the `Assert-HardwareForLlama` gate), iGPU-only or missing
  `vulkan-1.dll` → `warning`; confidence comes only from where detection data
  actually came from.
- Changed files: `Install-LlamaCpp-AMD.ps1`, `tests/Test-CommandCenter.ps1`,
  `catalog/hardware_profiles.json` (ROCm pattern + reasons moved here).
- Tests: 11 new checks — real-machine structural assertions (types, allowed value
  sets, recommendation model equals `Get-RecommendedModel`) plus pure verdicts on
  fakes (discrete supported with no reasons; no Radeon unsupported with a reason;
  iGPU-only + no loader = warning with both reasons; a 9070 XT class fake recommends
  ROCm + Qwen3.5 9B).
- Evidence: ADR-003 Amendment 1; ADR-004; harness section "Hardware profile: typed
  model with support, confidence and a recommendation".
- Blockers: none. Confidence/support/recommendation values are derivation rules, not
  measurements — no benchmark claims are made.

### A-10 — Versioned catalogue as runtime data
**State: validated** (2026-10-08)

- Behaviour: `catalog/models.json`, `runtimes.json`, `hardware_profiles.json` and
  `compatibility.json` are loaded at runtime by `Get-CatalogJson` (session-cached,
  preloaded at script start so a missing/broken file fails every action loudly with
  its path — no embedded fallback copy). Consumers: `Get-ModelCatalog`,
  `$script:AmdRocm*` initialisation, `Get-PlannedRuntime`, `Get-HardwareProfile`,
  `Get-ModelRuntimeBlocker` (rules replace the hardcoded b8407 condition, message
  unchanged). Files carry `schema_version`, `catalog_version`, `verified_on` and
  `verified_against`.
- Changed files: `catalog/*.json` (new), `Install-LlamaCpp-AMD.ps1`,
  `tests/Test-CommandCenter.ps1` (top vars + 11 checks), `.github/workflows/release.yml`
  (ZIP now ships `catalog/`), `README.md` (development layout + troubleshooting),
  `CLAUDE.md`, `docs/architecture/adr-004-versioned-catalogue.md` (new).
- Tests: 11 new checks (schema versions, nine models with id/file/rank, pinned AMD
  package facts 565,651,083 bytes / 2026-10-08 matching the evidence record, script
  vars matching the file, ROCm pattern present, compatibility rules present, blocker
  behaviour identical to the old inline logic for ROCm/Vulkan/unflagged models, and
  the missing-file error). All pre-existing catalogue/evidence/picker/launcher
  assertions now validate the shipped files — 298 total PASS.
- Evidence: ADR-004; harness section "Catalogue files: the single versioned source".
- Blockers: none. A lone copy of the `.ps1` outside the repository/ZIP is now
  intentionally unsupported (documented in ADR-004/README).

### B-1 — Hardware intelligence layer architecture (ADR-005)
**State: validated** (2026-10-08)

- Changed files: `docs/architecture/adr-005-hardware-intelligence-layer.md` (new).
- Defines: recommendation-engine contract (tier semantics, the four statuses
  `supported`/`recommended`/`experimental`/`unsupported`, confidence rules,
  blockers), the RuntimeAdapter interface (`GetRuntimeCapabilities`,
  `ValidateRuntime`, `StartRuntime`, `StopRuntime`, `RuntimeHealth`) mapped to
  `Get-RuntimeCapabilities`/`Test-RuntimeAdapter`/`Start-Runtime`/`Stop-Runtime`/
  `Get-RuntimeHealth`, the diagnostics document shape, the benchmark contract,
  and explicit non-goals (no UI, no fabricated numbers).
- Records the known-untested path: `Stop-Runtime -Force` never exercised by the
  harness (would kill a live server).

### B-2 — Recommendation engine (`-Action Recommend`)
**State: validated** (2026-10-08)

- Behaviour: `Get-WorkloadRecommendations` ranks the catalogue for `fast`,
  `balanced` and `maximum` workloads from GPU/VRAM/RAM/CPU, runtime availability
  and `catalog/*.json` only — no hardcoded GPU names (harness proves two
  hardware fakes differing only in GPU name produce byte-identical documents).
  Each tier carries `model_id`, `status`, `confidence`, `reason`, `blockers`;
  status derives from fit (VRAM residency/headroom), the catalogue
  `Experimental` flag (Ornith) and `Get-ModelRuntimeBlocker`; confidence derives
  from detection confidence plus fit. `Get-RecommendationDocument` wraps them
  with `schema_version`, `detection_confidence`, `hardware_error` and aggregate
  `blockers`.
- Changed files: `Install-LlamaCpp-AMD.ps1` (engine functions, `Recommend` in
  the `-Action` ValidateSet, read-only early exit before run logging),
  `catalog/models.json` (Ornith `Experimental: true`), `tests/Test-CommandCenter.ps1`,
  `README.md`, `CLAUDE.md`.
- Tests: 19 + 3 catalogue checks — tier presence/ids/statuses/confidences on a
  16 GB ROCm fake, the four status transitions (resident→recommended,
  spilling→supported, Experimental→experimental, blocker→unsupported),
  confidence rules (high/medium/low), nothing-fits degradation, GPU-name
  independence, experimental flag only on Ornith, adapter/capability catalogue
  shape. Live on this machine: exit 0, `fast=qwen3-4b/recommended/high`,
  `balanced=qwen3.5-9b/recommended/high`, `maximum=qwen3.8-27b/supported/medium`,
  no blockers.
- Blockers: none.

### B-3 — Runtime abstraction layer
**State: validated** (2026-10-08)

- Behaviour: `Get-RuntimeAdapters`/`Get-RuntimeAdapter` read `adapters[]` from
  `catalog/runtimes.json` (llamacpp `active`, lemonade/strata `stub`; unknown id
  throws). `Get-RuntimeCapabilities` claims nothing without an actual `--help`
  probe (`available=false`, `confidence=none`, all flags `null`, catalogue
  `llamacpp_capabilities` as the known shape). `Test-RuntimeAdapter` returns
  `validated`/`degraded`/`blocked` for llama.cpp and `not_implemented` with
  catalogue `unknowns` for stubs. `Start-Runtime`/`Stop-Runtime`/`Get-RuntimeHealth`
  are the only runtime entry points; stopping without `-Force` returns
  `requires_confirmation` and provably kills nothing (process count asserted
  unchanged); stub health is `unknown`/`none`, never guessed.
- Changed files: `Install-LlamaCpp-AMD.ps1`, `catalog/runtimes.json`
  (`adapters[]` + `llamacpp_capabilities[]`, verified against the flags
  `Get-ServerArguments` actually emits), `tests/Test-CommandCenter.ps1`.
- Tests: 13 checks — catalogue adapter statuses, unknown-id throw, capability
  honesty, blocked-when-not-installed, stub `not_implemented` + unknowns,
  start/stop stubs, stop-without-force never kills, live llama health
  `stopped|loading|running` at `high` confidence, failed start on an empty temp
  root.
- Known-untested gap: `Stop-Runtime -Force` (real kill) is deliberately not
  exercised — it would terminate the user's running server. Recorded in
  ADR-005 and the validation matrix, not claimed as a pass.

### B-4 — Diagnostics framework (`-Action Diagnose`)
**State: validated** (2026-10-08)

- Behaviour: `Get-DiagnosticReport` returns one typed document:
  `runtime_health` (adapter, state, `validation_status`, capability availability,
  confidence), `hardware_health` (support level/reasons, detection confidence),
  `model_health` (active model fit assessment), `editor_health` (VS Code, Continue,
  llama-vscode read through the existing typed helpers), plus document-level
  `warnings[]`, `blockers[]` and `overall {status, confidence}` with
  `status ∈ {ok, degraded, broken}`. Never throws; degrades to `hardware_error`
  like `State`. No string parsing, no GUI, read-only early exit.
- Changed files: `Install-LlamaCpp-AMD.ps1` (function + ValidateSet + early exit),
  `tests/Test-CommandCenter.ps1`, `README.md`.
- Tests: 16 checks — schema, all four sections, allowed value sets, arrays are
  arrays, JSON round-trip, overall roll-up (`broken` + blockers on an empty temp
  root), live subprocess exit 0. Live on this machine: `overall ok/high`,
  runtime `stopped/validated`, hardware `supported/ROCM`, no warnings/blockers.
- Blockers: none.

### B-5 — Benchmark contract (infrastructure only)
**State: validated** (2026-10-08)

- Changed files: `benchmarks/benchmark.schema.json` (draft-07, `schema_version` 1;
  required `ttft_ms`, `tokens_per_second`, `memory_peak_mb`, `runtime`, `model`,
  `timestamp`, all measurements `number|null`), `benchmarks/template.json` (all
  null), `benchmarks/README.md` (no-fabrication rules, provenance fields,
  versioning).
- Tests: 5 checks — files exist, schema version, required fields, template
  matches the schema exactly, every measurement field is `null`.
- Explicitly NOT done: no benchmark numbers were recorded (Phase B rule).

## Validation run (2026-10-08, after Phase B Task 5)

| Check | Command | Result |
|---|---|---|
| CRLF endings | python `(?<!\r)\n` over the 3 scripts | 0 lone LF (BOM intact) |
| AST parse (PS 5.1) | `Parser::ParseFile` script + tests | OK, 0 errors |
| PSScriptAnalyzer | `Invoke-ScriptAnalyzer -Severity Error`, both files | 0 errors |
| Offline harness | `powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tests\Test-CommandCenter.ps1` | 354 PASS, 0 FAIL, exit 0 |
| Batch smoke | `LLAMACPP_NO_PAUSE=1`, choices `x/5/8/0`, grep 5 markers | all present, `was unexpected at this time` = 0 |
| Live `-Action Recommend` | real install | exit 0; fast=qwen3-4b, balanced=qwen3.5-9b (both recommended/high), maximum=qwen3.8-27b (supported/medium), no blockers |
| Live `-Action Diagnose` | real install | exit 0; overall ok/high, runtime stopped/validated, hardware supported/high, no warnings or blockers |
| Live `-Action State` | empty temp root + real install | valid documents (14 fields), typed hardware, correct model states |
| Live `-Action Snapshot`/`Activate` | temp root | manual path printed; auto `before-Activate` written first, action then failed as expected |

Test growth: baseline **177** → evidence fixture **225** → state slice
**260** → core/catalogue/hardware/snapshot **298** → Phase B intelligence
slice **354** (+56: 3 catalogue, 19 recommendation engine, 13 runtime
adapters, 16 diagnostics, 5 benchmark contract) → Phase C robustness +
desktop backend **404** (+50: 15 path/Unicode/launcher, 11 staged download,
11 port ownership, 7 `-Action Runtime`, 2 diagnostics port ownership, 3
forced-stop, 1 recorded-benchmark contract). The harness still ends with the
guard that the real `chatLanguageModels.json` is unchanged.

---

## Phase C entries (2026-10-09)

### C-1 — Robustness gaps closed before any UI code

| Gap | What changed | Evidence |
|---|---|---|
| Paths with spaces and Unicode | Generated `.cmd` launchers no longer embed the install root (`%~dp0` + `ConvertTo-LauncherArgument`), JSON actions write UTF-8 without a BOM straight to the output stream, and arguments stay arrays | the generated launcher is byte-checked as pure ASCII under a spaced/CJK root, `cmd.exe` is made to run it (stand-in server) and report the exit line, and `-Action State` is round-tripped through a subprocess with `StandardOutputEncoding = UTF-8` |
| Download resume and checksum | Downloads stage in `<root>\downloads\staging`, promote by rename only after size + SHA-256 pass, delete the staged file on failure while reporting expected vs actual hash, adopt a legacy `.part`, and restart exactly once when the server refuses to resume (curl 33) | 11 harness checks with a scripted downloader: fresh, resent-on-mismatch, resumed, refuse-then-restart, short file, legacy `.part` |
| Port conflict | `Resolve-PortConflict` classifies the listener as `free`/`owned`/`conflict`; `Start-ActiveServer` refuses a foreign owner with port + PID and never kills or reroutes; diagnostics carry the same verdict in `runtime_health.port_owner` | real `TcpListener` squatters in the harness: free, conflict with the owning PID, owned by PID and by name, the start action refusing end to end, and the blocker appearing in diagnostics |

### C-2 — ADR-006 desktop stack (written before UI code)

`docs/architecture/adr-006-desktop-stack.md` decides Tauri v2 + React/TypeScript + a Rust
supervisor, defines the IPC contract (one subprocess per action, one UTF-8 JSON document on
stdout, raw detail preserved for expansion), the one-command dev workflow, how UI changes
are verified, and the upgrade path. It amends ADR-001's deferral, whose own revisit trigger
("staged behind the typed command surface with the PowerShell harness still passing") is now
met: the WPF window, the batch menu and the scripts are untouched.

### C-3 — Desktop vertical slice

| Check | Evidence |
|---|---|
| Launches as a real window | `desktop/src-tauri` builds (debug 1m13s, release 1m28s); the window opens with the expected title; screenshot at `docs/desktop-window.png` (1016×819) |
| Renders the State contract | 101,087 of 207,772 sampled pixels are the card colour, 45,429 the page colour, 268 the accent, 4,380 text — a rendered dark UI, not a blank page; every value on screen comes from one of the backend documents |
| Start / Stop / Diagnose on the real machine | `cargo test -- --ignored live_start_stop`: start → 6× `loading` polls → `running` (33/33 layers on the Radeon), diagnostics `ok`/high, soft stop returns `requires_confirmation` and leaves the server running, `-Force` stop kills 1 process and health then reports `stopped` |
| Stop contract (closes the ADR-005 gap) | Harness "Runtime adapters": a stand-in `llama-server.exe` (copy of `ping.exe`) is spawned, force-stopped, and asserted gone — guarded to **skip** whenever a real `llama-server` is already running, so it can never touch a server it did not start. The desktop's opt-in `cargo test -- --ignored live_start_stop` additionally drives the same path on a server it started itself |
| CRLF regression found and fixed | During this phase a `sed -i` edit silently converted the scripts to LF-only (which made the generated `.cmd` launchers LF-only and failed the CRLF assertion). Both scripts are re-normalised to CRLF (BOM intact) and the harness re-run green; the generated launcher bytes are asserted CRLF by the harness |
| No domain logic in the UI | Rust shells out and parses JSON only; TypeScript renders typed documents; no file reads, no output scraping |
| Works offline | Release binary embeds the interface (`bundle.active: false`, no dev server, no network calls on startup) |
| Keyboard navigation | Native `button`/`summary` controls, visible focus ring, `aria-live` status |

### C-4 — First real benchmark evidence

`benchmarks/results/2026-10-08-qwen3.5-9b.json` (schema `schema_version` 1), produced by
`benchmarks/run-local-benchmark.py` against a live server: median **13.31 tok/s** and
**235.2 ms** to first token over three runs, peak working set **10,052.8 MiB**, labels from
`-Action State` + `/props`, with the model quantisation (Q4_K_M) read from the catalogue
and the desktop's open windows recorded (Unreal Editor, Chrome, Discord, Firefox, Claude,
Freebuff). The older "45–90 tok/s" claim is now explicitly marked as not reproduced.

## Validation run (2026-10-09, Phase C final)

| Check | Command | Result |
|---|---|---|
| CRLF endings | python `(?<!\r)\n` over `Install-LlamaCpp-AMD.ps1`, `tests/Test-CommandCenter.ps1`, `Start-LlamaCpp.cmd` | 0 lone LF; script BOM intact |
| AST parse (PS 5.1) | `Parser::ParseFile`, script + tests | OK, 0 errors |
| PSScriptAnalyzer | `Invoke-ScriptAnalyzer -Severity Error`, both files | 0 errors |
| Offline harness | `powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tests\Test-CommandCenter.ps1` | **404 PASS, 0 FAIL, exit 0** |
| Batch smoke | `LLAMACPP_NO_PAUSE=1`, choices `x/5/8/0`, 5 CI markers | all present, `was unexpected at this time` = 0, exit 0 |
| Desktop release binary | `llamacpp-command-center-desktop.exe` (release) | window opens standalone, renders the State contract; screenshot `docs/desktop-window.png` |
| Stop-Runtime `-Force` (real kill) | harness (stand-in process) | stand-in killed, asserts gone, exit 0 |
| Benchmark | `benchmarks/run-local-benchmark.py` | median 13.31 tok/s, 235.2 ms TTFT over 3 runs; recorded in `benchmarks/results/2026-10-08-qwen3.5-9b.json` (Q4_K_M), and the harness now asserts every recorded result satisfies the schema with non-null measurements |

### D-1 — Settings surface (first Phase D slice)

- Backend: `-Action Settings` prints one typed document (schema_version 1): `idle_unload`
  (saved minutes, probed `--sleep-idle-seconds` capability, installed-model count) and
  `use_case` (saved value + the catalogue's allowed list). A `-SettingsPatch` JSON writes
  through the **existing** `Set-IdleSleep`/`Set-AppSetting` helpers only; its result
  document lists `applied[]`/`rejected[]` per field. StrictMode single-source note: the
  patch text parameter is `$SettingsPatchText` and parses into `$parsed` — three Prophet
  bugs found and fixed here: (1) a lowercase `$patch` local is the SAME variable as the
  `$Patch` parameter (case-insensitive) and wiped it before parse; (2) banners
  polluted stdout so the one-document contract broke (new `$script:JsonDocumentsOnly`
  switch silences the `║` writers during Settings writes; the run log still records
  every event); (3) PowerShell child invocation strips inner quotes from
  `-SettingsPatch '{"a":1}'`-style args, so the harness builds the patches as variables.
- Desktop: `get_settings`/`save_settings` commands; new Settings card renders idle
  minutes (only when capable) and the use-case picker from the backend document; Save
  shows the backend's applied/rejected summary and re-syncs the drafts from the returned
  document. Display rules (`describeUseCase`, `describeIdleCapability`, `isMinutesValid`,
  `isUseCaseValid`, `describeSettingsSave`) are pure and unit-tested.
- Validation: harness 422 PASS / 0 FAIL / exit 0 (17 new checks: read shape, empty
  admin root nulls, write-nothing-on-read, good-patch application per runtime
  capability, per-field rejection, junk input refused, values persisted to
  settings.json); cargo test 6 passed (settings read + typed refusal); vitest 21
  passed; release binary rebuilt; [desktop-window.png](../desktop-window.png) +
  [desktop-settings-scrolled.png](../desktop-settings-scrolled.png) show the live window.
- Honest limitation: the harness's temp root has no llama.cpp, so the good-patch path
  there proves the refusal rule (idle write rejected with the runtime reason, use case
  still saved); the at-capability branch is verified live on the real install via the
  probes in this session's transcript.

---
### D-2 — Model library screen (Phase D)

- Backend: `-Action Library` prints one typed document (`schema_version` 1) listing every
  catalog model with id/alias/size/tools/vision/experimental flags, its local truth
  (`downloaded`, `active`), the runtime blocker text and the fit assessment
  (EXCELLENT/GOOD/TIGHT/SLOWER/NOT RECOMMENDED + gpu_resident). Hardware failure degrades
  to null + error like `-Action State`.
- Write side: `-LibraryAction download|activate|remove -ModelId <id>` returns one typed
  result (status/detail + the refreshed library):
  **download** only validates (blocker, disk space, not-already-downloaded) and tells the
  caller to run the real transfer in its own console window; **activate** goes through
  `Switch-InstalledModel` (launchers re-generated, VS Code endpoint re-synced);
  **remove** goes through `Remove-DownloadedModel` with `-Force` scoped inside the helper
  (skips only the interactive prompt; the active-model and shared-projector refusals
  still apply). Any failure is `status: failed` with the backend's own message.
- Desktop: `get_library`/`library_change`/`download_model` commands; the Model library
  card renders size + capability badges (`2.6 GB · tools`), one state line
  (Active / Downloaded / Blocked with the reason / Not downloaded) plus fit wording, and
  exactly one operation per model derived from the backend fields — Download (with a
  GB + SHA-256 confirm), Switch/Remove (with a delete confirm), or a disabled
  "Not available on this runtime" for blocked and experimental models.
- Build-pipeline bug found and fixed in the process: building with plain
  `cargo build --release` (instead of `npm run build`) produces an exe whose window
  still loads the `devUrl` — "127.0.0.1 refused to connect" in a release binary.
  Diagnosed from the WebView2 request log; `npm run build` embeds the assets. Documented
  in `desktop/README.md`.
- Validation: harness +12 checks (434 PASS / 0 FAIL / exit 0): read document shape and
  full field set on an empty install, typed refusals for not-downloaded activate,
  unknown action (with the valid choices in the message) and missing `-ModelId`;
  live probes on the real install: 9 models with correct downloaded/active/fit/blocker
  values, blocked-model download rejected with the Ornith reason; cargo test 6 passed;
  vitest 27 passed (6 new library cases); tsc clean; release binary rebuilt with
  `npm run build`; [desktop-library.png](../desktop-library.png) shows the live window:
  Qwen3.8 27B (Switch/Remove), Qwen3.5 9B (Active, highlighted), Ornith + Gemma 4 12B
  (Blocked with reasons), Gemma 3 12B + Qwen3 8B (Download).
- Honest limitation: the download itself (a multi-GB transfer) was not run end to end
  from the screen during this slice — the validation path, the console-window handoff
  and the confirm wording are tested, and the transfer path is the same
  staged-checksum-download the harness has covered since Phase C.

---
## Blockers and gaps

- **Debug builds need the Vite dev server.** A Tauri debug binary loads `devUrl =
  http://127.0.0.1:5173`, so with `npm run dev` stopped it shows "127.0.0.1
  refused to connect". This is expected, not a product bug: use the **release**
  build (`npm run build`, then `src-tauri/target/release/llamacpp-command-center-desktop.exe`),
  which embeds the UI in `../dist` and needs no server. Documented in `desktop/README.md`.
- **No git metadata** in this checkout — no default branch/commit/sha can be
  recorded (checklist §1 evidence gap). Nothing was committed or pushed.
- **No automated UI driver** — the window's buttons are not click-automated (a
  WebView2 WebDriver setup is Phase D work). Typing `Enter` at the focused
  Start button via `SendKeys` was attempted and did not register; the same
  commands were then exercised through the app's own Rust layer instead. The
  screenshot plus `cargo test` are the substitute evidence.
- **No pixel-diff regression** for the window; the screenshot is re-taken by hand.
- **Benchmark numbers come from a loaded desktop** (Unreal Editor and friends
  open). They are honest and labelled, not clean-room.
- `code_search`/ripgrep is broken on this host; `grep -n` is used instead.

## Next independent slice

Phase D (all Phase C stop conditions met: three robustness gaps closed and
covered, ADR-006 written and reviewed, the desktop slice launching with State /
Start / Stop / Diagnose exercised against the real model, first benchmark
results recorded honestly, harness green at 400): the full model-library screen,
editor-integration screens, a settings screen, click-level UI automation, and a
clean-room re-measurement of the Qwen3.5 9B numbers.
