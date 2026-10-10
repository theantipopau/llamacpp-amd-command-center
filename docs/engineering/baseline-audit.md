# Baseline audit and feature-preservation matrix

Phase A deliverable for checklist §2. Everything below describes the repository as it
existed on **2026-10-08** before this phase's changes, verified by reading the source and
by the offline test harness (`tests/Test-CommandCenter.ps1`), not inferred from
documentation.

## 1. System inventory

| Area | What exists today | Source location |
|---|---|---|
| Entry point (beginners) | `Start-LlamaCpp.cmd` (807 lines). Opens the WPF window by default; falls back to the text menu when `LLAMACPP_TEXT_MENU`/`LLAMACPP_NO_PAUSE` is set or the window throws. | `Start-LlamaCpp.cmd` |
| Real work | `Install-LlamaCpp-AMD.ps1` (3,850 lines, 118 functions). `-Action` selects the mode; interactive menu is the default. | `Install-LlamaCpp-AMD.ps1` |
| Tests | Offline harness: parses the script with the PS 5.1 AST, loads **only function definitions**, redirects `APPDATA`/`USERPROFILE` to a temp folder, fails if the real `chatLanguageModels.json` changed. Baseline before Phase A: **177 PASS / 0 FAIL**; after Phase A changes: **225 PASS / 0 FAIL**. | `tests/Test-CommandCenter.ps1` |
| CI | CRLF check → PS 5.1 AST parse → PSScriptAnalyzer (errors only) → offline tests → batch menu smoke test. All five reproduced locally on 2026-10-08, all pass. | `.github/workflows/ci.yml` |
| Docs | README (source of truth), `docs/index.html` (GitHub Pages, kept in sync), this checklist. | `README.md`, `docs/` |

## 2. Feature map (checklist §2 items, mapped to code)

### First-run installation
- Menu `[1]` / `-Action Easy` → `Invoke-EasyStart` (line ~2236): one `YES` for the whole
  plan, sets `$script:AssumeYes`, then runs `Ensure-LlamaCppInstalled` + model download +
  optional extras (`VSCodeChat`, shortcuts, idle unload).
- `-Action Install` → hardware profile → `Ensure-LlamaCppInstalled` (line ~1178) →
  `Confirm-ModelDownload` → `Install-Model`.
- Backend choice: `Resolve-BackendChoice` — `Auto` keeps an installed backend, otherwise
  ROCm for supported Radeon dGPUs, Vulkan elsewhere; `ROCmLatest` is opt-in only and is
  rolled back if `llama-server --list-devices` does not show a dedicated ROCm GPU.
- Runtime is staged to `current\` with `current\` ↔ `current.bak` swap and restore on
  failure; `installation.json` records `tag`, `asset`, `sha256`, `installed_at`,
  `backend` (written at line ~1252).

### Hardware detection
- `Get-HardwareProfile` (line ~614): `Win32_Processor`, `Win32_ComputerSystem`, DXGI
  inventory via an in-process C# type (`Get-DxgiGpuInventory`, line ~453) with a
  registry/WMI fallback (`Get-RegistryVideoMemoryMap`, line ~590) because
  `Win32_VideoController.AdapterRAM` caps at 4 GiB.
- Produces CPU cores/threads, RAM GiB, max dedicated AMD VRAM, GPU list (name/vendor/
  integrated flag/VRAM), `Profile`, `ExecutionMode`, `ModelBudgetGiB`, `RocmRecommended`,
  `VulkanLoader`.
- The Ryzen iGPU is **never** used automatically: `Select-PrimaryLlamaDevice` pins the
  dedicated Radeon by name; single-GPU results in no `--device` flag (regression-tested).

### Model download
- Catalog: `Get-ModelCatalog` (line ~383), 9 models, all primary files published by
  `ggml-org`/verified orgs on Hugging Face, metadata pinned in
  `tests/fixtures/catalog-evidence.json` (Phase A).
- `Get-HfRepository`/`Get-HfFileDescriptor` resolve the pinned revision and Git LFS
  SHA-256 immediately before download; `Get-VerifiedDownload` (line ~961) downloads with
  `curl --continue-at -` into a `.part` file, verifies **size then SHA-256**, keeps the
  `.part` on failure for resume, and records AMD's package hash locally because AMD
  publishes no sidecar.
- `Install-Model` (line ~1804) writes into `models\` under the install root;
  `active-model.json` is written by `Set-ActiveModel` (line ~1634).

### Server start/stop
- Generated launchers (`New-Launchers`, line ~1462): `Start-LlamaCpp.cmd` (start),
  `Chat.cmd`, `Gaming-Mode.cmd` in the install folder; arguments come from
  `Get-ServerArguments` (line ~1411) — the **single source of truth** (also used by
  `Start-ActiveServer`, line ~1984).
- Lifecycle observed through `Get-CommandCenterStatus` (line ~2011): `stopped` →
  `loading` (process exists) → `running` (`/health` returns `ok`). Readiness end-to-end
  check with a real generation: `Test-LocalServer` (line ~2324).
- Stop paths: `Gaming-Mode.cmd` (menu [4]) and idle unload
  (`--sleep-idle-seconds`, `Set-IdleSleep`). Tests only ever stop what they started;
  **this project never stops a user's running server** (working rule).
- Ownership: the launcher records `LLAMA_EXIT`; stop scripts target only the
  install-folder launchers' process, not arbitrary PIDs.

### Editor setup
- VS Code Copilot Chat: `Install-VsCodeChatEndpoint` (line ~2410) writes the documented
  `chatLanguageModels.json` custom-endpoint provider, backs up to
  `*.command-center.bak`, keeps unrelated providers, refuses malformed/JSONC input, and
  `Sync-VsCodeChatEndpoint` (line ~1840) re-syncs after a model switch **only when the
  entry already exists**.
- Continue: `Install-ContinueConfig` (line ~2562) owns one commented managed block in
  `config.yaml`, falls back to printing instructions when a pre-existing `models:` list
  makes a safe merge impossible.
- llama-vscode: `Install-LlamaVscodeSettings` (line ~2653) sets only its own keys in
  `settings.json`, refuses JSONC, backs up first.
- GitHub Copilot itself is never modified.

### Status surfaces
- `Get-CommandCenterStatus` returns the 7-field `|` line read by `read_status` in the
  batch menu (`tokens=1-7`).
- `Get-GuiState`/`Set-GuiState` (pure display logic for the WPF window) parse that line;
  tests drive them (skipped on non-STA threads).
- `Get-InstalledModelList` returns `number|id|name|state` (`active`/`blocked`/`ready`).

## 3. File ownership (user-owned vs application-owned)

| File / location | Owner | Notes |
|---|---|---|
| `%LOCALAPPDATA%\Programs\llama.cpp\server-args.user.json` | **User** | Read and merged last; never written by the project. |
| `%APPDATA%\Code\User\settings.json` (llama-vscode keys) | **User** (shared) | Project touches only its own keys; refuses JSONC; backup first. |
| Continue `config.yaml` | **User** (shared) | Project owns one marked block only. |
| Everything under `%LOCALAPPDATA%\Programs\llama.cpp\` | **Application** | `current\`, `models\`, `active-model.json`, `settings.json`, generated launchers, `logs\`, `installation.json`, `state-history\`, `.sha256` records. |
| `%LOCALAPPDATA%\Programs\llama.cpp\state-history\` | **Application** | State snapshots; the newest `$script:StateSnapshotKeep` (40) files are kept, older ones pruned automatically; a full uninstall removes them with the install. |
| `catalog\*.json` next to the scripts | **Shipped data** (ADR-004) | Single source of truth loaded at runtime; never written at runtime; edited only as catalogue changes with a `catalog_version` bump. |
| `chatLanguageModels.json` `llama.cpp local` provider | **Application** (within user's file) | Backup `*.command-center.bak` on every write; removal deletes only that provider. |
| Desktop shortcuts `AI Chat (local).lnk`, `AI Off (gaming mode).lnk` | **Application** | `Remove-DesktopShortcuts` deletes only shortcuts whose target is inside this install. |

Migration requirement: an existing user keeps `models\`, `active-model.json`,
`settings.json` and `server-args.user.json` untouched across updates;
`Ensure-LlamaCppInstalled` swaps only `current\`. Uninstall (`Remove-Installation`,
line ~2527) requires `DELETE`/`-Force` and stops only this project's server.

## 4. Security / robustness audit (checklist §2 items)

| Item | Finding |
|---|---|
| Quoting, spaces, Unicode paths | `-LiteralPath` used throughout; launchers quote every path; argument arrays (never shell-concatenated user input) in `Get-ServerArguments`; batch code keeps `%PS_RUN%`/install path outside parenthesised blocks. Test harness runs from a temp path; **no dedicated space/Unicode-path test exists yet** (gap → validation matrix). |
| Environment variables | `LLAMACPP_NO_PAUSE`, `LLAMACPP_TEXT_MENU` read defensively; test harness sets `$script:` values at file top because it loads functions only. |
| Process ownership / stale PID | Status infers state from `Get-Process llama-server` + `/health`; no PID file exists (gap: PID-file-based ownership is a Phase B/C item). Stop actions target the known launcher only. |
| Network binding | `--host 127.0.0.1` hard-coded in `Get-ServerArguments` (line 1422); all URLs in code are `127.0.0.1`. No LAN/0.0.0.0 path exists. |
| API authentication | **No `--api-key` is emitted** — acceptable only because binding is loopback-only. Recorded as a Phase C/D item if any non-loopback option is ever added. |
| Logs | Run logs in `logs\` with transcript + JSONL events; `Protect-LogText` redacts before writing. |
| Checksum / partial downloads | Size + SHA-256 verified; `.part` resume; AMD sidecar hash recorded locally (see upstream evidence). |
| Privilege | No `#Requires -RunAsAdministrator`, no elevation prompts anywhere; installs are per-user under `LOCALAPPDATA`. |
| Alias propagation | `--alias` comes from the catalog; VS Code entry uses the catalog alias (`qwen3.5:9b`); status line field 1 carries the alias; `Sync-VsCodeChatEndpoint` updates it on switch. |
| JSON / JSONC / YAML | JSON written BOM-free via `[IO.File]::WriteAllText(..., UTF8Encoding($false))`; JSONC detected and refused (commented `settings.json` → print instructions); YAML handled only inside the marked Continue block. |
| Unknown-maintenance dependencies | `curl.exe` (ships with Windows 10+), `WScript.Shell` COM, PSScriptAnalyzer (CI only), Hugging Face + GitHub + repo.radeon.com endpoints. All have fallbacks or are CI-only. Alternative engines (Strata, Lemonade, llama-swap) remain **deferred/experimental**, isolated from the stable path. |

## 5. Baseline test capture

- Command: `powershell -NoProfile -ExecutionPolicy Bypass -File .\tests\Test-CommandCenter.ps1`
- Baseline (pre-Phase A, 2026-10-08): **177 PASS, 0 FAIL, exit 0**.
- After Phase A changes (fixture-backed catalog evidence + Gemma 4 fix): **225 PASS,
  0 FAIL, exit 0**.
- Full CI-equivalent set re-run after every change: CRLF (3 files), PS 5.1 AST,
  PSSA errors-only (0 issues), harness, batch smoke — all pass. Exact outputs are
  recorded in `docs/engineering/implementation-status.md`.

## 6. Feature-preservation matrix

Columns per checklist §2: existing behaviour | source location | risk | replacement
component | migration test | status.

| Existing behaviour | Source location | Risk if lost | Replacement component | Migration / regression test | Status |
|---|---|---|---|---|---|
| Interactive text menu (11 options) | `Start-LlamaCpp.cmd` | Beginners lose the only no-terminal path | Kept as-is; GUI is the front door with menu fallback | Batch smoke test (CI + local): menu renders, health check runs, clean exit | Preserved |
| WPF window (hero status, start/stop, memory bar, use-case picker, gaming switches) | `Get-GuiXaml` (~2864), `Show-CommandCenterWindow` (~3364) | Product becomes terminal-only | Kept; `Get-GuiState`/`Set-GuiState` remain the pure display core | Harness GUI tests (STA only) drive `Set-GuiState` through all five modes | Preserved |
| Hardware scan (CPU/RAM/DXGI VRAM, integrated flag) | `Get-HardwareProfile` (~614) | Wrong model recommendations, false ROCm choice | Kept; future hardware-inventory service must reuse DXGI + registry fallback | Harness asserts recommendation outcomes on a simulated 16 GB Radeon profile | Preserved |
| Backend selection with ROCm rollback | `Resolve-BackendChoice`, `Ensure-LlamaCppInstalled` (~1178) | Broken installs after failed upgrade | Kept; `ROCmLatest` stays opt-in with device check + rollback | Harness: `Get-LlamaDeviceList` rollback logic, asset-name resolvers | Preserved |
| Verified model download (size + SHA-256, resumable `.part`) | `Get-VerifiedDownload` (~961), `Get-HfFileDescriptor` (~1050) | Corrupt weights reach the GPU | Kept; a future download manager must keep size+hash+resume contract | Harness covers digest helpers; **network interruption test still missing** → validation matrix | Preserved (gap noted) |
| 9-model catalogue with pinned revisions | `Get-ModelCatalog` (~383) | Users download non-existent files (Phase A found exactly this bug for Gemma 4) | Kept; catalogue now backed by `tests/fixtures/catalog-evidence.json` | Harness section "Catalog matches the recorded upstream evidence" asserts repo/file/projector/size for all 9 | Preserved + hardened |
| Use-case picker | `Get-ModelForUseCase`, `Get-UseCaseCatalog` (~795) | Onboarding asks confusing questions | Kept; persists `use_case` in `settings.json` | Harness asserts chat/coding/images/fast/quality picks per hardware profile | Preserved |
| Launcher generation with 2-slot 64k pool, `--reasoning` policy, device pin | `New-Launchers` (~1462), `Get-ServerArguments` (~1411) | Server flags regress silently | Kept as single source of truth; no duplicate argument builders allowed | Harness checks every catalog model's generated block: carets, `--jinja`, `--parallel 2`, reasoning on/off, `--device` | Preserved |
| Server readiness + functional self-test (real generation, tool call) | `Test-LocalServer` (~2324) | "Running" claimed from process presence | Kept; Phase B supervisor must keep `/health` + generation readiness | Self-test is invoked by CI smoke indirectly; harness cannot run a server (offline) | Preserved (needs live test → validation matrix) |
| Idle unload + gaming mode | `Set-IdleSleep`, `Gaming-Mode.cmd` | Gamers lose VRAM reclamation | Kept; policy must stay visible and request-aware | Harness: `Set-IdleSleep` writes `settings.json`, regenerates launchers | Preserved |
| Desktop shortcuts (create/remove, scoped) | `New-DesktopShortcuts`/`Remove-DesktopShortcuts` (~2201) | Removal could delete user's own shortcuts | Kept; removal only when target is inside install | Harness creates a foreign same-named shortcut and asserts it survives | Preserved |
| VS Code Copilot endpoint (backup, merge, sync) | `Install-VsCodeChatEndpoint` (~2410), `Sync-VsCodeChatEndpoint` (~1840) | User's VS Code settings destroyed | Kept; any new integration must match backup+merge+refuse-unsafe contract | Harness: unrelated providers kept, backup written, malformed/JSONC refused, real profile untouched | Preserved |
| Continue managed block | `Install-ContinueConfig` (~2562) | YAML corruption | Kept; fallback prints instructions when merge unsafe | Harness covers managed-block add/update/remove + unsafe-merge fallback | Preserved |
| llama-vscode keys | `Install-LlamaVscodeSettings` (~2653) | Shared `settings.json` clobbered | Kept; only own keys, refuse JSONC | Harness: comments preserved, unrelated keys kept | Preserved |
| Status line (7 fields) for scripts/batch | `Get-CommandCenterStatus` (~2011) | Batch menu and scripts break | Kept; **contract frozen**: 7 `|` fields, `read_status` reads 1-7 | Harness asserts exactly 7 fields; batch smoke asserts `read_status` behaviour | Preserved (contract test exists) |
| Installed-model list (`active`/`blocked`/`ready`) | `Get-InstalledModelList` (~1761) | Blocked models become selectable and fail at start | Kept; blocker logic (`Get-ModelRuntimeBlocker`) unchanged | Harness asserts Ornith blocked on b8407, active/ready states | Preserved |
| Run logging with redaction | `Start-RunLogging`/`Write-RunLogEvent` (~184) | Diagnosability lost or secrets leaked | Kept; structured JSONL is the base for future diagnostics service | Harness skips logging via empty paths (documented at top of test file) | Preserved |
| Uninstall with confirmation, scoped deletions | `Remove-Installation` (~2527) | Data loss or leftovers | Kept; requires `DELETE`/`-Force`, stops only own server | Harness: removal of endpoints/shortcuts scoped to managed entries | Preserved |
| Batch menu status/guide strings | `Start-LlamaCpp.cmd` `read_status`, THE FIVE STEPS | CI smoke fails | Kept; any status-field change must update `read_status` **and** smoke greps together | CI batch smoke test (5 greps) | Preserved |

## 7. Deliberate behavioural changes made in Phase A

| Change | Why | Replaced what | Test |
|---|---|---|---|
| Catalogue `gemma4-12b` file `gemma-4-12B-it-Q4_K_M.gguf` → `gemma-4-12B-it-Q4_0.gguf`, `ApproxGiB` 7.5 → 6.87 (README/docs synced to 6.9 GB) | The Q4_K_M file does not exist upstream (HF API 404, verified 2026-10-08); download would fail after user confirmation | A hardcoded filename that was never verified | Fixture assertion `gemma4-12b` file + ApproxGiB tolerance |
| `$script:AmdRocmPackageCheckedOn` → 2026-10-08 (script + test) | AMD directory index re-checked; 7.2.1 still newest, byte size matches | Stale freshness date that would trigger a spurious re-check warning | Freshness-window tests (fresh + stale dates) |
| New: `tests/fixtures/catalog-evidence.json` + evidence-matching test section | Pin every catalog file to a verified revision/size/SHA-256 so catalogue drift fails CI | Trust in unverified catalog constants | 9-model evidence assertions (48 new checks) |
| New: `docs/research/upstream-evidence.md` | Checklist §1 requires a per-claim evidence record | Scattered research notes | N/A (document) |
| New read-only action `-Action State` (typed JSON, `schema_version` 1, ADR-003) plus shared helpers `Get-ServerState`/`Get-VsCodeChatState`/`Get-DesktopShortcutState`/`Get-InstalledModelStates`, now consumed by `Get-CommandCenterStatus` and `Get-InstalledModelList` | Give scripts and the future GUI one typed contract instead of splitting pipe-delimited strings; helpers keep the string and JSON contracts from drifting | Status-line and list-line logic duplicated inside each string builder (output format unchanged) | 35 new checks: schema/typed fields, JSON round-trip, status ↔ state drift equality, simulated hardware-failure degradation, subprocess run proving exit 0 + no writes |
| Status line and window reparsed onto a typed core: new `Get-CoreApplicationState`, `Get-CommandCenterStatus` reduced to a pure projection, `Get-GuiState` reads the typed object (no more `-split '\\|'`) | One authoritative data source (user directive); cmd.exe cannot parse JSON, so the 7-field line remains its serialization | Window token-splitting plus duplicate `active-model.json`/`installation.json` reads in each consumer | 7 new checks: state is a superset of core, `idle_minutes` matches the validator, line and window equal the core verbatim; batch smoke still passes |
| New snapshot subsystem: `Save-StateSnapshot`/`Get-StateSnapshots`/`-Action Snapshot` plus auto-capture before `Activate`/`Install`/`Update`/`Uninstall`/`RemoveModel`/`Easy`; newest 40 kept in `state-history\` | Diagnostics, rollback forensics and future benchmarking need history (user directive) | No history of what the install looked like before a change | 10 new checks: retention prune, newest-first ordering, reasons, parseability; subprocess proves manual write and capture-**before**-change (`before-Activate` exists though the action then failed) |
| `Get-HardwareProfile` expanded with typed `cpu`, `memory`, `detection` (`gpu_source` + `confidence`), `support` (level/confidence/reasons), `recommendation` (backend/model_id/confidence/reason), `HasDiscreteAmdGpu`, per-GPU `Source`/`VramConfidence` — all additive | Normalise CPU/GPU/RAM detection into a typed model with support verdict, detection confidence and a recommendation (user directive); no field renamed, so `schema_version` stays 1 | Flat untyped profile with no provenance for its numbers | 11 new checks: real-machine structure and allowed value sets, recommendation equals `Get-RecommendedModel`, pure verdicts on fakes (discrete/no-Radeon/iGPU-only) |
| Catalogue data moved from inline script literals to `catalog/*.json` (`models`, `runtimes`, `hardware_profiles`, `compatibility`) loaded at runtime with no embedded copy; release ZIP ships the folder | Versioned catalogue system (user directive, ADR-004): one source, reviewable data diffs, machine-readable for future tooling; missing files fail loudly | Hardcoded arrays/literals inside the script; two-file distribution | 11 new checks: schema versions, pinned AMD facts, blocker behaviour identical to the old inline logic, missing-file error; all prior catalogue/evidence/picker tests now validate the shipped files |

No user data, default, prompt behaviour, or file format was changed in Phase A; the status line (7 fields) and the installed-model list (`number\|id\|name\|state`) still print exactly what the batch menu parses.

## 8. Deliberate behavioural changes made in Phase B

| Change | Why | Replaced what | Test |
|---|---|---|---|
| New read-only actions `-Action Recommend` and `-Action Diagnose` (early exits printing one typed JSON document each, before run logging) | Hardware intelligence layer: machine-readable advice and health with no GUI and no string parsing (ADR-005, user directive) | Nothing — purely additive; `Advisor`/`Diagnostics` text actions unchanged | 35 new checks (19 engine, 16 diagnostics) plus live subprocess runs of both actions on the real install |
| New engine functions `Get-WorkloadRecommendations`/`Get-RecommendationDocument`/`Resolve-RecommendationStatus`/`Get-RecommendationConfidence` deriving every verdict from `catalog/*.json` + the hardware profile | Catalogue-driven recommendation with the four statuses and confidence, zero hardcoded GPU names (user directive) | Single-model `Get-RecommendedModel` advice (still used internally; output format unchanged) | GPU-name-independence test: two fake profiles differing only in GPU name produce byte-identical JSON |
| New runtime adapter surface `Get-RuntimeAdapter(s)`/`Get-RuntimeCapabilities`/`Test-RuntimeAdapter`/`Start-Runtime`/`Stop-Runtime`/`Get-RuntimeHealth` as the runtime entry points; llama.cpp active, Lemonade/Strata structured stubs returning `not_implemented` + catalogue `unknowns` | Stop assuming llama.cpp is the only future runtime; stubs document unknowns instead of guessing (ADR-005) | Direct scattered `Start-ActiveServer`/`Get-ServerState` calls for start/stop/health decisions (those remain the underlying implementations) | 13 checks incl. "stopping without -Force never kills" (process count unchanged). **Gap: `Stop-Runtime -Force` kill path deliberately untested.** |
| `Resolve-HardwareSupport` now guards optional fields (`HasDiscreteAmdGpu`, `VulkanLoader`) by property-presence check instead of unconditional read | Partial hardware objects are legitimate callers (adapter validation passes minimal fakes); under `Set-StrictMode` an unconditional read throws | Unconditional property reads (worked only because every in-tree caller passed the full profile) | The iGPU-only/no-loader verdict tests still pass; a partial fake now degrades instead of throwing |
| `catalog/runtimes.json` grew `adapters[]` and `llamacpp_capabilities[]`; `catalog/models.json` grew `Experimental` (true only on Ornith) | Runtime adapter registry and capability shape must be data, not code (ADR-004/ADR-005); experimental status must be a catalogue fact | Implicit knowledge of which flags the server supports and which model is experimental | Catalogue shape tests (3), capability flags verified against the flags `Get-ServerArguments` actually emits, experimental-only-on-Ornith test |
| New `benchmarks/` contract: `benchmark.schema.json` (all measurements `number\|null`), `template.json` (all `null`), `README.md` no-fabrication rules | Stable benchmark contract to populate later; Phase B forbids invented numbers (user directive) | No benchmark storage existed | 5 checks: template matches schema exactly, every measurement field is `null` |

No user data, default, prompt behaviour, batch-menu output or existing file format was changed in Phase B; all new behaviour is behind new `-Action` values and new functions.
